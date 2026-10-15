//
//  AppleSpeechService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
import Speech
import os

/// Runtime failures from the live speech path. `prepare()` throws
/// `SpeechReadiness` (never downloads); `finish()` may throw this.
enum SpeechSessionError: Error, Sendable {
    case excessiveAudioLoss(dropped: Int)
    case engineFailure(String)
    /// Zero buffers reached the feeder all session (dead/zombie mic):
    /// fail loud instead of completing empty (bt-sco-flap.md).
    case noAudioCaptured
}

extension SpeechSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .excessiveAudioLoss(let dropped):
            return "Too much audio was lost (\(dropped) buffers dropped)."
        case .engineFailure(let detail):
            return "Speech engine failed (\(detail))."
        case .noAudioCaptured:
            return "No audio reached the microphone."
        }
    }
}

// PROBE-ONLY (P2 plan §Probe): temporary flag for the analyzer-reuse probe.
// REMOVE with the PROBE blocks below after hardware reports. Default false =
// the entire probe path is dead code; never enabled in tests.
struct AnalyzerReuseProbe: Sendable, Equatable {
    var enabled: Bool

    nonisolated static let enabledKey = "app.Oto.probeAnalyzerReuse"

    nonisolated static func armed(defaults: UserDefaults = .standard) -> AnalyzerReuseProbe {
        AnalyzerReuseProbe(enabled: defaults.bool(forKey: enabledKey))
    }
}

/// Realtime feeder: the ONLY object the audio thread touches. Converter +
/// continuation live behind one lock; session state stays on the actor.
/// `feed` drops (never blocks) when no session is configured.
///
/// Concurrency (Swift 6, default MainActor isolation): the lock is the
/// isolation. Shared mutable state is `nonisolated(unsafe)` — manually
/// synchronized memory, every access under `lock` — and the methods are
/// plain checked `nonisolated`. `unsafe` names exactly the trust: remove
/// the lock discipline and nothing compiler-side saves us. The audio
/// thread can never hop to an actor, so actor isolation is not an
/// available alternative for this type. `NSLock` itself is Sendable
/// (`NS_SWIFT_SENDABLE` in the 27 SDK).
final class AudioFeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private nonisolated(unsafe) var format: AVAudioFormat?
    private nonisolated(unsafe) var conversionFailures = 0
    private let converter = BufferConverter()

    nonisolated func createStream() -> AsyncStream<AnalyzerInput> {
        lock.lock()
        defer { lock.unlock() }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        conversionFailures = 0
        return stream
    }

    nonisolated func configure(format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.format = format
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let continuation, let format else {
            lock.unlock()
            return
        }
        let converted: AVAudioPCMBuffer?
        do {
            converted = try converter.convertBuffer(buffer, to: format)
        } catch {
            // Counted, never logged per-buffer (realtime thread): surfaced
            // once per session at finish (bt-sco-flap.md). Silence with a
            // number beats silence with a shrug.
            conversionFailures += 1
            converted = nil
        }
        lock.unlock()
        if let converted {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    nonisolated func conversionFailureCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return conversionFailures
    }

    nonisolated func finishInput() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
        format = nil
    }
}

