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
}

struct LiveMediaVolumeHAL: MediaVolumeHAL {
    private nonisolated(unsafe) static let vmvc = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private nonisolated func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == 0 ? device : nil
    }

    nonisolated func currentVolume() -> (device: AudioObjectID, volume: Float32)? {
        guard let device = defaultOutputDevice(), deviceHasVolumeControl(device) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = Self.vmvc
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume)
        return status == 0 ? (device, volume) : nil
    }

    nonisolated func deviceHasVolumeControl(_ device: AudioObjectID) -> Bool {
        var addr = Self.vmvc
        guard AudioObjectHasProperty(device, &addr) else { return false }
        // Presence ≠ settability: a read-only `vmvc` must not be chosen
        // (restore would fail where the fallback succeeds).
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == 0 else { return false }
        return settable.boolValue
    }

    nonisolated func setVolume(_ volume: Float32, onDevice device: AudioObjectID) -> Bool {
        var addr = Self.vmvc
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == 0
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
    /// Restore grace for adoption (double-tap converts): a parked restore
    /// waits this long for a new duck before touching the volume. The
    /// crash flag stays set throughout — kill-safe in every direction.
    nonisolated static let restoreGraceNanoseconds: UInt64 = 250_000_000
    private var restoringSessionID: UUID?
    private var restoreTask: Task<Void, Never>?

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
        guard isEnabled else { return }
        // Idempotent per session: a second duck for the same session is
        // a no-op (one session at a time is the coordinator invariant;
        // an already-ducked slot from another session is left alone and
        // its owner restores it — never steal a live duck).
        if duckedSessionID == sessionID {
            // Same session re-ducking inside its own grace: unpark (still
            // live — the pending restore must not fire under it).
            if restoringSessionID == sessionID {
                restoreTask?.cancel()
                restoreTask = nil
                restoringSessionID = nil
            }
            return
        }
        if restoringSessionID != nil {
            // Absorb: a restore was parked inside its grace — transfer the
            // slot, stay muted, keep the flag set (crash-safe throughout).
            // Double-tap converts (micro restored, hands-free ducking
            // ~150-400 ms later) land here: no volume pump.
            restoreTask?.cancel()
            restoreTask = nil
            restoringSessionID = nil
            duckedSessionID = sessionID
            log.info("restore absorbed (adopted)")
            return
        }
        guard duckedSessionID == nil else { return }
        guard let current = hal.currentVolume() else {
            log.info("duck skipped — no vmvc control on default output")
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
        log.info("ducked \(sessionID.uuidString.prefix(8), privacy: .public)")
    }

    func restore(sessionID: UUID) async {
        // Session-scoped: never clear another owner's duck. Unreachable
        // via one-live-session today, but the contract holds regardless —
        // a foreign restore is a no-op, never an early unduck.
        guard savedVolume != nil, savedDevice != nil,
              duckedSessionID == sessionID
        else { return }
        // Park the restore for the grace window (adoption bait for the
        // next duck); superseding parks cancel their predecessor.
        restoringSessionID = sessionID
        restoreTask?.cancel()
        restoreTask = Task {
            try? await Task.sleep(nanoseconds: Self.restoreGraceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.finishRestore(sessionID: sessionID)
        }
    }

    /// Grace expiry: the parked restore runs only if nobody absorbed it.
    /// Ownership re-checked (an absorb transfers the slot and cancels this
    /// task, but defense in depth is free here).
    private func finishRestore(sessionID: UUID) async {
        restoreTask = nil
        restoringSessionID = nil
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
        if hal.setVolume(volume, onDevice: target) {
            // Clear ONLY on verified success: a transient set failure
            // keeps slot + flag, so the next restore (or relaunch)
            // retries instead of stranding the user muted.
            duckedSessionID = nil
            savedVolume = nil
            savedDevice = nil
            defaults.set(false, forKey: MediaDuckSettings.crashedKey)
            log.info("restored \(sessionID.uuidString.prefix(8), privacy: .public)")
        } else {
            log.error("restore set failed — launch-restore flag kept")
        }
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
        for key in [MediaDuckSettings.crashedKey, MediaDuckSettings.savedVolumeKey, MediaDuckSettings.savedDeviceKey] {
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
        let savedDevice = AudioObjectID(defaults.integer(forKey: MediaDuckSettings.savedDeviceKey))
        let target: AudioObjectID
        if hal.deviceHasVolumeControl(savedDevice) {
            target = savedDevice
        } else if let current = hal.currentVolume() {
            target = current.device
        } else {
            return
        }
        if hal.setVolume(volume, onDevice: target) {
            defaults.set(false, forKey: MediaDuckSettings.crashedKey)
        }
    }
}
