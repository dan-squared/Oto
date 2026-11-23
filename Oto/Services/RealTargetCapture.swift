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
    /// Hard AX IPC timeout so a hung target never stalls session start.
    nonisolated static let axTimeoutSeconds: Float = 0.25

    /// Synchronous snapshot read: reads `NSWorkspace.shared.frontmostApplication`
    /// ONCE so PID and display lookup never split across apps, and resolves
    /// display geometry via thread-safe CoreGraphics (never touching AppKit
    /// `NSScreen`/`NSEvent` off-main).
    nonisolated func capture() -> TargetApplication {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier
        let bundleID: String? = app?.bundleIdentifier
        return TargetApplication(
            bundleIdentifier: bundleID,
            processIdentifier: pid,
            windowIdentifier: nil,
            displayID: Self.screenDisplayID(pid: pid)
        )
    }

    func isAlive(_ target: TargetApplication) async -> Bool {
        guard let pid = target.processIdentifier else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    // MARK: - Screen (best-effort, nil-tolerant, thread-safe CoreGraphics)

    nonisolated private static func screenDisplayID(pid: pid_t?) -> CGDirectDisplayID? {
        if let pid, let id = focusedWindowDisplayID(pid: pid) { return id }
        return mouseDisplayID()
    }

    nonisolated private static func focusedWindowDisplayID(pid: pid_t) -> CGDirectDisplayID? {
        // Without AX trust every query below fails closed → nil. That is the
        // correct outcome: an unknown screen must never block dictation.
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.axTimeoutSeconds)
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute)
            ?? copyElement(axApp, kAXMainWindowAttribute),
            let position = copyPoint(window, kAXPositionAttribute),
            let size = copySize(window, kAXSizeAttribute),
            size.width > 0, size.height > 0
        else { return nil }
        // AX window origin/size are already in CoreGraphics global display
        // coordinates (top-left origin, y growing down), matching
        // `CGDisplayBounds` and `CGGetDisplaysWithRect`.
        let windowRect = CGRect(origin: position, size: size)
        return displayID(for: windowRect)
    }

    /// Picks the display with maximum intersection area against `rect`,
    /// falling back to the display containing the rect's center point.
    nonisolated private static func displayID(for rect: CGRect) -> CGDirectDisplayID? {
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        if CGGetDisplaysWithRect(rect, maxDisplays, &displays, &count) == .success, count > 0 {
            var bestID: CGDirectDisplayID = displays[0]
            var bestArea: CGFloat = -1
            for index in 0..<Int(count) {
                let candidate = displays[index]
                let overlap = CGDisplayBounds(candidate).intersection(rect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > bestArea {
                    bestArea = area
                    bestID = candidate
                }
            }
            return bestID
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displayID(for: center)
    }

    nonisolated private static func displayID(for point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else {
            return nil
        }
        return display
    }

    nonisolated private static func mouseDisplayID() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        return displayID(for: point)
    }

    nonisolated private static func copyElement(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: type ID verified above.
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        return element
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
