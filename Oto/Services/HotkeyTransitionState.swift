//
//  HotkeyTransitionState.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import CoreGraphics
import Foundation

/// Pure transition machine: (event, mode, pressed) → (transition, pressed).
/// No hardware, no async, no side effects — the exhaustively tested core
/// that both backends (Carbon combos, HID function keys, modifier-hold)
/// converge into (12). The coordinator owns everything after `begin`/`finish`.
///
/// Rules (02):
/// - Hold-to-talk: first non-repeat down begins; repeats ignored; matching
///   up finishes (including up-while-starting — the coordinator turns that
///   into finish-when-ready); down-while-active ignored.
/// - Hands-free: non-repeat down toggles begin/finish; up ignored.
/// - Monitor loss / second source of truth conflicts: reset local pressed
///   state, decide nothing about the session.
/// - Escape is translated to `reset` + coordinator cancel by the dispatch
///   layer (Escape always cancels, single step — no Yap two-step).
struct HotkeyTransitionState: Equatable, Sendable {
    /// Whether OUR tracked key is currently physically down. This is the
    /// only memory in the machine; repeats and foreign keys never set it.
    var isDown = false

    enum Input: Equatable, Sendable {
        case event(ShortcutEvent)
        case escape
    }

    mutating func step(_ input: Input, mode: InteractionMode) -> ShortcutTransition {
        switch input {
        case .escape:
            isDown = false
            return .reset
        case .event(.monitorLost):
            isDown = false
            return .reset
        case .event(.keyDown(let isRepeat)):
            switch mode {
            case .holdToTalk:
                guard !isRepeat, !isDown else { return .ignore }
                isDown = true
                return .begin
            case .handsFree:
                guard !isRepeat else { return .ignore }
                // Toggle: down while up begins; down while down finishes.
                // (Key-up never reaches this machine in hands-free.)
                if isDown {
                    isDown = false
                    return .finish
                } else {
                    isDown = true
                    return .begin
                }
            }
        case .event(.keyUp):
            switch mode {
            case .holdToTalk:
                guard isDown else { return .ignore }
                isDown = false
                return .finish
            case .handsFree:
                return .ignore
            }
        }
    }
}

/// Pure function-key matching (F-row + Dictation key on the HID path).
/// Bare press only: ⌘F5 is VoiceOver and modified F-keys belong to other
/// apps; fn flag is fine (it's how the row is typed in media mode).
/// Adopted from the Yap reference (`FunctionKeyTrigger.shouldFire`, MIT).
enum FunctionKeyMatching: Sendable {
    static func shouldFire(
        codes: Set<Int64>,
        keyCode: Int64,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        guard !isRepeat, codes.contains(keyCode) else { return false }
        return flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }
}
