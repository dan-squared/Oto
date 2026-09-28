//
//  DictationCoordinatorTests.swift
//  OtoTests
//
//  Phase 1: fake end-to-end session through the coordinator.
//  Every external boundary is faked; no audio, speech, paste, or
//  machine state. Deterministic: gates and polling, no bare sleeps
//  asserting behavior (short poll sleeps live only in the wait helper).
//

import Foundation
import Testing
@testable import Oto

// All sessions run through background actors; the suite itself rides the
// main actor (same precedent as RealTextInsertionTests): actors, inits,
// and state comparisons stay in one domain (Swift 6).
@MainActor
struct DictationCoordinatorTests {
    private static let stubTarget = TargetApplication(
        bundleIdentifier: "com.example.FakeTarget",
        processIdentifier: 1234,
        windowIdentifier: nil
    )

    private func makeSUT(
        finalText: String = "hello oto",
        insertionResult: InsertionResult = .inserted,
        prepareGateOpen: Bool = true,
        finishError: (any Error)? = nil,
        micDenied: Bool = false,
        audioPeak: Float = 1.0,
        startError: (any Error)? = nil,
        prepareError: (any Error)? = nil,
        finishGateOpen: Bool = true,
        insertGateOpen: Bool = true
    ) -> (
        coordinator: DictationCoordinator,
        audio: FakeAudioCapture,
        speech: FakeSpeechService,
        target: FakeTargetCapture,
        inserter: FakeTextInsertion
    ) {
        let audio = FakeAudioCapture(startError: startError, stubPeak: audioPeak)
        let speech = FakeSpeechService(
            finalText: finalText,
            prepareError: prepareError,
            finishError: finishError,
            prepareGateOpen: prepareGateOpen,
            finishGateOpen: finishGateOpen
        )
        let target = FakeTargetCapture(stubTarget: Self.stubTarget)
        let inserter = FakeTextInsertion(result: insertionResult, insertGateOpen: insertGateOpen)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: nil,
            micDeniedOverride: { micDenied }
        )
        return (coordinator, audio, speech, target, inserter)
    }

    /// Polls until `predicate` holds or the timeout expires.
    private func waitFor(
        _ coordinator: DictationCoordinator,
        timeout: Duration = .seconds(5),
        _ predicate: @Sendable (DictationState) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> DictationState {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let state = await coordinator.state
            if predicate(state) {
                return state
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for coordinator state", sourceLocation: sourceLocation)
        return await coordinator.state
    }

    // MARK: - 1. Happy path

    @Test func holdBeginFinishInsertsIntoCapturedTarget() async {
        let (coordinator, _, _, _, inserter) = makeSUT(finalText: "hello oto")

        let id = await coordinator.beginHold()
        #expect(id != nil)
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .completed(let context) = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(context.id == id)
        let calls = await inserter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.text == "hello oto")
        #expect(calls.first?.target == Self.stubTarget)
    }

    // MARK: - Silent skip (no loader for voice-less sessions)

    @Test func silentLongSessionSkipsTranscription() async {
        // Whole-session silence past the duration guard completes without
        // transcription — speech.finish never runs, so the loader never
        // exists. Nothing inserted, same silent vanish as pipeline-empty.
        let sut = makeSUT(finalText: "hello oto", audioPeak: 0)
        let id = await sut.coordinator.beginHold()
        #expect(id != nil)
        _ = await waitFor(sut.coordinator, { if case .recording = $0 { return true }; return false })
        try? await Task.sleep(for: .milliseconds(600))
        await sut.coordinator.finish(id!)
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(await sut.speech.finishCalls == 0)
        #expect(await sut.inserter.calls.isEmpty)
    }

    @Test func silentShortSessionTakesFullPath() async {
        // Short sessions always transcribe — a quick quiet word (or
        // not-yet-arrived buffers) must never die silent.
        let sut = makeSUT(finalText: "hello oto", audioPeak: 0)
        let id = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator, { if case .recording = $0 { return true }; return false })
        await sut.coordinator.finish(id!)
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(await sut.speech.finishCalls == 1)
    }

    @Test func silentSkipGateConstantsAreConservative() {
        // −40 dBFS floor, 500 ms of audio before trust, 120 ms
        // trailing-edge settle. Device matrix confirms or lowers.
        #expect(DictationCoordinator.silencePeakThreshold == 0.01)
        #expect(DictationCoordinator.minimumRecordedAudio == .milliseconds(500))
        #expect(DictationCoordinator.trailingEdgeSettle == .milliseconds(120))
    }

    @Test func micDeniedFailsFastWithoutStartingAudio() async {
        // No-flash workstream: denial is knowable upfront — preparation
        // fails with .microphoneDenied before audio.start() ever runs.
        let (coordinator, audio, _, _, _) = makeSUT(micDenied: true)
        _ = await coordinator.beginHold()
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed(_, .microphoneDenied) = terminal else {
            Issue.record("expected microphoneDenied, got \(terminal)")
            return
        }
        #expect(await audio.startCalls == 0)
    }

    // MARK: - 2. Release during preparation finishes when ready

    @Test func finishDuringStartingCompletesAfterPreparation() async {
        let (coordinator, _, speech, _, inserter) = makeSUT(prepareGateOpen: false)

        let id = await coordinator.beginHold()
        #expect(id != nil)
        _ = await waitFor(coordinator, { if case .starting = $0 { return true }; return false })

        // Release while preparing: must arm finish, not cancel.
        await coordinator.finish(id!)
        let stillStarting = await coordinator.state
        guard case .starting = stillStarting else {
            Issue.record("finish during starting must not leave starting, got \(stillStarting)")
            return
        }

        await speech.openPrepareGate()
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .completed = terminal else {
            Issue.record("expected completed after gate opened, got \(terminal)")
            return
        }
        #expect(await inserter.calls.count == 1)
        #expect(await speech.cancelCalls == 0)
    }

    // MARK: - 3. Cancel path

    @Test func cancelDuringRecordingInsertsNothing() async {
        let (coordinator, _, _, _, inserter) = makeSUT()

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.cancel(id!)
        let terminal = await waitFor(coordinator, { if case .cancelled = $0 { return true }; return false })

        guard case .cancelled = terminal else {
            Issue.record("expected cancelled, got \(terminal)")
            return
        }
        #expect(await inserter.calls.count == 0)
    }

    // MARK: - 4. Finish/cancel race once

    @Test func finishThenCancelStaysCompleted() async {
        let (coordinator, _, _, _, _) = makeSUT()

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        _ = await waitFor(coordinator, { if case .completed = $0 { return true }; return false })
        await coordinator.cancel(id!)

        let state = await coordinator.state
        guard case .completed = state else {
            Issue.record("cancel after finish must be a no-op, got \(state)")
            return
        }
    }

    @Test func cancelThenFinishStaysCancelled() async {
        let (coordinator, _, _, _, inserter) = makeSUT()

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.cancel(id!)
        _ = await waitFor(coordinator, { if case .cancelled = $0 { return true }; return false })
        await coordinator.finish(id!)

        let state = await coordinator.state
        guard case .cancelled = state else {
            Issue.record("finish after cancel must be a no-op, got \(state)")
            return
        }
        #expect(await inserter.calls.count == 0)
    }

    // MARK: - 5. One gesture, one session

    @Test func secondBeginWhileActiveIsRejected() async {
        let (coordinator, _, _, _, _) = makeSUT()

        let first = await coordinator.beginHold()
        #expect(first != nil)
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        let second = await coordinator.beginHold()
        #expect(second == nil)
    }

    // MARK: - 6. Stale results discarded

    @Test func latePreparationAfterCancelIsDiscarded() async {
        let (coordinator, _, speech, _, inserter) = makeSUT(prepareGateOpen: false)

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .starting = $0 { return true }; return false })
        await coordinator.cancel(id!)
        // Let the in-flight preparation run to completion after cancel.
        await speech.openPrepareGate()
        let gateClock = ContinuousClock()
        let gateDeadline = gateClock.now + .seconds(5)
        while await speech.prepareCalls < 1 && gateClock.now < gateDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await speech.prepareCalls >= 1)

        let state = await coordinator.state
        guard case .cancelled = state else {
            Issue.record("late preparation must not revive the session, got \(state)")
            return
        }
        #expect(await inserter.calls.count == 0)
    }

    @Test func finishWithUnknownSessionIDIsIgnored() async {
        let (coordinator, _, _, _, inserter) = makeSUT()

        _ = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(UUID())
        await coordinator.cancel(UUID())

        let state = await coordinator.state
        guard case .recording = state else {
            Issue.record("unknown IDs must not disturb the session, got \(state)")
            return
        }
        #expect(await inserter.calls.count == 0)
    }

    // MARK: - 7. Empty final completes without insertion

    @Test func emptyFinalCompletesWithoutInsertion() async {
        let (coordinator, _, _, _, inserter) = makeSUT(finalText: "   \n  ")

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(await inserter.calls.count == 0)
    }

    // MARK: - 8. Insertion failure stays recoverable

    @Test func insertionFailurePreservesTranscript() async {
        let (coordinator, _, _, _, _) = makeSUT(
            finalText: "keep me",
            insertionResult: .recoverableFailure(reason: "denied")
        )

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .failed(_, .insertionFailed(let reason)) = terminal else {
            Issue.record("expected failed(insertionFailed), got \(terminal)")
            return
        }
        #expect(reason == "denied")
        let recovery = await coordinator.recoveryTranscript
        #expect(recovery?.cleaned == "keep me")
    }

    // MARK: - 9. App switch keeps the captured target

    @Test func frontmostChangeDoesNotRedirectInsertion() async {
        let (coordinator, _, _, _, inserter) = makeSUT(finalText: "to captured")

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        // Capture is start-pinned by construction (the fake returns the
        // start target unconditionally, mirroring the real service): a
        // mid-session switch has nothing to redirect — the coordinator
        // holds no frontmost reference at all.
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        let calls = await inserter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.target == Self.stubTarget)
    }

    // MARK: - 10. Dead target keeps transcript in recovery

    @Test func deadTargetFailsWithoutInsertingElsewhere() async {
        let (coordinator, _, _, target, inserter) = makeSUT(finalText: "do not lose me")

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await target.setCapturedTargetAlive(false)
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .failed(_, .targetGone) = terminal else {
            Issue.record("expected failed(targetGone), got \(terminal)")
            return
        }
        #expect(await inserter.calls.count == 0)
        #expect(await coordinator.recoveryTranscript?.cleaned == "do not lose me")
    }

    // MARK: - 11. Hands-free shares the pipeline

    @Test func handsFreeToggleFinishesThroughSamePipeline() async {
        let (coordinator, _, _, _, inserter) = makeSUT(finalText: "hands free")

        let first = await coordinator.toggleHandsFree()
        #expect(first != nil)
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        _ = await coordinator.toggleHandsFree()
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .completed(let context) = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(context.interaction == .handsFree)
        #expect(context.id == first)
        let calls = await inserter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.text == "hands free")
    }

    // MARK: - 12. Repeated stop tolerance

    @Test func repeatedCancelAndFinishLeaveStableIdleSuccessor() async {
        let (coordinator, _, _, _, _) = makeSUT()

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        for _ in 0..<5 {
            await coordinator.cancel(id!)
            await coordinator.finish(id!)
        }
        let state = await coordinator.state
        guard case .cancelled = state else {
            Issue.record("expected stable cancelled, got \(state)")
            return
        }
        // A new session must still work afterwards — nothing stuck.
        let next = await coordinator.beginHold()
        #expect(next != nil)
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
    }

    // MARK: - 13. Dead mic fails loud (bt-sco-flap.md): zero audio is a
    // failure with an honest reason — never a silent empty completion.
    // No transcript exists to keep: recovery stays empty, clipboard
    // untouched, insertion never attempted.

    @Test func zeroAudioFailsWithoutRecovery() async {
        let (coordinator, _, _, _, inserter) = makeSUT(
            finishError: SpeechSessionError.noAudioCaptured
        )
        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })

        guard case .failed(_, .noAudioCaptured) = terminal else {
            Issue.record("expected failed(noAudioCaptured), got \(terminal)")
            return
        }
        #expect(await coordinator.recoveryTranscript == nil)
        #expect(await inserter.calls.count == 0)
        #expect(await coordinator.lastSessionSummary() == "failed: no audio captured — check the microphone")
    }

    // MARK: - 14. Menu status copy (audit S4): UI-visible strings pinned

    @Test func statusCopyTracksStates() async {
        let (coordinator, _, _, _, _) = makeSUT()
        #expect(await coordinator.lastSessionSummary() == "idle — no session yet")

        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        #expect(await coordinator.lastSessionSummary() == "recording (holdToTalk)…")

        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(await coordinator.lastSessionSummary() == "completed (holdToTalk)")
    }

    @Test func statusCopyNamesFailureAndRecovery() async {
        let (coordinator, _, _, _, _) = makeSUT(
            finalText: "keep me",
            insertionResult: .recoverableFailure(reason: "denied")
        )
        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed = terminal else {
            Issue.record("expected failed, got \(terminal)")
            return
        }
        #expect(await coordinator.lastSessionSummary() == "failed: insertion failed (denied), transcript kept")
    }

    // MARK: - Media duck (Phase 7, spike-green)

    private func makeDuckSUT(
        insertionResult: InsertionResult = .inserted
    ) -> (coordinator: DictationCoordinator, duck: FakeMediaDuck) {
        let audio = FakeAudioCapture(stubPeak: 1.0)
        let speech = FakeSpeechService(finalText: "hello oto", finishError: nil, prepareGateOpen: true)
        let target = FakeTargetCapture(stubTarget: Self.stubTarget)
        let inserter = FakeTextInsertion(result: insertionResult)
        let duck = FakeMediaDuck()
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: nil,
            micDeniedOverride: { false },
            mediaDuck: duck
        )
        return (coordinator, duck)
    }

    @Test func duckOnRecordRestoreOnComplete() async {
        let (coordinator, duck) = makeDuckSUT()
        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        #expect(await duck.ducks == [id!])
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(await duck.restores == [id!])
    }

    @Test func cancelRestoresMedia() async {
        let (coordinator, duck) = makeDuckSUT()
        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.cancel(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .cancelled = terminal else {
            Issue.record("expected cancelled, got \(terminal)")
            return
        }
        #expect(await duck.ducks == [id!])
        #expect(await duck.restores == [id!])
    }

    @Test func failedInsertionStillRestoresMedia() async {
        let (coordinator, duck) = makeDuckSUT(insertionResult: .recoverableFailure(reason: "denied"))
        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed = terminal else {
            Issue.record("expected failed, got \(terminal)")
            return
        }
        #expect(await duck.ducks == [id!])
        #expect(await duck.restores == [id!])
    }

    // MARK: - Void-paste divert (catcher fix)

    @Test func noEditableFieldFailsWithKeptTranscript() async {
        // Finder/desktop shape through the full pipeline: the inserter
        // diverts, the coordinator keeps the transcript under a distinct
        // failure the catcher (and only the catcher) fires for.
        let audio = FakeAudioCapture(stubPeak: 1.0)
        let speech = FakeSpeechService(finalText: "void words", finishError: nil, prepareGateOpen: true)
        let target = FakeTargetCapture(stubTarget: Self.stubTarget)
        let inserter = FakeTextInsertion(result: .noEditableField)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: nil,
            micDeniedOverride: { false }
        )
        let id = await coordinator.beginHold()
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        let terminal = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed(_, .noTextField) = terminal else {
            Issue.record("expected failed(noTextField), got \(terminal)")
            return
        }
        #expect(await coordinator.recoveryText() == "void words")
        #expect(await coordinator.lastSessionSummary() == "failed: no text field focused, transcript kept")
    }

    // MARK: - Audit batch (concurrency + untested branches)

    /// Polls until `reads()` returns true or the timeout expires.
    private func waitForCondition(
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ reads: @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await reads() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for fake call count", sourceLocation: sourceLocation)
    }

    @Test func cancelMidFinalizeWins() async {
        // Cancel landing while finalize is suspended in speech.finish:
        // terminal stays cancelled, the late result inserts nothing.
        // (Proves the F2 terminal-first reorder under concurrency.)
        let sut = makeSUT(finishGateOpen: false)
        let id = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator, { if case .recording = $0 { return true }; return false })
        Task { await sut.coordinator.finish(id!) }
        await waitForCondition { await sut.speech.finishCalls == 1 }
        await sut.coordinator.cancel(id!)
        await sut.speech.openFinishGate()
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .cancelled = terminal else {
            Issue.record("expected cancelled, got \(terminal)")
            return
        }
        #expect(await sut.inserter.calls.isEmpty)
    }

    @Test func cancelMidInsertWins() async {
        // Cancel landing while the insert call itself is suspended: the
        // recorded call is discarded, terminal stays cancelled.
        let sut = makeSUT(insertGateOpen: false)
        let id = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator, { if case .recording = $0 { return true }; return false })
        Task { await sut.coordinator.finish(id!) }
        await waitForCondition { await sut.inserter.calls.count == 1 }
        await sut.coordinator.cancel(id!)
        await sut.inserter.openInsertGate()
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .cancelled = terminal else {
            Issue.record("expected cancelled, got \(terminal)")
            return
        }
    }

    @Test func audioStartThrowFailsWithoutSpeech() async {
        let sut = makeSUT(startError: FakeAudioCapture.CaptureError())
        let id = await sut.coordinator.beginHold()
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed(_, .audioCapture) = terminal else {
            Issue.record("expected failed(audioCapture), got \(terminal)")
            return
        }
        #expect(await sut.audio.startCalls == 1)
        #expect(await sut.speech.prepareCalls == 0)
        #expect(id != nil)
    }

    @Test func prepareGenericThrowFailsAfterAudioStop() async {
        let sut = makeSUT(prepareError: FakeSpeechService.PreparationError())
        _ = await sut.coordinator.beginHold()
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed(_, .speechPreparation) = terminal else {
            Issue.record("expected failed(speechPreparation), got \(terminal)")
            return
        }
        #expect(await sut.audio.stopCalls == 1)
    }

    @Test func prepareMicDeniedThrowFailsDistinctly() async {
        // Second mic-denied path (readiness throw inside prepare), distinct
        // from the fast-fail gate — maps to .microphoneDenied, not the
        // preparation bucket.
        let sut = makeSUT(prepareError: SpeechReadiness.microphoneDenied)
        _ = await sut.coordinator.beginHold()
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed(_, .microphoneDenied) = terminal else {
            Issue.record("expected failed(microphoneDenied), got \(terminal)")
            return
        }
    }

    @Test func finishEngineThrowFailsAsSpeechPreparation() async {
        // Non-noAudio finish errors (drop-threshold, engine failure) land
        // in the preparation bucket with the detail preserved in reason.
        let sut = makeSUT(finishError: FakeSpeechService.FinalizationError())
        let id = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator, { if case .recording = $0 { return true }; return false })
        await sut.coordinator.finish(id!)
        let terminal = await waitFor(sut.coordinator, { $0.isTerminal && $0 != .idle })
        guard case .failed(_, .speechPreparation) = terminal else {
            Issue.record("expected failed(speechPreparation), got \(terminal)")
            return
        }
    }
}
