//
//  OnboardingHandoff.swift
//  Oto
//
//  The mark is the one thing that exists both in the onboarding window's
//  header and in the menu bar. When the last chapter finishes it leaves the
//  header and flies to the menu bar, which takes it in: the window is gone,
//  and the place the app now lives has just been pointed at. In every frame
//  the mark is in exactly one place.
//
//  Ported from Firstlight. Oto's menu-bar item is a SwiftUI `MenuBarExtra`,
//  so there is no `NSStatusBarButton` to measure; the flight lands at the
//  status area on the right of the screen instead.
//

import AppKit
import QuartzCore

@MainActor
enum OnboardingHandoff {
    static let flightDuration = 0.55

    /// The status area on the right of the menu bar, in screen coordinates.
    static func menuBarTarget(on screen: NSScreen, iconSide: CGFloat = 22) -> CGRect {
        CGRect(
            x: screen.frame.maxX - 30 - iconSide / 2,
            y: screen.frame.maxY - 12 - iconSide / 2,
            width: iconSide, height: iconSide
        )
    }

    /// Flies `image` from `start` (screen coordinates) to `end`, shrinking to
    /// the icon's size, then calls `arrival`. With Reduce Motion, or when the
    /// two are on different screens, there is no flight: `arrival` is called
    /// at once.
    static func fly(
        image: NSImage,
        from start: CGRect,
        to end: CGRect,
        reduceMotion: Bool,
        arrival: @escaping () -> Void
    ) {
        guard !reduceMotion, start.width > 0, start.height > 0 else {
            arrival()
            return
        }
        let cover = start.union(end).insetBy(dx: -40, dy: -40)

        let window = NSWindow(contentRect: cover, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Oto Handoff"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: cover.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host

        let mark = CALayer()
        mark.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        mark.contentsGravity = .resizeAspect
        mark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        mark.frame = start.offsetBy(dx: -cover.minX, dy: -cover.minY)
        host.layer?.addSublayer(mark)
        window.orderFrontRegardless()
        self.inFlight = window

        let target = end.offsetBy(dx: -cover.minX, dy: -cover.minY)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Task { @MainActor in
                window.orderOut(nil)
                window.close()
                if self.inFlight === window { self.inFlight = nil }
                arrival()
            }
        }
        // The same quintic ease the pair rose to the header with.
        let group = CAAnimationGroup()
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: mark.frame.midX, y: mark.frame.midY))
        position.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))
        let bounds = CABasicAnimation(keyPath: "bounds.size")
        bounds.fromValue = NSValue(size: mark.bounds.size)
        bounds.toValue = NSValue(size: target.size)
        group.animations = [position, bounds]
        group.duration = self.flightDuration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.83, 0, 0.17, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        mark.add(group, forKey: "flight")
        CATransaction.commit()
    }

    private static var inFlight: NSWindow?
}
