//
//  SettingsWindowDresser.swift
//  Oto
//
//  The native Settings scene names its window "<App> Settings" with no
//  SwiftUI API to change that — so the window gets dressed instead of
//  replaced (re-registering settings as a plain window would lose
//  system ⌘-comma, SettingsLink, and Settings-scene behaviors for zero
//  visual gain). Hidden title text + transparent bar over the ground
//  pair blends chrome into content in both schemes. Identification is by
//  exclusion (the only titled window besides onboarding) — no
//  localization dependence, no class sniffing. No match means native
//  look: never a broken state. Hiding text costs no accessibility:
//  window.title stays "Oto Settings" for VoiceOver and Exposé.
//

import AppKit

@MainActor
final class SettingsWindowDresser {
    /// The one titled window that is NOT dressed.
    nonisolated static let onboardingTitle = "Welcome to Oto"

    init() {
        // Selector-based (not closure-based): the notification object
        // can't cross into a Sendable closure under Swift 6, so scan
        // synchronously on post instead — the AppleAudioCapture
        // config-observer precedent. becomeKey posts on main; dressing
        // is idempotent, windows are few.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowBecameKey() {
        for window in NSApp.windows where Self.shouldDress(window) {
            Self.dress(window)
        }
    }

    nonisolated static func shouldDress(_ window: NSWindow) -> Bool {
        !window.title.isEmpty && window.title != onboardingTitle
    }

    static func dress(_ window: NSWindow) {
        guard shouldDress(window) else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = OtoPalette.NS.ground
    }
}
