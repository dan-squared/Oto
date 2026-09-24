//
//  MediaDuckTests.swift
//  OtoTests
//
//  Phase 7 (spike-green): duck saves current volume, sets 0.0, restores
//  the saved value on every terminal path. Double-restore safe; toggle
//  OFF and missing 'vmvc' mean zero HAL calls; a crash flag guarantees
//  launch restores. No audio hardware, no defaults pollution (suite
//  defaults per test). Deterministic: no sleeps, no polling.
//

import CoreAudio
import Foundation
import Testing
@testable import Oto

/// Recording HAL fake. Lock-guarded like the production feed box: the
/// requirements are nonisolated (project defaults to MainActor), so
/// every access goes through the lock.
final class FakeHAL: MediaVolumeHAL, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _volume: Float32 = 0.5
    private nonisolated(unsafe) var _device: AudioObjectID = 70
    private nonisolated(unsafe) var _controlled: Set<AudioObjectID> = [70]
    private nonisolated(unsafe) var _noVolume = false
    private nonisolated(unsafe) var _setCalls: [(volume: Float32, device: AudioObjectID)] = []
    private nonisolated(unsafe) var _getCalls = 0

    func stub(volume: Float32, device: AudioObjectID, controlled: Set<AudioObjectID>) {
        lock.withLock {
            _volume = volume
            _device = device
            _controlled = controlled
            _noVolume = false
        }
    }

    /// Default output exposes no 'vmvc' at all (absolute-volume BT set).
    func stubNoVolumeControl() {
        lock.withLock { _noVolume = true }
    }

    var setCalls: [(volume: Float32, device: AudioObjectID)] {
        lock.withLock { _setCalls }
    }

    var getCalls: Int {
        lock.withLock { _getCalls }
    }

    nonisolated func currentVolume() -> (device: AudioObjectID, volume: Float32)? {
        lock.withLock {
            _getCalls += 1
            guard !_noVolume else { return nil }
            guard _controlled.contains(_device) else { return nil }
            return (_device, _volume)
        }
    }

    nonisolated func deviceHasVolumeControl(_ device: AudioObjectID) -> Bool {
        lock.withLock { !_noVolume && _controlled.contains(device) }
    }

    nonisolated func setVolume(_ volume: Float32, onDevice device: AudioObjectID) -> Bool {
        lock.withLock {
            guard !_noVolume && _controlled.contains(device) else { return false }
            _setCalls.append((volume, device))
            _volume = volume
            return true
        }
    }
}

/// Recording coordinator seam: asserts duck/restore happen with the
/// live session ID on the right transitions. MainActor class (not an
/// actor) because MediaDucking is MainActor-isolated.
@MainActor
final class FakeMediaDuck: MediaDucking {
    var ducks: [UUID] = []
    var restores: [UUID] = []

    func duck(sessionID: UUID) async { ducks.append(sessionID) }
    func restore(sessionID: UUID) async { restores.append(sessionID) }
}

