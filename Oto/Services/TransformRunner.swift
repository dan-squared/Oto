//
//  TransformRunner.swift
//  Oto
//
//  E2: explicit, user-fired rewrites on selected text. One run at a time
//  (a new press cancels the previous); never touches dictation state.
//  Flow: snapshot target at press → grab selection → bounded rewrite →
//  replace selection. Every failure leaves the selection untouched and
//  speaks only through logs/menu — never the pill. Native Cmd+Z in the
//  target app is the undo path.
//

import Carbon.HIToolbox
import Foundation
import os

/// Serial transform executor. Publishes `currentWork` for the pill feed
/// (the controller polls it next to the coordinator's feed).
actor TransformRunner {
    /// Selection jobs are user-waited, so a longer honest bound than Auto
    /// Cleanup. Missing it leaves the selection untouched, silently.
    nonisolated static let transformTimeout: Duration = .seconds(6)

    private let grabber: any SelectionGrabbing
    private let inserter: any TextInserting
    private let targetService: any TargetCapturing
    private let polish: any PolishServing
    private let behaviorProvider: (@Sendable () -> CleanupBehavior)
    private(set) var currentWork: WorkLabel?
    private let log = Logger(subsystem: "app.Oto", category: "transform")

    init(
        grabber: any SelectionGrabbing,
        inserter: any TextInserting,
        targetService: any TargetCapturing,
        polish: any PolishServing,
        behaviorProvider: (@Sendable () -> CleanupBehavior)? = nil
    ) {
        self.grabber = grabber
        self.inserter = inserter
        self.targetService = targetService
        self.polish = polish
        self.behaviorProvider = behaviorProvider ?? { CleanupBehavior.current() }
    }

    func currentWorkLabel() -> WorkLabel? { currentWork }

    /// Runs one transform to completion. Serialized by the caller
    /// (TransformDispatch scope — never call concurrently): cancellation
    /// cooperates at the usual points (fresh checks, race end, replace).
    func execute(preset: TransformPreset) async {
        guard behaviorProvider().enabled else { return }
        guard polish.availability() == .available else { return }
        // Target captured synchronously at press, before any Oto UI could
        // appear — never re-resolved later (insertion-rule precedent).
        let target = targetService.capture()
        guard await targetService.isAlive(target) else { return }
        guard !Task.isCancelled else { return }
        currentWork = .preset(preset)
        defer { currentWork = nil }
        guard let selection = await grabber.grabSelection(),
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard !Task.isCancelled else { return }
        // Re-verify: the grab took real time (clipboard round-trip) during
        // which the user may have switched apps.
        guard await targetService.isAlive(target) else { return }
        guard let rewritten = await racePolishText(
            polish: polish, text: selection,
            job: .transform(preset), timeout: Self.transformTimeout
        ), rewritten != selection else { return }
        guard !Task.isCancelled else { return }
        guard await targetService.isAlive(target) else { return }
        switch await inserter.replaceSelection(rewritten, into: target) {
        case .inserted:
            log.info("transform applied chars=\(rewritten.count, privacy: .public)")
        case .recoverableFailure(let reason):
            // Selection stands as it was; native Cmd+Z was never needed.
            log.info("transform refused (\(reason), privacy: .public); selection stands")
        case .noEditableField:
            log.info("transform refused (no editable field); selection stands")
        }
    }
}

/// Owns the three transform hotkeys (Carbon combos — no AX needed to
/// receive them). Suspends by rule, not by flag: a press while dictation is
/// non-terminal is ignored (transforms never interleave with recording).
/// Registration conflicts with other apps surface per preset (`isLive`)
/// instead of failing silent.
@MainActor
final class TransformDispatch {
    /// Settle window: a same-family hold `begin` fires on modifier-down
    /// BEFORE any combo completes (queued async emit vs direct Carbon
    /// delivery — order is racy). Every transform press waits this out,
    /// then cancels a fresh hold micro-session if one landed, so stale
    /// configs work deterministically instead of flaking. Invisible against
    /// model latency (seconds); pinned, never tuned by feel.
    nonisolated static let comboSettle: Duration = .milliseconds(100)

    private let runner: TransformRunner
    private let dictationLive: @Sendable () async -> Bool
    private let dictationKinds: () -> (hold: ShortcutTrigger.Kind, handsFree: ShortcutTrigger.Kind)
    /// Combo-wins safety net: cancels a fresh hold micro-session that this
    /// press's modifier-down may have started (lossless pre-insertion).
    private let cancelFreshMicroSession: @Sendable () async -> Void
    /// Mutual exclusion: dictation keys sleep for the run duration so no
    /// later hold press can strand a session mid-transform. Idle-safe
    /// (nothing active to cancel when a transform legitimately starts).
    private let setDictationSuspended: (Bool) -> Void

