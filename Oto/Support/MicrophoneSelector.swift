//
//  MicrophoneSelector.swift
//  Oto
//
//  Input-device picker over the CoreAudio HAL: enumerate physical inputs,
//  read the system default, set the system default. The capture engine
//  (`AppleAudioCapture`) always follows the system default input, so this
//  file is the entire backend touch — the realtime graph is unchanged
//  (a mid-session switch arrives as the already-handled config-change
//  rebuild). Setting the default affects every app: the UI labels it
//  "System input" and says so. No entitlement needed (unsandboxed).
//

import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// HAL object ID (valid this launch only — never persisted).
    let id: AudioDeviceID
    /// Stable across launches — the only thing compared/stored.
    let uid: String
    let name: String
}

enum MicrophoneSelector {
    /// All devices with at least one input channel, in HAL order.
    nonisolated static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id), let uid = stringProperty(
                id, selector: kAudioDevicePropertyDeviceUID
            ) else { return nil }
            let name = stringProperty(
                id, selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? uid
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// UID of the current system default input, if any.
    nonisolated static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0 else { return nil }
        return stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Makes `device` the system default input (all apps follow).
    /// Returns false without touching anything on failure.
    @discardableResult
    nonisolated static func setDefaultInput(_ device: AudioInputDevice) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        ) == noErr
    }

    // MARK: - Private

    /// True when the device exposes ≥1 input-stream channel.
    nonisolated private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, data) == noErr else { return false }
        return data.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { list in
            let buffers = UnsafeBufferPointer(start: &list.pointee.mBuffers, count: Int(list.pointee.mNumberBuffers))
            return buffers.contains { $0.mNumberChannels > 0 }
        }
    }

    /// CFString device properties (UID, name). Property fetches hand back
    /// +1 references — taken retained through the raw pointer, never
    /// bridged as a managed optional (which would leak one per call).
    nonisolated private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UnsafeRawPointer>.size)
        var raw: UnsafeRawPointer?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr,
              let raw else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
    }
}
