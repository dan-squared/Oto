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

/// Paste-letter keycode resolution. Pure core (injected translator — fully
/// unit-tested incl. Dvorak remap + failure) + thin live edge (TIS layout +
/// UCKeyTranslate, matrix-proven).
enum PasteKeycodeResolver {
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

    /// Paste key for a letter: live layout first, ANSI fallback always.
    nonisolated static func keyCode(for letter: Character) -> CGKeyCode {
        if let found = keyCode(for: letter, translate: liveTranslation) {
            return CGKeyCode(found)
        }
        return CGKeyCode(fallback(for: letter))
    }

    /// Live translator: UCKeyTranslate over the current layout, dead keys
    /// disabled (a paste key is never a dead key). Nil on any failure
    /// (missing layout, bad format, API error) — the caller falls back.
    nonisolated static func liveTranslation(keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let rawLayout = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue()
        let byteCount = CFDataGetLength(layoutData)
        guard byteCount > 0, let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var chars = [UInt16](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, chars.count, &actualLength, &chars
            )
        }
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}
