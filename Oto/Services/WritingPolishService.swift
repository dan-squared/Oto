//
//  WritingPolishService.swift
//  Oto
//
//  One Intelligence action: Clean up. Post-transcript only: receives finalized
//  text, streams back a draft. Never touches audio, insertion, or storage —
//  the coordinator owns those, and this service is not in its path.
//
//  Model discipline (grep-gated, same pattern as the download gate in
//  SpeechAssetPreparer): `SystemLanguageModel` ONLY. Never
//  `PrivateCloudComputeLanguageModel` (cloud — banned by the product
//  boundary), never shell out to `fm respond` / `fm serve` (the CLI license
//  binds programmatic CLI access; the framework path needs no CLI at all).
//

import Foundation
import FoundationModels
import os

/// Availability of the on-device writing model, mapped to honest user copy
/// at the call site (never a bare bool — every unavailable reason teaches).
enum PolishAvailability: Sendable {
    case available
    case unavailable(copy: String)

    // Explicit: compared from the coordinator actor (Swift 6) — same reason
    // InsertionDecision carries its own == instead of synthesis.
    nonisolated static func == (lhs: PolishAvailability, rhs: PolishAvailability) -> Bool {
        switch (lhs, rhs) {
        case (.available, .available):
            return true
        case (.unavailable(let a), .unavailable(let b)):
            return a == b
        default:
            return false
        }
    }
}

extension PolishAvailability: Equatable {}

/// The single Intelligence seam. `Sendable`-conforming so the coordinator,
/// panes, and sheets can all hold it without isolation questions.
/// Cross-actor contract (coordinator, panes, sheets): every requirement
/// is explicitly `nonisolated` so the MainActor-default build setting can
/// never silently isolate this seam (witnesses carry the same marks).
protocol PolishServing: Sendable {
    /// Synchronous property read — safe to call from anywhere, including
    /// tests and `.onAppear`. Never downloads, never prompts.
    nonisolated func availability() -> PolishAvailability
    /// Streams cumulative draft snapshots. Finishes empty on error (the UI
    /// treats empty as "couldn't clean up", raw intact). Cancellation
    /// propagates: breaking the loop cancels generation.
    nonisolated func streamCleanup(_ text: String) -> AsyncStream<String>
    /// Warms the model while a preview surface is already open, so the first
    /// tap streams instantly. Memory cost only while visible; never called
    /// on the dictation path.
    nonisolated func prewarm()
    /// Stats of the most recent run (nil before the first run or after a
    /// failed one). Powers the sheet caption — the matrix reads UI, not logs.
    nonisolated func lastRunStats() -> PolishRunStats?
}

/// Timing of one cleanup run, surfaced in the sheet caption ("Cleaned in
/// 1.4s · 38 words") so nobody opens Console. Words, not tokens — the unit
/// the user thinks in.
struct PolishRunStats: Equatable, Sendable {
    /// ms from call to first streamed snapshot.
    var firstTokenMs: Int
    /// ms from call to stream end.
    var totalMs: Int
    var inWords: Int
    var outWords: Int
}

/// Caption for run stats. Pure — unit-tested.
nonisolated func polishTimingCaption(stats: PolishRunStats) -> String {
    let seconds = Double(stats.totalMs) / 1000.0
    return String(format: "Cleaned in %.1fs · %d words", seconds, stats.outWords)
}

private nonisolated func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

/// Rule for the Clean up affordance: offered only when the user left it on
/// AND the model is actually available. Pure — unit-tested.
nonisolated func polishActionVisible(availability: PolishAvailability, enabled: Bool) -> Bool {
    enabled && availability == .available
}

/// Intelligence behavior modes (Slice B picker: manual + upgrade; automatic
/// arrives with Slice C — the picker never offers unbuilt behavior).
enum IntelligenceMode: String, Sendable, CaseIterable {
    case manual
    case upgrade
    case automatic

    nonisolated static func == (lhs: IntelligenceMode, rhs: IntelligenceMode) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension IntelligenceMode: Equatable {}

/// Effective behavior for one session: master switch + mode. Read per
/// session from UserDefaults (thread-safe) so Settings flips apply to the
/// next dictation with no restart. Unknown/future mode values fall back to
/// manual — they can never trigger unbuilt behavior (pinned by test).
struct PolishBehavior: Equatable, Sendable {
    var enabled: Bool
    var mode: IntelligenceMode

    nonisolated static func current(defaults: UserDefaults = .standard) -> PolishBehavior {
        let enabled = defaults.object(forKey: IntelligenceSettings.enabledKey) == nil
            ? true
            : defaults.bool(forKey: IntelligenceSettings.enabledKey)
        // Absent key ⇒ shipped default (upgrade). Present-but-unknown ⇒
        // safe manual (future values can never trigger unbuilt behavior).
        let mode: IntelligenceMode
        if let raw = defaults.string(forKey: IntelligenceSettings.modeKey) {
            mode = IntelligenceMode(rawValue: raw) ?? .manual
        } else {
            mode = .upgrade
        }
        return PolishBehavior(enabled: enabled, mode: mode)
    }
}

/// Preference keys shared by the panes and the coordinator (single source —
/// literals here, never scattered).
enum IntelligenceSettings {
    nonisolated static let enabledKey = "app.Oto.intelligenceEnabled"
    nonisolated static let modeKey = "app.Oto.intelligenceMode"
}

/// Live implementation over Apple's on-device model.
final class LivePolishService: PolishServing, @unchecked Sendable {
    private let log = Logger(subsystem: "app.Oto", category: "polish")

