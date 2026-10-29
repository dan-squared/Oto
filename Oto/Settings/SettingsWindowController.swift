import AppKit
import SwiftUI

/// Owns the single Settings window. The full-size content style is present
/// before the root view is attached, so the sidebar material runs behind the
/// traffic lights just as it does in Firstlight.
@MainActor
final class OtoSettingsWindowController: NSObject, NSWindowDelegate {
    private let rootView: SettingsRoot
    private(set) var window: NSWindow?

    init(rootView: SettingsRoot) {
        self.rootView = rootView
    }

    func show() {
        if window == nil { makeWindow() }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func makeWindow() {
        let host = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: SettingsRoot.width, height: SettingsRoot.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = SettingsWindowLocator.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        // Settings is a fixed-shape utility window: full screen would stretch
        // a two-column form across the display, and the green button would
        // promise a mode this window can't honour. Refuse the capability and
        // grey the button — ⌃⌘F and the View menu follow the same flag.
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = NSSize(width: SettingsRoot.minimumWidth, height: SettingsRoot.minimumHeight)
        window.contentMaxSize = NSSize(width: SettingsRoot.maximumWidth, height: .greatestFiniteMagnitude)
        window.maxSize = NSSize(width: SettingsRoot.maximumWidth, height: .greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The host installs SwiftUI's own toolbar (back/forward). Assigning a
        // replacement NSToolbar here would drop those items. Reapply the
        // measured content size last, as the Firstlight controller does, or
        // AppKit can retain a transient zero width from the outer SwiftUI
        // host during the first layout pass.
        window.setContentSize(NSSize(width: SettingsRoot.width, height: SettingsRoot.height))
        window.contentView?.layoutSubtreeIfNeeded()
        window.center()
        self.window = window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // AppKit revalidates the titlebar buttons on focus changes; the zoom
        // button must stay refused for the window's whole life.
        window?.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
    }
}
