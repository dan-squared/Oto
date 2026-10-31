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
//  so there is no `NSStatusItem` to ask; the item's AppKit window is in
//  `NSApp.windows`, and its `NSStatusBarButton` gives the icon's real frame
//  on whichever display the menu bar is on.
//

import AppKit
import QuartzCore

@MainActor
enum OnboardingHandoff {
    static let flightDuration = 0.55
    /// The mark dissolves into the real glyph over the last eighth of the
    /// flight; the two shapes are close but not identical, and the dissolve
    /// hides the difference at the moment of the hand-over.
    static let fadeDuration = 0.08
    /// Measured on this Mac (38 pt menu bar, 29 pt status button): the SF
    /// waveform's ink is 12 × 13.5 pt, centred on the button. 47% of the
    /// button's height is that 13.5 pt; the clamp keeps the mark icon-sized
    /// if a shorter menu bar yields a shorter button.
    private static let iconHeightRatio: CGFloat = 0.47
    private static let iconHeightRange: ClosedRange<CGFloat> = 13 ... 16

    /// The status area on the right of the menu bar, in screen coordinates.
    /// Only the fallback: when the real item cannot be found (auto-hidden
    /// bar, no status window yet) this is the best guess there is.
    static func menuBarTarget(on screen: NSScreen, iconSide: CGFloat = 22) -> CGRect {
        let barHeight = max(
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top,
            24
        )
        let centreY = screen.frame.maxY - barHeight / 2
        return CGRect(
            x: screen.frame.maxX - 30 - iconSide / 2,
            y: centreY - iconSide / 2,
            width: iconSide, height: iconSide
        )
    }

    /// Where the icon is drawn inside a status button: centred, with the
    /// mark's own aspect so its ink fills the icon's measured height.
    static func landingRect(centredIn button: CGRect, aspect: CGFloat) -> CGRect {
        let height = min(
            max(button.height * Self.iconHeightRatio, Self.iconHeightRange.lowerBound),
            Self.iconHeightRange.upperBound
        )
        let width = height * max(aspect, 0.01)
        return CGRect(
            x: button.midX - width / 2, y: button.midY - height / 2,
            width: width, height: height
        )
    }

    /// The real menu-bar item's icon rect, in screen coordinates.
    ///
    /// `NSApp.windows` only holds this process's windows, so the status
    /// window found here is Oto's own. Dimmers and the onboarding carrier
    /// also sit at `.statusBar` level; requiring a public `NSStatusBarButton`
    /// in the hierarchy is what tells the item apart from them. On a display
    /// with a mirrored menu bar the window on the onboarding screen wins.
    static func statusItemTarget(
        on screen: NSScreen?,
        aspect: CGFloat,
        windows: [NSWindow] = NSApp.windows
    ) -> CGRect? {
        let candidates = windows.filter {
            $0.level == .statusBar && $0.isVisible
                && $0.frame.width > 0 && $0.frame.height > 0
        }
        let preferred = candidates.filter { window in
            guard let windowScreen = window.screen else { return false }
            return windowScreen === screen
        }
        guard let window = preferred.first ?? candidates.first,
              let button = statusButton(in: window.contentView)
        else { return nil }
        // `convert(_:to: nil)` is window space (bottom-left origin), which is
        // the space `convertToScreen` takes; the button already accounts for
        // the notch, the bar's height and every neighbouring item.
        let inWindow = button.convert(button.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        guard onScreen.width > 0, onScreen.height > 0 else { return nil }
        return self.landingRect(centredIn: onScreen, aspect: aspect)
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
        guard !reduceMotion, start.width > 0, start.height > 0,
              let screen = screen(containing: end), screen.frame.intersects(start)
        else {
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
        mark.contentsScale = screen.backingScaleFactor
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
                // The tap is the tap of the landing, not of a window closing.
                OtoHaptics.handoffLanded()
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
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1, 1, 0]
        opacity.keyTimes = [0, NSNumber(value: 1 - Self.fadeDuration / Self.flightDuration), 1]
        group.animations = [position, bounds, opacity]
        group.duration = self.flightDuration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.83, 0, 0.17, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        mark.add(group, forKey: "flight")
        CATransaction.commit()
    }

    private static var inFlight: NSWindow?

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = self.statusButton(in: subview) { return button }
        }
        return nil
    }

    /// The display a rect lands on; a rect on a screen's seam belongs to the
    /// screen that owns its centre.
    private static func screen(containing rect: CGRect) -> NSScreen? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main
    }
}
