//
//  FeedbackSoundsTests.swift
//  OtoTests
//
//  The three cue moments: which paths sound, which stay silent, and the one
//  ordering rule that matters — an outcome cue must be announced after the
//  media duck is restored, or it plays into a zeroed system volume.
//  Also pins the preference key, the default (on), and the asset resolver,
//  which is the only part of this feature that touches private OS layout.
//

import Foundation
import Testing
@testable import Oto

/// Ordered timeline of cues and duck transitions. Thread-safe because the
/// coordinator calls the cue sink from its own actor and the duck from the
/// main actor; the `await` in `restoreMedia` orders the two for real.
final class CueLog: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case cue(DictationCue)
        case ducked
        case restored
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.withLock { events.append(event) }
    }

    var all: [Event] {
        lock.withLock { events }
    }

    /// Only the sounds, in order — the duck transitions dropped.
    var cues: [DictationCue] {
        all.compactMap { event in
            guard case .cue(let cue) = event else { return nil }
            return cue
        }
    }
}

/// Press-cue spy for the shortcut layer (MainActor, like the real player).
@MainActor
final class SpyFeedbackSounds: FeedbackSounding {
    private(set) var cues: [DictationCue] = []

    func play(_ cue: DictationCue) {
        cues.append(cue)
    }
}

/// Duck fake that writes into the same timeline as the cues, so a test can
/// assert the cue came after the restore rather than merely that both ran.
@MainActor
final class LoggingDuck: MediaDucking {
    private let log: CueLog

    init(log: CueLog) {
        self.log = log
    }

    func duck(sessionID: UUID) async {
        log.record(.ducked)
    }

    func restore(sessionID: UUID) async {
        log.record(.restored)
    }
}

@MainActor
struct FeedbackSoundsTests {
    private static let stubTarget = TargetApplication(
        bundleIdentifier: "com.example.FakeTarget",
        processIdentifier: 1234,
        windowIdentifier: nil
    )

    private struct SUT {
        let coordinator: DictationCoordinator
        let speech: FakeSpeechService
        let inserter: FakeTextInsertion
        let log: CueLog
    }

