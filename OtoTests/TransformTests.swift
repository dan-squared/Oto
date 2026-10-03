//
//  TransformTests.swift
//  OtoTests
//
//  E2: selection grab (fail-closed, clipboard restored), the serial runner
//  (gates, single-flight, work feed), the transform save gate, the shared
//  bounded race, and the pill text/width math. No AX, no hardware, no
//  network — fakes and scratch boards throughout.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

private func scratchBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("oto-transform-\(UUID().uuidString)"))
}

/// Sendable board handle for `@Sendable` scripted closures (the grabber's
/// `postCopy` hook). Same precedent as `HookCount` in insertion tests.
private final class BoardBox: @unchecked Sendable {
    let board: NSPasteboard
    init(_ board: NSPasteboard) { self.board = board }
}

private struct StubGrabFocus: FocusChecking {
    let verdict: EditableFocus
    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus { verdict }
}

private func grabEvents(
    trusted: Bool = true,
    frontmostPID: @escaping @Sendable () -> pid_t? = { 99999 },
    otoFrontmost: @escaping @Sendable () -> Bool = { false },
    postCopy: @escaping @Sendable () async -> Bool = { true }
) -> InsertionEvents {
    InsertionEvents(
        isTrusted: { trusted },
        reactivate: { _ in true },
        currentModifiers: { [] },
        frontmostPID: frontmostPID,
        otoFrontmost: otoFrontmost,
        postPaste: { true },
        postCopy: postCopy,
        postUndo: { true },
        sleep: { _ in }
    )
}

/// Sendable Bool log for scripted dispatch hooks (suspend/cancel calls).
private final class HookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func bump() { record(true) }
    func record(_ value: Bool) { lock.withLock { items.append(value) } }
    func values() -> [Bool] { lock.withLock { items } }
}

@MainActor
struct TransformTests {
    // MARK: - Selection grab

