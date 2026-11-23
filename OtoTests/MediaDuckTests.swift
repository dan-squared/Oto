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
    private nonisolated(unsafe) var _uids: [AudioObjectID: String] = [:]

    func stub(
        volume: Float32,
        device: AudioObjectID,
        controlled: Set<AudioObjectID>,
        uids: [AudioObjectID: String] = [:]
    ) {
        lock.withLock {
            _volume = volume
            _device = device
            _controlled = controlled
            _uids = uids
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

    nonisolated func deviceUID(for device: AudioObjectID) -> String? {
        lock.withLock { _uids[device] }
    }

    nonisolated func deviceID(forUID uid: String) -> AudioObjectID? {
        lock.withLock { _uids.first(where: { $0.value == uid })?.key }
    }
}

/// Recording coordinator seam: asserts duck/restore happen with the
/// live session ID on the right transitions. MainActor class (not an
/// actor) because MediaDucking is MainActor-isolated.
@MainActor
final class FakeMediaDuck: MediaDucking {
    var ducks: [UUID] = []
    var restores: [UUID] = []
    /// Restore is idempotent by contract: every terminal path may call it
    /// after the release already gave the output back. A session that is
    /// still ducked is the only one a restore records, so tests can assert
    /// "the output came back" without pinning how many paths asked.
    private var ducked: Set<UUID> = []

    func duck(sessionID: UUID) async {
        self.ducks.append(sessionID)
        self.ducked.insert(sessionID)
    }

    func restore(sessionID: UUID) async {
        guard self.ducked.remove(sessionID) != nil else { return }
        self.restores.append(sessionID)
    }
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
        // Immediate by contract: the set has landed when restore returns.
        #expect(hal.setCalls.count == 2)
        #expect(hal.setCalls[1].volume == 0.5)
        #expect(hal.setCalls[1].device == 70)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
        await duck.restore(sessionID: id)
        #expect(hal.setCalls.count == 2)
    }

    @Test func restoreReturnsOnlyAfterTheVolumeIsBack() async {
        // The stop cue plays the moment restore returns. If restore parked,
        // the cue would start at volume 0 and be swallowed (the shipped bug
        // this pins against).
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: freshDefaults(), hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        await duck.restore(sessionID: id)
        #expect(hal.setCalls.last?.volume == 0.5)
    }

    @Test func duckAfterRestoreMutesAgain() async {
        // Double-tap shape: the first restore gives the volume back, the
        // next duck re-mutes and saves the restored level. No grace, no
        // pump promise — media resumes, then re-mutes.
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let micro = UUID()
        let handsFree = UUID()
        await duck.duck(sessionID: micro)
        await duck.restore(sessionID: micro)
        #expect(hal.setCalls.count == 2)
        await duck.duck(sessionID: handsFree)
        #expect(hal.setCalls.count == 3)
        #expect(hal.setCalls[2].volume == 0.0)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        await duck.restore(sessionID: handsFree)
        #expect(hal.setCalls.count == 4)
        #expect(hal.setCalls[3].volume == 0.5)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func failedRestoreAdoptsNextDuck() async {
        // Stuck-muted fix: a restore that fails keeps its retry data, but
        // the dead owner's slot must transfer — otherwise every later
        // session ducks nothing while the HAL sits at 0, and their
        // restores are rejected as foreign. Only relaunch recovered.
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let a = UUID()
        await duck.duck(sessionID: a)
        #expect(hal.setCalls.count == 1)
        #expect(hal.setCalls[0].volume == 0.0)
        hal.stubNoVolumeControl() // device gone before the restore: it fails
        await duck.restore(sessionID: a)
        // Slot kept (retry data survives), volume untouched since the duck.
        #expect(hal.setCalls.count == 1)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        let b = UUID()
        await duck.duck(sessionID: b)
        // Adopted, not re-muted: zero HAL contact, still silent (correct —
        // B is recording), flag still set throughout.
        #expect(hal.setCalls.count == 1)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))
        // Heal the HAL; B's restore lands the saved level.
        hal.stub(volume: 0.0, device: 70, controlled: [70])
        await duck.restore(sessionID: b)
        #expect(hal.setCalls.count == 2)
        #expect(hal.setCalls[1].volume == 0.5)
        #expect(hal.setCalls[1].device == 70)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
        // Slot cleared: a fresh session ducks normally again.
        await duck.duck(sessionID: UUID())
        #expect(hal.setCalls.count == 3)
        #expect(hal.setCalls[2].volume == 0.0)
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
        #expect(hal.setCalls.last?.volume == 0.5)
        #expect(hal.setCalls.last?.device == 70)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func skipsDuckWhenVolumeAlreadySilent() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        hal.stub(volume: 0.0005, device: 70, controlled: [70])
        let duck = MediaDuck(defaults: defaults, hal: hal)
        await duck.duck(sessionID: UUID())
        #expect(hal.setCalls.isEmpty)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func restoreDoesNotClobberUserVolumeIncrease() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let id = UUID()
        await duck.duck(sessionID: id)
        #expect(hal.setCalls.count == 1)
        // User manually turned volume up to 0.35 while recording.
        hal.stub(volume: 0.35, device: 70, controlled: [70])
        await duck.restore(sessionID: id)
        #expect(hal.setCalls.count == 1)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func disabledToggleHealsStrandedSlot() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        let duck = MediaDuck(defaults: defaults, hal: hal)
        let a = UUID()
        await duck.duck(sessionID: a)
        hal.stubNoVolumeControl()
        await duck.restore(sessionID: a)
        #expect(defaults.bool(forKey: MediaDuckSettings.crashedKey))

        // User turns MediaDuck off; device recovers; next duck heals stranded slot.
        defaults.set(false, forKey: MediaDuckSettings.key)
        hal.stub(volume: 0.0, device: 70, controlled: [70])
        await duck.duck(sessionID: UUID())
        #expect(hal.setCalls.last?.volume == 0.5)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }

    @Test func crashRecoveryPrefersStableDeviceUID() async {
        let defaults = freshDefaults()
        let hal = FakeHAL()
        hal.stub(volume: 0.6, device: 70, controlled: [70], uids: [70: "uid-speakers"])
        let duck = MediaDuck(defaults: defaults, hal: hal)
        await duck.duck(sessionID: UUID())
        #expect(defaults.string(forKey: MediaDuckSettings.savedDeviceUIDKey) == "uid-speakers")

        // Simulate reboot: device 70 is now something else, speakers moved to ID 99.
        hal.stub(
            volume: 0.0,
            device: 99,
            controlled: [70, 99],
            uids: [70: "uid-hdmi", 99: "uid-speakers"]
        )
        MediaDuck.restoreIfCrashed(defaults: defaults, hal: hal)
        #expect(hal.setCalls.last?.device == 99)
        #expect(hal.setCalls.last?.volume == 0.6)
        #expect(!defaults.bool(forKey: MediaDuckSettings.crashedKey))
    }
}
