//
//  OnboardingWindowController.swift
//  Oto
//
//  The single onboarding window: one titled, native window, centred on the
//  screen. AppKit exclusively supplies the frame corners and shadow; the
//  traffic lights stay hidden — the footer's own controls and Escape are the
//  way out. There is no arrival animation and no second window.
//
//  Why not a SwiftUI `WindowGroup(id:)` scene: a named scene never opens
//  itself — something must call `openWindow`, and no Oto view instantiates at
//  launch (menu content is lazy, Settings is on-demand), so there is no
//  reliable SwiftUI-side trigger in either Dock or menu-bar-only mode. The
//  AppDelegate calls `showIfNeeded()` at launch; the menu calls `show()`.
//
//  Closing via the red X marks nothing — first-run reshows next launch by
//  construction (no-skip rule); only Finish marks seen.
//

import AppKit
import SwiftUI

private final class OnboardingWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { self.onEscape?() }
}

private final class ClearOnboardingHost: NSHostingView<OnboardingView> {
    override var isOpaque: Bool { false }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    nonisolated static let width: CGFloat = 1020
    nonisolated static let height: CGFloat = 760
    nonisolated static let minimumWidth: CGFloat = 620
    nonisolated static let minimumHeight: CGFloat = 420

    init(dispatch: ShortcutDispatch, uiState: SettingsUIState) {
        self.dispatch = dispatch
        self.uiState = uiState
    }

    private(set) var isPresented = false
    var onClose: (() -> Void)?

    /// First-launch entry: shows only while unseen. Suppressed under unit
    /// tests (XCTest linked into the host): a first-run window stealing focus
    /// mid-suite destabilizes timing-sensitive tests, and dismissal coverage
    /// belongs to the UI test, which launches the app clean.
    func showIfNeeded() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard OnboardingStore.shouldShow() else { return }
        self.show(activating: true)
    }

    /// Menu-bar re-run entry: always shows, with the flow rebuilt from the
    /// live config so staged edits start fresh every time.
    func show(activating: Bool = false) {
        if self.isPresented {
            if let window = self.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                self.bringForward(window)
            } else {
                NSApp.activate()
            }
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Decode and mask the static mark before the window is built, rather
        // than during its first layout pass.
        _ = OtoMarkSource.cropped
        OnboardingStage.shared.restore()
        let flow = OnboardingFlow(dispatch: self.dispatch, uiState: self.uiState) { [weak self] in
            self?.finish()
        }
        self.flow = flow
        self.isPresented = true
        self.generation = UUID()
        let area = screen.visibleFrame
        let size = NSSize(
            width: min(Self.width, area.width - 24),
            height: min(Self.height, area.height - 24)
        )
        let canvas = NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let window = OnboardingWindow(
            contentRect: canvas,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to Oto"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // The page is pure white or pure black — not the window's native
        // background — so nothing of the frame shows through.
        window.backgroundColor = Self.ground
        window.isOpaque = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: Self.minimumWidth, height: Self.minimumHeight)
        // House rule: full screen is refused and the green button is greyed —
        // ⌃⌘F and the View menu follow the same flag.
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // The walkthrough is a page, not a document window: no traffic lights.
        // AppKit revalidates them on focus changes, so `windowDidBecomeKey`
        // hides them again.
        Self.hideStandardButtons(of: window)
        window.delegate = self
        window.onEscape = { [weak self] in self?.window?.performClose(nil) }
        window.contentView = self.makeHost(flow: flow)
        window.setFrame(canvas, display: false)
        self.window = window

        self.bringForward(window)
        if activating {
            NSApp.activate()
        }
    }

    /// The page mark, in screen coordinates: where the handoff flight starts.
    /// The walk draws this mark at the top left of every chapter, so the
    /// flight leaves from the brand's real place on the page.
    func headerMarkScreenRect() -> CGRect? {
        guard let window = self.window else { return nil }
        let panel = window.contentView?.bounds.size ?? window.frame.size
        let slot = OnboardingChapterLayout.markRect(in: panel)
        let frame = window.frame
        return CGRect(
            x: frame.minX + slot.minX, y: frame.maxY - slot.maxY,
            width: slot.width, height: slot.height
        )
    }

    /// Finish: the mark leaves the header for the menu bar, then the window
    /// goes and the gate is marked seen.
    func finish() {
        guard self.isPresented, !self.finishing else { return }
        self.finishing = true
        OnboardingStage.shared.advance(to: .handoff)
        let ticket = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == ticket else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard !reduceMotion,
                  let start = self.headerMarkScreenRect(),
                  let screen = self.window?.screen ?? NSScreen.main,
                  let image = OtoMarkSource.tinted(Self.ink)
            else {
                self.complete()
                return
            }
            OnboardingStage.shared.markInFlight = true
            let target = OnboardingHandoff.statusItemTarget(
                on: screen,
                aspect: image.size.height > 0 ? image.size.width / image.size.height : 1
            ) ?? OnboardingHandoff.menuBarTarget(on: screen)
            OnboardingHandoff.fly(
                image: image, from: start, to: target,
                reduceMotion: reduceMotion
            ) { [weak self] in
                guard let self, self.generation == ticket else { return }
                self.complete()
            }
        }
    }

    func close() {
        self.tearDown(closeNative: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // AppKit revalidates the titlebar buttons on focus changes; the zoom
        // button must stay refused and all three stay hidden for the window's
        // whole life.
        guard let window = self.window else { return }
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        Self.hideStandardButtons(of: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === self.window else { return }
        self.tearDown(closeNative: false)
        self.onClose?()
    }

    // MARK: Private

    /// The system appearance at the moment the window is built.
    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The page behind everything: pure white on paper, pure black at night.
    /// Dynamic, so a live theme switch repaints the window without a rebuild.
    private static var ground: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        }
    }

    /// The walkthrough has no traffic lights; the footer's own controls and
    /// Escape remain the way out.
    private static func hideStandardButtons(of window: NSWindow) {
        for button in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    /// The mark's own colour: white bars on a dark stage, ink on paper.
    private static var ink: NSColor {
        NSColor(white: Self.isDark ? 0.93 : 0.09, alpha: 1)
    }

    private let dispatch: ShortcutDispatch
    private let uiState: SettingsUIState
    private var flow: OnboardingFlow?
    private var window: OnboardingWindow?
    private var generation = UUID()
    /// The finish flight to the menu bar is under way.
    private var finishing = false

    private func makeHost(flow: OnboardingFlow) -> NSView {
        let host = ClearOnboardingHost(rootView: OnboardingView(flow: flow))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        return host
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate()
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func complete() {
        OnboardingStore.markSeen()
        OnboardingStage.shared.reset()
        self.tearDown(closeNative: true)
    }

    private func tearDown(closeNative: Bool) {
        self.isPresented = false
        self.generation = UUID() // Invalidate queued handoff callbacks.
        OnboardingHandoff.cancelIfNeeded()
        OnboardingStage.shared.markInFlight = false
        self.flow?.disarm()
        self.window?.delegate = nil
        if closeNative { self.window?.close() }
        self.window = nil
        self.flow = nil
        self.finishing = false
    }
}
