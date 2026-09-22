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

@MainActor
final class FlowBarController {
    nonisolated static let pollInterval: UInt64 = 150_000_000
    nonisolated static let noticeDuration: Double = 2.0
    /// Vanish grace (v6): the first hidden poll after a visible state melts
    /// the loader out immediately — no hold, no end-state. Total exit ≈
    /// one 0.12s fade + this margin.
    nonisolated static let vanishDelay: Double = 0.14

    let model: FlowBarModel
    private let coordinator: DictationCoordinator
    private let analyzer: AudioSpectrumAnalyzer
    private let box: SpectrumFeedBox
    /// Internal for headless transition tests (@testable).
    let modal: NoTargetModalController
    private let pasteboard: NSPasteboard

    private var panel: FlowBarPanel?
    private var pollTask: Task<Void, Never>?
    private var lastRouteKey: String?
    private var noticeDeadline: Date?
    private var analyzerRecording = false
    /// Fade-hide generation: any state change invalidates a pending hide
    /// so a new session never inherits a stale fade (v4 finishing).
    private var hideGeneration: UInt64 = 0
    private var lastStateKey: String?
    private var hideTask: Task<Void, Never>?

    /// `pasteboard` is injectable so tests never touch the user's clipboard.
    init(
        coordinator: DictationCoordinator,
        analyzer: AudioSpectrumAnalyzer,
        box: SpectrumFeedBox,
        modal: NoTargetModalController,
        pasteboard: NSPasteboard = .general
    ) {
        self.coordinator = coordinator
        self.analyzer = analyzer
        self.box = box
        self.modal = modal
        self.pasteboard = pasteboard
        self.model = FlowBarModel()
    }

    func start() {
        guard pollTask == nil else { return }
        // Prewarm (v4 F3b): first-show construction moves to launch, so
        // transitions only ever setFrame + orderFront.
        modal.prewarm()
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
        await analyzer.stop()
        analyzerRecording = false
        panel?.cancelSnapFeedback()
        panel?.hide()
    }

    // MARK: - Poll

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
            if projection.state != .hidden || model.notice != nil {
                hideGeneration += 1
                hideTask?.cancel()
                hideTask = nil
                panel?.restoreContentAlpha()
            }
        }

        // Recovery routing BEFORE analyzer sync (v4 F3c): the modal must
        // not wait behind an awaited stop (~35ms) on the same poll.
        syncRecovery(state: state, recovery: recovery)
        await syncAnalyzer(state: state)
        syncPanel(state: state, projection: projection)
        syncDeadlines(projection: projection)
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
        let hasNotice = model.notice != nil
        // v6 vanish path: no end-state pixels. The first hidden poll after a
        // visible state melts the loader straight out (generation-guarded);
        // later hidden polls are no-ops. Notices render below, never here.
        if !hasNotice, projection.state == .hidden {
            // Drag owns the frame: cancel a pending melt instead of
            // scheduling one — the drop's next poll resumes normal logic.
            if panel?.isDragging == true {
                hideTask?.cancel()
                hideTask = nil
                return
            }
            guard hideTask == nil else { return }
            guard panel?.isVisible == true else {
                panel?.hide()
                return
            }
            let generation = hideGeneration
            panel?.fadeContentOut()
            hideTask = Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.vanishDelay * 1_000_000_000)
                )
                guard !Task.isCancelled, generation == self.hideGeneration else { return }
                // A grab landed inside the melt window: skip this cycle and
                // clear the task so the next poll reschedules — never stuck.
                if self.panel?.isDragging == true {
                    self.hideTask = nil
                    return
                }
                self.panel?.hideNow()
            }
            return
        }
        let width: CGFloat
        if hasNotice {
            // v7: the ONLY wide pill — auto-copy confirmation. Failure
            // panels are gone (concise menu status owns errors).
            width = VisualizerMath.noticeWidth
        } else {
            width = VisualizerMath.panelWidth(for: projection.state)
        }
        guard hasNotice || (projection.state != .hidden && width > 0) else {
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
            panel?.render(
                visual: visual,
                values: model.sample.values,
                text: model.notice,
                centerText: model.notice != nil,
                reduceMotion: model.motionFrozen,
                animated: !shrink
            )
        } else if let notice = model.notice {
            panel?.render(
                visual: .message,
                values: model.sample.values,
                text: notice, centerText: true,
                reduceMotion: model.motionFrozen,
                animated: !shrink
            )
        }
    }

    private func syncDeadlines(projection: FlowBarProjection) {
        // v6: no terminal-flash holds (completion renders nothing — the
        // vanish path in syncPanel owns the exit). Only transient notices
        // have deadlines now. `projection` stays in the signature so the
        // poll reads as one snapshot in, everything driven out.
        let now = Date()
        if model.notice != nil {
            if noticeDeadline == nil {
                noticeDeadline = now.addingTimeInterval(Self.noticeDuration)
            } else if let deadline = noticeDeadline, now >= deadline {
                noticeDeadline = nil
                model.clearNotice()
            }
        } else {
            noticeDeadline = nil
        }
    }

    // MARK: - Recovery routing (6C1: modal or auto-copy, once per key)

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
            modal.show(text: text, displayID: Self.targetScreen(of: state))
        case .autoCopy(_, let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            model.showNotice("Copied — paste with ⌘V.")
        }
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
