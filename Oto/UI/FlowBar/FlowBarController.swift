//
//  FlowBarController.swift
//  Oto
//
//  Slice 6B (+6C1 routing): the single owner of all pill/modal motion.
//  One 150 ms snapshot poll reads coordinator state (+ recovery text) and
//  drives everything: model projection, analyzer arm/disarm, panel
//  show/resize/hide, flash deadlines, failure-hold + dismiss, and the
//  catcher-modal/auto-copy routing. Views never poll; the coordinator is
//  never edited (reads only); the menu keeps its own one-shot reads.
//
//  Invariants: analyzer stops whenever recording ends (silence guaranteed
//  by await stop); the panel melts out (fade + orderOut) on the first
//  hidden poll after a visible state — completion renders no pixels,
//  insertion is the confirmation (v6); modal/auto-copy fire exactly once
//  per failure transition (route-key comparison); auto-copy writes once
//  per key; while dragging, the finger owns geometry (poll renders, never
//  moves) and no hide is scheduled or fired (Phase 8).
//

import AppKit
import Foundation
import os

@MainActor
final class FlowBarController {
    nonisolated static let pollInterval: UInt64 = 150_000_000
    /// Adoption window: a parked hide waits this long for a new session
    /// before melting (double-tap converts land inside it).
    nonisolated static let adoptionWindowNanoseconds: UInt64 = 400_000_000
    /// Vanish grace (v6): the first hidden poll after a visible state melts
    /// the loader out immediately — no hold, no end-state. Total exit ≈
    /// one 0.12s fade + this margin.
    nonisolated static let vanishDelay: Double = 0.14

    let model: FlowBarModel
    private let log = Logger(subsystem: "app.Oto", category: "flowbar")
    private let coordinator: DictationCoordinator
    private let analyzer: AudioSpectrumAnalyzer
    private let box: SpectrumFeedBox
    /// Internal for headless transition tests (@testable).
    let modal: NoTargetModalController
    /// Mic-denied mini modal (pill-slot card, not the pill).
    let permission: PermissionModalController
    private let pasteboard: NSPasteboard
    /// Mic-denied gate (no-flash workstream): when true the pill never
    /// shows — the permission card owns the surface. Injectable so tests
    /// never touch TCC; production reads the synchronous record permission.
    private let isMicDenied: () -> Bool

    private var panel: FlowBarPanel?
    private var pollTask: Task<Void, Never>?
    private var lastRouteKey: String?
    private var lastPermissionKey: String?
    private var analyzerRecording = false
    /// Fade-hide generation: any state change invalidates a pending hide
    /// so a new session never inherits a stale fade (v4 finishing).
    private var hideGeneration: UInt64 = 0
    private var lastStateKey: String?
    private var hideTask: Task<Void, Never>?
    /// True while a parked hide (adoption window) is pending. A new
    /// visible session then adopts the live panel instead of hide→show.
    private var parkedForAdoption = false

    /// `pasteboard` is injectable so tests never touch the user's clipboard.
    init(
        coordinator: DictationCoordinator,
        analyzer: AudioSpectrumAnalyzer,
        box: SpectrumFeedBox,
        modal: NoTargetModalController,
        permission: PermissionModalController,
        pasteboard: NSPasteboard = .general,
        isMicDenied: @escaping () -> Bool = { PermissionsManager().microphoneStatus() == .denied }
    ) {
        self.coordinator = coordinator
        self.analyzer = analyzer
        self.box = box
        self.modal = modal
        self.permission = permission
        self.pasteboard = pasteboard
        self.isMicDenied = isMicDenied
        self.model = FlowBarModel()
    }

    func start() {
        guard pollTask == nil else { return }
        // Prewarm (v4 F3b): first-show construction moves to launch, so
        // transitions only ever setFrame + orderFront.
        modal.prewarm()
        permission.prewarm()
        if panel == nil {
            panel = FlowBarPanel(width: VisualizerMath.panelWidth(for: .recording))
        }
        pollTask = Task { await self.pollLoop() }
    }

    func stop() async {
        pollTask?.cancel()
        if let pollTask { _ = await pollTask.value }
        pollTask = nil
        hideTask?.cancel()
        hideTask = nil
        parkedForAdoption = false
        await analyzer.stop()
        analyzerRecording = false
        panel?.cancelSnapFeedback()
        panel?.hide()
        permission.hide()
        // Route keys are per-poll-run dedup state: a stop/start inside
        // one failure window must re-fire, not inherit silence (audit).
        lastRouteKey = nil
        lastPermissionKey = nil
        lastStateKey = nil
    }

