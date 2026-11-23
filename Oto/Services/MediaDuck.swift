//
//  MediaDuck.swift
//  Oto
//
//  Phase 7 (behind the sandbox spike, GREEN 2026-09-22): mute media
//  output while dictating so speaker bleed cannot ruin transcripts,
//  then restore the exact prior volume on every terminal path.
//  (Spike-era notes below predate the unsandboxing — kept as history:
//  the API choice stands either way; the sandbox verdict is moot now.)
//
//  API choice (spike-mandated): AudioObjectGet/SetPropertyData from
//  CoreAudio — current. AudioHardwareService* is API_DEPRECATED("no
//  longer supported", macos(10.5, 10.11)) and must not back new code,
//  even though it still works at runtime. The 'vmvc' selector constant
//  itself is current (only the ancient VirtualMaster* aliases are
//  deprecated); it is just a fourcc usable with either spelling.
//  Sandbox verdict (spike, ad-hoc-signed .app with app-sandbox +
//  audio-input): full duck+restore cycle green, restore verified by
//  read-back. BT absolute-volume devices may ignore 'vmvc' — degrade
//  is an honest log line, never a failure state.
//
//  Safety: volume-save/restore (not a mute-flag) coexists with the
//  user pressing mute mid-duck. A crash-recovery flag in UserDefaults
//  guarantees a kill mid-dictation can never leave the user muted:
//  launch restores + clears. Toggle default ON (absent key = ON).
//

import CoreAudio
import AudioToolbox
import Foundation
import os

/// Kill-switch setting. Default ON (speaker bleed ruins transcripts;
/// resume is automatic; the toggle is one tap away). Absent key means
/// ON so a fresh install gets the protection.
enum MediaDuckSettings {
    nonisolated static let key = "app.Oto.muteMediaWhileDictating"
    nonisolated static let crashedKey = "app.Oto.mediaDuckedByOto"
    nonisolated static let savedVolumeKey = "app.Oto.mediaDuckSavedVolume"
    nonisolated static let savedDeviceKey = "app.Oto.mediaDuckSavedDevice"
    nonisolated static let savedDeviceUIDKey = "app.Oto.mediaDuckSavedDeviceUID"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

/// Thin HAL seam: volume I/O on output devices. Synchronous syscalls;
/// the live implementation re-resolves the default output on every
/// call (devices can flap mid-session — this repo's BT history).
protocol MediaVolumeHAL: Sendable {
    /// (device, volume) for the current default output, or nil when the
    /// device exposes no 'vmvc' control (e.g. absolute-volume BT sets).
    nonisolated func currentVolume() -> (device: AudioObjectID, volume: Float32)?
    /// True when the device still exposes a settable 'vmvc'.
    nonisolated func deviceHasVolumeControl(_ device: AudioObjectID) -> Bool
    /// Set 'vmvc' on the given device. False on any failure.
    nonisolated func setVolume(_ volume: Float32, onDevice device: AudioObjectID) -> Bool
    /// Stable device UID (`kAudioDevicePropertyDeviceUID`) for crash recovery.
    nonisolated func deviceUID(for device: AudioObjectID) -> String?
    /// Resolves a persisted device UID back to a live `AudioObjectID`.
    nonisolated func deviceID(forUID uid: String) -> AudioObjectID?
    /// Current 'vmvc' volume for a specific device, if readable.
    nonisolated func volume(onDevice device: AudioObjectID) -> Float32?
}

extension MediaVolumeHAL {
    nonisolated func deviceUID(for device: AudioObjectID) -> String? { nil }
    nonisolated func deviceID(forUID uid: String) -> AudioObjectID? { nil }
    nonisolated func volume(onDevice device: AudioObjectID) -> Float32? {
        guard let current = currentVolume(), current.device == device else { return nil }
        return current.volume
    }
}

struct LiveMediaVolumeHAL: MediaVolumeHAL {
    private nonisolated static let vmvc = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private nonisolated func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    nonisolated func currentVolume() -> (device: AudioObjectID, volume: Float32)? {
        guard let device = defaultOutputDevice(), deviceHasVolumeControl(device),
              let volume = volume(onDevice: device)
        else { return nil }
        return (device, volume)
    }

    nonisolated func volume(onDevice device: AudioObjectID) -> Float32? {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = Self.vmvc
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    nonisolated func deviceHasVolumeControl(_ device: AudioObjectID) -> Bool {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        var addr = Self.vmvc
        guard AudioObjectHasProperty(device, &addr) else { return false }
        // Presence ≠ settability: a read-only `vmvc` must not be chosen
        // (restore would fail where the fallback succeeds).
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    nonisolated func setVolume(_ volume: Float32, onDevice device: AudioObjectID) -> Bool {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        var addr = Self.vmvc
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr
    }

    nonisolated func deviceUID(for device: AudioObjectID) -> String? {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UnsafeRawPointer>.size)
        var raw: UnsafeRawPointer?
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &raw) == noErr,
              let raw
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
    }

