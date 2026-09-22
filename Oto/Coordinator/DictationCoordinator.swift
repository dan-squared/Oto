//
//  DictationCoordinator.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation
import os

/// Sole owner of dictation session state (02: "Only the coordinator may
/// move between these states"). Views, shortcut monitors, and services emit
/// intent; they never start audio, insert text, or decide completion.
///
/// Rules implemented verbatim from 02 §Finish and cancel rules:
/// - finish and cancel are mutually exclusive and idempotent;
/// - every asynchronous result is checked against the active session ID
///   before it can update state or insert text (no lock is held across
///   `await` — actor reentrancy is made safe by re-checking identity
///   after every suspension);
/// - release during preparation means "finish when ready", never cancel.
actor DictationCoordinator {
    private(set) var state: DictationState = .idle

    /// Transcript preserved when insertion fails or the target is gone.
    /// Cleared when a new session begins. The production menu copies it
    /// until the Flow Bar (Phase 6) surfaces it.
    private(set) var recoveryTranscript: Transcript?

    private let audio: any AudioCaptureServing
    private let speech: any SpeechServing
    private let targetService: any TargetCapturing
    private let inserter: any TextInserting
    private var pipeline: TranscriptPipeline
    /// Optional history sink (Phase 6A). Nil in tests and when history is
    /// off — recording is a no-op either way. Set once at app composition.
    private let history: HistoryStore?

    private var currentSessionID: UUID?
    private var sessionContext: SessionContext?
    private var finishRequested = false
    /// When the current session entered recording (silent-skip duration
    /// guard). Nil until the starting→recording transition; cleared on
    /// every begin so a stale instant can never green-light a new session.
    private var recordingBeganAt: ContinuousClock.Instant?
    /// Silent-skip gate (no loader for voice-less sessions): peak under
    /// −40 dBFS with enough recorded audio to trust it. Conservative
    /// starting point — speech peaks ~0.1–0.5, mic idle noise ~0.001;
    /// the device matrix confirms or lowers. Tests pin whatever ships.
    nonisolated static let silencePeakThreshold: Float = 0.01
    /// Short sessions always take the full path — a quick quiet word
    /// (or not-yet-arrived buffers) must never die silent.
    nonisolated static let minimumRecordedAudio: Duration = .milliseconds(500)
    /// Trailing-edge settle: the tap's last buffers flush just after
    /// stop, so a word in the final instant still counts. Costs time
    /// only in the case that saves it (an already-loud peak returns
    /// before the settle, short sessions never reach it).
    nonisolated static let trailingEdgeSettle: Duration = .milliseconds(120)
    /// Mic fast-fail gate (no-flash workstream): when denied, preparation
    /// fails with `.microphoneDenied` before audio starts. Production reads
    /// the synchronous record permission on the MainActor (this actor is
    /// not the MainActor — default project isolation is); tests inject a
    /// pure override so they never touch TCC (nil = real read).
    private let micDeniedOverride: (@Sendable () -> Bool)?
    /// Phase 7 media duck (spike-green): muted output while recording.
    /// Nil in tests and when unwired — every call site is optional, so
    /// duck-off sessions behave exactly as before. Injected (protocol)
    /// so coordinator tests never touch the HAL.
    private let mediaDuck: (any MediaDucking)?

    /// Phase 1 observability: state transitions are the only visible trace
    /// of fake sessions (no Flow Bar yet). Watch in Console.app.
    private let log = Logger(subsystem: "app.Oto", category: "coordinator")

    init(
        audio: any AudioCaptureServing,
        speech: any SpeechServing,
        targetService: any TargetCapturing,
        inserter: any TextInserting,
        pipeline: TranscriptPipeline = TranscriptPipeline(),
        history: HistoryStore?,
        micDeniedOverride: (@Sendable () -> Bool)? = nil,
        mediaDuck: (any MediaDucking)? = nil
    ) {
        self.audio = audio
        self.speech = speech
        self.targetService = targetService
        self.inserter = inserter
        self.pipeline = pipeline
        self.history = history
        self.micDeniedOverride = micDeniedOverride
        self.mediaDuck = mediaDuck
    }

    /// Live rule refresh from the dictionary store (Writing pane saves).
    /// Value copy: the background finalize path keeps using plain arrays.
    func setDictionaryRules(_ rules: [DictionaryRule]) {
        pipeline = TranscriptPipeline(dictionaryRules: rules)
    }

    // MARK: - Intents

    /// Hold-to-talk key-down (first non-repeat). Returns the session ID,
    /// or nil when a session is already active (repeats ignored).
    @discardableResult
    func beginHold() -> UUID? {
        begin(interaction: .holdToTalk)
    }

    /// Hands-free toggle. First press begins, second press finishes the
    /// same session through the shared pipeline. Key-up and repeats are
    /// the monitor's business — they never reach this method.
    @discardableResult
    func toggleHandsFree() async -> UUID? {
        if let context = sessionContext,
           context.interaction == .handsFree,
           currentSessionID == context.id,
           state.canFinish
        {
            await finish(context.id)
            return context.id
        }
        return begin(interaction: .handsFree)
    }

    /// Hold-to-talk key-up, hands-free second press, or Flow Bar stop.
    /// During `starting` this arms finish-when-ready (02 rule 4);
    /// otherwise it runs finalization. Idempotent.
    func finish(_ sessionID: UUID) async {
        guard let context = sessionContext,
              context.id == sessionID,
              currentSessionID == sessionID,
              state.canFinish
        else { return }

        switch state {
        case .starting:
            // Release during preparation: finish when ready, do not cancel.
            finishRequested = true
            log.info("finish requested during starting \(sessionID.uuidString.prefix(8), privacy: .public) — will finalize when ready")
        case .recording:
            state = .finalizing(context)
            log.info("finalizing \(sessionID.uuidString.prefix(8), privacy: .public)")
            await finalizeSession(sessionID: sessionID, context: context)
        case .idle, .finalizing, .inserting, .completed, .cancelled, .failed:
            break
        }
    }

    /// Escape / Flow Bar cancel / monitor reset. Always wins over an
    /// in-flight finalize ("cancellation wins", 02 timeline). Idempotent.
    func cancel(_ sessionID: UUID) async {
        guard let context = sessionContext,
              context.id == sessionID,
              currentSessionID == sessionID,
              state.canCancel
        else { return }

        // Invalidate first: any suspended work re-checks this and
        // discards its result instead of touching state or inserting.
        // Note: teardown of an in-flight `start` that completes after
        // this point is the real services' responsibility (Phase 2);
        // fakes hold no resources.
        currentSessionID = nil
        state = .cancelled(context)
        log.info("cancelled \(sessionID.uuidString.prefix(8), privacy: .public)")
        await audio.cancel()
        await speech.cancel()
        await restoreMedia(sessionID: sessionID)
    }

    /// One-line human-readable summary of the current/terminal state, for
    /// the menu status line only. Real status UI is the Flow Bar
    /// (Phase 6); this query exists so sessions stay observable
    /// without log-diving. Never includes transcript text.
    func recoveryText() -> String? {
        recoveryTranscript?.text
    }

    func lastSessionSummary() -> String {
        switch state {
        case .idle:
            return "idle — no session yet"
        case .starting(let context):
            return "starting (\(context.interaction))…"
        case .recording(let context):
            return "recording (\(context.interaction))…"
        case .finalizing:
            return "finalizing…"
        case .inserting:
            return "inserting…"
        case .completed(let context):
            return "completed (\(context.interaction))"
        case .cancelled:
            return "cancelled — nothing inserted"
        case .failed(_, let failure):
            let reason: String
            switch failure {
            case .audioCapture: reason = "audio capture failed"
            case .speechPreparation: reason = "speech preparation failed"
            case .microphoneDenied: reason = "microphone denied"
            case .noAudioCaptured: reason = "no audio captured — check the microphone"
            case .targetGone: reason = "target app closed"
            case .insertionFailed(let detail): reason = "insertion failed (\(detail))"
            }
            let kept = recoveryTranscript == nil ? "" : ", transcript kept"
            return "failed: \(reason)\(kept)"
        }
    }

    // MARK: - Private

    private func begin(interaction: InteractionMode) -> UUID? {
        guard state.isTerminal else { return nil }

        // Target is captured synchronously here, before any Oto UI could
        // appear or activation could change — never re-resolved later.
        let target = targetService.capture()
        let context = SessionContext(
            id: UUID(),
            startedAt: ContinuousClock().now,
            target: target,
            targetScreen: target.displayID,
            interaction: interaction
        )
        sessionContext = context
        currentSessionID = context.id
        finishRequested = false
        recordingBeganAt = nil
        recoveryTranscript = nil
        state = .starting(context)
        log.info("begin \(context.id.uuidString.prefix(8), privacy: .public) mode=\(String(describing: interaction), privacy: .public) target=\(context.target.bundleIdentifier ?? "?", privacy: .public)")

        Task { await self.runPreparation(sessionID: context.id) }
        return context.id
    }

    private func runPreparation(sessionID: UUID) async {
        guard currentSessionID == sessionID,
              let context = sessionContext,
              context.id == sessionID
        else { return }

        // Mic fast-fail (no-flash workstream): denial is knowable before
        // any audio spins up — fail without starting the engine so neither
        // work nor pill pixels are spent on a session that cannot record.
        // Cancel still wins (identity re-check, same as every path here).
        let micDenied: Bool
        if let override = micDeniedOverride {
            micDenied = override()
        } else {
            micDenied = await MainActor.run {
                PermissionsManager().microphoneStatus() == .denied
            }
        }
        if micDenied {
            guard currentSessionID == sessionID else { return }
            currentSessionID = nil
            state = .failed(context, .microphoneDenied)
            return
        }

        do {
            try await audio.start()
        } catch {
            guard currentSessionID == sessionID else { return }
            currentSessionID = nil
            state = .failed(context, .audioCapture(error.localizedDescription))
            return
        }

        guard currentSessionID == sessionID else { return }

        do {
            try await speech.prepare()
        } catch {
            guard currentSessionID == sessionID else { return }
            await audio.stop()
            currentSessionID = nil
            // Distinct mic recovery (02 table): readiness errors map
            // precisely, everything else keeps the preparation bucket.
            if let readiness = error as? SpeechReadiness,
               readiness == .microphoneDenied
            {
                state = .failed(context, .microphoneDenied)
            } else {
                state = .failed(context, .speechPreparation(error.localizedDescription))
            }
            return
        }

        guard currentSessionID == sessionID,
              let context = sessionContext,
              context.id == sessionID
        else { return }

        if finishRequested {
            state = .finalizing(context)
            await finalizeSession(sessionID: sessionID, context: context)
            return
        }

        guard case .starting = state else { return }
        state = .recording(context)
        recordingBeganAt = ContinuousClock().now
        await mediaDuck?.duck(sessionID: sessionID)
        // Suspension crossed: a cancel may have won mid-duck. Re-check
        // identity — a late duck with no owner restores immediately, so
        // no path can leave the user muted.
        guard currentSessionID == sessionID else {
            await restoreMedia(sessionID: sessionID)
            return
        }
    }

    /// Silent-skip decision: true only for whole-session silence with
    /// enough recorded audio to trust the peak. Short sessions and any
    /// session with voice always return false (full loader path).
    /// Identity is re-checked by the caller after this suspends.
    private func shouldSkipTranscription(context: SessionContext) async -> Bool {
        guard let began = recordingBeganAt,
              began.duration(to: ContinuousClock().now) > Self.minimumRecordedAudio
        else { return false }
        if await audio.sessionPeakAmplitude() >= Self.silencePeakThreshold {
            return false
        }
        try? await Task.sleep(for: Self.trailingEdgeSettle)
        return await audio.sessionPeakAmplitude() < Self.silencePeakThreshold
    }

    /// Media-duck restore funnel: every terminal path calls this, so no
    /// session can end muted. Nil-duck and already-restored are no-ops.
    private func restoreMedia(sessionID: UUID) async {
        await mediaDuck?.restore(sessionID: sessionID)
    }

    private func finalizeSession(sessionID: UUID, context: SessionContext) async {
        await audio.stop()

        guard currentSessionID == sessionID else { return }

        // Silent-skip: whole-session silence completes without
        // transcription, so the loader never exists. Late speech always
        // counts — this reads the full-session peak once, after the last
        // buffer is captured, never on a timer mid-session.
        if await shouldSkipTranscription(context: context) {
            guard currentSessionID == sessionID else { return }
            await restoreMedia(sessionID: sessionID)
            currentSessionID = nil
            state = .completed(context)
            log.info("completed (silent, loader skipped) \(sessionID.uuidString.prefix(8), privacy: .public)")
            return
        }
        // The settle above suspends: cancel may have won while waiting.
        guard currentSessionID == sessionID else { return }

        let raw: String
        do {
            raw = try await speech.finish()
        } catch {
            guard currentSessionID == sessionID else { return }
            await restoreMedia(sessionID: sessionID)
            currentSessionID = nil
            // Dead mic surfaces honestly: no transcript exists to keep,
            // so recovery stays empty and the reason names the mic.
            if let sessionError = error as? SpeechSessionError,
               case .noAudioCaptured = sessionError
            {
                state = .failed(context, .noAudioCaptured)
            } else {
                state = .failed(context, .speechPreparation(error.localizedDescription))
            }
            return
        }

        guard currentSessionID == sessionID,
              case .finalizing = state
        else { return }

        let clean = pipeline.process(raw, for: context.target)
        guard !clean.isEmpty else {
            // Empty final: complete without insertion (02 timeline).
            await restoreMedia(sessionID: sessionID)
            currentSessionID = nil
            state = .completed(context)
            log.info("completed (empty, no insertion) \(sessionID.uuidString.prefix(8), privacy: .public)")
            return
        }

        // Opt-in recall: final text only (never audio/partials/clipboard).
        // The store itself no-ops when history is off. Recorded once here so
        // inserted, target-gone, and insertion-failed finals are all kept.
        if let history {
            await history.record(finalText: clean, bundleID: context.target.bundleIdentifier)
            // Suspension crossed actor isolation: a cancel may have won
            // while recording. Re-check identity before touching targets.
            guard currentSessionID == sessionID else { return }
        }

        // Liveness over freshness: a dead target keeps the transcript in
        // recovery. Never substitute whatever is frontmost now.
        let alive = await targetService.isAlive(context.target)
        guard currentSessionID == sessionID else { return }
        guard alive else {
            await restoreMedia(sessionID: sessionID)
            currentSessionID = nil
            recoveryTranscript = Transcript(text: clean)
            state = .failed(context, .targetGone)
            log.info("failed target-gone, transcript preserved \(sessionID.uuidString.prefix(8), privacy: .public)")
            return
        }

        state = .inserting(context)
        let result = await inserter.insert(clean, into: context.target)

        guard currentSessionID == sessionID else { return }
        await restoreMedia(sessionID: sessionID)
        currentSessionID = nil
        switch result {
        case .inserted:
            state = .completed(context)
            log.info("completed, inserted \(clean.count, privacy: .public) chars into \(context.target.bundleIdentifier ?? "?", privacy: .public)")
        case .recoverableFailure(let reason):
            // No false success: the transcript stays recoverable.
            recoveryTranscript = Transcript(text: clean)
            state = .failed(context, .insertionFailed(reason))
            log.info("failed insertion, transcript preserved \(sessionID.uuidString.prefix(8), privacy: .public) reason=\(reason, privacy: .public)")
        }
    }
}
