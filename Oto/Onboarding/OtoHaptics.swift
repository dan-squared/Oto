//
//  OtoHaptics.swift
//  Oto
//
//  The walk's one tap. AppKit's performer has fixed strength, so it is used
//  sparingly.
//

import AppKit

@MainActor
enum OtoHaptics {
    private static var performer: NSHapticFeedbackPerformer {
        NSHapticFeedbackManager.defaultPerformer
    }

    /// The mark reaches the menu-bar item: the one tap that says the app now
    /// lives there. Silent on a mouse, and the system suppresses it when no
    /// finger is on the trackpad.
    static func handoffLanded() {
        self.performer.perform(.alignment, performanceTime: .now)
    }
}
