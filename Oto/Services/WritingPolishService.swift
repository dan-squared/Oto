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
    /// Streams cumulative draft snapshots for one job. Finishes empty on
    /// error (the UI treats empty as "couldn't clean up", raw intact).
    /// Cancellation propagates: breaking the loop cancels generation.
    /// `.cleanup(.none)` is never streamed (callers guard before calling —
    /// zero model contact is the whole point of None); a nil-instructions
    /// job defensively finishes empty.
    nonisolated func streamCleanup(_ text: String, job: PolishJob) -> AsyncStream<String>
    /// Warms the model while a preview surface is already open, so the first
    /// tap streams instantly. Memory cost only while visible; never called
    /// on the dictation path.
    nonisolated func prewarm()
    /// Job-tagged prewarm (E1: the record-start hint warms the expected
    /// cleanup level while the user speaks). Default: plain prewarm — the
    /// job match is a live-session optimization, not a contract.
    nonisolated func prewarm(job: PolishJob)
    /// Stats of the most recent run (nil before the first run or after a
    /// failed one). Powers the sheet caption — the matrix reads UI, not logs.
    nonisolated func lastRunStats() -> PolishRunStats?
}

extension PolishServing {
    nonisolated func prewarm(job: PolishJob) { prewarm() }
}

/// Timing of one cleanup run, surfaced in the sheet caption ("Cleaned with
/// Light in 1.4s · 38 words") so nobody opens Console. Words, not tokens —
/// the unit the user thinks in.
struct PolishRunStats: Equatable, Sendable {
    /// ms from call to first streamed snapshot.
    var firstTokenMs: Int
    /// ms from call to stream end.
    var totalMs: Int
    var inWords: Int
    var outWords: Int
}

/// One polish job: Auto Cleanup at a level, or a named Transform preset.
/// Carried through streaming so prompts, captions, and the pill all derive
/// from one value — never three parallel switches.
enum PolishJob: Sendable {
    case cleanup(CleanupLevel)
    case transform(TransformPreset)

    nonisolated static func == (lhs: PolishJob, rhs: PolishJob) -> Bool {
        switch (lhs, rhs) {
        case (.cleanup(let a), .cleanup(let b)):
            return a == b
        case (.transform(let a), .transform(let b)):
            return a == b
        default:
            return false
        }
    }

    /// Short label for captions ("Light", "Polish"). Pure — unit-tested.
    nonisolated var shortLabel: String {
        switch self {
        case .cleanup(let level): return level.shortLabel
        case .transform(let preset): return preset.displayName
        }
    }
}

extension PolishJob: Equatable {}

/// Auto Cleanup levels (E1): the writing question the user answers, not a
/// timing question. None = exact words, zero model contact. Light = filler
/// removal + grammar + simple punctuation. Medium = Light + light rewording
/// for clarity and conciseness. Every level is meaning-preserving and
/// same-language; register preservation (casual stays casual) holds at all
/// levels (Matrix A lesson, kept).
enum CleanupLevel: String, Sendable, CaseIterable {
    case none
    case light
    case medium

    nonisolated static func == (lhs: CleanupLevel, rhs: CleanupLevel) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    nonisolated var shortLabel: String {
        switch self {
        case .none: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        }
    }
}

extension CleanupLevel: Equatable {}

/// Transform presets (E2): explicit, user-fired rewrites on selected text.
/// Fixed set (custom prompts deferred): Polish = clarity + conciseness,
/// Concise = shorten keeping every fact, Professional = work-ready tone.
enum TransformPreset: String, Sendable, CaseIterable {
    case polish
    case concise
    case professional

    nonisolated static func == (lhs: TransformPreset, rhs: TransformPreset) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    /// Pill + Settings display name ("Polish"). Pure — unit-tested.
    nonisolated var displayName: String {
        switch self {
        case .polish: return "Polish"
        case .concise: return "Concise"
        case .professional: return "Professional"
        }
    }

    /// One-line Settings description per preset. Pure — unit-tested.
    nonisolated var tagline: String {
        switch self {
        case .polish: return "Improve clarity and conciseness"
        case .concise: return "Shorten, keep every fact"
        case .professional: return "Work-ready tone, same meaning"
        }
    }

    /// One-word pill verb while this preset runs (Cleaning's siblings:
    /// Polishing / Shortening / Formalizing). Pure — unit-tested.
    nonisolated var pillVerb: String {
        switch self {
        case .polish: return "Polishing"
        case .concise: return "Shortening"
        case .professional: return "Formalizing"
        }
    }
}

extension TransformPreset: Equatable {}

/// Live work feed for the pill: what the model is doing right now.
/// Published by whoever runs the work (coordinator cleanup branch,
/// TransformRunner); polled by the FlowBar controller next to its existing
/// `recoveryText()` read. Dictation `state` never carries it.
enum WorkLabel: Sendable, Equatable {
    case cleaningUp
    case preset(TransformPreset)
}

