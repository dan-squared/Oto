//
//  OnboardingWindowController.swift
//  Oto
//
//  The single onboarding window, AppKit-hosted (NSWindow + NSHostingView).
//
//  Why not a SwiftUI `WindowGroup(id:)` scene: a named scene never opens
//  itself — something must call `openWindow`, and no Oto view instantiates
//  at launch (menu content is lazy, Settings is on-demand), so there is no
//  reliable SwiftUI-side trigger in either Dock or menu-bar-only mode. The
//  AppDelegate calls `showIfNeeded()` at launch; the menu calls `show()`.
//  Fixed non-resizable 620×480: the compact mandate, enforced by chrome
//  rather than trust. Closing via the red X marks nothing — first-run
//  reshows next launch by construction (no-skip rule); only Finish marks
//  seen.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    nonisolated static let width: CGFloat = 620
    nonisolated static let height: CGFloat = 480

    private let dispatch: ShortcutDispatch
    private let uiState: SettingsUIState
    private var window: NSWindow?

    init(dispatch: ShortcutDispatch, uiState: SettingsUIState) {
        self.dispatch = dispatch
        self.uiState = uiState
    }

    /// First-launch entry: shows only while unseen. Suppressed under unit
    /// tests (XCTest linked into the host): a first-run window stealing
    /// focus mid-suite destabilizes timing-sensitive tests, and dismissal
    /// coverage belongs to the UI test, which launches the app clean.
    func showIfNeeded() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard OnboardingStore.shouldShow() else { return }
        show(activating: true)
    }

    /// Menu-bar re-run entry: always shows, with content rebuilt from the
    /// live config so staged edits start fresh every time.
    func show(activating: Bool = false) {
        if let window {
            window.contentView = NSHostingView(rootView: freshView())
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Oto"
            // Dressed toward the reference welcome: content flows under a
            // transparent titlebar (standard live lights stay — house rule).
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = OtoPalette.NS.ground
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: freshView())
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func freshView() -> OnboardingView {
        OnboardingView(
            dispatch: dispatch,
            uiState: uiState,
            onFinish: { [weak self] in self?.finish() }
        )
    }

    private func finish() {
        OnboardingStore.markSeen()
        window?.close()
    }
}
