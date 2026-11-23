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
    /// Adoption window: a parked hide waits this long for a new session
    /// before melting (double-tap converts land inside it).
    nonisolated static let adoptionWindowNanoseconds: UInt64 = 400_000_000
    /// Vanish grace (v6): the first hidden update after a visible state melts
    /// the loader out immediately — no hold, no end-state. Total exit ≈
    /// one 0.12s fade + this margin.
    nonisolated static let vanishDelay: Double = 0.14
    /// Loader minimum dwell: finalizing/inserting routinely pass quickly
    /// (and completion melts in 0.14s), so the loader often never paints.
    /// Every completed session holds loader pixels for at least this long —
    /// a readability floor for work that genuinely happened, never motion
    /// for its own sake. Quick by design (0.4 s); matrix-tuned, never guessed.
    nonisolated static let loaderMinDwell: TimeInterval = 0.4
    /// Per-session loader-tail latch: the completed tail below fires
    /// once per session id. Without it, every later completed update
    /// (state is terminal-persistent until the next begin) would
    /// re-schedule and the pill would pop back forever.
    private var loaderTailedSession: UUID?

    let model: FlowBarModel
    private let log = Logger(subsystem: "app.Oto", category: "flowbar")
    private let coordinator: DictationCoordinator
    /// E2 transform feed (nil in tests and when unwired — the coordinator
    /// feed alone drives the cleanup beat). Optional so every existing
    /// construction compiles untouched.
    private let runner: TransformRunner?
    private let analyzer: AudioLevelAnalyzer
    private let box: LevelFeedBox
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
    private var isStarted = false
    private var coordinatorTask: Task<Void, Never>?
    private var runnerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var armedDeadline: ContinuousClock.Instant?
    private var isRefreshing = false
    private var needsAnotherRefresh = false
    private var workspaceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastRouteKey: String?
    private var lastPermissionKey: String?
    private var lastAnnouncedRecordingSession: UUID?
    private var analyzerRecording = false
    /// Fade-hide generation: any state change invalidates a pending hide
    /// so a new session never inherits a stale fade (v4 finishing).
    private var hideGeneration: UInt64 = 0
    private var lastStateKey: String?
    private var hideTask: Task<Void, Never>?
    /// True while a parked hide (adoption window) is pending. A new
    /// visible session then adopts the live panel instead of hide→show.
    private var parkedForAdoption = false
    /// Over-limit Copied pill latch: text + monotonic deadline. Set once per
    /// failure route; cleared by any live session or on expiry. Keeps
    /// the pixels capped at pill size without touching the coordinator.
    private var overLimitText: String?
    private var overLimitUntil: ContinuousClock.Instant?
    nonisolated static let overLimitDuration: TimeInterval = 2.5
    /// Failure notice latch: the same transient message pill as over-limit,
    /// for failures with no dedicated surface (the permission card owns
    /// mic-denied; the catcher/auto-copy owns recovery). One shot per failure
    /// transition, so state persistence never re-arms it.
    private var failureText: String?
    private var failureUntil: ContinuousClock.Instant?
    private var lastFailureKey: String?
    nonisolated static let failureMessageDuration: TimeInterval = 3.0

    /// `pasteboard` is injectable so tests never touch the user's clipboard.
    /// `runner` is optional (E2 transforms): nil in tests and pre-E2 hosts.
    init(
        coordinator: DictationCoordinator,
        analyzer: AudioLevelAnalyzer,
        box: LevelFeedBox,
        modal: NoTargetModalController,
        permission: PermissionModalController,
        pasteboard: NSPasteboard = .general,
        runner: TransformRunner? = nil,
        isMicDenied: @escaping () -> Bool = { PermissionsManager().microphoneStatus() == .denied }
    ) {
        self.coordinator = coordinator
        self.analyzer = analyzer
        self.box = box
        self.modal = modal
        self.permission = permission
        self.pasteboard = pasteboard
        self.runner = runner
        self.isMicDenied = isMicDenied
        self.model = FlowBarModel()
    }

    isolated deinit {
        coordinatorTask?.cancel()
        runnerTask?.cancel()
        refreshTask?.cancel()
        deadlineTask?.cancel()
        hideTask?.cancel()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func ensurePanel(width: CGFloat) -> FlowBarPanel {
        if let panel { return panel }
        let created = FlowBarPanel(width: width)
        created.onDragEnded = { [weak self] in
            self?.triggerRefresh()
        }
        panel = created
        return created
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Prewarm (v4 F3b): first-show construction moves to launch, so
        // transitions only ever setFrame + orderFront.
        modal.prewarm()
        permission.prewarm()
        _ = ensurePanel(width: VisualizerMath.panelWidth(for: .recording))

        let coord = coordinator
        coordinatorTask = Task { [weak self] in
            let stream = await coord.stateChanges()
            for await _ in stream {
                guard !Task.isCancelled, let self else { break }
                self.triggerRefresh()
            }
        }

        if let runner {
            runnerTask = Task { [weak self] in
                let stream = await runner.workChanges()
                for await _ in stream {
                    guard !Task.isCancelled, let self else { break }
                    self.triggerRefresh()
                }
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRefresh()
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRefresh()
            }
        }

        triggerRefresh()
    }

    func stop() async {
        isStarted = false
        coordinatorTask?.cancel()
        runnerTask?.cancel()
        refreshTask?.cancel()
        deadlineTask?.cancel()
        hideTask?.cancel()
        if let coordinatorTask { _ = await coordinatorTask.value }
        if let runnerTask { _ = await runnerTask.value }
        if let refreshTask { _ = await refreshTask.value }
        coordinatorTask = nil
        runnerTask = nil
        refreshTask = nil
        deadlineTask = nil
        armedDeadline = nil
        isRefreshing = false
        needsAnotherRefresh = false
        hideTask = nil
        parkedForAdoption = false
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        await analyzer.stop()
        analyzerRecording = false
        panel?.cancelSnapFeedback()
        panel?.hide()
        permission.hide()
        // Per-run dedup state resets on stop so a restart never inherits stale latches.
        lastRouteKey = nil
        lastPermissionKey = nil
        lastStateKey = nil
        lastAnnouncedRecordingSession = nil
        loaderTailedSession = nil
        overLimitText = nil
        overLimitUntil = nil
        failureText = nil
        failureUntil = nil
        lastFailureKey = nil
    }

    // MARK: - Event-driven refresh

    /// Coalesces bursts of coordinator, runner, accessibility, and defaults
    /// notifications into serialized `pollOnce()` passes with zero idle wakeups.
    private func triggerRefresh() {
        if isRefreshing {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.needsAnotherRefresh = false
                await self.pollOnce()
                if !self.needsAnotherRefresh { break }
            }
            self?.isRefreshing = false
        }
    }

    /// Arms a single one-shot timer ONLY while a timed latch (`overLimitUntil`
    /// or `failureUntil`) is active; cancels immediately when idle.
    private func syncDeadlineTimer(until deadline: ContinuousClock.Instant?) {
        guard isStarted, let deadline else {
            deadlineTask?.cancel()
            deadlineTask = nil
            armedDeadline = nil
            return
        }
        if armedDeadline == deadline, deadlineTask != nil { return }
        deadlineTask?.cancel()
        armedDeadline = deadline
        deadlineTask = Task { [weak self] in
            try? await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(20))
            guard !Task.isCancelled, let self else { return }
            self.armedDeadline = nil
            self.deadlineTask = nil
            self.triggerRefresh()
        }
    }

    /// Test hooks: pill surface state without exposing the panel.
    var isPillVisible: Bool { panel?.isVisible ?? false }
    var isLiveValues: Bool { panel?.isLiveValues ?? false }
    /// True while content is fully opaque (a visible window with faded
    /// content reads as missing — this catches what isPillVisible can't).
    var isContentFull: Bool { (panel?.contentAlpha ?? 1) >= 1 }
    /// Test hook: active pill content width (0 if panel not yet created).
    var currentPillWidth: CGFloat { panel?.currentWidth ?? 0 }

    /// Snapshot refresh. Event-driven in production (`start()`), and callable
    /// directly from headless transition tests (`@testable`).
    func pollOnce() async {
        let state = await coordinator.state
        let recovery = await coordinator.recoveryText()
        let baseProjection = FlowBarProjection.project(state, recoveryAvailable: recovery != nil)
        if baseProjection.state != .hidden {
            // Any live session supersedes a latched message outright.
            overLimitText = nil
            overLimitUntil = nil
            failureText = nil
            failureUntil = nil
        }
        model.setMotionFrozen(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        model.update(projection: baseProjection)

        // Announce recording start once per session for VoiceOver users.
        if case .recording(let context) = state {
            if lastAnnouncedRecordingSession != context.id {
                lastAnnouncedRecordingSession = context.id
                Self.announce("Dictation started")
            }
        } else {
            lastAnnouncedRecordingSession = nil
        }

        // E2 work feed: recording/starting never show work (transforms are
        // suspended while recording; cleanup never runs while recording).
        let workText: String?
        if Self.workAllows(state: state) {
            if let runnerWork = await runner?.currentWorkLabel() {
                workText = workPillText(runnerWork)
            } else {
                workText = await coordinator.workLabel().map(workPillText)
            }
        } else {
            workText = nil
        }

        // Recovery routing & failure latch run BEFORE the hide-invalidation
        // gate so transient `.message` pills (over-limit "Copied" and failure
        // notices) properly cancel any pending `hideTask` and restore alpha.
        let recoveryOwned = syncRecovery(state: state, recovery: recovery)
        syncFailureLatch(state: state, recoveryOwned: recoveryOwned)

        let now = ContinuousClock.now
        if let until = overLimitUntil, now >= until {
            overLimitText = nil
            overLimitUntil = nil
        }
        if let until = failureUntil, now >= until {
            failureText = nil
            failureUntil = nil
        }

        let messageText: String?
        let messageUntil: ContinuousClock.Instant?
        if let text = overLimitText, let until = overLimitUntil {
            messageText = text
            messageUntil = until
        } else {
            messageText = failureText
            messageUntil = failureUntil
        }

        var shownMessage: String?
        let routed: FlowBarProjection
        if baseProjection.state == .hidden,
           let text = messageText,
           let until = messageUntil,
           now < until
        {
            shownMessage = text
            routed = FlowBarProjection(
                state: .message, sessionID: nil,
                handsFreeCaption: false,
                recoveryAvailable: baseProjection.recoveryAvailable
            )
            syncDeadlineTimer(until: until)
        } else {
            routed = baseProjection
            syncDeadlineTimer(until: nil)
        }

        // E2 work beat: live model work overrides the state visual (same
        // controller-latch pattern as the message above — the coordinator
        // owns no pill state for this either).
        let projection = FlowBarProjection(
            state: routed.state, sessionID: routed.sessionID,
            handsFreeCaption: routed.handsFreeCaption,
            recoveryAvailable: routed.recoveryAvailable,
            workText: workText
        )

        // State change invalidates any pending fade-hide AFTER computing the
        // routed projection (including `.message` and `workText`), so transient
        // messages cancel stale hides and restore content alpha. Hidden→hidden
        // moves (completed→idle) let the scheduled melt ride.
        let stateKey = "\(state)-\(projection.sessionID?.uuidString ?? "nil")-work:\(workText ?? "-")-msg:\(shownMessage ?? "-")"
        if stateKey != lastStateKey {
            lastStateKey = stateKey
            if projection.state != .hidden || projection.workText != nil {
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

        syncPermissionModal(state: state)
        await syncAnalyzer(state: state)
        syncPanel(state: state, projection: projection, messageText: shownMessage)
    }

    // MARK: - Analyzer arm/disarm (recording only)

    /// Pure gate: work beats never render over recording/starting. Pinned
    /// by test (projection-level, no window).
    nonisolated static func workAllows(state: DictationState) -> Bool {
        switch state {
        case .starting, .recording:
            return false
        default:
            return true
        }
    }

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

    private func syncPanel(
        state: DictationState,
        projection: FlowBarProjection,
        messageText: String?
    ) {
        // v6 vanish path: no end-state pixels. The first hidden poll after a
        // visible state melts the loader straight out (generation-guarded);
        // later hidden polls are no-ops. Live work with no dictation state
        // skips this branch and takes the show path below — the pill is the
        // transform's session.
        if projection.state == .hidden && projection.workText == nil {
            // Drag owns the frame: cancel a pending melt instead of
            // scheduling one — the drop's next poll resumes normal logic.
            if panel?.isDragging == true {
                hideTask?.cancel()
                hideTask = nil
                parkedForAdoption = false
                return
            }
            guard hideTask == nil else { return }
            // Loader guarantee: a completed session holds loader pixels
            // for loaderMinDwell even when finalizing/inserting passed
            // between polls (or melted instantly). Once per session id
            // (state persists until the next begin); cancelled/failed and
            // recovery routes keep their existing paths.
            if case .completed(let context) = state, lastRouteKey == nil,
               loaderTailedSession != context.id
            {
                loaderTailedSession = context.id
                let panel = ensurePanel(width: VisualizerMath.panelWidth(for: .inserting))
                panel.setLiveValues(nil)
                // Full alpha, no fade: the tail holds readable pixels, so
                // the scheduled close must not melt them (a faded tail is
                // why the loader read as missing).
                panel.restoreContentAlpha()
                panel.show(
                    sessionID: context.id,
                    displayID: Self.targetScreen(of: state),
                    width: VisualizerMath.panelWidth(for: .inserting),
                    position: FlowBarPosition.current()
                )
                panel.render(
                    visual: .dotsSpinner,
                    level: 0,
                    time: CACurrentMediaTime(),
                    text: nil,
                    centerText: false,
                    reduceMotion: model.motionFrozen,
                    animated: true,
                    liveValues: false
                )
                scheduleHide(after: UInt64(Self.loaderMinDwell * 1_000_000_000), parked: true, fade: false)
                return
            }
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
        let width: CGFloat
        if let workText = projection.workText {
            // Work pill fits its text (measured, clamped) — the fixed
            // table never applies to work.
            width = VisualizerMath.workPillWidth(textWidth: VisualizerMath.measureWorkText(workText))
        } else if projection.state == .message, let messageText {
            // Dynamic width for message notices: `"Copied"` stays at
            // `dictationWidth` (80.85 pt) while full failure notices expand
            // cleanly up to 320 pt instead of truncating to ~8 characters.
            width = VisualizerMath.messagePillWidth(textWidth: VisualizerMath.measureWorkText(messageText))
        } else {
            width = VisualizerMath.panelWidth(for: projection.state)
        }
        // Work may render with no dictation state at all (transforms run
        // outside sessions — the pill is the session).
        guard (projection.state != .hidden || projection.workText != nil) && width > 0 else {
            panel?.hide()
            return
        }
        let panel = ensurePanel(width: width)
        let position = FlowBarPosition.current()
        let dragging = panel.isDragging
        // Shrink transitions play no fade-out (v4 F1b): the outgoing group
        // would overflow the already-narrower frame mid-fade.
        let shrink = width < panel.currentWidth
        if !dragging {
            panel.show(
                sessionID: projection.sessionID,
                displayID: Self.targetScreen(of: state),
                width: width,
                position: position
            )
        }
        // One visual per refresh: live work wins over the state visual (same
        // single render path — never a state render followed by a work
        // render, which would flicker through two group fades).
        let visual: PillVisual? = projection.workText != nil ? .work : PillVisual.forState(projection.state)
        if let visual {
            // Vsync values loop owns bar transforms while bars are live;
            // the controller keeps group switching + geometry only (liveValues).
            let live = visual == .bars && !model.motionFrozen
            panel.setLiveValues(live ? model : nil)
            panel.render(
                visual: visual,
                level: model.sample.level,
                time: CACurrentMediaTime(),
                text: projection.workText ?? (projection.state == .message ? messageText : nil),
                centerText: projection.workText == nil && projection.state == .message,
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
    /// today's prompt path. `fade: false` skips the fade for holds that
    /// must stay fully visible until close (loader tail).
    private func scheduleHide(after delay: UInt64, parked: Bool, fade: Bool = true) {
        let generation = hideGeneration
        parkedForAdoption = parked
        if fade {
            panel?.fadeContentOut()
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, generation == self.hideGeneration else { return }
            // A grab landed inside the window: skip this cycle and
            // clear the task so drag-end resumes hide scheduling — never stuck.
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

    /// Returns true when a recovery surface owns this failure — the pill
    /// must stay quiet even on a deduped update (the route is still live).
    @discardableResult
    private func syncRecovery(state: DictationState, recovery: String?) -> Bool {
        let route = RecoveryRouter.route(
            state, recoveryText: recovery,
            modalEnabled: NoTargetModalSettings.isEnabled()
        )
        guard let route else {
            lastRouteKey = nil
            overLimitText = nil
            overLimitUntil = nil
            return false
        }
        guard route.sessionKey != lastRouteKey else { return true }
        lastRouteKey = route.sessionKey
        // Recovery owns this transition: never stack a failure pill on top
        // of the catcher or the clipboard confirmation.
        failureText = nil
        failureUntil = nil
        switch route {
        case .catcher(_, let text):
            // Over-limit transcripts skip the modal: auto-copy + transient
            // message pill (latched below), pixels capped at pill size.
            if CatcherText.isOverLimit(text) {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                overLimitText = CatcherText.overLimitMessage
                overLimitUntil = ContinuousClock.now + .seconds(Self.overLimitDuration)
                Self.announce("Transcript copied to clipboard")
                log.info("over-limit auto-copy words=\(CatcherText.wordCount(text))")
                return true
            }
            overLimitText = nil
            overLimitUntil = nil
            // v6 morph: grow out of the live pill frame at its own slot
            // (top grows down, bottom grows up — zero travel). Pill hidden
            // or Reduce Motion → today's centered fade, byte-identical.
            if let pillFrame = panel?.frameForMorph {
                modal.showFromPill(
                    pillFrame: pillFrame, text: text,
                    displayID: Self.targetScreen(of: state),
                    position: FlowBarPosition.current(),
                    reduceMotion: model.motionFrozen
                )
            } else {
                modal.show(text: text, displayID: Self.targetScreen(of: state))
            }
        case .autoCopy(_, let text):
            // Silent auto-copy: the catcher-off toggle promises the
            // transcript lands on the clipboard — no pill, no pixels.
            // Menu status + Copy/Retry own recovery (audit: status owns
            // errors, the pill never confirms finished sessions).
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            Self.announce("Transcript copied to clipboard")
        }
        return true
    }

    // MARK: - Failure notice (transient pill message)

    /// Arms the short pill notice once per failure transition for failures
    /// with no dedicated surface. Mic-denied is card-owned (`failurePillText`
    /// returns nil); recovery-owned failures are skipped here. The key
    /// includes the failure so a retry that fails differently re-latches.
    private func syncFailureLatch(state: DictationState, recoveryOwned: Bool) {
        guard case .failed(let context, let failure) = state,
              let text = failurePillText(failure),
              !recoveryOwned
        else {
            lastFailureKey = nil
            return
        }
        let key = "\(context?.id.uuidString ?? "nil-context")|\(failure)"
        guard key != lastFailureKey else { return }
        lastFailureKey = key
        failureText = text
        failureUntil = ContinuousClock.now + .seconds(Self.failureMessageDuration)
        Self.announce(text)
    }

    private static func announce(_ message: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
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