    nonisolated func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return nil }
        let actualCount = min(count, Int(size) / MemoryLayout<AudioObjectID>.size)
        return ids.prefix(actualCount).first { deviceUID(for: $0) == uid }
    }
}

/// Coordinator-facing seam. Session-ID threading makes duck/restore
/// idempotent per session; tests inject a recording fake.
///
/// Explicitly MainActor (the compiler infers this anyway under the
/// project's default isolation + InferIsolatedConformances, and an
/// actor fake is rejected — made explicit so the next reader doesn't
/// re-derive it): duck/restore serialize on the main actor, which is
/// exactly where the live implementation keeps its slot.
@MainActor
protocol MediaDucking: Sendable {
    func duck(sessionID: UUID) async
    func restore(sessionID: UUID) async
}

/// Mutes media on `.recording`, restores on every terminal state.
/// All state is MainActor-isolated; HAL calls are synchronous and fast.
@MainActor
final class MediaDuck: MediaDucking {
    private let defaults: UserDefaults
    private let hal: any MediaVolumeHAL
    private let isEnabledOverride: (@Sendable () -> Bool)?
    private let log = Logger(subsystem: "app.Oto", category: "mediaduck")

    /// The ducked session + what to put back. Nil = not ducked, so
    /// restore is a no-op (double-restore safe by construction).
    private var duckedSessionID: UUID?
    private var savedVolume: Float32?
    private var savedDevice: AudioObjectID?
    /// No restore grace. `restore` returns only after the HAL set lands (or
    /// fails), because the stop tone plays immediately after it: a parked
    /// restore left the output muted and swallowed the 0.43 s cue. A
    /// follow-on session re-ducks instead — a brief media resume, which is
    /// the honest shape (see plan/stop-tone-audible-through-media-duck.md).

