//
//  MorphCurve.swift
//  Oto
//
//  The pill → catcher shape transition, copied from the reference's own
//  timing rather than approximated. The reference animates ONE CSS element
//  (30×6 → 416×80) over 420 ms on `--spring-easing`, a `linear()` list:
//
//    linear(0, 0.005, 0.019 1.8%, 0.079 3.9%, 0.476 13.5%, 0.663 19.1%,
//           0.738 22%, 0.8 25.1%, 0.852 28.4%, 0.894 32%, 0.928 36%,
//           0.953 40.5%, 0.972 45.6%, 0.985 51.6%, 0.997 67.3%, 1)
//
//  Two properties matter and neither survives a cubic Bézier: it never
//  overshoots (no sample passes 1 — this is a hard settle, not a spring),
//  and it is nearly a step (48 % of the travel by 13.5 % of the time) with
//  a 300 ms asymptotic tail. Best-fit cubic-bezier(0.10, 0.61, 0.20, 0.99)
//  is off by +0.146 at t = 0.05 — it would double the first frames and lose
//  the settle. So the stops below ARE the animation: `stops` feeds a
//  CAKeyframeAnimation whose segment pacing is linear, exactly as CSS
//  `linear()` interpolates between listed points.
//
//  Unspecified percentages follow the CSS rule (evenly spread between the
//  neighbouring specified points): the two leading points share 0…1.8 %,
//  so 0 % and 0.6 %.
//

import CoreGraphics
import Foundation

/// Reference easing, sampled. Pure and headless-assertable.
enum MorphCurve {
    struct Stop: Equatable, Sendable {
        let time: Double
        let value: Double
    }

    /// The reference's 16 stops, verbatim (seconds normalised to 0…1).
    nonisolated static let stops: [Stop] = [
        Stop(time: 0.000, value: 0.000),
        Stop(time: 0.006, value: 0.005),
        Stop(time: 0.018, value: 0.019),
        Stop(time: 0.039, value: 0.079),
        Stop(time: 0.135, value: 0.476),
        Stop(time: 0.191, value: 0.663),
        Stop(time: 0.220, value: 0.738),
        Stop(time: 0.251, value: 0.800),
        Stop(time: 0.284, value: 0.852),
        Stop(time: 0.320, value: 0.894),
        Stop(time: 0.360, value: 0.928),
        Stop(time: 0.405, value: 0.953),
        Stop(time: 0.456, value: 0.972),
        Stop(time: 0.516, value: 0.985),
        Stop(time: 0.673, value: 0.997),
        Stop(time: 1.000, value: 1.000),
    ]

    /// Eased progress at a normalised time, linear between the reference's
    /// own samples (CSS `linear()` semantics).
    nonisolated static func value(at time: Double) -> Double {
        let t = min(1, max(0, time))
        guard let first = stops.first else { return 1 }
        if t <= first.time { return first.value }
        for i in 1..<stops.count {
            let lo = stops[i - 1]
            let hi = stops[i]
            guard t <= hi.time else { continue }
            let span = hi.time - lo.time
            guard span > 0 else { return hi.value }
            return lo.value + (hi.value - lo.value) * ((t - lo.time) / span)
        }
        return stops.last?.value ?? 1
    }

    /// Keyframe inputs for Core Animation: same samples, same times.
    nonisolated static var keyTimes: [NSNumber] {
        stops.map { NSNumber(value: $0.time) }
    }

    nonisolated static var easedValues: [NSNumber] {
        stops.map { NSNumber(value: $0.value) }
    }
}

/// Geometry of the growing surface. Pure: window coordinates in, window
/// coordinates out — the panel owner does nothing but apply it.
///
/// Anchoring matches the reference's `transform-origin` at the slot edge:
/// a card in the TOP slot shares its top edge with the pill and grows
/// downward; the bottom slot shares its bottom edge and grows upward. x is
/// centred in both cases (the pill and the card are both screen-centred),
/// so the silhouette never travels — it only opens.
enum MorphGeometry {
    /// Surface rect at eased `progress` (0 = pill, 1 = card).
    nonisolated static func rect(
        pill: NSRect, card: NSRect, position: FlowBarPosition, progress: Double
    ) -> NSRect {
        let t = CGFloat(min(1, max(0, progress)))
        let width = pill.width + (card.width - pill.width) * t
        let height = pill.height + (card.height - pill.height) * t
        let y: CGFloat = position == .top ? card.maxY - height : card.minY
        return NSRect(x: card.midX - width / 2, y: y, width: width, height: height)
    }

    /// Corner radius at `progress`: the pill is a capsule (height / 2), the
    /// card is `cardRadius`.
    nonisolated static func radius(
        pillHeight: CGFloat, cardRadius: CGFloat, progress: Double
    ) -> CGFloat {
        let t = CGFloat(min(1, max(0, progress)))
        return pillHeight / 2 + (cardRadius - pillHeight / 2) * t
    }

    /// Rounded-rect path, radius clamped so a thin sliver can never produce
    /// an invalid (self-crossing) capsule.
    nonisolated static func path(_ rect: NSRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        return CGPath(
            roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil
        )
    }
}