    private func makeSUT(
        finalText: String = "hello oto",
        insertionResult: InsertionResult = .inserted,
        micDenied: Bool = false,
        audioPeak: Float = 1.0,
        startError: (any Error)? = nil,
        prepareError: (any Error)? = nil,
        finishError: (any Error)? = nil,
        targetAlive: Bool = true,
        startTone: Duration = .zero
    ) async -> SUT {
        let log = CueLog()
        let audio = FakeAudioCapture(startError: startError, stubPeak: audioPeak)
        let speech = FakeSpeechService(
            finalText: finalText, prepareError: prepareError, finishError: finishError
        )
        let target = FakeTargetCapture(stubTarget: Self.stubTarget)
        await target.setCapturedTargetAlive(targetAlive)
        let inserter = FakeTextInsertion(result: insertionResult)
        let duck = LoggingDuck(log: log)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: nil,
            micDeniedOverride: { micDenied },
            mediaDuck: duck,
            feedback: { cue in log.record(.cue(cue)) },
            startTone: startTone
        )
        return SUT(coordinator: coordinator, speech: speech, inserter: inserter, log: log)
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
        Issue.record("timed out waiting for state", sourceLocation: sourceLocation)
        return await coordinator.state
    }

    /// Full press → record → release → terminal, returning the terminal state.
    private func runSession(_ sut: SUT) async -> DictationState {
        guard let id = await sut.coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return await sut.coordinator.state
        }
        _ = await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.coordinator.finish(id)
        return await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
    }

    // MARK: - Success

    @Test func insertedAnnouncesLanded() async {
        let sut = await makeSUT()
        let terminal = await runSession(sut)
        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(sut.log.cues == [.landed])
    }

    @Test func silentSessionAnnouncesNothing() async {
        // Whole-session silence skips transcription and inserts nothing —
        // there are no words to confirm, so there is nothing to announce.
        let sut = await makeSUT(audioPeak: 0)
        guard let id = await sut.coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return
        }
        _ = await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        try? await Task.sleep(for: .milliseconds(600))
        await sut.coordinator.finish(id)
        _ = await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
        #expect(sut.log.cues.isEmpty)
    }

    @Test func emptyTranscriptAnnouncesNothing() async {
        let sut = await makeSUT(finalText: "")
        let terminal = await runSession(sut)
        guard case .completed = terminal else {
            Issue.record("expected completed, got \(terminal)")
            return
        }
        #expect(sut.log.cues.isEmpty)
    }

    @Test func cancelledSessionAnnouncesNothing() async {
        let sut = await makeSUT()
        guard let id = await sut.coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return
        }
        _ = await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.coordinator.cancel(id)
        _ = await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
        #expect(sut.log.cues.isEmpty)
    }

    // MARK: - Failures (one tone for all of them)

    @Test func microphoneDeniedAnnouncesFailed() async {
        let sut = await makeSUT(micDenied: true)
        _ = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
        #expect(sut.log.cues == [.failed])
    }

    @Test func audioStartErrorAnnouncesFailed() async {
        let sut = await makeSUT(startError: FakeAudioCapture.CaptureError())
        _ = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
        #expect(sut.log.cues == [.failed])
    }

    @Test func speechPrepareErrorAnnouncesFailed() async {
        let sut = await makeSUT(prepareError: FakeSpeechService.PreparationError())
        _ = await sut.coordinator.beginHold()
        _ = await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
        #expect(sut.log.cues == [.failed])
    }

    @Test func speechFinalizeErrorAnnouncesFailed() async {
        let sut = await makeSUT(finishError: FakeSpeechService.FinalizationError())
        let terminal = await runSession(sut)
        guard case .failed(_, .speechPreparation) = terminal else {
            Issue.record("expected failed(speechPreparation), got \(terminal)")
            return
        }
        #expect(sut.log.cues == [.failed])
    }

    @Test func targetGoneAnnouncesFailed() async {
        let sut = await makeSUT(targetAlive: false)
        let terminal = await runSession(sut)
        guard case .failed(_, .targetGone) = terminal else {
            Issue.record("expected failed(targetGone), got \(terminal)")
            return
        }
        #expect(sut.log.cues == [.failed])
    }

    @Test func insertionFailureAnnouncesFailed() async {
        let sut = await makeSUT(insertionResult: .recoverableFailure(reason: "denied"))
        let terminal = await runSession(sut)
        guard case .failed(_, .insertionFailed) = terminal else {
            Issue.record("expected failed(insertionFailed), got \(terminal)")
            return
        }
        #expect(sut.log.cues == [.failed])
    }

    @Test func noTextFieldAnnouncesFailed() async {
        // The catcher is a recovery surface, not a success: the words did not
        // land, so it takes the same failure tone as everything else.
        let sut = await makeSUT(insertionResult: .noEditableField)
        let terminal = await runSession(sut)
        guard case .failed(_, .noTextField) = terminal else {
            Issue.record("expected failed(noTextField), got \(terminal)")
            return
        }
        #expect(sut.log.cues == [.failed])
    }

    // MARK: - Ordering (the one rule that can be silently wrong)

    @Test func failureIsAnnouncedAfterTheDuckIsRestored() async {
        // Media ducking zeroes the output volume while recording, so a failure
        // tone played next to the state assignment would be inaudible. The
        // timeline proves the cue comes after the restore, not merely that
        // both happened.
        let sut = await makeSUT(insertionResult: .recoverableFailure(reason: "denied"))
        _ = await runSession(sut)
        #expect(sut.log.all == [.ducked, .restored, .cue(.failed)])
    }

    @Test func landedIsAnnouncedAfterTheDuckIsRestored() async {
        let sut = await makeSUT()
        _ = await runSession(sut)
        #expect(sut.log.all == [.ducked, .restored, .cue(.landed)])
    }

    // MARK: - The start tone owns the first half-second

    @Test func duckWaitsOutTheStartTone() async {
        // Ducking zeroes the output instantly; press→ready lands around
        // 110–140 ms while the start tone runs 454 ms. The duck must come after
        // the tone, or the user hears a click instead of a tone.
        let tone = Duration.milliseconds(350)
        let sut = await makeSUT(startTone: tone)
        let clock = ContinuousClock()
        let pressedAt = clock.now
        guard let id = await sut.coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return
        }
        _ = await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        while !sut.log.all.contains(.ducked) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(clock.now - pressedAt >= tone)
        await sut.coordinator.cancel(id)
    }

    @Test func finishingInsideTheStartToneNeverDucks() async {
        // A quick tap that ends before the tone does must not leave the machine
        // muted: no duck at all is the only safe answer.
        let sut = await makeSUT(startTone: .milliseconds(400))
        guard let id = await sut.coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return
        }
        _ = await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.coordinator.finish(id)
        _ = await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
        // Let the (abandoned) tone window close, then prove nothing ducked.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!sut.log.all.contains(.ducked))
        #expect(sut.log.cues == [.landed])
    }

    // MARK: - Settings

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "oto-feedback-sounds-test-\(UUID().uuidString)")!
    }

    @Test func settingsKeyIsPinned() {
        // The Settings row stores this literal; the player reads it. Pinned so
        // a rename cannot silently mute the toggle.
        #expect(FeedbackSoundSettings.key == "app.Oto.feedbackSounds")
    }

    @Test func absentKeyMeansOn() {
        #expect(FeedbackSoundSettings.isEnabled(defaults: freshDefaults()))
    }

    @Test func explicitOffSticks() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: FeedbackSoundSettings.key)
        #expect(!FeedbackSoundSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: FeedbackSoundSettings.key)
        #expect(FeedbackSoundSettings.isEnabled(defaults: defaults))
    }

    // MARK: - Asset resolution

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oto-feedback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func overrideDirectoryWins() throws {
        let directory = try tempDirectory()
        let file = directory.appendingPathComponent(FeedbackSoundAsset.beginRecord.rawValue)
        try Data([0, 1, 2, 3]).write(to: file)
        #expect(FeedbackSoundAsset.beginRecord.url(in: directory)?.path == file.path)
    }

    @Test func overrideWithoutTheFileResolvesNothing() throws {
        // An explicit directory means exactly that directory: no silent fall
        // back to the system copy, which would hide a broken override.
        let empty = try tempDirectory()
        #expect(FeedbackSoundAsset.beginRecord.url(in: empty) == nil)
    }

    @Test func systemFilesResolveOnThisMac() {
        // OS layout check, not an assertion about Apple's release schedule: if
        // the files are not where 26 puts them, this is a silent skip and the
        // app falls back to silence by design.
        let expected = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf"
        guard FileManager.default.isReadableFile(atPath: expected) else { return }
        #expect(FeedbackSoundAsset.beginRecord.url(in: nil)?.path == expected)
        #expect(FeedbackSoundAsset.endRecord.url(in: nil) != nil)
        #expect(FeedbackSoundAsset.unableToStart.url(in: nil) != nil)
    }

    @Test func playerBuildsVoicesForResolvableCues() throws {
        let directory = try tempDirectory()
        let systemFile = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf")
        guard FileManager.default.isReadableFile(atPath: systemFile.path) else { return }
        try FileManager.default.copyItem(
            at: systemFile,
            to: directory.appendingPathComponent(FeedbackSoundAsset.beginRecord.rawValue)
        )
        let player = FeedbackSoundPlayer(directory: directory)
        #expect(player.loadedCues == [.listening])
        // Missing cues are silent, not fatal.
        player.play(.landed)
        player.play(.failed)
    }

    @Test func emptyDirectoryYieldsASilentPlayer() throws {
        let player = FeedbackSoundPlayer(directory: try tempDirectory())
        #expect(player.loadedCues.isEmpty)
        player.play(.listening)
    }
}
