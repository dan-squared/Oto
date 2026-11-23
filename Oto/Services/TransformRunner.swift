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
/// (both pull via `currentWorkLabel()` and push via `workChanges()`).
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
    private var activeRunID: UUID?
    private var workWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
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

    /// Event-driven notification stream yielding whenever `currentWork` changes.
    func workChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            self.workWaiters[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeWorkWaiter(id) }
            }
        }
    }

    private func removeWorkWaiter(_ id: UUID) {
        workWaiters.removeValue(forKey: id)
    }

    private func setCurrentWork(_ label: WorkLabel?) {
        guard currentWork != label else { return }
        currentWork = label
        for waiter in workWaiters.values {
            waiter.yield(())
        }
    }

    /// Synchronous target capture helper so `TransformDispatch` can snapshot
    /// the frontmost app at keypress before any settle sleep or actor hop.
    nonisolated func captureTarget() -> TargetApplication {
        targetService.capture()
    }

    /// Runs one transform to completion. Serialized by the caller
    /// (TransformDispatch scope — never call concurrently): cancellation
    /// cooperates at the usual points (fresh checks, race end, replace).
    /// `target` may be pre-captured synchronously at keypress.
    func execute(preset: TransformPreset, target preCapturedTarget: TargetApplication? = nil) async {
        guard behaviorProvider().enabled else { return }
        guard polish.availability() == .available else { return }
        // Custom with no written instruction is idle: fail closed before
        // touching the target, the clipboard, or the pill (same contract
        // as empty selection — nothing happens, silently).
        if preset == .custom, !CustomPrompt.load().isUsable { return }
        // Target captured synchronously at press, before any Oto UI could
        // appear — never re-resolved later (insertion-rule precedent).
        let target = preCapturedTarget ?? targetService.capture()
        guard await targetService.isAlive(target) else { return }
        guard !Task.isCancelled else { return }
        let runID = UUID()
        activeRunID = runID
        setCurrentWork(.preset(preset))
        defer {
            if activeRunID == runID {
                activeRunID = nil
                setCurrentWork(nil)
            }
        }
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
            log.info("transform refused (\(reason, privacy: .public)); selection stands")
        case .noEditableField:
            log.info("transform refused (no editable field); selection stands")
        }
    }
}

/// Owns the four transform hotkeys (Carbon combos — no AX needed to
/// receive them). Suspends by rule, not by flag: a press while dictation is
/// non-terminal is ignored (transforms never interleave with recording).
/// Registration conflicts with other apps surface per preset (`isLive`)
/// instead of failing silent.
@MainActor
final class TransformDispatch {
    /// Settle window: a same-family hold `begin` fires on modifier-down
    /// BEFORE any combo completes (queued async emit vs direct Carbon
    /// delivery — order is racy). Every same-family transform press waits this
    /// out, then cancels a live hold-to-talk session of its own modifier family,
    /// so stale configs work deterministically instead of flaking. Invisible
    /// against model latency (seconds); pinned, never tuned by feel.
    nonisolated static let comboSettle: Duration = .milliseconds(100)

    private let runner: TransformRunner
    private let dictationLive: @Sendable () async -> Bool
    private let dictationKinds: () -> (hold: ShortcutTrigger.Kind, handsFree: ShortcutTrigger.Kind)
    /// Combo-wins safety net: cancels a live hold-to-talk session that this
    /// press's modifier-down may have started (lossless pre-insertion). Only
    /// invoked when the pressed transform combo actually shares a modifier
    /// family with the active hold slot.
    private let cancelHoldForCombination: @Sendable () async -> Bool
    /// Mutual exclusion: dictation keys sleep for the run duration so no
    /// later hold press can strand a session mid-transform. Idle-safe
    /// (nothing active to cancel when a transform legitimately starts).
    private let setDictationSuspended: (Bool) -> Void
    private let behaviorProvider: @Sendable () -> CleanupBehavior

    private var monitors: [TransformPreset: ModifierHotkeyMonitor] = [:]
    private let log = Logger(subsystem: "app.Oto", category: "transform")
    private var transformTask: Task<Void, Never>?
    private var isDictationSuspended = false
    private var isStarted = false
    private var registeredEnabledState: Bool?
    nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?
    private(set) var shortcuts: TransformShortcuts {
        didSet { shortcuts.save() }
    }