@MainActor
struct MediaDuckTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "oto-mediaduck-test-\(UUID().uuidString)")!
    }

    // MARK: - Settings

    @Test func settingsKeyMatches() {
        #expect(MediaDuckSettings.key == "app.Oto.muteMediaWhileDictating")
    }

    @Test func absentKeyMeansOn() {
        #expect(MediaDuckSettings.isEnabled(defaults: freshDefaults()))
    }

    @Test func explicitOffSticks() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: MediaDuckSettings.key)
        #expect(!MediaDuckSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: MediaDuckSettings.key)
        #expect(MediaDuckSettings.isEnabled(defaults: defaults))
    }

    // MARK: - Duck / restore

    @Test func duckSavesAndMutes() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        #expect(hal.setCalls.count == 1)
        #expect(hal.setCalls[0].volume == 0.0)
        #expect(hal.setCalls[0].device == 70)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        #expect(defaults.float(forKey: MediaDuckSettings.savedVolumeKey) == 0.5)
    }

    @Test func duckTwiceSameSessionSetsOnce() async {
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: freshDefaults(), hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        await duck.duck(sessionID: id)
        #expect(hal.setCalls.count == 1)
    }

    @Test func restoreReturnsSavedAndDoubleRestoreIsSafe() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        await duck.restore(sessionID: id)
        // Restore parks for the grace window: nothing set yet, flag stays.
        #expect(hal.setCalls.count == 1)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        try? await Task.sleep(for: .milliseconds(350))
        #expect(hal.setCalls.count == 2)
        #expect(hal.setCalls[1].volume == 0.5)
        #expect(hal.setCalls[1].device == 70)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
        await duck.restore(sessionID: id)
        #expect(hal.setCalls.count == 2)
    }

    @Test func restoreGraceAbsorbsNextDuck() async {
        // Double-tap shape: micro restored, hands-free ducking inside the
        // grace — slot transfers, volume never pumps, flag never clears.
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let micro = UUID()
        let handsFree = UUID()
        await duck.duck(sessionID: micro)
        await duck.restore(sessionID: micro)
        #expect(hal.setCalls.count == 1)
        await duck.duck(sessionID: handsFree)
        #expect(hal.setCalls.count == 1)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        await duck.restore(sessionID: handsFree)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(hal.setCalls.count == 2)
        #expect(hal.setCalls[1].volume == 0.5)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func foreignRestoreDuringLiveDuckIsNoop() async {
        // A foreign restore is a no-op and never parks: the live slot and
        // flag are untouched.
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        await duck.restore(sessionID: UUID())
        #expect(hal.setCalls.count == 1)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func restoreWithoutDuckTouchesNothing() async {
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: freshDefaults(), hal: hal)
        await duck.restore(sessionID: UUID())
        #expect(hal.setCalls.isEmpty)
        #expect(hal.getCalls == 0)
    }

    @Test func disabledToggleMeansZeroHALCalls() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal, isEnabledOverride: { false })
        await duck.duck(sessionID: UUID())
        #expect(hal.setCalls.isEmpty)
        #expect(hal.getCalls == 0)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func missingVolumeControlSkipsSilently() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        hal.stubNoVolumeControl()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        await duck.duck(sessionID: UUID())
        #expect(hal.setCalls.isEmpty)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func restorePrefersDuckedDevice() async {
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: freshDefaults(), hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        // Mid-session switch: default moves to 99, but 70 is still
        // controllable — the restore belongs to 70.
        hal.stub(volume: 0.0, device: 99, controlled: [70, 99])
        await duck.restore(sessionID: id)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(hal.setCalls.last?.device == 70)
        #expect(hal.setCalls.last?.volume == 0.5)
    }

    @Test func restoreFallsBackToCurrentDefault() async {
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: freshDefaults(), hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        // Ducked device lost its control AND is no longer default:
        // fall back to the current default rather than staying muted.
        hal.stub(volume: 0.0, device: 99, controlled: [99])
        await duck.restore(sessionID: id)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(hal.setCalls.last?.device == 99)
        #expect(hal.setCalls.last?.volume == 0.5)
    }

    // MARK: - Crash recovery

    @Test func crashFlagRoundTrip() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        await duck.duck(sessionID: UUID())
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        // Simulated relaunch with a fresh instance: flag restores + clears.
        MediaDuck.restoreIfCrashed(defaults: defaults, hal: hal)
        #expect(hal.setCalls.last?.volume == 0.5)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func noCrashFlagMeansNoTouch() {
        let hal = FakeHAL()
        MediaDuck.restoreIfCrashed(defaults: freshDefaults(), hal: hal)
        #expect(hal.setCalls.isEmpty)
        #expect(hal.getCalls == 0)
    }

    @Test func sandboxedFlagMigratesOnce() {
        // Pre-upgrade crash flag in the dead Container plist surfaces in
        // standard defaults (muted user keeps their backstop); absent
        // source or present destination both no-op.
        let defaults = freshDefaults()
        MediaDuck.migrateSandboxedFlagIfNeeded(defaults: defaults, containerPreferences: [
            MediaDuckSettings.crashedKey: true,
            MediaDuckSettings.savedVolumeKey: Float(0.25),
            MediaDuckSettings.savedDeviceKey: 70,
        ])
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        #expect(defaults.float(forKey: MediaDuckSettings.savedVolumeKey) == 0.25)
        MediaDuck.migrateSandboxedFlagIfNeeded(defaults: defaults, containerPreferences: [
            MediaDuckSettings.crashedKey: true,
            MediaDuckSettings.savedVolumeKey: Float(0.75),
        ])
        #expect(defaults.float(forKey: MediaDuckSettings.savedVolumeKey) == 0.25)
        let clean = freshDefaults()
        MediaDuck.migrateSandboxedFlagIfNeeded(defaults: clean, containerPreferences: nil)
        MediaDuck.migrateSandboxedFlagIfNeeded(defaults: clean, containerPreferences: [:])
        #expect(!clean.bool(forKey: MediaDuckSettings.crashedKey))
    }

    // MARK: - Audit batch (session scope + retry)

    @Test func crashKeysMatch() {
        // Renaming a persisted key orphans flags across launches —
        // pin all three alongside the settings key.
        #expect(MediaDuckSettings.crashedKey == "app.Oto.mediaDuckedByOto")
        #expect(MediaDuckSettings.savedVolumeKey == "app.Oto.mediaDuckSavedVolume")
        #expect(MediaDuckSettings.savedDeviceKey == "app.Oto.mediaDuckSavedDevice")
    }

    @Test func foreignRestoreLeavesOwnerDucked() async {
        // Session B's restore must never clear session A's live duck
        // (unreachable via one-live-session today; contract holds anyway).
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: freshDefaults(), hal: hal)
        let a = UUID()
        await duck.duck(sessionID: a)
        await duck.restore(sessionID: UUID())
        #expect(hal.setCalls.count == 1)
        await duck.restore(sessionID: a)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(hal.setCalls.count == 2)
        #expect(hal.setCalls[1].volume == 0.5)
    }

    @Test func transientRestoreFailureRetries() async {
        // A failed set keeps slot + flag (no silent stranding): control
        // returns and the next restore completes the job.
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        hal.stubNoVolumeControl()
        await duck.restore(sessionID: id)
        #expect(hal.setCalls.count == 1)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        hal.stub(volume: 0.0, device: 70, controlled: [70])
        await duck.restore(sessionID: id)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(hal.setCalls.last?.volume == 0.5)
        #expect(hal.setCalls.last?.device == 70)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }
}
