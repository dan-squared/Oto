//
//  OtoHaptics.swift
//  Oto
//
//  The intro's taps. AppKit's performer has fixed strength, so cadence
//  carries the swell — the same vocabulary Firstlight's arrival uses.
//

import AppKit

@MainActor
enum OtoHaptics {
    private static var performer: NSHapticFeedbackPerformer {
        NSHapticFeedbackManager.defaultPerformer
    }

    /// One tap in the ray swell, before the window arrives.
    static func introPulse() {
        self.performer.perform(.generic, performanceTime: .now)
    }

    /// The accent when the swell reaches its crest.
    static func introClimax() {
        self.performer.perform(.alignment, performanceTime: .now)
    }

    /// The wordmark leaves the mark.
    static func introNameStarted() {
        self.performer.perform(.levelChange, performanceTime: .now)
    }

    /// The pair lands in the header.
    static func introRiseLanded() {
        self.performer.perform(.generic, performanceTime: .now)
    }
}