    /// Fixed instructions, v2 (register preservation added after Matrix A:
    /// casual stays casual). Own copy — changeable with judgment, never
    /// silently. Narrowly rewriting-class: grammar + filler, meaning
    /// preserved, same language, output only.
    nonisolated static let instructions =
        "Clean up the grammar and remove filler words. Preserve the meaning exactly. " +
        "Write as the speaker would: casual stays casual, formal stays formal. " +
        "Keep the same language. Output only the cleaned text, no commentary."

    /// Token cap scaled to the job: cleanup output ≈ input size, so short
    /// entries finish sooner instead of paying for headroom they need.
    /// (1 token ≈ 4 chars; +64 headroom; clamped — long entries unchanged.)
    nonisolated static func options(for text: String) -> GenerationOptions {
        let cap = min(512, max(128, text.count / 2 + 64))
        return GenerationOptions(temperature: 0.2, maximumResponseTokens: cap)
    }

    private let lock = NSLock()
    /// Single-slot prewarmed session (codebase pattern: lock-disciplined,
    /// invalidated after one use — a session accumulates transcript context,
    /// and cleanup must stay stateless).
    nonisolated(unsafe) private var warmSession: LanguageModelSession?
    /// Last-run stats for the sheet caption. Cleared at each run start so a
    /// failed run shows no stale caption.
    nonisolated(unsafe) private var runStats: PolishRunStats?

    nonisolated func availability() -> PolishAvailability {
        Self.map(SystemLanguageModel.default.availability)
    }

    /// Pure availability→copy mapping (unit-tested). The enum is non-frozen,
    /// so `@unknown default` future-proofs new reasons as honest ignorance.
    nonisolated static func map(_ availability: SystemLanguageModel.Availability) -> PolishAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(copy: "This Mac doesn't support Apple Intelligence, so cleanup isn't available.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(copy: "Turn on Apple Intelligence in System Settings to use cleanup.")
            case .modelNotReady:
                return .unavailable(copy: "The on-device model is still preparing. Try again shortly.")
            @unknown default:
                // Future reasons must surface as honest ignorance, never
                // as availability.
                return .unavailable(copy: "Cleanup isn't available right now.")
            }
        }
    }

    nonisolated func prewarm() {
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        lock.withLock { warmSession = session }
    }

    nonisolated func lastRunStats() -> PolishRunStats? {
        lock.withLock { runStats }
    }

    nonisolated func streamCleanup(_ text: String) -> AsyncStream<String> {
        let session: LanguageModelSession = lock.withLock {
            defer { warmSession = nil }
            runStats = nil
            return warmSession ?? LanguageModelSession(instructions: Self.instructions)
        }
        let prompt = "Clean up this dictation transcript:\n\(text)"
        let options = Self.options(for: text)
        let inWords = wordCount(text)
        let started = Date()
        return AsyncStream { continuation in
            let task = Task {
                do {
                    let stream = session.streamResponse(to: prompt, options: options)
                    var firstYield: Date?
                    var last = ""
                    for try await snapshot in stream {
                        if firstYield == nil { firstYield = Date() }
                        last = snapshot.content
                        continuation.yield(snapshot.content)
                    }
                    let finished = Date()
                    let stats = PolishRunStats(
                        firstTokenMs: Int((firstYield ?? finished).timeIntervalSince(started) * 1000),
                        totalMs: Int(finished.timeIntervalSince(started) * 1000),
                        inWords: inWords,
                        outWords: wordCount(last)
                    )
                    self.lock.withLock { self.runStats = stats }
                    self.log.debug("polish stream firstTokenMs=\(stats.firstTokenMs) totalMs=\(stats.totalMs) inWords=\(inWords) outWords=\(stats.outWords)")
                    continuation.finish()
                } catch {
                    log.error("cleanup stream failed: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Scripted fake: chunks in order, optional error (finishes empty),
/// availability override. No store references — it cannot persist by
/// construction (pinned by the no-persistence test).
final class FakePolishService: PolishServing, @unchecked Sendable {
    /// Test-configured on the main actor before streaming; stream Tasks may
    /// read off-thread. Same set-before-use discipline as the other fakes.
    nonisolated(unsafe) var availabilityResult: PolishAvailability = .available
    nonisolated(unsafe) var chunks: [String] = []
    nonisolated(unsafe) var shouldError = false

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedPrompts: [String] = []
    nonisolated(unsafe) private var prewarmCount = 0

    /// Test-only stream gate (FakeTextInsertion.insertGateOpen precedent):
    /// while closed, streams suspend before yielding — lets tests park the
    /// upgrade race mid-flight and trip the clock/timeout guards
    /// deterministically. Per-fake instance (no shared mutable test state).
    /// Open by default; production never closes it.
    actor StreamGate {
        private var open = true
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func setOpen(_ open: Bool) {
            waiters.forEach { $0.resume() }
            waiters = []
            self.open = open
        }

        func waitIfClosed() async {
            guard !open else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    let streamGate = StreamGate()
    var prompts: [String] { lock.withLock { recordedPrompts } }
    var prewarms: Int { lock.withLock { prewarmCount } }

    nonisolated func availability() -> PolishAvailability { availabilityResult }

    /// Fakes carry no timings — the sheet shows no caption in fake contexts.
    nonisolated func lastRunStats() -> PolishRunStats? { nil }

    nonisolated func prewarm() {
        lock.withLock { prewarmCount += 1 }
    }

    nonisolated func streamCleanup(_ text: String) -> AsyncStream<String> {
        lock.withLock { recordedPrompts.append(text) }
        let chunks = chunks
        let shouldError = shouldError
        let gate = streamGate
        return AsyncStream { continuation in
            let task = Task {
                await gate.waitIfClosed()
                guard !shouldError else {
                    continuation.finish()
                    return
                }
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
