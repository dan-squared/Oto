//
//  CatcherSurface.swift
//  Oto
//
//  The catcher's card surface + its pill→card reveal (plan/
//  catcher-morph-parity.md). Replaces the old "animate the window frame"
//  morph, which had three visible defects: the hosting view entered as a
//  square-cornered sliver (window geometry led, the mask lagged a tick),
//  the whole surface faded in instead of being revealed, and the corner
//  radius jumped 13 → 22 mid-flight.
//
//  How this works, and why it is one animation and not four:
//
//  The panel takes its FINAL frame on the first frame of the morph. What
//  animates is a single CAShapeLayer `path` used as the container's mask —
//  a rounded rect that grows from the pill's capsule (at the pill's screen
//  position, in the container's coordinates) to the full card rect, with
//  the corner radius interpolated on the same curve. The card fill and the
//  SwiftUI content both live inside the masked container, so they are
//  revealed by it — the content never moves, reflows, or scales. That is
//  exactly what the reference does (one element's width/height/border-radius
//  animate; the page does not resize).
//
//  Consequences that made this the right shape: no window resize means no
//  per-frame AppKit layout, no SwiftUI re-layout, and no chance of the
//  content's own frame disagreeing with the window's — the content is laid
//  out once at its final size, like a screenshot being wiped on.
//
//  The curve is the reference's own `linear()` spring (MorphCurve), replayed
//  as keyframes because its first 13.5 % of time covering 48 % of the travel
//  cannot be expressed by a cubic Bézier (best fit is off by 0.146 at
//  t = 0.05).
//

import AppKit
import QuartzCore

@MainActor
final class CatcherSurfaceView: NSView {
    /// The card fill. A plain rectangle: the container's mask does the
    /// rounding, so this layer never needs a corner radius (and can never
    /// disagree with the mask about it).
    private let fill = CALayer()
    /// The animating silhouette. Opaque black; only its alpha channel is
    /// read, and as a mask it clips every sublayer *and* subview below.
    private let reveal = CAShapeLayer()
    private var content: NSView?

    /// Card corner radius for the settled state (22).
    private var cardRadius: CGFloat = NoTargetModalController.cornerRadius
    /// Morph endpoints, container coordinates (y up, origin bottom-left —
    /// the same space MorphGeometry reasons in).
    private var startRect = NSRect.zero
    private var endRect = NSRect.zero
    private var anchor: FlowBarPosition = .bottom
    /// While true, `layout()` must not touch `reveal.path`: the render
    /// server owns it until the keyframe animation ends.
    private var isMorphing = false

    private static let morphKey = "oto.catcher.morph"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        reveal.fillColor = NSColor.black.cgColor
        fill.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(fill)
        layer?.mask = reveal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    /// Hosts the SwiftUI card inside the masked container.
    func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        content = view
    }

    var contentAlpha: CGFloat { content?.alphaValue ?? 1 }

    func setContentAlpha(_ alpha: CGFloat) {
        content?.alphaValue = alpha
    }

    /// Ease the content up. Called after the morph's first beat (the
    /// reference fades its content in while the surface is still opening,
    /// so the card is never a blank panel).
    func fadeContentIn(duration: Double) {
        guard let content else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().alphaValue = 1
        }
    }

    func setCardColor(_ color: CGColor) {
        fill.backgroundColor = color
    }

    // MARK: - Settled (non-morph) state

    /// Mask = the whole card, content visible. Used by the plain `show`
    /// path (centred fade, no morph) and as the morph's destination.
    func showStatic(cardRadius: CGFloat) {
        self.cardRadius = cardRadius
        isMorphing = false
        reveal.removeAnimation(forKey: Self.morphKey)
        reveal.path = MorphGeometry.path(bounds, radius: cardRadius)
        setContentAlpha(1)
    }

    // MARK: - Morph

    /// Arms the reveal at the pill's capsule. `pillRect` must already be in
    /// this view's coordinates (the caller subtracts the panel origin);
    /// the card rect is simply our bounds, which the caller has already
    /// sized to the final frame.
    func beginMorph(from pillRect: NSRect, position: FlowBarPosition) {
        cardRadius = NoTargetModalController.cornerRadius
        startRect = pillRect
        endRect = bounds
        anchor = position
        isMorphing = true
        reveal.removeAnimation(forKey: Self.morphKey)
        // Model value first: a dropped frame can only ever show the
        // START silhouette, never an unmasked card.
        reveal.path = MorphGeometry.path(pillRect, radius: pillRect.height / 2)
    }

    /// Replays MorphCurve as a `path` keyframe animation. Every stop is a
    /// fully-formed rounded rect (size AND radius eased together), so the
    /// corner radius can never arrive before the edges do.
    func animateMorph(duration: Double) {
        guard isMorphing, !startRect.isEmpty, !endRect.isEmpty else { return }
        let values: [Any] = MorphCurve.stops.map { stop in
            let rect = MorphGeometry.rect(
                pill: startRect, card: endRect, position: anchor, progress: stop.value
            )
            let radius = MorphGeometry.radius(
                pillHeight: startRect.height, cardRadius: cardRadius, progress: stop.value
            )
            return MorphGeometry.path(rect, radius: radius)
        }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = values
        animation.keyTimes = MorphCurve.keyTimes
        animation.calculationMode = .linear
        animation.duration = duration
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        // Model value is the destination: when the animation is removed the
        // layer is already in its settled state (no snap at the end).
        reveal.path = MorphGeometry.path(endRect, radius: cardRadius)
        reveal.add(animation, forKey: Self.morphKey)
    }

    /// Settle exactly on the card. Idempotent: the controller calls this
    /// when the animation's duration elapses (and again if a re-show
    /// supersedes it), so a dropped completion can never strand the mask.
    func finishMorph() {
        guard isMorphing else { return }
        isMorphing = false
        reveal.removeAnimation(forKey: Self.morphKey)
        reveal.path = MorphGeometry.path(bounds, radius: cardRadius)
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        fill.frame = bounds
        if reveal.frame != bounds { reveal.frame = bounds }
        guard !isMorphing else { return }
        let path = MorphGeometry.path(bounds, radius: cardRadius)
        if reveal.path != path { reveal.path = path }
    }
}