/// Real `SpeechServing` over `SpeechAnalyzer` + `SpeechTranscriber`
/// (fixed module choice per build, 07 §3.3 — not selectable, no fallback).
/// Short-lived analyzer per session, released at every terminal path
/// (07 §3.2). Session ordering follows 07 §4.3 tactics 5–9 and the
/// Yap-proven finish sequence; the download-during-dictation behavior is
/// deliberately NOT adopted (locked Oto rule).
actor AppleSpeechService: SpeechServing {
    /// Volatile (display-only) partials. Unwired in Phase 2 — the Flow Bar
    /// lands in Phase 6. Finals are the only path to insertion.
    var onPartial: (@Sendable (String) -> Void)?

    private let relay: AudioBufferRelay
    private let permissions: PermissionsManager
    private let feedBox = AudioFeedBox()
    private let log = Logger(subsystem: "app.Oto", category: "speech")

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var finalizedText = ""

    // PROBE-START (P2 plan §Probe): stashed session kept past finish so the
    // next prepare can attempt re-start + results re-iteration. Populated
    // only when the probe flag is armed and only on successful finishes;
    // consumed (single attempt) or dropped on any error/cancel. REMOVE after
    // the probe reports.
    private var probeKeptAnalyzer: SpeechAnalyzer?
    private var probeKeptTranscriber: SpeechTranscriber?
    private var probeKeptFormat: AVAudioFormat?

    init(
        relay: AudioBufferRelay,
        permissions: PermissionsManager = PermissionsManager()
    ) {
        self.relay = relay
        self.permissions = permissions
    }

    /// Resolve locale → verify assets → build session. Inspects readiness
    /// ONLY: anything but ready throws a specific `SpeechReadiness` with a
    /// recovery message. This method never downloads.
    func prepare() async throws {
        // 1. Microphone first (most actionable recovery).
        guard await permissions.ensureMicrophone() else {
            throw SpeechReadiness.microphoneDenied
        }

        // PROBE-START: single reuse attempt when armed. Success skips the
        // whole slow path below; any throw drops the stash and falls through
        // to it (single retry, then propagate — no retry loops). REMOVE after
        // the probe reports.
        if AnalyzerReuseProbe.armed().enabled,
           let keptAnalyzer = probeKeptAnalyzer,
           let keptTranscriber = probeKeptTranscriber,
           let keptFormat = probeKeptFormat
        {
            probeKeptAnalyzer = nil
            probeKeptTranscriber = nil
            probeKeptFormat = nil
            do {
                let probeStart = ContinuousClock.now
                let stream = feedBox.createStream()
                feedBox.configure(format: keptFormat)
                self.transcriber = keptTranscriber
                self.analyzer = keptAnalyzer
                finalizedText = ""
                resultTask = Task { [weak self] in
                    await self?.consumeResults()
                }
                try await keptAnalyzer.start(inputSequence: stream)
                let feedBox = self.feedBox
                relay.attach { buffer in feedBox.feed(buffer) }
                let startMs = PerfTrace.ms(probeStart.duration(to: .now))
                log.info("PROBE reuse start ok startMs=\(startMs, privacy: .public)ms (results verdict = this dictation's transcript)")
                log.info("speech prepared (PROBE reuse)")
                return
            } catch {
                teardown()
                log.error("PROBE reuse start failed, slow-path fallback: \(error.localizedDescription, privacy: .public)")
            }
        }
        // PROBE-END.

        // 2. Resolve the system locale against what Apple supports. P3:
        // flag-gated snapshot (zero awaits on hit); the requery path reads
        // per session, so a language change without relaunch still dictates
        // (audit N3 — the snapshot invalidates on locale change, Settings
        // prepare, and age cap, so the guarantee survives the cache).
        let tLocale = PerfTrace.begin(.localeResolve)
        let resolved: Locale
        var pendingSnapshotSupported: [Locale]?
        if LocaleCacheExperiment.current().enabled,
           case .use(let cached) = LocaleSnapshotCache.shared.resolve()
        {
            resolved = cached
        } else {
            let supported = await SpeechTranscriber.supportedLocales
            guard let match = SpeechLocaleMatching.bestMatch(for: .current, in: supported) else {
                PerfTrace.end(.localeResolve, tLocale)
                throw SpeechReadiness.unsupportedLocale
            }
            resolved = match
            pendingSnapshotSupported = supported
        }
        PerfTrace.end(.localeResolve, tLocale)

        // 3. Readiness inspection — probe module for the status call.
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let tProbe = PerfTrace.begin(.assetProbe)
        let installed = await SpeechTranscriber.installedLocales
        let status = await AssetInventory.status(forModules: [transcriber])
        let readiness = SpeechReadinessMapper.map(
            microphoneGranted: true,
            resolvedLocale: resolved,
            installedLocales: installed,
            assetStatus: status
        )
        PerfTrace.end(.assetProbe, tProbe)
        // P3: refresh the snapshot from the values just read (requery path
        // only — a cache hit already resolved from these). Stored even when
        // readiness is not ready: the snapshot reflects system state, and
        // the next press re-probes, so the honest failure recurs; a
        // successful Settings prepare invalidates anyway.
        if let supported = pendingSnapshotSupported {
            LocaleSnapshotCache.shared.store(supported: supported, installed: installed)
        }
        guard readiness == .ready else { throw readiness }

        // 4. Build the single-analyzer session.
        let tWarm = PerfTrace.begin(.engineWarm)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            PerfTrace.end(.engineWarm, tWarm)
            throw SpeechSessionError.engineFailure("no compatible audio format")
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            PerfTrace.end(.engineWarm, tWarm)
            throw SpeechSessionError.engineFailure(error.localizedDescription)
        }

        let stream = feedBox.createStream()
        feedBox.configure(format: format)
        self.transcriber = transcriber
        self.analyzer = analyzer
        finalizedText = ""

        resultTask = Task { [weak self] in
            await self?.consumeResults()
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            PerfTrace.end(.engineWarm, tWarm)
            teardown()
            throw SpeechSessionError.engineFailure(error.localizedDescription)
        }

        // Attach AFTER the stream exists: pre-attach audio buffered in the
        // relay flushes here in order (capture-first, no lost first words).
        let feedBox = self.feedBox
        relay.attach { buffer in feedBox.feed(buffer) }
        PerfTrace.end(.engineWarm, tWarm)
        log.info("speech prepared")
    }

    /// Close input → drain once → finalize through end of input → collect
    /// finals → release. Then the drop counter decides: past threshold the
    /// transcript is untrustworthy and this throws instead of returning it.
    func finish() async throws -> String {
        feedBox.finishInput()
        let tFinal = PerfTrace.begin(.finalizeAwait)
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Non-fatal by itself (Yap-proven): finals collected so far
            // still count; teardown proceeds below.
            log.error("finalize failed, keeping collected finals")
        }
        PerfTrace.end(.finalizeAwait, tFinal)
        resultTask?.cancel()
        resultTask = nil

        let text = finalizedText
        let dropped = relay.droppedBufferCount()
        let delivered = relay.deliveredBufferCount()
        let convFail = feedBox.conversionFailureCount()
        // PROBE-START: seed the next prepare's reuse attempt (success path
        // only — the no-audio/excessive-loss throws below still fire and
        // stash nothing). Format is re-resolved here so the slow path above
        // stays untouched; the extra await runs only on armed probe runs,
        // never on matrix data. REMOVE after the probe reports.
        if AnalyzerReuseProbe.armed().enabled,
           delivered > 0,
           dropped <= AudioBufferRelay.maximumDroppedBeforeFailure,
           let keptAnalyzer = analyzer,
           let keptTranscriber = transcriber,
           let keptFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [keptTranscriber])
        {
            probeKeptAnalyzer = keptAnalyzer
            probeKeptTranscriber = keptTranscriber
            probeKeptFormat = keptFormat
            log.info("PROBE seeded for next prepare")
        }
        // PROBE-END.
        teardown()
        log.info("speech finished delivered=\(delivered, privacy: .public) dropped=\(dropped, privacy: .public) convFail=\(convFail, privacy: .public) chars=\(text.count, privacy: .public)")

        // Dead/zombie mic: zero buffers all session. Fail loud with an
        // honest reason instead of completing empty (bt-sco-flap.md).
        if delivered == 0 {
            throw SpeechSessionError.noAudioCaptured
        }
        if dropped > AudioBufferRelay.maximumDroppedBeforeFailure {
            throw SpeechSessionError.excessiveAudioLoss(dropped: dropped)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Serialized teardown: stop delivery, end analysis now, release refs.
    /// Never runs concurrently with finalization (coordinator guarantees
    /// finish/cancel mutual exclusion).
    func cancel() async {
        feedBox.finishInput()
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        resultTask = nil
        // PROBE-START: a cancelled engine is never borrowed (matches the
        // P2 policy: cancelled → rebuild). REMOVE after the probe reports.
        probeKeptAnalyzer = nil
        probeKeptTranscriber = nil
        probeKeptFormat = nil
        // PROBE-END.
        teardown()
        log.info("speech cancelled")
    }

    // MARK: - Private

    private func consumeResults() async {
        guard let transcriber else { return }
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalizedText += text
                    onPartial?(finalizedText)
                } else {
                    onPartial?(finalizedText + text)
                }
            }
        } catch {
            // Stream ended or task cancelled — teardown owns the outcome.
        }
    }

    private func teardown() {
        relay.reset()
        transcriber = nil
        analyzer = nil
        finalizedText = ""
    }
}
