//
//  PasteKeycodeResolver.swift
//  Oto
//
//  Phase 8b Slice 3 (Hex steal-list): the Cmd+V/C/Z letter keys move with
//  the keyboard layout (Dvorak remaps them) — resolve per current layout
//  via UCKeyTranslate, failing safe to the ANSI constants (today's
//  behavior, never worse). Hex does exactly this resolution; Oto keeps its
//  guarded posting around it.
//

import Carbon
import CoreGraphics
import Foundation
import Synchronization

/// Paste-letter keycode resolution. Pure core (injected translator — fully
/// unit-tested incl. Dvorak remap + failure) + thin live edge (TIS ASCII-capable
/// layout fetched once on the main thread + UCKeyTranslate, matrix-proven).
enum PasteKeycodeResolver {
    private struct LayoutSnapshot: Sendable {
        let currentData: Data?
        let asciiCapableData: Data?
        let keyboardType: UInt32
    }

    /// Carbon `cmdKey >> 8` — the UCKeyTranslate modifier state for the Command
    /// layer. Layouts like "Dvorak – QWERTY ⌘" switch key positions while ⌘ is
    /// held, so Command shortcuts must check this layer first (borrowed from Hex).
    nonisolated static let commandModifierState: UInt32 = UInt32(cmdKey >> 8)

    private struct CacheState: Sendable {
        var snapshot: LayoutSnapshot?
        var dirty = true
        var observerInstalled = false
    }

    private nonisolated static let cache = Mutex(CacheState())

    /// Pure core: first keycode in 0..<128 whose translation equals the
    /// target (case-insensitive); nil when the layout never produces it.
    nonisolated static func keyCode(
        for character: Character,
        translate: (UInt16) -> String?
    ) -> UInt16? {
        let wanted = String(character).lowercased()
        for code in UInt16(0)..<UInt16(128) {
            if translate(code)?.lowercased() == wanted {
                return code
            }
        }
        return nil
    }

    /// ANSI fallbacks per letter (today's hardcoded behavior, kept as the
    /// never-worse floor; unknown letters fall back to V).
    nonisolated static func fallback(for letter: Character) -> UInt16 {
        switch String(letter).lowercased() {
        case "c": return UInt16(kVK_ANSI_C)
        case "z": return UInt16(kVK_ANSI_Z)
        default: return UInt16(kVK_ANSI_V)
        }
    }

    /// Populates or refreshes the cached ASCII-capable keyboard layout on the
    /// main thread so background/async posting paths never call main-thread-only
    /// Carbon TIS APIs off the main thread.
    @MainActor
    static func warmLayoutCacheOnMainThread() {
        _ = readSnapshot()
    }

    /// Paste key for a Command shortcut letter: checks the current keyboard
    /// layout's Command layer first (fixes "Dvorak – QWERTY ⌘"), then its plain
    /// layer, then the ASCII-capable layout (for non-Latin layouts like Russian,
    /// Hebrew, Arabic, Greek), falling back to ANSI constants on any failure.
    nonisolated static func keyCode(for letter: Character) -> CGKeyCode {
        guard let snapshot = readSnapshot() else {
            return CGKeyCode(fallback(for: letter))
        }
        if let current = snapshot.currentData {
            if let found = keyCode(for: letter, translate: { code in
                translate(
                    keyCode: code,
                    layoutData: current,
                    keyboardType: snapshot.keyboardType,
                    modifierState: commandModifierState
                )
            }) {
                return CGKeyCode(found)
            }
            if let found = keyCode(for: letter, translate: { code in
                translate(
                    keyCode: code,
                    layoutData: current,
                    keyboardType: snapshot.keyboardType,
                    modifierState: 0
                )
            }) {
                return CGKeyCode(found)
            }
        }
        if let ascii = snapshot.asciiCapableData {
            if let found = keyCode(for: letter, translate: { code in
                translate(
                    keyCode: code,
                    layoutData: ascii,
                    keyboardType: snapshot.keyboardType,
                    modifierState: commandModifierState
                )
            }) {
                return CGKeyCode(found)
            }
            if let found = keyCode(for: letter, translate: { code in
                translate(
                    keyCode: code,
                    layoutData: ascii,
                    keyboardType: snapshot.keyboardType,
                    modifierState: 0
                )
            }) {
                return CGKeyCode(found)
            }
        }
        return CGKeyCode(fallback(for: letter))
    }