    init(
        defaults: UserDefaults = .standard,
        hal: any MediaVolumeHAL = LiveMediaVolumeHAL(),
        isEnabledOverride: (@Sendable () -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.hal = hal
        self.isEnabledOverride = isEnabledOverride
    }

    private var isEnabled: Bool {
        isEnabledOverride?() ?? MediaDuckSettings.isEnabled(defaults: defaults)
    }

    func duck(sessionID: UUID) async {
        guard isEnabled else {
            // Heal any stranded slot left behind by a prior failed restore
            // even if the user subsequently toggled MediaDuck off.
            if let stranded = duckedSessionID {
                await finishRestore(sessionID: stranded)
            }
            return
        }
        // Idempotent per session: a second duck for the same session is
        // a no-op (one session at a time is the coordinator invariant;
        // an already-ducked slot from another session is left alone and
        // its owner restores it — never steal a live duck).
        if duckedSessionID == sessionID { return }
        if let holder = duckedSessionID, holder != sessionID {
            // Stale owner (its restore failed and kept the slot — the only
            // way a different session arrives here under one-live-session):
            // adopt without touching the volume (already 0 from the dead
            // session's duck). savedVolume/Device/flag stay: they describe
            // the pre-duck level THIS session must restore. A future
            // multi-session design must revisit this branch.
            duckedSessionID = sessionID
            log.info("duck adopted stale slot \(holder.uuidString.prefix(8), privacy: .public)")
            return
        }
        guard duckedSessionID == nil else { return }
        guard let current = hal.currentVolume() else {
            log.info("duck skipped — no vmvc control on default output")
            return
        }
        guard current.volume > 0.001 else {
            log.info("duck skipped — output already silent")
            return
        }
        guard hal.setVolume(0.0, onDevice: current.device) else {
            log.error("duck set failed — leaving volume untouched")
            return
        }
        duckedSessionID = sessionID
        savedVolume = current.volume
        savedDevice = current.device
        defaults.set(true, forKey: MediaDuckSettings.crashedKey)
        defaults.set(current.volume, forKey: MediaDuckSettings.savedVolumeKey)
        defaults.set(Int(current.device), forKey: MediaDuckSettings.savedDeviceKey)
        if let uid = hal.deviceUID(for: current.device) {
            defaults.set(uid, forKey: MediaDuckSettings.savedDeviceUIDKey)
        } else {
            defaults.removeObject(forKey: MediaDuckSettings.savedDeviceUIDKey)
        }
        log.info("ducked \(sessionID.uuidString.prefix(8), privacy: .public)")
    }

    func restore(sessionID: UUID) async {
        // Session-scoped: never clear another owner's duck. Unreachable
        // via one-live-session today, but the contract holds regardless —
        // a foreign restore is a no-op, never an early unduck.
        guard savedVolume != nil, savedDevice != nil,
              duckedSessionID == sessionID
        else { return }
        // Immediate by contract: when this returns the output is audible
        // again (or the failure kept the slot + crash flag for retry). The
        // stop cue plays right after this call, so a park would swallow it.
        await finishRestore(sessionID: sessionID)
    }

    /// Performs the HAL set. Ownership re-checked: a stale restore is a
    /// no-op, never an early unduck of another session.
    private func finishRestore(sessionID: UUID) async {
        guard let volume = savedVolume, let device = savedDevice,
              duckedSessionID == sessionID
        else { return }
        // Prefer the ducked device (it may no longer be default after a
        // mid-session switch); fall back to the current default output.
        // Either way the user gets sound back — the target is logged.
        let target: AudioObjectID
        if hal.deviceHasVolumeControl(device) {
            target = device
        } else if let current = hal.currentVolume() {
            target = current.device
        } else {
            log.error("restore failed — no controllable output; launch-restore flag kept")
            return
        }
        // If the user manually raised volume during dictation, honor their
        // adjustment instead of clobbering it with the pre-duck level.
        if let liveVolume = hal.volume(onDevice: target), liveVolume > 0.05 {
            clearDuckSlot()
            log.info("restore skipped — user raised volume to \(liveVolume, privacy: .public)")
            return
        }
        if hal.setVolume(volume, onDevice: target) {
            // Clear ONLY on verified success: a transient set failure
            // keeps slot + flag, so the next restore (or relaunch)
            // retries instead of stranding the user muted.
            clearDuckSlot()
            log.info("restored \(sessionID.uuidString.prefix(8), privacy: .public)")
        } else {
            log.error("restore set failed — launch-restore flag kept")
        }
    }

    private func clearDuckSlot() {
        duckedSessionID = nil
        savedVolume = nil
        savedDevice = nil
        defaults.set(false, forKey: MediaDuckSettings.crashedKey)
        defaults.removeObject(forKey: MediaDuckSettings.savedDeviceUIDKey)
    }

    /// One-shot sandbox→unsandboxed migration (audit F7): the crash flag
    /// lived in the Container plist; without migration a flag set
    /// pre-upgrade is invisible to this build (muted, no backstop).
    /// Copies the duck keys when standard defaults lack them; no-ops
    /// otherwise (including every launch after the first).
    nonisolated static func migrateSandboxedFlagIfNeeded(
        defaults: UserDefaults = .standard,
        containerPreferences: [String: Any]? = nil
    ) {
        let source = containerPreferences ?? Self.sandboxContainerPreferences()
        guard defaults.object(forKey: MediaDuckSettings.crashedKey) == nil,
              let source,
              (source[MediaDuckSettings.crashedKey] as? Bool) == true
        else { return }
        for key in [
            MediaDuckSettings.crashedKey,
            MediaDuckSettings.savedVolumeKey,
            MediaDuckSettings.savedDeviceKey,
            MediaDuckSettings.savedDeviceUIDKey,
        ] {
            if let value = source[key] { defaults.set(value, forKey: key) }
        }
    }

    private nonisolated static func sandboxContainerPreferences() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/app.Oto/Data/Library/Preferences/app.Oto.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        return dict
    }

    /// Launch backstop: a kill mid-dictation leaves the flag set; put
    /// the saved volume back regardless of the current toggle (the user
    /// was left muted — the toggle governs future ducks, not this debt).
    nonisolated static func restoreIfCrashed(
        defaults: UserDefaults = .standard,
        hal: any MediaVolumeHAL = LiveMediaVolumeHAL()
    ) {
        guard defaults.bool(forKey: MediaDuckSettings.crashedKey) else { return }
        let volume = defaults.float(forKey: MediaDuckSettings.savedVolumeKey)
        let savedUID = defaults.string(forKey: MediaDuckSettings.savedDeviceUIDKey)
        let savedDevice = AudioObjectID(defaults.integer(forKey: MediaDuckSettings.savedDeviceKey))

        let target: AudioObjectID
        if let savedUID,
           let resolved = hal.deviceID(forUID: savedUID),
           hal.deviceHasVolumeControl(resolved)
        {
            target = resolved
        } else if savedUID == nil,
                  savedDevice != AudioObjectID(kAudioObjectUnknown),
                  hal.deviceHasVolumeControl(savedDevice)
        {
            target = savedDevice
        } else if let current = hal.currentVolume() {
            target = current.device
        } else {
            return
        }

        if let liveVolume = hal.volume(onDevice: target), liveVolume > 0.05 {
            defaults.set(false, forKey: MediaDuckSettings.crashedKey)
            defaults.removeObject(forKey: MediaDuckSettings.savedDeviceUIDKey)
            return
        }
        if hal.setVolume(volume, onDevice: target) {
            defaults.set(false, forKey: MediaDuckSettings.crashedKey)
            defaults.removeObject(forKey: MediaDuckSettings.savedDeviceUIDKey)
        }
    }
}
