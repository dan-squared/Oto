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
    nonisolated static let successFlashDuration: Double = 1.0
    nonisolated static let cancelledFlashDuration: Double = 0.8
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
    private var dismissedSessionID: UUID?
    private var consumedFlashID: UUID?
    private var lastRouteKey: String?
    private var flashDeadline: Date?
    private var flashSessionID: UUID?
    private var noticeDeadline: Date?
    private var analyzerRecording = false

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
        self.model = FlowBarModel(coordinator: coordinator)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { await self.pollLoop() }
    }

    func stop() async {
        pollTask?.cancel()
        if let pollTask { _ = await pollTask.value }
        pollTask = nil
        await analyzer.stop()
        analyzerRecording = false
        panel?.hide()
    }

    /// Failure-panel Dismiss intent. The state stays failed (recovery is
    /// untouched); only this session's panel is suppressed until the state
    /// moves on.
    func dismissFailure() {
        dismissedSessionID = model.projection.sessionID
        flashDeadline = nil
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
        var projection = FlowBarProjection.project(state, recoveryAvailable: recovery != nil)

        // Dismiss suppression: same failed session stays hidden.
        if projection.state == .failure, projection.sessionID == dismissedSessionID {
            projection = FlowBarProjection(
                state: .hidden, sessionID: nil, handsFreeCaption: false,
                message: nil, showsSettingsLink: false,
                recoveryAvailable: projection.recoveryAvailable
            )
        } else if projection.sessionID != dismissedSessionID {
            dismissedSessionID = nil
        }

        model.motionFrozen = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.update(projection: projection)

        await syncAnalyzer(state: state)
        syncPanel(state: state, projection: projection)
        syncRecovery(state: state, recovery: recovery)
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
            panel = FlowBarPanel(model: model, controller: self, width: width)
        }
        panel?.show(
            sessionID: projection.sessionID,
            displayID: Self.targetScreen(of: state),
            width: width
        )
        panel?.syncContentWidth(model: model, controller: self)
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
                flashDeadline = nil
                consumedFlashID = projection.sessionID
                panel?.hide()
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
