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
        let toolbar = NSToolbar(identifier: "OtoSettings")
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = NSSize(width: SettingsRoot.minimumWidth, height: SettingsRoot.minimumHeight)
        window.contentMaxSize = NSSize(width: SettingsRoot.maximumWidth, height: .greatestFiniteMagnitude)
        window.maxSize = NSSize(width: SettingsRoot.maximumWidth, height: .greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Assigning the host and then the unified toolbar lets AppKit replace
        // the content view. Reapply the measured content size last, as the
        // Firstlight controller does, or AppKit can retain a transient zero
        // width from the outer SwiftUI host during the first layout pass.
        window.setContentSize(NSSize(width: SettingsRoot.width, height: SettingsRoot.height))
        window.contentView?.layoutSubtreeIfNeeded()
        window.center()
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
    }
}