    init(
        runner: TransformRunner,
        shortcuts: TransformShortcuts = .load(),
        dictationLive: @Sendable @escaping () async -> Bool,
        dictationKinds: @escaping () -> (hold: ShortcutTrigger.Kind, handsFree: ShortcutTrigger.Kind),
        cancelHoldForCombination: @Sendable @escaping () async -> Bool,
        setDictationSuspended: @escaping (Bool) -> Void,
        behaviorProvider: @Sendable @escaping () -> CleanupBehavior = { CleanupBehavior.current() }
    ) {
        self.runner = runner
        self.shortcuts = shortcuts
        self.dictationLive = dictationLive
        self.dictationKinds = dictationKinds
        self.cancelHoldForCombination = cancelHoldForCombination
        self.setDictationSuspended = setDictationSuspended
        self.behaviorProvider = behaviorProvider
    }

    deinit {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// (Re)register all four combos when Apple Intelligence is enabled.
    /// Unregisters first: re-registering can never leave a stale callback
    /// behind. Non-combo kinds never register (the UI refuses to save them
    /// with guidance — transforms need a combination like ⌥1).
    func start() {
        unregisterMonitors()
        isStarted = true
        installDefaultsObserverIfNeeded()
        let enabled = behaviorProvider().enabled
        registeredEnabledState = enabled
        guard enabled else { return }
        for preset in TransformPreset.allCases {
            guard case .combo(let modifiers, let keyCode) = shortcuts.kind(for: preset) else { continue }
            let monitor = ModifierHotkeyMonitor()
            monitor.onEvent = { [weak self] event in self?.receive(event, preset: preset) }
            monitor.configure(comboModifiers: modifiers, keyCode: keyCode)
            monitors[preset] = monitor
        }
    }

    /// Re-evaluates hotkey registration against the current
    /// `CleanupBehavior.enabled` flag without interrupting a stopped state.
    func refreshRegistration() {
        guard isStarted else { return }
        start()
    }

    func stop() {
        isStarted = false
        registeredEnabledState = nil
        transformTask?.cancel()
        transformTask = nil
        setSuspended(false)
        unregisterMonitors()
    }

    private func unregisterMonitors() {
        monitors.values.forEach { $0.stop() }
        monitors = [:]
    }

    private func installDefaultsObserverIfNeeded() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                let nowEnabled = self.behaviorProvider().enabled
                if self.registeredEnabledState != nowEnabled {
                    self.start()
                }
            }
        }
    }

    private func setSuspended(_ suspended: Bool) {
        guard isDictationSuspended != suspended else { return }
        isDictationSuspended = suspended
        setDictationSuspended(suspended)
    }

    /// Pure modifier-family check: true only when the active hold slot is a
    /// bare modifier whose family appears in the pressed transform combo.
    nonisolated static func comboSharesHoldFamily(
        comboKind: ShortcutTrigger.Kind,
        holdKind: ShortcutTrigger.Kind
    ) -> Bool {
        guard case .combo(let modifiers, _) = comboKind,
              case .modifierHold(let holdCode) = holdKind
        else { return false }
        return ShortcutTrigger.Kind.holdCodeSharesComboFamily(
            holdCode: holdCode, comboModifiers: modifiers
        )
    }

    /// False when the OS refused registration (used by another app) — the
    /// Settings row says so instead of going silently dead.
    func isLive(_ preset: TransformPreset) -> Bool {
        monitors[preset]?.isLive ?? false
    }

    /// Current dictation kinds for the Settings advisory (same rule, same
    /// strings — the pure gate compares all six slots).
    func currentDictationKinds() -> (hold: ShortcutTrigger.Kind, handsFree: ShortcutTrigger.Kind) {
        dictationKinds()
    }

    private func receive(_ event: ShortcutEvent, preset: TransformPreset) {
        guard case .keyDown(let isRepeat) = event, !isRepeat else { return }
        // Capture target synchronously at keypress (before any settle sleep).
        let capturedTarget = runner.captureTarget()
        let pressedKind = shortcuts.kind(for: preset)
        // Strict serialization: cancel the prior run AND await its cleanup
        // before starting the new run, so clipboard grabs never overlap and
        // `setSuspended(false)` can never be leaked.
        let previousTask = transformTask
        previousTask?.cancel()
        transformTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            // Settle: let an in-flight hold-begin from THIS press's
            // modifier-down land, then combo-wins cancel it ONLY if this
            // transform combo actually shares a modifier family with the hold.
            try? await Task.sleep(for: Self.comboSettle)
            guard !Task.isCancelled else { return }
            if Self.comboSharesHoldFamily(
                comboKind: pressedKind,
                holdKind: self.dictationKinds().hold
            ) {
                let cancelledHold = await self.cancelHoldForCombination()
                if cancelledHold {
                    self.log.info("transform cancelled a same-family hold and won")
                }
            }
            // Real sessions (hands-free, other-family hold, finalizing) veto.
            guard await !self.dictationLive() else { return }
            self.setSuspended(true)
            defer { self.setSuspended(false) }
            await self.runner.execute(preset: preset, target: capturedTarget)
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
