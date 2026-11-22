//
//  AccessibilityPrewarm.swift
//  Oto
//
//  Session-start AX prewarm: ask the captured target to publish its
//  accessibility tree *before* the focus gate reads it.
//
//  Chromium and Electron build no accessibility tree until an assistive
//  client asks ("Accessibility features in Chrome are off by default and
//  enabled automatically on-demand"). With the tree asleep the app answers
//  `kAXErrorNoValue` for the focused element, which the gate used to read
//  as "nowhere to paste" — measured on a live Claude composer, 2026-10-19.
//
//  Two documented/observed handshakes, both app-defined attribute names
//  (neither is an SDK constant — verified by grep over HIServices headers):
//
//    AXManualAccessibility  — Electron's documented third-party switch
//                             ("third-party assistive technology can toggle
//                             accessibility features … by setting the
//                             AXManualAccessibility attribute").
//    AXEnhancedUserInterface — the AppKit/WebKit enhanced-UI flag that
//                             Chromium-family shells also watch (Codex ships
//                             this string and not the other one).
//
//  Apps that implement neither answer `kAXErrorAttributeUnsupported`
//  (-25205). That is expected, harmless, and logged.
//
//  Rules: runs off the press path (the user is about to speak — those
//  seconds are free), gated on AX trust, never prompts, never downloads,
//  never reads content, never throws. Its only failure mode is "no
//  improvement", because the gate no longer depends on the app answering.
//

import ApplicationServices
import Foundation
import os

enum AccessibilityPrewarm: Sendable {
    /// Raw AX results, kept for the trail (Int32 so they compare and log
    /// without the opaque `AXError` description).
    struct Outcome: Equatable, Sendable {
        var trusted: Bool
        var manual: Int32
        var enhanced: Int32
        var pull: Int32
    }

    /// App-defined attribute names — see the header. Not SDK constants.
    nonisolated static let manualAccessibility = "AXManualAccessibility"
    nonisolated static let enhancedUserInterface = "AXEnhancedUserInterface"

    private nonisolated static let log = Logger(subsystem: "app.Oto", category: "focus")

    /// Fire-and-forget: the caller is on the press path and must not wait
    /// on another app's AX server.
    nonisolated static func armInBackground(pid: pid_t, bundleID: String?) {
        DispatchQueue.global(qos: .utility).async {
            _ = arm(pid: pid, bundleID: bundleID)
        }
    }

    /// Ask the target app to publish, then pull once. `pull` matters because
    /// Chromium enables on a *read*, not on the write alone.
    @discardableResult
    nonisolated static func arm(pid: pid_t, bundleID: String?) -> Outcome {
        guard pid > 0, AXIsProcessTrusted() else {
            return Outcome(trusted: false, manual: 0, enhanced: 0, pull: 0)
        }
        let app = AXUIElementCreateApplication(pid)
        let manual = AXUIElementSetAttributeValue(
            app, manualAccessibility as CFString, kCFBooleanTrue
        ).rawValue
        let enhanced = AXUIElementSetAttributeValue(
            app, enhancedUserInterface as CFString, kCFBooleanTrue
        ).rawValue
        var focused: CFTypeRef?
        let pull = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused
        ).rawValue
        let outcome = Outcome(trusted: true, manual: manual, enhanced: enhanced, pull: pull)
        log.info("arm pid=\(pid, privacy: .public) app=\(bundleID ?? "?", privacy: .public) manual=\(manual, privacy: .public) enhanced=\(enhanced, privacy: .public) pull=\(pull, privacy: .public)")
        return outcome
    }
}