/// Effective Auto Cleanup behavior for one session: master switch + level.
/// Read per session from UserDefaults (thread-safe) so Settings flips apply
/// to the next dictation with no restart. Absent keys ⇒ shipped default
/// (on + None: exact words until the user opts into cleanup). Present-but-
/// unknown level ⇒ None (fail-safe: future values can never trigger unbuilt
/// behavior — pinned by test). Legacy Slice-B keys
/// (`app.Oto.intelligenceEnabled` / `app.Oto.intelligenceMode`) are honored
/// read-only when the new keys are absent (manual→None, upgrade→Light,
/// automatic→Medium); `CleanupMigrator.migrateIfNeeded` writes them forward
/// once, so the fallback is a backstop, not the path.
struct CleanupBehavior: Equatable, Sendable {
    var enabled: Bool
    var level: CleanupLevel

    nonisolated static func current(defaults: UserDefaults = .standard) -> CleanupBehavior {
        let enabled: Bool
        if defaults.object(forKey: CleanupSettings.enabledKey) != nil {
            enabled = defaults.bool(forKey: CleanupSettings.enabledKey)
        } else if defaults.object(forKey: LegacyIntelligenceSettings.enabledKey) != nil {
            enabled = defaults.bool(forKey: LegacyIntelligenceSettings.enabledKey)
        } else {
            enabled = true
        }
        let level: CleanupLevel
        if let raw = defaults.string(forKey: CleanupSettings.levelKey) {
            level = CleanupLevel(rawValue: raw) ?? .none
        } else if let raw = defaults.string(forKey: LegacyIntelligenceSettings.modeKey) {
            level = LegacyIntelligenceSettings.migratedLevel(raw: raw)
        } else {
            level = .none
        }
        return CleanupBehavior(enabled: enabled, level: level)
    }
}

/// Preference keys for Auto Cleanup (single source — literals here, never
/// scattered). NEW keys so the Slice-B keys migrate cleanly exactly once.
enum CleanupSettings {
    nonisolated static let enabledKey = "app.Oto.cleanupEnabled"
    nonisolated static let levelKey = "app.Oto.cleanupLevel"
}

/// Slice-B keys, read-only migration source. Never written by new code
/// (same precedent as `ShortcutConfiguration`); removal no earlier than
/// 2 releases after this ships.
enum LegacyIntelligenceSettings {
    nonisolated static let enabledKey = "app.Oto.intelligenceEnabled"
    nonisolated static let modeKey = "app.Oto.intelligenceMode"

    /// Pure legacy-mode mapping (unit-tested): manual→None, upgrade→Light,
    /// automatic→Medium, anything else→None (fail-safe).
    nonisolated static func migratedLevel(raw: String) -> CleanupLevel {
        switch raw {
        case "manual": return .none
        case "upgrade": return .light
        case "automatic": return .medium
        default: return .none
        }
    }
}

/// One-shot forward migration: legacy Slice-B values land on the new keys
/// the first time this runs (app launch + Intelligence pane appear — both
/// call it, idempotent by construction: present new keys are never touched).
enum CleanupMigrator {
    nonisolated static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        let hasNew = defaults.object(forKey: CleanupSettings.enabledKey) != nil
            || defaults.object(forKey: CleanupSettings.levelKey) != nil
        guard !hasNew else { return }
        let hasLegacy = defaults.object(forKey: LegacyIntelligenceSettings.enabledKey) != nil
            || defaults.object(forKey: LegacyIntelligenceSettings.modeKey) != nil
        guard hasLegacy else { return }
        let mapped = CleanupBehavior.current(defaults: defaults)
        defaults.set(mapped.enabled, forKey: CleanupSettings.enabledKey)
        defaults.set(mapped.level.rawValue, forKey: CleanupSettings.levelKey)
    }
}

/// Caption for run stats, tagged with the job ("Cleaned with Light in 1.4s
/// · 38 words"). Pure — unit-tested.
nonisolated func polishTimingCaption(stats: PolishRunStats, job: PolishJob = .cleanup(.light)) -> String {
    let seconds = Double(stats.totalMs) / 1000.0
    return String(format: "Cleaned with %@ in %.1fs · %d words", job.shortLabel, seconds, stats.outWords)
}

private nonisolated func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