    private var monitors: [TransformPreset: ModifierHotkeyMonitor] = [:]
    private var transformTask: Task<Void, Never>?
    private var transformGeneration = 0
    private(set) var shortcuts: TransformShortcuts {
        didSet { shortcuts.save() }
    }

    init(
        runner: TransformRunner,
        shortcuts: TransformShortcuts = .load(),
        dictationLive: @Sendable @escaping () async -> Bool,
        dictationKinds: @escaping () -> (hold: ShortcutTrigger.Kind, handsFree: ShortcutTrigger.Kind),
        cancelFreshMicroSession: @Sendable @escaping () async -> Void,
        setDictationSuspended: @escaping (Bool) -> Void
    ) {
        self.runner = runner
        self.shortcuts = shortcuts
        self.dictationLive = dictationLive
        self.dictationKinds = dictationKinds
        self.cancelFreshMicroSession = cancelFreshMicroSession
        self.setDictationSuspended = setDictationSuspended
    }

    /// (Re)register all three combos. Unregisters first: re-registering can
    /// never leave a stale callback behind. Non-combo kinds never register
    /// (the UI refuses to save them with guidance — transforms need a
    /// combination like ⌥1).
    func start() {
        stop()
        for preset in TransformPreset.allCases {
            guard case .combo(let modifiers, let keyCode) = shortcuts.kind(for: preset) else { continue }
            let monitor = ModifierHotkeyMonitor()
            monitor.onEvent = { [weak self] event in self?.receive(event, preset: preset) }
            monitor.configure(comboModifiers: modifiers, keyCode: keyCode)
            monitors[preset] = monitor
        }
    }

    func stop() {
        monitors.values.forEach { $0.stop() }
        monitors = [:]
    }

    /// False when the OS refused registration (used by another app) — the
    /// Settings row says so instead of going silently dead.
    func isLive(_ preset: TransformPreset) -> Bool {
        monitors[preset]?.isLive ?? false
    }

    /// Current dictation kinds for the Settings advisory (same rule, same
    /// strings — the pure gate compares all five slots).
    func currentDictationKinds() -> (hold: ShortcutTrigger.Kind, handsFree: ShortcutTrigger.Kind) {
        dictationKinds()
    }

    private func receive(_ event: ShortcutEvent, preset: TransformPreset) {
        guard case .keyDown(let isRepeat) = event, !isRepeat else { return }
        // Serial scope: a new press cancels the previous run (no piles, no
        // queues). Generation-guarded resume: a cancelled stale task never
        // resumes dictation keys early from its defer.
        transformGeneration += 1
        let generation = transformGeneration
        transformTask?.cancel()
        transformTask = Task { [weak self] in
            guard let self else { return }
            // Settle: let an in-flight hold-begin from THIS press's
            // modifier-down land, then combo-wins cancel it (lossless).
            try? await Task.sleep(for: Self.comboSettle)
            guard !Task.isCancelled else { return }
            await self.cancelFreshMicroSession()
            // Real sessions (old, hands-free, finalizing) still veto.
            guard await !self.dictationLive() else { return }
            self.setDictationSuspended(true)
            defer {
                if generation == self.transformGeneration {
                    self.setDictationSuspended(false)
                }
            }
            await self.runner.execute(preset: preset)
        }
    }

    /// Test hook: drive a transform press without hardware.
    func fireForTests(_ preset: TransformPreset) {
        receive(.keyDown(isRepeat: false), preset: preset)
    }

    /// Save gate: `.blocked` keeps the old trigger (the UI shows the
    /// advisory, built by the same pure rule). Non-combos are refused with
    /// guidance — transforms fire on key-down, a bare hold makes no sense.
    func updateShortcut(_ kind: ShortcutTrigger.Kind, for preset: TransformPreset) -> TriggerUpdateResult {
        switch kind {
        case .combo:
            break
        default:
            return .blocked
        }
        let kinds = dictationKinds()
        if TransformShortcutGate.advisory(
            kind: kind, preset: preset,
            transforms: shortcuts, hold: kinds.hold, handsFree: kinds.handsFree
        ) != nil {
            return .blocked
        }
        shortcuts.set(kind, for: preset)
        start()
        return .applied
    }

    func resetToDefaults() {
        shortcuts = .default()
        start()
    }

    /// Clears one preset to unassigned (empty slot claims nothing — always
    /// allowed, never gated).
    func clearShortcut(for preset: TransformPreset) {
        shortcuts.set(.unassigned, for: preset)
        start()
    }
}
