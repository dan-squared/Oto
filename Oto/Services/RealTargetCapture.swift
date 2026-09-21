//
//  RealTargetCapture.swift
//  Oto
//

import AppKit
import ApplicationServices
import Foundation

/// Real target capture (Phase 4). Reads the frontmost app synchronously at
/// session start — before any Oto UI can appear — plus a best-effort screen
/// for Phase 6's Flow Bar. Never re-resolved at insertion time (02).
///
/// The screen follows the Yap `FocusedWindow` lesson (MIT, Oto-owned): anchor
/// to the focused window's screen, not the mouse — on multi-monitor setups
/// the cursor is often on a display the person isn't looking at. Chain is
/// focused-window → mouse → nil; every step is nil-tolerant.
final class RealTargetCapture: TargetCapturing {
    /// Synchronous snapshot read (NSWorkspace/AX/screen queries are all
    /// nonisolated in the 27 SDK): `nonisolated` to satisfy the protocol
    /// for the background coordinator (Swift 6).
    nonisolated func capture() -> TargetApplication {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID: String? = app?.bundleIdentifier ?? nil
        return TargetApplication(
            bundleIdentifier: bundleID,
            processIdentifier: app?.processIdentifier,
            windowIdentifier: nil,
            displayID: Self.screenDisplayID()
        )
    }

    func isAlive(_ target: TargetApplication) async -> Bool {
        guard let pid = target.processIdentifier else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    // MARK: - Screen (best-effort, nil-tolerant)

    // Synchronous snapshot reads: `nonisolated` for the background
    // capture path (Swift 6); every SDK call inside is nonisolated.
    nonisolated private static func screenDisplayID() -> CGDirectDisplayID? {
        if let id = focusedWindowDisplayID() { return id }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        {
            return CGDirectDisplayID(truncating: number)
        }
        return nil
    }

    nonisolated private static func focusedWindowDisplayID() -> CGDirectDisplayID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Without AX trust every query below fails closed → nil. That is the
        // correct outcome: an unknown screen must never block dictation.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute)
            ?? copyElement(axApp, kAXMainWindowAttribute),
            let position = copyPoint(window, kAXPositionAttribute),
            let size = copySize(window, kAXSizeAttribute),
            size.width > 0, size.height > 0
        else { return nil }
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        for screen in NSScreen.screens {
            // AX reports a top-left origin, y growing down from the primary
            // display's top; NSScreen uses bottom-left. Flip around the
            // primary height to compare against frames.
            guard let height = primaryScreenHeight() else { continue }
            let flipped = CGPoint(x: center.x, y: height - center.y)
            if screen.frame.contains(flipped),
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            {
                return CGDirectDisplayID(truncating: number)
            }
        }
        return nil
    }

    nonisolated private static func primaryScreenHeight() -> CGFloat? {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height
    }

    nonisolated private static func copyElement(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: type ID verified above.
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    nonisolated private static func copyAXValue(_ element: AXUIElement, _ attribute: String, expecting: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        // Safe: type ID verified above.
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == expecting else { return nil }
        return axValue
    }

    nonisolated private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let axValue = copyAXValue(element, attribute, expecting: .cgPoint) else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &result) else { return nil }
        return result
    }

    nonisolated private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let axValue = copyAXValue(element, attribute, expecting: .cgSize) else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &result) else { return nil }
        return result
    }
}
