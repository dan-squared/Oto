//
//  ShortcutDispatch.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os

/// Calibration state for the test-shortcut row. Set ONLY by observed real
/// global events — never by the recorder (12 limit).
enum ShortcutCalibration: Equatable, Sendable {
    case untested
    case ready
    case notReceivedGlobally
    case conflicts
    case requiresAccessibility
}

/// MainActor owner of the shortcut layer. Holds the monitors, the config,
/// and the transition machine; translates transitions into the ONE async
/// hop to the coordinator. Backends emit values; this decides nothing
/// about sessions beyond routing intents.
@MainActor
final class ShortcutDispatch {
    private let coordinator: DictationCoordinator
    private let log = Logger(subsystem: "app.Oto", category: "shortcut")

    private let modifierMonitor = ModifierHotkeyMonitor()
    private let hidMonitor = HIDEventMonitor()

    private var transition = HotkeyTransitionState()
    /// Latest session ID returned by the coordinator. Never cleared
    /// eagerly: cancel/finish are idempotent, so a stale ID is a harmless
    /// no-op — but clearing it would strand an Escape-during-starting
    /// cancel. Overwritten by each new begin.
    private var activeSessionID: UUID?
    private(set) var configuration: ShortcutConfiguration {
        didSet { configuration.save() }
    }

    /// Last real global down/up observed (for calibration). Nil until a
    /// full press-release cycle arrives through a live backend.
    private var observedDown = false
    private var observedUpAfterDown = false
    private(set) var calibration: ShortcutCalibration = .untested

    /// While true, global registration is suspended (recorder listening).
    private(set) var isSuspended = false

    init(coordinator: DictationCoordinator, configuration: ShortcutConfiguration = .load()) {
        self.coordinator = coordinator
        self.configuration = configuration

        modifierMonitor.onEvent = { [weak self] in self?.receive($0) }
        hidMonitor.onEvent = { [weak self] in self?.receive($0) }
        hidMonitor.onEscape = { [weak self] in self?.receiveEscape() }
    }

    // MARK: - Lifecycle

    /// (Re)register backends for the current configuration. Unregisters
    /// first: re-registering can never leave a stale callback behind
    /// (10_NEXT_STEP §1 acceptance).
    func start() {
        stop()
        guard configuration.enabled, !isSuspended else {
            updateCalibrationForAvailability()
            return
        }
        switch configuration.trigger.kind {
        case .modifierHold(let keyCode):
            // HID tap path (NSEvent monitors are banned: proven to wedge
            // MenuBarExtra tracking). Requires Accessibility trust.
            hidMonitor.configure(functionCodes: [], holdKeyCode: keyCode)
            if !hidMonitor.isLive {
                calibration = .requiresAccessibility
                log.error("HID tap unavailable (accessibility?)")
                return
            }
        case .combo(let modifiers, let keyCode):
            modifierMonitor.configure(comboModifiers: modifiers, keyCode: keyCode)
            if !modifierMonitor.isLive {
                calibration = .conflicts
                log.error("combo registration failed (conflict)")
                return
            }
            // Escape still rides the HID tap (best-effort: tap liveness
            // must NOT gate combo calibration — combos work without AX).
            hidMonitor.configure(functionCodes: [], holdKeyCode: nil)
        case .functionKey(let codes):
            hidMonitor.configure(functionCodes: codes, holdKeyCode: nil)
            if !hidMonitor.isLive {
                calibration = .requiresAccessibility
                log.error("HID tap unavailable (accessibility?)")
                return
            }
        }
        // Escape observation rides the HID tap (zero NSEvent monitors in
        // the trigger path); combo triggers need no Escape backend change.
        transition = HotkeyTransitionState()
        updateCalibrationForAvailability()
        log.info("shortcut dispatch started")
    }

    func stop() {
        modifierMonitor.stop()
        hidMonitor.stop()
        transition = HotkeyTransitionState()
    }