/// Bounded polish race shared by Auto Cleanup (coordinator, pre-insertion)
/// and Transforms (runner, on selection). First finisher wins; timeout /
/// error / empty ⇒ nil (callers fail open: raw inserts / selection stands).
/// Structured: cancelling the caller cancels the race; the sleep task bounds
/// every path. A timed-out live stream keeps generating in the background
/// until the model finishes (bounded by the token cap, results discarded) —
/// single-flight would end this properly (deferred, 7c).
nonisolated func racePolishText(
    polish: any PolishServing, text: String, job: PolishJob, timeout: Duration
) async -> String? {
    await withTaskGroup(of: String?.self, returning: String?.self) { group in
        group.addTask {
            var last: String?
            for await snapshot in polish.streamCleanup(text, job: job) {
                last = snapshot
            }
            return (last?.isEmpty == false) ? last : nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Rule for the Clean up affordance: offered only when the user left it on
/// AND the model is actually available. Pure — unit-tested.
nonisolated func polishActionVisible(availability: PolishAvailability, enabled: Bool) -> Bool {
    enabled && availability == .available
}

/// Intelligence behavior, superseded by Auto Cleanup (E1). Kept (deprecated)
/// ONLY as the read path for `LegacyIntelligenceSettings` raw strings — new
/// code must use `CleanupLevel`. Removal no earlier than 2 releases.
enum IntelligenceMode: String, Sendable, CaseIterable {
    case manual
    case upgrade
    case automatic

    nonisolated static func == (lhs: IntelligenceMode, rhs: IntelligenceMode) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension IntelligenceMode: Equatable {}

/// Superseded by `CleanupBehavior` (E1). Kept (deprecated) so existing call
/// sites migrate in this slice; do not use in new code.
struct PolishBehavior: Equatable, Sendable {
    var enabled: Bool
    var mode: IntelligenceMode

    nonisolated static func current(defaults: UserDefaults = .standard) -> PolishBehavior {
        let mapped = CleanupBehavior.current(defaults: defaults)
        let mode: IntelligenceMode
        switch mapped.level {
        case .none: mode = .manual
        case .light: mode = .upgrade
        case .medium: mode = .automatic
        }
        return PolishBehavior(enabled: mapped.enabled, mode: mode)
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

    /// Pinned instructions per job (E1+E2). Light keeps the Matrix-A v2 text
    /// verbatim (register preservation included); Medium adds one sentence
    /// of clarity license — the entire difference between the levels.
    /// Transforms share the Polish core with per-preset license. All
    /// rewriting-class: meaning preserved, same language, output only.
    /// Returns nil for `.cleanup(.none)` (never streamed — defensive).
    nonisolated static func instructions(for job: PolishJob) -> String? {
        switch job {
        case .cleanup(.none):
            return nil
        case .cleanup(.light):
            return Self.lightInstructions
        case .cleanup(.medium):
            return Self.lightInstructions +
                " You may lightly reword for clarity and conciseness, but change nothing substantive."
        case .transform(.polish):
            return "Improve clarity and conciseness. Preserve the meaning exactly. " +
                "Keep the same language. Output only the rewritten text, no commentary."
        case .transform(.concise):
            return Self.instructions(for: .transform(.polish))! +
                " Shorten substantially: cut redundancy, keep every fact and number."
        case .transform(.professional):
            return Self.instructions(for: .transform(.polish))! +
                " Lift the tone to work-ready: direct, polite, confident. Change nothing substantive."
        }
    }

    /// The Light core (Matrix-A v2, preserved verbatim). Own copy —
    /// changeable with judgment, never silently.
    nonisolated static let lightInstructions =
        "Clean up the grammar and remove filler words. Preserve the meaning exactly. " +
        "Write as the speaker would: casual stays casual, formal stays formal. " +
        "Keep the same language. Output only the cleaned text, no commentary."

    /// Kept for compatibility: the Light core (v2 text). New code must use
    /// `instructions(for:)`.
    nonisolated static let instructions = lightInstructions

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
    /// and cleanup must stay stateless). Tagged with the job it was warmed
    /// for: a Light-warmed session must never serve a Professional run (or
    /// vice versa) — mismatch falls back to a fresh correctly-instructed
    /// session instead of a wrongly-instructed fast one.
    nonisolated(unsafe) private var warmSession: LanguageModelSession?
    nonisolated(unsafe) private var warmJob: PolishJob?
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
        prewarm(job: .cleanup(.light))
    }

    /// Warms the model for an expected job while a surface is already open
    /// (E1: record start warms while the user speaks). Memory cost only
    /// while the hint lives; never called on the mic path itself.
    nonisolated func prewarm(job: PolishJob) {
        guard let instructions = Self.instructions(for: job) else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        lock.withLock {
            warmSession = session
            warmJob = job
        }
    }

    nonisolated func lastRunStats() -> PolishRunStats? {
        lock.withLock { runStats }
    }

    nonisolated func streamCleanup(_ text: String, job: PolishJob) -> AsyncStream<String> {
        guard let instructions = Self.instructions(for: job) else {
            // `.cleanup(.none)` reaches no model: finish empty, raw intact.
            return AsyncStream { $0.finish() }
        }
        let session: LanguageModelSession = lock.withLock {
            defer {
                warmSession = nil
                warmJob = nil
            }
            runStats = nil
            if let warm = warmSession, warmJob == job { return warm }
            return LanguageModelSession(instructions: instructions)
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
    nonisolated(unsafe) private var recordedJobs: [PolishJob] = []
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
    var jobs: [PolishJob] { lock.withLock { recordedJobs } }
    var prewarms: Int { lock.withLock { prewarmCount } }

    nonisolated func availability() -> PolishAvailability { availabilityResult }

    /// Fakes carry no timings — the sheet shows no caption in fake contexts.
    nonisolated func lastRunStats() -> PolishRunStats? { nil }

    nonisolated func prewarm() {
        lock.withLock { prewarmCount += 1 }
    }

    nonisolated func streamCleanup(_ text: String, job: PolishJob) -> AsyncStream<String> {
        lock.withLock {
            recordedPrompts.append(text)
            recordedJobs.append(job)
        }
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
