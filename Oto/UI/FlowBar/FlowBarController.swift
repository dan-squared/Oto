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
//  by await stop); panel orderOut only after terminal flashes elapse or an
//  explicit dismiss; modal/auto-copy fire exactly once per failure
//  transition (route-key comparison); auto-copy writes once per key.
//

import AppKit
import Foundation

@MainActor
final class FlowBarController {
    nonisolated static let pollInterval: UInt64 = 150_000_000
    // Liquid-quick finish (v5): the flash holds just long enough to read as
    // confirmation (~0.35s), then melts out in 0.12s — total vanish <0.55s.
    // (Was 1.0/0.8: the pill lingered past the "done" feeling.)
    nonisolated static let successFlashDuration: Double = 0.35
    nonisolated static let cancelledFlashDuration: Double = 0.30
    nonisolated static let noticeDuration: Double = 2.0

    let model: FlowBarModel
    private let coordinator: DictationCoordinator
    private let analyzer: AudioSpectrumAnalyzer
    private let box: SpectrumFeedBox
    /// Internal for headless transition tests (@testable).
    let modal: NoTargetModalController
    private let pasteboard: NSPasteboard

    private var panel: FlowBarPanel?
    private var pollTask: Task<Void, Never>?
    private var consumedFlashID: UUID?
    private var lastRouteKey: String?
    private var flashDeadline: Date?
    private var flashSessionID: UUID?
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
            panel = FlowBarPanel(width: VisualizerMath.panelWidth(for: .successFlash))
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

        // State change invalidates any pending fade-hide first.
        let stateKey = "\(state)-\(projection.sessionID?.uuidString ?? "nil")"
        if stateKey != lastStateKey {
            lastStateKey = stateKey
            hideGeneration += 1
            hideTask?.cancel()
            hideTask = nil
            panel?.restoreContentAlpha()
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
        let width: CGFloat
        if hasNotice {
            width = VisualizerMath.panelWidth(for: .failure)
        } else {
            width = VisualizerMath.panelWidth(for: projection.state)
        }
        // A consumed flash stays out until the state moves on (otherwise
        // the deadline would re-arm every poll — an infinite flash loop).
        let isConsumedFlash: Bool = {
            switch projection.state {
            case .successFlash, .cancelledFlash:
                return projection.sessionID == consumedFlashID
            default:
                return false
            }
        }()
        if !hasNotice, projection.sessionID != consumedFlashID {
            consumedFlashID = nil
        }
        guard !isConsumedFlash, (hasNotice || (projection.state != .hidden && width > 0)) else {
            // Flash deadlines hide explicitly; plain hidden hides now.
            if flashDeadline == nil { panel?.hide() }
            return
        }
        if panel == nil {
            panel = FlowBarPanel(width: width)
        }
        // Shrink transitions play no fade-out (v4 F1b): the outgoing group
        // would overflow the already-narrower frame mid-fade.
        let shrink = width < (panel?.currentWidth ?? .greatestFiniteMagnitude)
        panel?.show(
            sessionID: projection.sessionID,
            displayID: Self.targetScreen(of: state),
            width: width
        )
        if let visual = PillVisual.forState(projection.state) {
            panel?.render(
                visual: visual,
                values: model.sample.values,
                text: model.notice ?? projection.message,
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
        let now = Date()
        // Terminal flashes hold, then hide (failure holds indefinitely).
        switch projection.state {
        case .successFlash, .cancelledFlash:
            // Re-arm per session: a stale deadline from a previous flash
            // must never hide the new one instantly.
            if flashSessionID != projection.sessionID {
                flashSessionID = projection.sessionID
                let duration = projection.state == .successFlash
                    ? Self.successFlashDuration : Self.cancelledFlashDuration
                flashDeadline = now.addingTimeInterval(duration)
            } else if let deadline = flashDeadline, now >= deadline {
                // Buttery finish (v4 F2): render-server fade, then orderOut.
                // Generation-guarded: a state change above already cancelled
                // this task, so a stale completion can never hide new UI.
                flashDeadline = nil
                consumedFlashID = projection.sessionID
                let generation = hideGeneration
                panel?.fadeContentOut()
                hideTask?.cancel()
                hideTask = Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, generation == self.hideGeneration else { return }
                    self.panel?.hideNow()
                }
            }
        default:
            flashSessionID = nil
            break
        }
        if model.notice != nil {
            if noticeDeadline == nil {
                noticeDeadline = now.addingTimeInterval(Self.noticeDuration)
            } else if now >= noticeDeadline! {
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