    @Test func grabReturnsSelectionAndRestoresClipboard() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let box = BoardBox(board)
        let grabber = LiveSelectionGrabber(
            events: grabEvents(postCopy: {
                let board = box.board
                board.clearContents()
                board.setString("selected words", forType: .string)
                return true
            }),
            pasteboard: board,
            focusCheck: StubGrabFocus(verdict: .editable)
        )
        #expect(await grabber.grabSelection() == "selected words")
        // Read-only by contract: the user's clipboard comes back.
        #expect(board.string(forType: .string) == "mine")
        #expect(board.changeCount != before) // restore rewrites; content proves it
    }

    @Test func grabRefusalsReturnNilUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        // Untrusted.
        let untrusted = LiveSelectionGrabber(
            events: grabEvents(trusted: false), pasteboard: board,
            focusCheck: StubGrabFocus(verdict: .editable)
        )
        #expect(await untrusted.grabSelection() == nil)
        // Secure field.
        let secure = LiveSelectionGrabber(
            events: grabEvents(), pasteboard: board,
            focusCheck: StubGrabFocus(verdict: .secureField)
        )
        #expect(await secure.grabSelection() == nil)
        // No field.
        let void = LiveSelectionGrabber(
            events: grabEvents(), pasteboard: board,
            focusCheck: StubGrabFocus(verdict: .noField)
        )
        #expect(await void.grabSelection() == nil)
        // Copy keystroke failed.
        let noCopy = LiveSelectionGrabber(
            events: grabEvents(postCopy: { false }), pasteboard: board,
            focusCheck: StubGrabFocus(verdict: .editable)
        )
        #expect(await noCopy.grabSelection() == nil)
        // App wrote nothing (empty selection): change count never moves.
        let empty = LiveSelectionGrabber(
            events: grabEvents(postCopy: { true }), pasteboard: board,
            focusCheck: StubGrabFocus(verdict: .editable)
        )
        #expect(await empty.grabSelection() == nil)
        // Read-only by contract throughout: content restored on every path
        // (the grab's own snapshot+restore rewrites the board, so the count
        // moves — content equality is the proof, not the count).
        #expect(board.string(forType: .string) == "mine")
    }

    // MARK: - Runner

    private func makeRunner(
        selection: String? = "helo wrld",
        chunks: [String] = ["Hello world."],
        enabled: Bool = true,
        available: PolishAvailability = .available,
        targetAlive: Bool = true
    ) async -> (TransformRunner, FakeTextInsertion, FakePolishService, FakeSelectionGrabber, FakeTargetCapture) {
        let grabber = FakeSelectionGrabber()
        grabber.selection = selection
        let inserter = FakeTextInsertion()
        let target = FakeTargetCapture(stubTarget: TargetApplication(
            bundleIdentifier: "com.example.App", processIdentifier: 99999, windowIdentifier: nil
        ))
        await target.setCapturedTargetAlive(targetAlive)
        let polish = FakePolishService()
        polish.availabilityResult = available
        polish.chunks = chunks
        let behavior = CleanupBehavior(enabled: enabled, level: .light)
        let runner = TransformRunner(
            grabber: grabber, inserter: inserter, targetService: target,
            polish: polish, behaviorProvider: { behavior }
        )
        return (runner, inserter, polish, grabber, target)
    }

    private func waitForReplaces(
        _ inserter: FakeTextInsertion, count: Int, timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await inserter.replaceSelectionCalls.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func runAppliesRewriteOnce() async {
        let (runner, inserter, polish, grabber, _) = await makeRunner()
        await runner.execute(preset: .polish)
        #expect(await waitForReplaces(inserter, count: 1))
        let calls = await inserter.replaceSelectionCalls
        #expect(calls.count == 1)
        #expect(calls.first?.text == "Hello world.")
        #expect(polish.jobs == [.transform(.polish)])
        #expect(grabber.grabs == 1)
        #expect(await runner.currentWorkLabel() == nil)
    }

    @Test func runGatesRefuseSilently() async {
        // Disabled master switch: nothing grabbed, nothing streamed.
        let (off, _, offPolish, offGrab, _) = await makeRunner(enabled: false)
        await off.execute(preset: .polish)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(offGrab.grabs == 0)
        #expect(offPolish.prompts.isEmpty)
        // Unavailable model.
        let (na, _, naPolish, naGrab, _) = await makeRunner(available: .unavailable(copy: "x"))
        await na.execute(preset: .polish)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(naGrab.grabs == 0)
        // Empty selection.
        let (empty, emptyInserter, _, _, _) = await makeRunner(selection: nil)
        await empty.execute(preset: .polish)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await emptyInserter.replaceSelectionCalls.count == 0)
        // Identical rewrite: nothing to replace.
        let (same, sameInserter, _, _, _) = await makeRunner(selection: "same", chunks: ["same"])
        await same.execute(preset: .polish)
        #expect(await waitForReplaces(sameInserter, count: 1, timeout: .milliseconds(200)) == false)
        // Dead target.
        let (dead, deadInserter, _, _, _) = await makeRunner(targetAlive: false)
        await dead.execute(preset: .polish)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await deadInserter.replaceSelectionCalls.count == 0)
    }

    // MARK: - Dispatch scope (serial, suspend, live veto)

    private func makeDispatch(
        selection: String? = "helo wrld",
        chunks: [String] = ["Hello world."],
        dictationLive: @escaping @Sendable () async -> Bool = { false },
        cancelLog: HookLog? = nil,
        suspendLog: HookLog? = nil
    ) -> (TransformDispatch, FakeTextInsertion, FakePolishService, FakeSelectionGrabber) {
        let grabber = FakeSelectionGrabber()
        grabber.selection = selection
        let inserter = FakeTextInsertion()
        let target = FakeTargetCapture(stubTarget: TargetApplication(
            bundleIdentifier: "com.example.App", processIdentifier: 99999, windowIdentifier: nil
        ))
        let polish = FakePolishService()
        polish.chunks = chunks
        let runner = TransformRunner(
            grabber: grabber, inserter: inserter, targetService: target,
            polish: polish,
            behaviorProvider: { CleanupBehavior(enabled: true, level: .light) }
        )
        let holdOpt = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        let dispatch = TransformDispatch(
            runner: runner,
            dictationLive: dictationLive,
            dictationKinds: { (holdOpt, .unassigned) },
            cancelFreshMicroSession: { cancelLog?.bump() },
            setDictationSuspended: { suspended in suspendLog?.record(suspended) }
        )
        return (dispatch, inserter, polish, grabber)
    }

    @Test func secondPressCancelsFirst() async {
        // Both presses park at the closed gate (+100 ms settle each); the
        // second cancels the first. Opening the gate completes only the
        // survivor — one replacement, suspend balanced (true…false).
        let suspends = HookLog()
        let (dispatch, inserter, polish, _) = makeDispatch(suspendLog: suspends)
        await polish.streamGate.setOpen(false)
        dispatch.fireForTests(.polish)
        try? await Task.sleep(for: .milliseconds(300))
        dispatch.fireForTests(.concise)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await inserter.replaceSelectionCalls.count == 0)
        await polish.streamGate.setOpen(true)
        #expect(await waitForReplaces(inserter, count: 1))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await inserter.replaceSelectionCalls.count == 1)
        let log = suspends.values()
        #expect(log.first == true)
        #expect(log.last == false)
    }

    @Test func liveDictationVetoesTransform() async {
        // Recording: press ignored — no grab, no stream, no suspend. The
        // combo-wins cancel hook still fires first by design (it is the
        // safety net; with no micro-session it no-ops inside the
        // coordinator), then the live check vetoes before anything runs.
        let suspends = HookLog()
        let (dispatch, _, polish, grabber) = makeDispatch(
            dictationLive: { true }, suspendLog: suspends
        )
        dispatch.fireForTests(.polish)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(grabber.grabs == 0)
        #expect(polish.prompts.isEmpty)
        #expect(suspends.values().isEmpty)
    }

    // MARK: - Save gate

    @Test func gateAdvisoryCoversAllFiveSlots() {
        let transforms = TransformShortcuts.default()
        // Clean baseline: the factory pair (Opt hold + Cmd trio) never
        // conflicts — different families, zero cross-fire.
        let holdOpt = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        let free = ShortcutTrigger.Kind.unassigned
        // Clean triple: no advisory anywhere.
        for preset in TransformPreset.allCases {
            #expect(TransformShortcutGate.advisory(
                kind: transforms.kind(for: preset), preset: preset,
                transforms: transforms, hold: holdOpt, handsFree: free
            ) == nil)
        }
        // Opt-combo staged against an Option hold: refused, names the purpose.
        let optCombo = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_9)
        )
        #expect(TransformShortcutGate.advisory(
            kind: optCombo, preset: .polish,
            transforms: transforms, hold: holdOpt, handsFree: free
        )?.contains("Push to talk") == true)
        // Cmd-combo staged against a Command hold: refused symmetrically.
        let holdCmd = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightCommand))
        let cmdCombo = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_9)
        )
        #expect(TransformShortcutGate.advisory(
            kind: cmdCombo, preset: .polish,
            transforms: transforms, hold: holdCmd, handsFree: free
        )?.contains("Push to talk") == true)
        // Sibling digit: a new same-modifier digit alongside the trio is
        // allowed (Carbon distinguishes by keyCode — no double-fire).
        #expect(TransformShortcutGate.advisory(
            kind: cmdCombo, preset: .concise,
            transforms: transforms, hold: holdOpt, handsFree: free
        ) == nil)
        // Exact dup of a sibling: refused, names the sibling.
        #expect(TransformShortcutGate.advisory(
            kind: transforms.kind(for: .polish), preset: .concise,
            transforms: transforms, hold: holdOpt, handsFree: free
        )?.contains("Polish") == true)
    }

    // MARK: - Shared race + pill math

    @Test func boundedRaceFailsOpen() async {
        let polish = FakePolishService()
        polish.chunks = ["Polished."]
        let fast = await racePolishText(
            polish: polish, text: "raw", job: .transform(.polish), timeout: .seconds(2)
        )
        #expect(fast == "Polished.")
        polish.chunks = []
        let empty = await racePolishText(
            polish: polish, text: "raw", job: .cleanup(.light), timeout: .seconds(2)
        )
        #expect(empty == nil)
        await polish.streamGate.setOpen(false)
        let slow = await racePolishText(
            polish: polish, text: "raw", job: .cleanup(.light), timeout: .milliseconds(50)
        )
        #expect(slow == nil)
        await polish.streamGate.setOpen(true)
    }

    @Test func workTextAndGate() {
        // One verb max, always: Cleaning for Auto Cleanup, the preset's
        // own pill verb for transforms.
        #expect(workPillText(.cleaningUp) == "Cleaning")
        #expect(workPillText(.preset(.polish)) == "Polishing")
        #expect(workPillText(.preset(.concise)) == "Shortening")
        #expect(workPillText(.preset(.professional)) == "Formalizing")
        #expect(TransformPreset.polish.pillVerb == "Polishing")
        let ctx = SessionContext(
            id: UUID(), startedAt: ContinuousClock().now,
            target: TargetApplication(bundleIdentifier: nil, processIdentifier: nil, windowIdentifier: nil),
            targetScreen: nil, interaction: .holdToTalk
        )
        #expect(FlowBarController.workAllows(state: .recording(ctx)) == false)
        #expect(FlowBarController.workAllows(state: .starting(ctx)) == false)
        #expect(FlowBarController.workAllows(state: .finalizing(ctx)) == true)
        #expect(FlowBarController.workAllows(state: .idle) == true)
    }

    @Test func workWidthFitsLabelsAndClamps() {
        // All four labels fit untruncated at the pill font (the plan's pin).
        for text in ["Cleaning", "Polishing", "Shortening", "Formalizing"] {
            let w = VisualizerMath.workPillWidth(textWidth: VisualizerMath.measureWorkText(text))
            #expect(w < VisualizerMath.workMaxWidth)
        }
        // Longest label measures widest (raw metrics).
        #expect(VisualizerMath.measureWorkText("Formalizing") > VisualizerMath.measureWorkText("Polishing"))
        // Exact hug: no minimum padding — width always exceeds raw text by
        // at least the chrome (slack included, so exact-fit ellipsis can
        // never recur), and tiny text hugs instead of floating in a floor.
        let chrome = VisualizerMath.workPadding * 2 + VisualizerMath.workSpinnerGap
            + VisualizerMath.spinnerSize + VisualizerMath.workTextSlack
        #expect(VisualizerMath.workPillWidth(textWidth: VisualizerMath.measureWorkText("Polishing"))
            - VisualizerMath.measureWorkText("Polishing") >= chrome - 1)
        #expect(VisualizerMath.workPillWidth(textWidth: 0) == chrome)
        #expect(VisualizerMath.workPillWidth(textWidth: 10_000) == VisualizerMath.workMaxWidth)
    }
}
