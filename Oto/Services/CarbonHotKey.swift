//
//  CarbonHotKey.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Carbon modifier masks (stable since forever; verified in 27 SDK).
/// Namespace enum: `Sendable`-conformance keeps the constants shareable
/// from nonisolated contexts (Swift 6, default MainActor isolation).
enum CarbonModifiers: Sendable {
    nonisolated static let command = 256
    nonisolated static let shift = 512
    nonisolated static let option = 2048
    nonisolated static let control = 4096
}

extension NSEvent.ModifierFlags {
    /// NSEvent flags → Carbon modifier mask for hotkey matching. Pure
    /// bit math: `nonisolated` (Swift 6).
    nonisolated var carbonMask: Int {
        var mask = 0
        if contains(.command) { mask |= CarbonModifiers.command }
        if contains(.shift) { mask |= CarbonModifiers.shift }
        if contains(.option) { mask |= CarbonModifiers.option }
        if contains(.control) { mask |= CarbonModifiers.control }
        return mask
    }
}

/// A single global combo registration. RAII by construction: registration
/// failure makes `init?` nil (conflict surfaced, never silent), and
/// `deinit` unregisters — stale callbacks are impossible because a dead
/// HotKey cannot remain registered. Technique follows the
/// KeyboardShortcuts 3.1.0 reference (`HotKey.swift`, MIT) as Oto-owned
/// code; the center below is simplified to Oto's one-combo reality.
final class CarbonHotKey {
    let carbonKeyCode: Int
    let carbonModifiers: Int
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    fileprivate let id: Int
    nonisolated(unsafe) fileprivate var eventHotKeyRef: EventHotKeyRef?

    init?(
        carbonKeyCode: Int,
        carbonModifiers: Int,
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void
    ) {
        self.id = CarbonHotKeyCenter.shared.nextId()
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp

        guard CarbonHotKeyCenter.shared.register(self) else {
            return nil
        }
    }

    deinit {
        // Nonisolated by definition, and the center is MainActor-bound —
        // no hop is possible here. Unregister at the OS level directly:
        // the RAII guarantee (a dead HotKey cannot remain registered)
        // holds; the center's weak entry evaporates and is swept on the
        // next registration. Runs on the main actor in practice (the
        // monitor owns this from @MainActor lifecycle methods).
        if let ref = eventHotKeyRef {
            UnregisterEventHotKey(ref)
            eventHotKeyRef = nil
        }
    }
}

/// Owns the shared Carbon handler and routes pressed/released by
/// signature-scoped ID. Deliberately minimal: no menu-tracking mode, no
/// raw-event fallback, no NSEvent monitors of any kind — NSEvent monitors
/// wedge MenuBarExtra menu tracking on this macOS (proven by bisect), so
/// the trigger path stays on Carbon + HID tap only. A combo pressed while
/// a menu is open is simply missed (benign: no partial state exists to
/// stick). Follows the 3.1.0 reference registration design, Oto-owned.
final class CarbonHotKeyCenter {
    static let shared = CarbonHotKeyCenter()

    private struct WeakHotKey {
        weak var value: CarbonHotKey?
    }

    private var lastHotKeyId = 0
    private var hotKeys = [Int: WeakHotKey]()
    private var eventHandler: EventHandlerRef?

    // 'OTOS' signature scopes our registrations apart from any other app's.
    private let signature: UInt32 = 0x4F544F53

    private let hotKeyEventTypes = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
    ]

    private init() {}

    func nextId() -> Int {
        lastHotKeyId += 1
        return lastHotKeyId
    }

    @discardableResult
    func register(_ hotKey: CarbonHotKey) -> Bool {
        guard let ref = registerEventHotKey(for: hotKey) else {
            return false
        }
        hotKey.eventHotKeyRef = ref
        // Sweep weak entries whose owners de-registered via deinit (the
        // explicit unregister path was removed with the deinit fix — one
        // OS-level path, no stale callbacks either way).
        hotKeys = hotKeys.filter { $0.value.value != nil }
        hotKeys[hotKey.id] = WeakHotKey(value: hotKey)
        setUpEventHandlerIfNeeded()
        return true
    }

    /// System symbolic hotkeys (for recorder conflict warnings).
    /// Each entry is (carbonKeyCode, carbonModifiers) of an ENABLED system
    /// shortcut. Best-effort: empty on failure, never fatal.
    static func enabledSystemShortcuts() -> [(keyCode: Int, modifiers: Int)] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return list.compactMap {
            guard ($0[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = $0[kHISymbolicHotKeyCode] as? Int,
                  let mods = $0[kHISymbolicHotKeyModifiers] as? Int
            else { return nil }
            return (code, mods)
        }
    }

    // MARK: - Private

    private func registerEventHotKey(for hotKey: CarbonHotKey) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let error = RegisterEventHotKey(
            UInt32(hotKey.carbonKeyCode),
            UInt32(hotKey.carbonModifiers),
            EventHotKeyID(signature: signature, id: UInt32(hotKey.id)),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard error == noErr, let ref else { return nil }
        return ref
    }

    private func setUpEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var handler: EventHandlerRef?
        let error = InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonHotKeyEventHandler,
            2,
            hotKeyEventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard error == noErr, let handler else { return }
        eventHandler = handler
    }

    /// Parsed, Sendable fire command: kind + id cross the isolation
    /// boundary; the non-Sendable EventRef never does (Swift 6 region
    /// isolation). Parsed synchronously on the delivery thread, which is
    /// valid: Carbon event data is live for the callback's duration.
    struct Fire: Sendable {
        var kind: Int
        var id: Int
    }

    fileprivate func fire(_ fire: Fire) -> OSStatus {
        guard let hotKey = hotKeys[fire.id]?.value else { return OSStatus(eventNotHandledErr) }
        switch fire.kind {
        case kEventHotKeyPressed:
            hotKey.onKeyDown()
            return noErr
        case kEventHotKeyReleased:
            hotKey.onKeyUp()
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }

    nonisolated fileprivate func parseFire(_ event: EventRef?) -> Fire? {
        guard let event else { return nil }
        var hotKeyId = EventHotKeyID()
        guard GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyId
        ) == noErr,
              hotKeyId.signature == signature
        else { return nil }
        return Fire(kind: Int(GetEventKind(event)), id: Int(hotKeyId.id))
    }
}

/// C entry point for the Carbon handler: must be `nonisolated` (a C
/// function pointer cannot be formed from an isolated function). The hop
/// back onto the actor is explicit inside via `assumeIsolated` — Carbon
/// guarantees main-thread delivery, asserted below.
nonisolated private func carbonHotKeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<CarbonHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    guard Thread.isMainThread else {
        assertionFailure("Carbon event callback must run on the main thread.")
        return OSStatus(eventNotHandledErr)
    }
    guard let fire = center.parseFire(event) else { return OSStatus(eventNotHandledErr) }
    return MainActor.assumeIsolated {
        center.fire(fire)
    }
}