    /// Suspend global registration while the recorder listens, resume after.
    /// A release during suspension belongs to the recorder, never to us —
    /// so an in-flight session is cancelled first rather than stranded
    /// recording with its release path torn down.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        transition = HotkeyTransitionState()
        if suspended {
            cancelActiveSession()
            stop()
        } else {
            start()
        }
    }

    /// Re-check Accessibility-derived availability. Called on every menu
    /// open (the one hook guaranteed to run while the user is present —
    /// audit F2 wired the previously zero-caller path here). Revocation
    /// surfaces as unavailable; recovery re-registers. Never rebuilds
    /// while the trigger is physically down — tearing down mid-hold would
    /// strand the release.
    func refreshAvailability() {
        if requiresAccessibility && !isAccessibilityTrusted() {
            calibration = .requiresAccessibility
            return
        }
        guard !transition.isDown else { return }
        // Re-register to heal a timed-out tap or revoked backend.
        start()
    }

    // MARK: - Configuration changes

    func updateTrigger(_ trigger: ShortcutTrigger) {
        cancelActiveSession()
        configuration.trigger = trigger
        resetCalibration()
        start()
    }

    func updateInteraction(_ interaction: InteractionMode) {
        cancelActiveSession()
        configuration.trigger.interaction = interaction
        resetCalibration()
        transition = HotkeyTransitionState()
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            cancelActiveSession()
        }
        configuration.enabled = enabled
        resetCalibration()
        start()
    }

    // MARK: - Calibration

    /// Mark a full observed press-release cycle. Called only from `receive`
    /// on real backend events.
    private func noteObserved(down: Bool) {
        if down {
            observedDown = true
        } else if observedDown {
            observedUpAfterDown = true
            calibration = .ready
        }
    }

    func resetCalibration() {
        observedDown = false
        observedUpAfterDown = false
        calibration = .untested
        updateCalibrationForAvailability()
    }

    private var requiresAccessibility: Bool {
        // Carbon combos ride the window-server hotkey path (no AX needed);
        // anything on the HID tap needs trust.
        if case .combo = configuration.trigger.kind { return false }
        return true
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateCalibrationForAvailability() {
        guard configuration.enabled, !isSuspended else { return }
        if requiresAccessibility, !isAccessibilityTrusted() {
            calibration = .requiresAccessibility
        } else if calibration == .untested, !backendsLive {
            calibration = .notReceivedGlobally
        }
    }

    private var backendsLive: Bool {
        switch configuration.trigger.kind {
        case .combo:
            return modifierMonitor.isLive
        case .modifierHold, .functionKey:
            return hidMonitor.isLive
        }
    }

    // MARK: - Event routing (the single async hop)

    /// Any reconfiguration orphans the in-flight release path, so the
    /// active session (if any) is cancelled deterministically instead of
    /// stranding it recording. Cancel is discard-only.
    private func cancelActiveSession() {
        guard let id = activeSessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.cancel(id)
        }
    }

    /// One Task per user gesture at most (begin/finish only — repeats and
    /// ignores never hop). The 12 "no per-event task" limit constrains
    /// event streams, not gesture intents.
    private func receive(_ event: ShortcutEvent) {
        if case .keyDown = event {
            noteObserved(down: true)
        } else if case .keyUp = event {
            noteObserved(down: false)
        }
        let mode = configuration.trigger.interaction
        let action = transition.step(.event(event), mode: mode)
        route(action, mode: mode)
    }

    private func receiveEscape() {
        _ = transition.step(.escape, mode: configuration.trigger.interaction)
        guard let id = activeSessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.cancel(id)
        }
    }

    /// Escape-cancel availability (escape workstream): Escape rides the
    /// HID tap, which needs Accessibility trust — but combo triggers work
    /// without AX. So on a combo with a dead tap, dictation works while
    /// Escape cancel silently doesn't; the menu surfaces that instead of
    /// lying. HID-trigger configs are dead as a whole without the tap
    /// (calibration already reports it), so no second warning there.
    var isEscapeCancelAvailable: Bool {
        if case .combo = configuration.trigger.kind {
            return hidMonitor.isLive
        }
        return true
    }

    /// Test hooks: drive Escape→cancel without hardware. Seeding mirrors
    /// what route(.begin) stores on a real key-down.
    func seedActiveSessionForTests(_ id: UUID) { activeSessionID = id }
    func receiveEscapeForTests() { receiveEscape() }

    private func route(_ action: ShortcutTransition, mode: InteractionMode) {
        switch action {
        case .ignore, .reset:
            break
        case .begin:
            // Hands-free begins through the toggle path so the session is
            // recorded with the mode the person actually chose (audit F1).
            // `beginHold` would label it `.holdToTalk` and leave the tested
            // toggle path dead in production. Finish below is mode-agnostic.
            if mode == .handsFree {
                Task { [weak self] in
                    guard let self else { return }
                    if let id = await self.coordinator.toggleHandsFree() {
                        self.activeSessionID = id
                    }
                }
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    if let id = await self.coordinator.beginHold() {
                        self.activeSessionID = id
                    }
                }
            }
        case .finish:
            guard let id = activeSessionID else { break }
            Task { [weak self] in
                guard let self else { return }
                await self.coordinator.finish(id)
            }
        }
    }
}
