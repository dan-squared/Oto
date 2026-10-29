//
//  OnboardingWindowController.swift
//  Oto
//
//  The single onboarding window, ported from Firstlight: a borderless
//  "carrier" carries the light across the desktop, then the real titled
//  window takes over while the light is still moving. AppKit exclusively
//  supplies the traffic lights, frame corners and shadow.
//
//  Why two windows: the intro is edge-to-edge light, and a titled window's
//  chrome would sit on top of it. The carrier is what the desktop sees until
//  the light has filled the pane; the native window is the one that stays.
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
import Metal
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
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Decode and mask the static mark before the clock starts, rather than
        // during its visible handoff from the shader to the SwiftUI image.
        _ = OtoMarkSource.cropped
        if let device = MTLCreateSystemDefaultDevice() {
            do { try MetalRenderer.prewarm(device: device) }
            catch { self.playback.fail(error.localizedDescription) }
        }
        OnboardingStage.shared.reset()
        let flow = OnboardingFlow(dispatch: self.dispatch, uiState: self.uiState) { [weak self] in
            self?.finish()
        }
        self.flow = flow
        self.isPresented = true
        self.generation = UUID()
        self.playback.prepare()
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

        let carrier = OnboardingWindow(contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: false)
        carrier.title = "Oto Intro"
        carrier.backgroundColor = .clear
        carrier.isOpaque = false
        carrier.hasShadow = false
        carrier.alphaValue = 0
        carrier.isReleasedWhenClosed = false
        carrier.ignoresMouseEvents = true
        carrier.collectionBehavior = [.fullScreenAuxiliary]
        carrier.contentView = self.makeHost(flow: flow, native: false)
        carrier.onEscape = { [weak self] in self?.finishAnimation() }
        self.carrier = carrier

        // AppKit exclusively supplies the traffic lights, frame corners and shadow.
        let native = OnboardingWindow(
            contentRect: canvas.insetBy(dx: self.inset, dy: self.inset),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        native.title = "Welcome to Oto"
        native.titleVisibility = .hidden
        native.titlebarAppearsTransparent = true
        native.titlebarSeparatorStyle = .none
        // The form must remain readable even before Metal presents a frame,
        // especially when reopening skips the animated intro. The window
        // follows the system appearance; the shader is told the same thing.
        native.backgroundColor = .windowBackgroundColor
        native.isOpaque = true
        native.hasShadow = true
        native.isReleasedWhenClosed = false
        native.isMovableByWindowBackground = true
        native.contentMinSize = NSSize(width: Self.minimumWidth, height: Self.minimumHeight)
        // House rule: full screen is refused and the green button is greyed —
        // ⌃⌘F and the View menu follow the same flag.
        native.collectionBehavior.remove(.fullScreenPrimary)
        native.collectionBehavior.insert(.fullScreenNone)
        native.collectionBehavior.insert(.moveToActiveSpace)
        native.standardWindowButton(.zoomButton)?.isEnabled = false
        native.delegate = self
        native.onEscape = { [weak self] in self?.window?.performClose(nil) }
        native.contentView = self.makeHost(flow: flow, native: true)
        native.setFrame(canvas.insetBy(dx: self.inset, dy: self.inset), display: false)
        self.window = native
        self.playback.panelRect = CGRect(
            x: self.inset,
            y: self.inset,
            width: native.frame.width,
            height: native.frame.height
        )
        self.playback.onFrame = { [weak self] time, finished in self?.updateDesktop(time: time, finished: finished) }
        self.playback.onNativeFramePresented = { [weak self] time in
            self?.retireCarrier(afterNativeFrame: time)
        }
        self.observeInterruptions()

        // Prewarm the final drawable without exposing any underlying window chrome.
        native.alphaValue = 0
        native.orderBack(nil)
        native.contentView?.layoutSubtreeIfNeeded()
        // The intro plays in the carrier, so it is the one to bring forward;
        // the real window takes over from it at the hand-off below, by which
        // time the app is active and can simply take the keyboard.
        self.bringForward(carrier)
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ticket = self.generation
        // Activation and the first Metal drawable settle before the clock starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.2 : 0)) { [weak self] in
            guard let self, self.isPresented, self.generation == ticket, !self.finishing else { return }
            self.playback.start(animated: animated, sound: OnboardingSoundVariant.selected())
        }
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Escape or a click on the intro: skip to the static mark, never skip
    /// the flow itself.
    func finishAnimation() {
        guard self.isPresented else { return }
        if self.playback.finished {
            self.playback.stop()
        } else {
            self.playback.finish()
        }
    }

    /// The header mark, in screen coordinates: where the handoff flight starts.
    func headerMarkScreenRect() -> CGRect? {
        guard let native = self.window else { return nil }
        let panel = native.contentView?.bounds.size ?? native.frame.size
        let slot = WelcomeLayout.frame(at: IntroTiming.duration, in: panel, rise: 1).markRect
        let frame = native.frame
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
            OnboardingHandoff.fly(
                image: image, from: start, to: OnboardingHandoff.menuBarTarget(on: screen),
                reduceMotion: reduceMotion
            ) { [weak self] in
                self?.complete()
            }
        }
    }

    func close() {
        self.tearDown(closeNative: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // AppKit revalidates the titlebar buttons on focus changes; the zoom
        // button must stay refused for the window's whole life.
        self.window?.standardWindowButton(.zoomButton)?.isEnabled = false
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

    /// The mark's own colour: white bars on a dark stage, ink on paper.
    private static var ink: NSColor {
        NSColor(white: Self.isDark ? 0.93 : 0.09, alpha: 1)
    }

    private let dispatch: ShortcutDispatch
    private let uiState: SettingsUIState
    private let inset: CGFloat = 76
    private let playback = IntroPlayback()
    private var flow: OnboardingFlow?
    private var carrier: OnboardingWindow?
    private var window: OnboardingWindow?
    private var dimmers: [NSWindow] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation = UUID()
    /// The carrier has handed the light to the real window.
    private var nativeHandedOff = false
    /// The finish flight to the menu bar is under way.
    private var finishing = false
    /// The desktop has been darkened for this presentation, once. Checking the
    /// dimmers themselves would bring them back the frame after they were
    /// let go of.
    private var desktopStaged = false

    private func makeHost(flow: OnboardingFlow, native: Bool) -> NSView {
        let host = ClearOnboardingHost(
            rootView: OnboardingView(playback: self.playback, flow: flow, nativeSurface: native)
        )
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        return host
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
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

    private func updateDesktop(time: Double, finished: Bool) {
        guard self.isPresented, let carrier, let native = self.window else { return }
        // The real window takes over while the light is still moving; the same
        // clock keeps running inside it until the light has become the mark.
        let presentNative = self.playback.readyForNative || finished
        if !presentNative, !self.desktopStaged {
            self.desktopStaged = true
            native.orderOut(nil)
            for screen in NSScreen.screens {
                let dimmer = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                dimmer.title = "Oto Desktop Dimmer"
                // A dark veil over a dark desktop, a light one over paper.
                dimmer.backgroundColor = Self.isDark ? .black : .white
                dimmer.isOpaque = false
                dimmer.hasShadow = false
                dimmer.alphaValue = 0
                dimmer.ignoresMouseEvents = true
                dimmer.isReleasedWhenClosed = false
                dimmer.level = .statusBar
                dimmer.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                dimmer.orderFrontRegardless()
                self.dimmers.append(dimmer)
            }
            carrier.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            carrier.makeKeyAndOrderFront(nil)
            let ticket = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.generation == ticket, !self.nativeHandedOff else { return }
                carrier.alphaValue = 1
            }
        }
        self.dimmers.forEach { $0.alphaValue = IntroTiming.dimming(atReal: self.playback.realElapsed) }
        guard presentNative, !self.nativeHandedOff, !self.playback.nativePresented else { return }
        self.removeDimmers()
        self.nativeHandedOff = true
        let ticket = self.generation
        native.alphaValue = 0
        native.orderBack(nil)
        native.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.generation == ticket, self.isPresented else { return }
            native.alphaValue = 1
            // Somebody who clicked elsewhere during the intro still sees it
            // arrive: in front, without taking the keyboard from them.
            if NSApp.isActive { native.makeKeyAndOrderFront(nil) }
            else { native.orderFrontRegardless() }
            native.invalidateShadow()
            // Keep the last carrier image beneath the native window until its
            // first Metal drawable is actually presented. Window ordering and
            // GPU presentation can otherwise leave one bare desktop frame.
            carrier.level = native.level
            carrier.order(.below, relativeTo: native.windowNumber)
            self.playback.didPresentNative()
            if finished || self.playback.shaderFailure != nil {
                carrier.orderOut(nil)
                carrier.contentView = nil
            }
        }
    }

    private func retireCarrier(afterNativeFrame time: Double) {
        guard time >= IntroTiming.handoff,
              self.window?.alphaValue == 1, self.playback.nativePresented,
              let carrier = self.carrier, carrier.contentView != nil else { return }
        carrier.orderOut(nil)
        carrier.contentView = nil
    }

    private func removeDimmers() {
        self.dimmers.forEach { $0.close() }
        self.dimmers.removeAll()
    }

    private func observeInterruptions() {
        // A click anywhere outside the window, or another app coming forward,
        // used to end the intro on the spot: its last seconds vanished in one
        // frame. Now it plays on, and only the darkened desktop is given back.
        let center = NotificationCenter.default
        let resigned = center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeDimmers() }
        }
        self.observers.append((center, resigned))
        for name in [
            NSApplication.didChangeScreenParametersNotification,
            NSApplication.didHideNotification,
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishAnimation() }
            }
            self.observers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let reduce = workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.finishAnimation() }
            }
        }
        self.observers.append((workspace, reduce))
        let sleep = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishAnimation() }
        }
        self.observers.append((workspace, sleep))
    }

    private func tearDown(closeNative: Bool) {
        self.isPresented = false
        self.generation = UUID() // Invalidate queued prewarm/handoff callbacks.
        self.playback.stop()
        self.playback.onFrame = nil
        self.playback.onNativeFramePresented = nil
        self.removeDimmers()
        for (center, token) in self.observers { center.removeObserver(token) }
        self.observers.removeAll()
        self.window?.delegate = nil
        if closeNative { self.window?.close() }
        self.carrier?.close()
        self.carrier = nil
        self.window = nil
        self.flow = nil
        self.nativeHandedOff = false
        self.finishing = false
        self.desktopStaged = false
    }
}