    /// Live translator: UCKeyTranslate over the cached layout (Command layer
    /// first, then plain, then ASCII-capable). Nil on any failure.
    nonisolated static func liveTranslation(keyCode: UInt16) -> String? {
        guard let snapshot = readSnapshot() else { return nil }
        if let current = snapshot.currentData,
           let s = translate(keyCode: keyCode, layoutData: current, keyboardType: snapshot.keyboardType)
        {
            return s
        }
        if let ascii = snapshot.asciiCapableData {
            return translate(keyCode: keyCode, layoutData: ascii, keyboardType: snapshot.keyboardType)
        }
        return nil
    }

    /// Pure layout translation over a copied `UCKeyboardLayout` buffer.
    /// Verifies `data.count >= MemoryLayout<UCKeyboardLayout>.size` before
    /// rebinding to prevent out-of-bounds reads on malformed layout data.
    nonisolated static func translate(
        keyCode: UInt16,
        layoutData: Data,
        keyboardType: UInt32,
        modifierState: UInt32 = 0
    ) -> String? {
        guard layoutData.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var chars = [UInt16](repeating: 0, count: 4)
        let status: OSStatus = layoutData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return OSStatus(paramErr) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), modifierState,
                keyboardType, UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, chars.count, &actualLength, &chars
            )
        }
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }

    private nonisolated static func copyLayoutData(from source: TISInputSource?) -> Data? {
        guard let source,
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue()
        let byteCount = CFDataGetLength(layoutData)
        guard byteCount >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(layoutData)
        else { return nil }
        return Data(bytes: bytes, count: byteCount)
    }

    private nonisolated static func installObserverIfNeeded() {
        let shouldInstall = cache.withLock { state -> Bool in
            guard !state.observerInstalled else { return false }
            state.observerInstalled = true
            return true
        }
        guard shouldInstall else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { _ in
            cache.withLock { $0.dirty = true }
        }
    }

    /// Reads the current ASCII-capable layout snapshot. Carbon TIS calls are
    /// main-thread-only, so off-main callers use the last cached snapshot and
    /// schedule an async main-thread refresh rather than calling TIS off-main
    /// or blocking with `DispatchQueue.main.sync`.
    private nonisolated static func readSnapshot() -> LayoutSnapshot? {
        installObserverIfNeeded()
        let (cached, isDirty) = cache.withLock { ($0.snapshot, $0.dirty) }
        if !isDirty, let cached { return cached }

        if Thread.isMainThread {
            let fresh = fetchLayoutOnMainThread()
            cache.withLock { state in
                state.snapshot = fresh
                state.dirty = false
            }
            return fresh
        }

        // Off-main thread: schedule an async main-thread refresh and return
        // the last known snapshot (or nil → safe ANSI fallback).
        DispatchQueue.main.async {
            let fresh = fetchLayoutOnMainThread()
            cache.withLock { state in
                state.snapshot = fresh
                state.dirty = false
            }
        }
        return cached
    }

    private nonisolated static func fetchLayoutOnMainThread() -> LayoutSnapshot? {
        let currentSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        let currentData = copyLayoutData(from: currentSource)
        let asciiData = copyLayoutData(from: asciiSource)
        guard currentData != nil || asciiData != nil else { return nil }
        return LayoutSnapshot(
            currentData: currentData,
            asciiCapableData: asciiData,
            keyboardType: UInt32(LMGetKbdType())
        )
    }
}