    // MARK: - Poll

    /// Test hooks: pill surface state without exposing the panel.
    var isPillVisible: Bool { panel?.isVisible ?? false }
    var isLiveValues: Bool { panel?.isLiveValues ?? false }

    private func pollLoop() async {
        while !Task.isCancelled {
            await self.pollOnce()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    /// Internal for headless transition tests (@testable). Production
    /// path is the poll loop above.
    func pollOnce() async {
        let state = await coordinator.state
        let recovery = await coordinator.recoveryText()
        let projection = FlowBarProjection.project(state, recoveryAvailable: recovery != nil)

        model.motionFrozen = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.update(projection: projection)

        // State change invalidates any pending fade-hide first — but ONLY
        // when the new target needs the panel. Hidden→hidden moves
        // (completed→idle) let the scheduled melt ride; cancelling there
        // would hide→reshow flicker on the very next poll (v6).
        let stateKey = "\(state)-\(projection.sessionID?.uuidString ?? "nil")"
        if stateKey != lastStateKey {
            lastStateKey = stateKey
            if projection.state != .hidden {
                if hideTask != nil, parkedForAdoption {
                    // Adoption: a new session landed inside the parked
                    // window (double-tap converts) — keep the live panel,
                    // switch sessions, never hide→show.
                    log.info("adopted hide for new session")
                }
                parkedForAdoption = false
                hideGeneration += 1
                hideTask?.cancel()
                hideTask = nil
                panel?.restoreContentAlpha()
            }
        }

        // Recovery routing BEFORE analyzer sync (v4 F3c): the modal must
        // not wait behind an awaited stop (~35ms) on the same poll.
        syncRecovery(state: state, recovery: recovery)
        syncPermissionModal(state: state)
        await syncAnalyzer(state: state)
        syncPanel(state: state, projection: projection)
    }

    // MARK: - Analyzer arm/disarm (recording only)

    private func syncAnalyzer(state: DictationState) async {
        let recording: Bool
        if case .recording = state { recording = true } else { recording = false }
        if recording, !analyzerRecording {
            analyzerRecording = true
            await analyzer.start(box: box, model: model)
        } else if !recording, analyzerRecording {
            analyzerRecording = false
            // Awaited: post-stop reads are silent, guaranteed.
            await analyzer.stop()
        }
    }

    // MARK: - Panel show/resize/hide

    private func syncPanel(state: DictationState, projection: FlowBarProjection) {
        // v6 vanish path: no end-state pixels. The first hidden poll after a
        // visible state melts the loader straight out (generation-guarded);
        // later hidden polls are no-ops.
        if projection.state == .hidden {
            // Drag owns the frame: cancel a pending melt instead of
            // scheduling one — the drop's next poll resumes normal logic.
            if panel?.isDragging == true {
                hideTask?.cancel()
                hideTask = nil
                parkedForAdoption = false
                return
            }
            guard hideTask == nil else { return }
            guard panel?.isVisible == true else {
                panel?.hide()
                return
            }
            switch state {
            case .cancelled, .completed:
                // Adoption park: fade now (as always) but hold hideNow for
                // the window — a new session inside adopts the live panel
                // instead of hide→show flicker. Double-tap converts (micro
                // cancelled, hands-free starting ~150 ms later) land here.
                // Pixel-silent terminals only: failed keeps the prompt melt
                // below (the catcher/modal owns those pixels).
                scheduleHide(after: Self.adoptionWindowNanoseconds, parked: true)
            default:
                scheduleHide(
                    after: UInt64(Self.vanishDelay * 1_000_000_000),
                    parked: false
                )
            }
            return
        }
        // Mic gate: denied owns the card, never the pill — not even during
        // starting (the flash this kills: preparing bars showed for the
        // whole audio.start + speech.prepare window before the failure
        // existed). Card lifecycle stays in syncPermissionModal.
        if isMicDenied() {
            panel?.hide()
            return
        }
        let width: CGFloat = VisualizerMath.panelWidth(for: projection.state)
        guard projection.state != .hidden && width > 0 else {
            panel?.hide()
            return
        }
        if panel == nil {
            panel = FlowBarPanel(width: width)
        }
        let position = FlowBarPosition.current()
        let dragging = panel?.isDragging == true
        // Shrink transitions play no fade-out (v4 F1b): the outgoing group
        // would overflow the already-narrower frame mid-fade.
        let shrink = width < (panel?.currentWidth ?? .greatestFiniteMagnitude)
        if !dragging {
            panel?.show(
                sessionID: projection.sessionID,
                displayID: Self.targetScreen(of: state),
                width: width,
                position: position
            )
        }
        if let visual = PillVisual.forState(projection.state) {
            // Vsync values loop owns bar transforms while bars are live;
            // the poll keeps group switching + geometry only (liveValues).
            let live = visual == .bars && !model.motionFrozen
            panel?.setLiveValues(live ? model : nil)
            panel?.render(
                visual: visual,
                values: model.sample.values,
                text: nil,
                centerText: false,
                reduceMotion: model.motionFrozen,
                animated: !shrink,
                liveValues: live
            )
        }
    }

    // MARK: - Recovery routing (6C1: modal or auto-copy, once per key)

    /// Schedules content fade now + `hideNow` after the delay
    /// (generation-guarded; drag inside skips and reschedules). A parked
    /// hide is adoption bait for the next visible session; a melt is
    /// today's prompt path.
    private func scheduleHide(after delay: UInt64, parked: Bool) {
        let generation = hideGeneration
        parkedForAdoption = parked
        panel?.fadeContentOut()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, generation == self.hideGeneration else { return }
            // A grab landed inside the window: skip this cycle and
            // clear the task so the next poll reschedules — never stuck.
            if self.panel?.isDragging == true {
                self.hideTask = nil
                self.parkedForAdoption = false
                return
            }
            self.hideTask = nil
            self.parkedForAdoption = false
            self.panel?.hideNow()
        }
    }

    private func syncRecovery(state: DictationState, recovery: String?) {
        let route = RecoveryRouter.route(
            state, recoveryText: recovery,
            modalEnabled: NoTargetModalSettings.isEnabled()
        )
        guard let route else {
            lastRouteKey = nil
            return
        }
        guard route.sessionKey != lastRouteKey else { return }
        lastRouteKey = route.sessionKey
        switch route {
        case .catcher(_, let text):
            // v6 morph: grow out of the live pill frame at its own slot
            // (top grows down, bottom grows up — zero travel). Pill hidden
            // or Reduce Motion → today's centered fade, byte-identical.
            // Over-limit transcripts (>100 words) auto-copy with the modal
            // rendering Copied: pixels stay capped, data stays whole.
            let overLimit = CatcherText.isOverLimit(text)
            if let pillFrame = panel?.frameForMorph {
                modal.showFromPill(
                    pillFrame: pillFrame, text: text,
                    displayID: Self.targetScreen(of: state),
                    position: FlowBarPosition.current(),
                    reduceMotion: model.motionFrozen,
                    autoCopied: overLimit
                )
            } else {
                modal.show(text: text, displayID: Self.targetScreen(of: state), autoCopied: overLimit)
            }
        case .autoCopy(_, let text):
            // Silent auto-copy: the catcher-off toggle promises the
            // transcript lands on the clipboard — no pill, no pixels.
            // Menu status + Copy/Retry own recovery (audit: status owns
            // errors, the pill never confirms finished sessions).
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    // MARK: - Permission modal (mic-denied pill-slot card)

    /// Mic-denied owns a card, never the pill: show once per failure
    /// transition at the current slot (hiding any pill flash), hide the
    /// moment state leaves `.failed` (a retry reshows it if still denied).
    /// Separate key from recovery routing — different surface, different lifecycle.
    private func syncPermissionModal(state: DictationState) {
        let key: String?
        if case .failed(let context, .microphoneDenied) = state {
            key = context?.id.uuidString ?? "nil-context"
        } else {
            key = nil
        }
        guard key != lastPermissionKey else { return }
        lastPermissionKey = key
        guard key != nil else {
            permission.hide()
            return
        }
        // Kill the pill flash first: the card replaces it, never joins it.
        hideTask?.cancel()
        hideTask = nil
        parkedForAdoption = false
        panel?.hide()
        permission.show(
            displayID: Self.targetScreen(of: state),
            position: FlowBarPosition.current()
        )
    }

    private nonisolated static func targetScreen(of state: DictationState) -> CGDirectDisplayID? {
        switch state {
        case .starting(let context), .recording(let context),
             .finalizing(let context), .inserting(let context),
             .completed(let context), .cancelled(let context):
            return context.targetScreen
        case .failed(let context, _):
            return context?.targetScreen
        case .idle:
            return nil
        }
    }
}
