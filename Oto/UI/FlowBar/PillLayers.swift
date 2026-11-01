//
//  PillLayers.swift
//  Oto
//
//  Slice 6B v8: the pill's GPU renderer. One layer-backed NSView, zero
//  SwiftUI: a frosted-glass capsule hosts all the artwork (background scrim,
//  bars, dots, labels, spinner). Motion is two clocks: DATA (one loudness
//  level + ripple phase per vsync, actions disabled) and MOTION (the loader's
//  chase glide as an infinite CAAnimation interpolating on the render server —
//  zero MainActor work per frame, no timers, no Metal).
//  Overflow is caged by masksToBounds (sublayers) + clipsToBounds (subviews).
//
//  Colour: the body ramp, the veil and the frost tint are one
//  `PillPalette` (PillColor.swift) resolved from the user's pill colour —
//  graphite (black glass) by default, six swatches in Settings → General
//  (plan/pill-color-palette.md). Every colour shares the same stop count,
//  locations and alphas; only hue moves.
//
//  Hierarchy (AppKit only guarantees the glass CONTENT view sits inside the
//  glass, so the artwork is reparented, never layered underneath it):
//
//  PillContentView (drag; NO rect clip — the material's own edge must not be
//                   chopped where the capsule touches the bounds)
//  └── NSGlassEffectView (regular, capsule)
//      └── ink (contentView, layer-backed, masked to the capsule so no
//               group can ever paint outside the silhouette)
//          ├── bg (scrim, capsule inset 1 pt; solid fallback under Reduce
//          │       Transparency)
//          ├── tintGradient (the colour body ramp; mask = the capsule)
//          │   └── sheen (one feathered top → body → bottom highlight)
//          ├── 10 bars, 9 chase dots (CALayers)
//          └── label, shineLabel, spinner (subviews)
//
//  Chrome rule (v3): no stroked layer touches the silhouette. Every edge is
//  either a mask's antialiasing or a gradient stop — a hard 1 pt rim on a
//  26 pt pill reads as a drawn outline, which is exactly what the previous
//  rimStroke/rimGradient pair produced (plan/pill-liquid-chrome-v3.md).
//
//  Geometry: relaxed compact (80.85×26.4 recording). Elements shrink, count
//  stays: 10 thin bars, 9 chase dots. No record dot — it was removed on
//  2026-11-01 so the capsule is just its wave; the width table in
//  VisualizerMath follows the row.
//

import AppKit
import QuartzCore

/// Pill chrome constants, in one place so the look is swappable.
enum PillChrome {
    /// Legibility floor painted over the glass, UNDER the body ramp. It was
    /// 0.45 while the pill was a near-black capsule; 0.12 is now only enough
    /// to stop a white wallpaper from washing the colour out. A heavier veil is
    /// also what kills the glass: a translucent pill has to show the frost
    /// behind it (2026-11-01, second pass — "more glassy, liquid glass").
    nonisolated static let scrimAlpha: CGFloat = 0.12

    /// The scrim's colour is per-palette (`PillPalette.scrim`): the veil is
    /// colour *density*, so it darkens the body without greying it.

    /// The veil stops this far inside the silhouette. A capsule that reaches
    /// the edge puts its own dark antialiasing exactly on the rim, where the
    /// material is most translucent — the rim then reads dark instead of lit
    /// (`plan/pill-liquid-chrome-v3.md` D3). 1 pt in, the body covers it.
    nonisolated static let scrimInset: CGFloat = 1.0

    /// Colour crossfade when the user picks another pill colour. Long enough
    /// to read as a material change (the ramp + the veil move together),
    /// short enough that the pill never lags the click.
    nonisolated static let colorMorphDuration: Double = 0.22

    // MARK: - Body ramp
    //
    // The ramp itself lives in `PillPalette` (PillColor.swift): hue is the
    // user's choice, density is the pill's. It used to be six hard-coded red
    // stops here (plan/pill-red-glass.md); that recipe is now the crimson
    // case of the same five-stop math, reproduced to within a couple of
    // points, so nothing about the shipped red look was lost in the move.
    //
    // The structure is unchanged and still measured from the inspiration:
    // hue constant, only lightness moves — deepest at the horizontal middle,
    // softening to a pale, light-catching tip at each cap. AXIAL, not radial
    // (a radial ramp's falloff is tied to the half-height on a 26 pt pill and
    // flattened the whole body into one dark block).

    /// The lit edge, v3: **no stroke anywhere**. The rim is a *gradient* —
    /// a bright top band that feathers into the body, a soft highlight under
    /// it, nothing through the waist, and a dim reflected band at the bottom.
    /// Every boundary here is a gradient stop or the capsule mask's own
    /// antialiasing, so there is no line to read as an outline.
    ///
    /// What this replaced (and why): `rimGradient` was a gradient painted
    /// through a 1 pt inset capsule *stroke*. A 1 pt hard band on a 26 pt pill
    /// is a third of the perceived colour, and its bottom stop was darker than
    /// the body beside it — literally a dark hairline at the silhouette.
    nonisolated static let sheenRimTop = NSColor(white: 1, alpha: 0.34)
    /// Body highlight just under the top rim — the cue that the surface is
    /// curved glass, not a painted shape.
    nonisolated static let sheenBody = NSColor(white: 1, alpha: 0.10)
    nonisolated static let sheenWaist = NSColor(white: 1, alpha: 0)
    /// Reflected rim at the bottom: dimmer, never dark.
    nonisolated static let sheenRimBottom = NSColor(white: 1, alpha: 0.18)

    /// Sheen stops. Start = top (`ink` is non-flipped: y = 1 is the top), so
    /// location 0 is the rim and 1 is the bottom edge.
    nonisolated static let sheenStops: [(location: CGFloat, color: NSColor)] = [
        (0.00, sheenRimTop),
        (0.14, sheenBody),
        (0.42, sheenWaist),
        (0.84, sheenWaist),
        (1.00, sheenRimBottom),
    ]

    nonisolated static var sheenLocations: [NSNumber] {
        sheenStops.map { NSNumber(value: Double($0.location)) }
    }

    nonisolated static var sheenColors: [CGColor] {
        sheenStops.map { $0.color.cgColor }
    }
}

/// Display-only work-verb label: a stock `NSTextField` label that is also
/// mouse-transparent. The shine overlay sits topmost over the base label;
/// returning nil from hit-testing lets every press fall through to the
/// base label / content view beneath, so the pill's press-drag grab works
/// starting on shimmering text exactly as it does on plain text. (Drag is
/// owned by `PillContentView.mouseDown`, the pill carries no buttons, and
/// the overlay is AX-hidden — nothing needs events on it, ever.)
private final class ShineLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Which layer group is visible. Maps 1:1 from FlowBarState (+ notice).
/// v6: no stagnant dots at either end — preparing renders bars (waves from
/// frame one), completion renders nothing (vanish path). Dots exist only
/// as the working loader (finalizing/inserting).
enum PillVisual: Equatable {
    case bars
    case dots
    case dotsSpinner
    case message
    /// E2 live-model work: joint label + divider + spinner layout at a
    /// measured dynamic width (`Cleanup` / preset name — one word max).
    /// Transient working state (preparing/recording family) — controller-latched from
    /// the work feed, never state-mapped (same as `.message`), never an
    /// end-state or error pixel (v6/v7 rules).
    case work

    /// Pill case → layer group. Nil renders nothing (hidden).
    /// v7: failures never reach the pill (concise menu status owns them).
    /// `.message` renders only the controller-latched over-limit Copied
    /// pill — same size as recording, so the switch is a re-render, never
    /// a resize.
    nonisolated static func forState(_ state: FlowBarState) -> PillVisual? {
        switch state {
        case .hidden: nil
        case .preparing: .bars
        case .recording: .bars
        case .finalizing, .inserting: .dotsSpinner
        case .message: .message
        }
    }
}

/// Drag source (Phase 8): the pill carries no buttons, so every
/// press-drag is a move. Origins are screen-space, grab-offset corrected.
@MainActor
protocol PillDragDelegate: AnyObject {
    func pillDragBegan()
    func pillDragMoved(toOrigin screenOrigin: NSPoint)
    func pillDragEnded(moved: Bool)
}

@MainActor
final class PillContentView: NSView {
    nonisolated static let padding: CGFloat = 8.25

    /// Frosted chrome. `ink` is the glass's content view — the glass header
    /// only guarantees that view sits inside the effect, so all artwork
    /// lives there.
    private let glass = NSGlassEffectView()
    private let ink = NSView()
    private let bg = CAShapeLayer()
    /// Glass stack (plan/pill-red-glass.md, v3 in
    /// plan/pill-liquid-chrome-v3.md). `tintGradient` is the axial body ramp;
    /// `sheen` is its only sublayer, so ONE capsule mask (`capsuleMask`)
    /// clips both — a mask clips its layer's whole subtree, so no per-layer
    /// mask bookkeeping and only one antialiased silhouette edge.
    private let tintGradient = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let capsuleMask = CAShapeLayer()
    /// The artwork cage: the same capsule, as `ink`'s mask. It replaces the
    /// pill's old rectangular `clipsToBounds`/`masksToBounds` pair, which cut
    /// the glass's own outer edge exactly where the capsule touches the
    /// bounds (the "it is clipped" report, 2026-11-01).
    private let inkMask = CAShapeLayer()
    /// Whether the ramp is currently carrying the colour alone (Reduce
    /// Transparency). Nil until the first applyChrome; drives a one-shot
    /// colour swap, never a per-render set (which would re-animate).
    private var rampOpaque: Bool?
    private var barLayers: [CAShapeLayer] = []
    private var chaseLayers: [CALayer] = []
    /// Native Apple spinner. Forced dark appearance so it always draws
    /// its light variant — the pill is near-black in both schemes, and
    /// the default appearance resolution can leave it dark-on-dark.
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    /// Shine-sweep overlay (work verbs only): full-bright duplicate of
    /// `label` — same construction, so text rendering and mouse-event
    /// behavior are identical by construction. Display-only: AX-hidden
    /// (the base label stays the single AX source) and alive only while
    /// the `.work` visual is up. A `CAGradientLayer` bright window masks
    /// it (see `shineMask`); the mask's position sweeps on the render
    /// server — zero per-frame MainActor work.
    private let shineLabel = ShineLabel(labelWithString: "")
    private let shineMask = CAGradientLayer()
    private var shineOn = false
    private var shineInstalledWidth: CGFloat = 0
    private var currentWidth: CGFloat = 0
    private var currentVisual: PillVisual?
    /// Render-server motion state (v5): the chase glide and the work shine
    /// are CAAnimations interpolating on the render server — zero per-frame
    /// MainActor work. `motionVisual` tracks which visual owns installed
    /// animations so the 150 ms poll never restarts them. Data (loudness,
    /// label) and motion (chase/shine) are independent clocks by design:
    /// the analyzer stops outside recording, but the loader must stay alive.
    private var motionVisual: PillVisual?
    private var frozenMotion = false
    /// Reduce Transparency is read per render; injectable so tests never
    /// depend on the machine's accessibility settings.
    var reduceTransparencyProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    /// The pill's colour, read per render like the Reduce Transparency flag
    /// above (the Settings pane writes the key, the poll picks it up within
    /// one frame and crossfades). Injectable for the same reason.
    var colorProvider: () -> PillColor = { PillColor.current() }
    /// The colour currently installed on the ramp/veil. Nil until the first
    /// `applyChrome` — that first pass snaps (no crossfade from a default the
    /// user never picked).
    private var activeColor: PillColor?
    weak var dragDelegate: PillDragDelegate?
    private var dragGrabOffset = NSSize.zero
    private var dragMoved = false
    nonisolated static let chaseKey = "oto.chase"
    /// Shine-sweep animation key (work verbs). Same render-server discipline
    /// as the chase key above — install-guarded, never poked per frame.
    nonisolated static let shineKey = "oto.shine"
    /// Sweep pacing: explicit linear. Duration math (travel/velocity)
    /// promises constant velocity, which only holds with linear pacing —
    /// never rely on the framework default. Shared instance (effectively
    /// immutable after creation; MainActor-confined like its owning view,
    /// since CAMediaTimingFunction is not Sendable) so tests can pin
    /// identity, not just behavior.
    static let shinePacing = CAMediaTimingFunction(name: .linear)
    /// One chase cycle: 9 dots at ~6.7 dots/s (the old tick feel, gliding).
    nonisolated static let chaseCycle: Double = 1.35

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // NO rect clip on the pill (plan/pill-liquid-chrome-v3.md D2): the
        // glass capsule touches the bounds at its left/right extremes, so a
        // rectangular clip chops the material's own outer edge there. Overflow
        // is caged instead by `inkMask` — the same capsule, one level down —
        // which clips with the silhouette's shape instead of a box.
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        // Frosted chrome first (it must stay behind the artwork, and the
        // artwork lives INSIDE it — see the header).
        glass.style = .regular
        glass.cornerRadius = VisualizerMath.pillHeight / 2
        glass.frame = bounds
        addSubview(glass)
        ink.wantsLayer = true
        ink.layer?.masksToBounds = true
        ink.layer?.backgroundColor = NSColor.clear.cgColor
        ink.autoresizingMask = [.width, .height]
        ink.frame = glass.bounds
        // The cage: a capsule mask, never a box clip.
        inkMask.fillColor = NSColor.black.cgColor
        ink.layer?.mask = inkMask
        glass.contentView = ink

        bg.fillColor = PillPalette(color: colorProvider()).scrim
        bg.opacity = Float(PillChrome.scrimAlpha)
        // No self-drawn shadow: with masksToBounds (overflow clip) a
        // sublayer shadow would be clipped invisible — and a same-layer
        // shadow is clipped with it (classic masksToBounds gotcha). The
        // drop shadow comes from the window (hasShadow, follows the pill
        // alpha via the WindowServer), which masksToBounds never touches.
        ink.layer?.addSublayer(bg)

        // Colour glass, above the scrim (the scrim is the legibility floor;
        // the ramp is the design). Built bottom-up so the mask can clip the
        // whole subtree.
        // AXIAL, not radial: the ramp runs along the capsule's long axis
        // (pale tips → deep waist), exactly like the inspiration. A radial
        // ramp's falloff is tied to the half-height on a 26 pt pill, which
        // flattened the whole body into one dark block.
        tintGradient.type = .axial
        tintGradient.startPoint = CGPoint(x: 0.0, y: 0.5)
        tintGradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        tintGradient.colors = PillPalette(color: colorProvider()).bodyColors(opaque: false)
        tintGradient.locations = PillPalette.stops.map { NSNumber(value: Double($0)) }
        tintGradient.mask = capsuleMask
        glass.tintColor = PillPalette(color: colorProvider()).tint

        // The lit rim, v3: ONE feathered gradient instead of a rim stroke.
        // Bright at the top edge, a soft highlight just under it, nothing
        // through the waist, a dim reflected band at the bottom. `ink` is
        // non-flipped, so y = 1 is the top and location 0 is the top rim.
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheen.colors = PillChrome.sheenColors
        sheen.locations = PillChrome.sheenLocations
        tintGradient.addSublayer(sheen)

        ink.layer?.addSublayer(tintGradient)

        let barPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: VisualizerMath.barWidth, height: VisualizerMath.barFullHeight),
            cornerWidth: VisualizerMath.barWidth / 2,
            cornerHeight: VisualizerMath.barWidth / 2, transform: nil
        )
        for _ in 0..<VisualizerMath.barCount {
            let bar = CAShapeLayer()
            bar.path = barPath
            bar.fillColor = NSColor.white.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: VisualizerMath.barWidth, height: VisualizerMath.barFullHeight)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayers.append(bar)
            ink.layer?.addSublayer(bar)
        }

        for _ in 0..<VisualizerMath.dotCount {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = VisualizerMath.chaseDot / 2
            dot.bounds = CGRect(x: 0, y: 0, width: VisualizerMath.chaseDot, height: VisualizerMath.chaseDot)
            chaseLayers.append(dot)
            ink.layer?.addSublayer(dot)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.frame = CGRect(x: 0, y: 0, width: VisualizerMath.spinnerSize, height: VisualizerMath.spinnerSize)
        ink.addSubview(spinner)

        label.textColor = .white
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        ink.addSubview(label)

        shineLabel.textColor = .white
        // Single-sourced with measurement (measureWorkText uses workFont):
        // a future size change moves base, overlay, and metrics together,
        // so the shine can never sit 1px off the glyphs.
        shineLabel.font = VisualizerMath.workFont
        shineLabel.lineBreakMode = .byTruncatingTail
        shineLabel.maximumNumberOfLines = 1
        // Explicit layer: the mask below needs a host layer even before
        // first paint (subviews of a layer-backed view normally get one,
        // but this is load-bearing — never implicit).
        shineLabel.wantsLayer = true
        // Display-only duplicate: never an AX element, never a drag or
        // click target beyond what the base label already is.
        shineLabel.setAccessibilityElement(false)
        shineLabel.isHidden = true
        ink.addSubview(shineLabel)

        showOnly(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillContentView has no nib")
    }

    // MARK: - Layout (width changes only — scrim path + positions)

    /// The glass and its ink follow the pill's bounds. Called from
    /// `layout()` and from every width change so the capsule and the
    /// window frame morph together.
    private func layoutChrome() {
        let radius = bounds.height / 2
        if glass.frame != bounds { glass.frame = bounds }
        if glass.cornerRadius != radius { glass.cornerRadius = radius }
        if ink.frame != glass.bounds { ink.frame = glass.bounds }
        // The glass stack fills the ink; its masks carry the silhouette.
        let inkBounds = ink.bounds
        for layer in [tintGradient, sheen] {
            if layer.frame != inkBounds { layer.frame = inkBounds }
        }
        // First layout (the scrim has no path yet): snap every silhouette
        // path. Later width changes animate them with the scrim below.
        if bg.path == nil { syncChromePaths() }
    }

    /// Capsule silhouettes, one path source: the scrim (inset, so its dark
    /// edge can never land on the rim), the body ramp's mask, and the ink's
    /// cage mask. All three are the pill's own outline, so they can never
    /// disagree with each other or with the window frame.
    private func syncChromePaths() {
        let w = bounds.width
        let h = bounds.height
        let size = CGSize(width: w, height: h)
        let capsule = CGPath(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerWidth: h / 2, cornerHeight: h / 2, transform: nil
        )
        capsuleMask.frame = CGRect(origin: .zero, size: size)
        capsuleMask.path = capsule
        inkMask.frame = CGRect(origin: .zero, size: size)
        inkMask.path = capsule
        let inset = PillChrome.scrimInset
        let inner = CGSize(width: max(0, w - inset * 2), height: max(0, h - inset * 2))
        bg.path = CGPath(
            roundedRect: CGRect(x: inset, y: inset, width: inner.width, height: inner.height),
            cornerWidth: inner.height / 2, cornerHeight: inner.height / 2, transform: nil
        )
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    func layout(width: CGFloat) {
        guard width != currentWidth else { return }
        currentWidth = width
        setFrameSize(NSSize(width: width, height: VisualizerMath.pillHeight))
        layoutChrome()
        let h = VisualizerMath.pillHeight
        let hadPath = bg.path != nil
        if hadPath {
            // Liquid chrome (v5 F4, v6 retime): the silhouette morphs over
            // the same 0.15s easeOut as the window frame (FlowBarPanel.setFrame),
            // so pill and window move as one. First layout snaps (no path yet).
            // Element positions snap to the final geometry instantly — with
            // the outgoing group already dead (shrink) or fading in (growth),
            // the eye reads content-leading-chrome-following as liquid.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            // The scrim, the ramp mask and the ink cage ride the SAME
            // transaction: a snapping mask over a gliding scrim would flash a
            // rectangle of ramp past the old corner.
            syncChromePaths()
            CATransaction.commit()
        } else {
            syncChromePaths()
        }
        let midY = h / 2

        // Recording block: the bar row, centred. No record dot (removed
        // 2026-11-01) — the row IS the content, so it centres on the pill
        // and the capsule width follows it (VisualizerMath.dictationWidth).
        let barsBlock = CGFloat(VisualizerMath.barCount) * VisualizerMath.barPitch
        let x = (width - barsBlock) / 2
        for (i, bar) in barLayers.enumerated() {
            bar.position = CGPoint(x: x + CGFloat(i) * VisualizerMath.barPitch + VisualizerMath.barPitch / 2, y: midY)
        }

        // Chase block: dots (+ spinner), centered.
        let dotsBlock = CGFloat(VisualizerMath.dotCount - 1) * VisualizerMath.chasePitch + VisualizerMath.chaseDot
        var dotsX = (width - dotsBlock) / 2
        if currentVisual == .dotsSpinner {
            dotsX = (width - (dotsBlock + 6.6 + VisualizerMath.spinnerSize)) / 2
        }
        for (i, dot) in chaseLayers.enumerated() {
            dot.position = CGPoint(x: dotsX + CGFloat(i) * VisualizerMath.chasePitch + VisualizerMath.chaseDot / 2, y: midY)
        }
        // Work positions its own spinner in update() (text-measured geometry);
        // the dots-block origin below never applies to it.
        if currentVisual != .work {
            spinner.setFrameOrigin(NSPoint(
                x: dotsX + dotsBlock + 6.6,
                y: midY - VisualizerMath.spinnerSize / 2
            ))
        }

        // Message label fills between padding.
        label.frame = CGRect(
            x: Self.padding, y: 0,
            width: max(0, width - Self.padding * 2), height: h
        )
    }

    // MARK: - Render (cheap property sets; fades ride the render server)

    /// The pill carries no controls: every press inside its bounds is a
    /// drag. Without this, presses landing on the glass's own content
    /// view (and on the label) would be routed to those views instead of
    /// the drag owner.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// Group switch with a render-server fade. Call before `layout(width:)`
    /// so centering (which depends on the visible group) is exact.
    /// `animated=false` kills the outgoing group instantly (no fade-out):
    /// used on shrink transitions, where a fading group would overflow the
    /// already-narrower frame (v4 F1b).
    func show(visual: PillVisual, animated: Bool = true) {
        if visual != currentVisual || !animated {
            // Stop render-server motion FIRST (an attached infinite opacity
            // animation would override the fade-out below and the dying
            // group would never leave) — EXCEPT dots ↔ dotsSpinner, which
            // share one wave: restarting it on preparing→finalizing would
            // visibly rewind mid-flight.
            let keepWave = animated && isChase(currentVisual) && isChase(visual)
            if !keepWave { stopMotionAnimations() }
            showOnly(visual, animated: animated)
            // Shine lives and dies with the work visual only (a sweep over
            // the Copied notice would teach "working" for a confirmation).
            if visual != .work { removeShine() }
            currentVisual = visual
        }
        ensureMotion(for: visual)
    }

    private func isChase(_ visual: PillVisual?) -> Bool {
        visual == .dots || visual == .dotsSpinner
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopMotionAnimations()
            removeShine()
        }
    }

    // MARK: - Render-server motion (v5: true GPU, zero per-frame CPU)

    /// Idempotent: installs the motion for `visual` unless it already runs.
    /// The poll calls `show` every 150 ms — restarting a CAAnimation there
    /// would rewind the wave 6.7×/s (visible stutter). The `motionVisual`
    /// guard makes re-entry free.
    private func ensureMotion(for visual: PillVisual?) {
        guard motionVisual != visual else { return }
        stopMotionAnimations()
        guard !frozenMotion else {
            motionVisual = visual
            return
        }
        switch visual {
        case .bars:
            // The wave is data-driven (loudness + ripple per vsync); there is
            // no render-server motion in the recording state since the record
            // dot was removed.
            break
        case .dots, .dotsSpinner:
            startChaseAnimation()
        case .message, .work, .none:
            break
        }
        motionVisual = visual
    }

    /// Traveling brightness wave: every dot runs the SAME 12-sample pulse
    /// (sampled from VisualizerMath so pixels agree with the tested model),
    /// staggered by one dot-step via beginTime. At commit time the wave is
    /// already mid-flight — no spin-up pop. Interpolated on the render
    /// server at display refresh; the MainActor does nothing per frame.
    private func startChaseAnimation() {
        let cycle = Self.chaseCycle
        let step = cycle / Double(VisualizerMath.dotCount)
        let samples = 12
        let values: [NSNumber] = (0..<samples).map { j in
            NSNumber(value: VisualizerMath.dotOpacityContinuous(
                index: 0, head: Double(j) * Double(VisualizerMath.dotCount) / Double(samples)
            ))
        }
        let keyTimes: [NSNumber] = (0..<samples).map { j in
            NSNumber(value: Double(j) / Double(samples - 1))
        }
        let t0 = CACurrentMediaTime()
        for (i, dot) in chaseLayers.enumerated() {
            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = values
            anim.keyTimes = keyTimes
            anim.duration = cycle
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            // Negative stagger: dot i is already i steps into its cycle,
            // so dot 0 is brightest and the tail falls off — instantly.
            anim.beginTime = t0 - Double(i) * step
            dot.opacity = 1
            dot.add(anim, forKey: Self.chaseKey)
        }
    }

    private func stopMotionAnimations() {
        chaseLayers.forEach { $0.removeAnimation(forKey: Self.chaseKey) }
        motionVisual = nil
    }

    // MARK: - Work shimmer (traveling shine on the work verb)

    /// Installs the shine sweep over the current label content. Idempotent:
    /// repolls with identical text+frame are free — the wave is never
    /// restarted mid-flight (same discipline as `ensureMotion`). A text or
    /// width change reinstalls from scratch (rare: the work verb is fixed
    /// per run). Per explicit product direction (2026-10-05) this installs
    /// regardless of Reduce Motion; content accessibility is unchanged.
    private func installShine() {
        let text = label.stringValue
        let frame = label.frame
        guard !text.isEmpty, frame.width > 0, frame.height > 0 else { return }
        if shineOn, shineLabel.stringValue == text, shineInstalledWidth == frame.width {
            shineLabel.isHidden = false
            return
        }
        // (Re)install: kill the old sweep first so a text change never
        // stacks two waves.
        shineMask.removeAnimation(forKey: Self.shineKey)
        shineLabel.stringValue = text
        shineLabel.frame = frame
        shineLabel.isHidden = false
        label.textColor = NSColor.white.withAlphaComponent(VisualizerMath.shineBaseAlpha)
        // Bright window: soft band `band` wide at the gradient center.
        // The mask is oversized (label + one band each side) so the sweep
        // starts/ends fully off-text — no edge pops, ever. Direction is
        // EXPLICITLY horizontal: CAGradientLayer defaults to vertical
        // (top-to-bottom), which renders as a static stripe through the
        // letters and ignores the X sweep entirely (seen on device).
        let band = VisualizerMath.shineBandWidth(forLabelWidth: frame.width)
        let travelW = frame.width + 2 * band
        let halfFraction = (band / 2) / travelW
        shineMask.colors = [
            NSColor.clear.cgColor, NSColor.white.cgColor,
            NSColor.white.cgColor, NSColor.clear.cgColor,
        ]
        shineMask.startPoint = CGPoint(x: 0, y: 0.5)
        shineMask.endPoint = CGPoint(x: 1, y: 0.5)
        shineMask.locations = [
            NSNumber(value: 0.5 - halfFraction), NSNumber(value: 0.5),
            NSNumber(value: 0.5), NSNumber(value: 0.5 + halfFraction),
        ]
        shineMask.bounds = CGRect(x: 0, y: 0, width: travelW, height: frame.height)
        // Band center == mask x by construction (band sits at the gradient
        // center): sweep the center from fully-left to fully-right.
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -band
        anim.toValue = frame.width + band
        anim.duration = VisualizerMath.shineDuration(forLabelWidth: frame.width)
        anim.timingFunction = Self.shinePacing
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        shineMask.position = CGPoint(x: frame.width + band, y: frame.height / 2)
        shineLabel.layer?.mask = shineMask
        shineMask.add(anim, forKey: Self.shineKey)
        shineOn = true
        shineInstalledWidth = frame.width
    }

    /// Tears down the sweep and restores the base label to full white.
    /// Safe when absent (guard) — called on every visual switch out of
    /// `.work` and on window teardown. Deliberately NOT called from
    /// `stopMotionAnimations()`: that funnel also runs per-poll under
    /// Reduce Motion, which would restart the wave 6.7×/s.
    private func removeShine() {
        guard shineOn else { return }
        shineMask.removeAnimation(forKey: Self.shineKey)
        shineLabel.layer?.mask = nil
        shineLabel.isHidden = true
        label.textColor = .white
        shineOn = false
        shineInstalledWidth = 0
    }

    // MARK: - Loudness-driven bars (poll path)

    /// One loudness level + ripple phase → 10 bar scales.
    /// `animated` glides the poll's ~6.7 Hz targets (the live display-link
    /// path skips this and sets at vsync); `reduceMotion` holds one still,
    /// shaped row instead.
    private func applyBarScales(
        level: Float, time: Double, animated: Bool, reduceMotion: Bool
    ) {
        CATransaction.begin()
        if animated {
            // Buttery (v7): each poll's targets glide 0.12s easeOut from
            // the current presentation, so the slow poll clock never reads
            // as stiffness. (The live path owns 1:1 vsync sets instead.)
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, bar) in barLayers.enumerated() {
            let scale: Float = reduceMotion
                ? VisualizerMath.staticScale(index: i)
                : VisualizerMath.barScale(index: i, level: level, time: time)
            bar.transform = CATransform3DMakeScale(1, max(0.02, CGFloat(scale)), 1)
        }
        CATransaction.commit()
    }

    /// Per-data-push values (poll clock, ≤6.7 Hz). Touches ONLY data-driven
    /// properties: bar scales + label text. The chase lives on the render
    /// server (see above) and is never poked here — data rate and motion
    /// rate are independent clocks by design.
    func update(
        level: Float, time: Double, text: String?, centerText: Bool,
        reduceMotion: Bool, liveValues: Bool = false
    ) {
        if reduceMotion != frozenMotion {
            frozenMotion = reduceMotion
            // Force motion re-evaluation on the freeze/unfreeze edge.
            motionVisual = nil
        }
        // Chrome first: Reduce Transparency may have flipped since the last
        // poll, and the scrim under the artwork must be right before paint.
        applyChrome()
        // Instant sets: label text + frozen statics (never glide).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if currentVisual == .message {
            if let text { label.stringValue = text }
            label.alignment = centerText ? .center : .left
            // Vertically center: an NSTextField draws from the top of a
            // tall frame, so fit the label to its text and center it in
            // the pill (same 92.4 width as dictation — re-render, no resize).
            label.sizeToFit()
            let h = VisualizerMath.pillHeight
            var f = label.frame
            f.size.width = min(f.size.width, max(0, currentWidth - Self.padding * 2))
            f.size.height = min(f.size.height, h)
            f.origin.x = centerText ? (currentWidth - f.size.width) / 2 : Self.padding
            f.origin.y = max(0, (h - f.size.height) / 2)
            label.frame = f
        } else if currentVisual == .work {
            // Joint layout: [padding][text][gap][spinner][padding], matching
            // VisualizerMath.workPillWidth chrome (same slack — single
            // source, exact-fit truncation can never recur).
            if let text { label.stringValue = text }
            label.alignment = .left
            label.sizeToFit()
            let h = VisualizerMath.pillHeight
            let measured = ceil(VisualizerMath.measureWorkText(label.stringValue))
                + VisualizerMath.workTextSlack
            let chromeTail = VisualizerMath.workPadding
                + VisualizerMath.workSpinnerGap
                + VisualizerMath.spinnerSize
                + VisualizerMath.workPadding
            let labelW = min(measured, max(0, currentWidth - chromeTail))
            let labelH = min(label.frame.size.height, h)
            label.frame = CGRect(
                x: VisualizerMath.workPadding, y: max(0, (h - labelH) / 2),
                width: labelW, height: labelH
            )
            spinner.setFrameOrigin(NSPoint(
                x: VisualizerMath.workPadding + labelW + VisualizerMath.workSpinnerGap,
                y: h / 2 - VisualizerMath.spinnerSize / 2
            ))
        }
        if reduceMotion {
            // Frozen: statics only, no animations (Reduce Motion contract).
            if currentVisual == .dots || currentVisual == .dotsSpinner {
                chaseLayers.forEach { $0.opacity = 0.6 }
            }
        }
        CATransaction.commit()
        if currentVisual == .bars, !liveValues {
            applyBarScales(
                level: level, time: time,
                animated: !reduceMotion, reduceMotion: reduceMotion
            )
        }
        if reduceMotion {
            stopMotionAnimations()
            motionVisual = currentVisual
        } else {
            ensureMotion(for: currentVisual)
        }
        if currentVisual == .dotsSpinner || currentVisual == .work, !reduceMotion { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
        spinner.isHidden = reduceMotion || (currentVisual != .dotsSpinner && currentVisual != .work)
        // Shine sweep on the work verb (render-server wave; idempotent
        // across repolls — see installShine). Deliberately outside the
        // Reduce Motion gate per product direction (2026-10-05): whenever
        // the work visual is up, the verb shimmers.
        if currentVisual == .work {
            installShine()
        }
    }

    /// Vsync path (display link owns delivery): instant 1:1 sets, no glide.
    /// At 60/120 Hz the data IS the motion — a 0.12s glide would smear it.
    /// Actions disabled, no allocation, MainActor-only.
    func setLiveLevels(level: Float, time: Double) {
        guard currentVisual == .bars, !frozenMotion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let scale = VisualizerMath.barScale(index: i, level: level, time: time)
            bar.transform = CATransform3DMakeScale(1, max(0.02, CGFloat(scale)), 1)
        }
        CATransaction.commit()
    }

    /// Glass on, or the solid scrim when the user asked for reduced
    /// transparency. Same silhouette, same bars either way.
    private func applyChrome() {
        let reduceTransparency = reduceTransparencyProvider()
        if glass.isHidden != reduceTransparency { glass.isHidden = reduceTransparency }
        let opacity: Float = reduceTransparency ? 1 : Float(PillChrome.scrimAlpha)
        if bg.opacity != opacity { bg.opacity = opacity }

        // Colour: the ramp, the veil and the frost tint all move together, so
        // a palette change lands as one material change. Read every poll (the
        // Settings key is written from another window); the guard makes a
        // repoll free. Under Reduce Transparency the frost is gone, so the
        // ramp alone has to carry the colour at full alpha — the fallback is
        // *flat colour glass*, never grey.
        let color = colorProvider()
        guard activeColor != color || rampOpaque != reduceTransparency else { return }
        let firstInstall = activeColor == nil && rampOpaque == nil
        activeColor = color
        rampOpaque = reduceTransparency
        let palette = PillPalette(color: color)
        CATransaction.begin()
        if firstInstall {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(PillChrome.colorMorphDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        tintGradient.colors = palette.bodyColors(opaque: reduceTransparency)
        bg.fillColor = palette.scrim
        CATransaction.commit()
        // Tint is a view property, not a layer one: no render-server
        // crossfade available, and a 26 pt capsule hides the step.
        glass.tintColor = palette.tint
    }

    /// Group visibility with a render-server fade. Model values flip
    /// immediately (assertable headless); pixels interpolate on the GPU.
    /// v6: 0.15s — buttery fast, no float.
    private func showOnly(_ visual: PillVisual?, animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.15)
        } else {
            CATransaction.setDisableActions(true)
        }
        let barsOn = visual == .bars
        barLayers.forEach { $0.opacity = barsOn ? 1 : 0 }
        let dotsOn = visual == .dots || visual == .dotsSpinner
        chaseLayers.forEach { $0.opacity = dotsOn ? $0.opacity : 0 }
        CATransaction.commit()
        label.isHidden = visual != .message && visual != .work
        // Shine overlay tracks the base label's visibility exactly (the
        // sweep itself is installed/torn down separately).
        shineLabel.isHidden = visual != .work
        if visual != .dotsSpinner && visual != .work { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    // MARK: - Drag and snap (Phase 8)

    /// Nonactivating panel: without this, press-drag never reaches us.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let window else { return }
        // Grab-offset: the pill follows the finger, it never jumps.
        let mouse = NSEvent.mouseLocation
        dragGrabOffset = NSSize(
            width: mouse.x - window.frame.origin.x,
            height: mouse.y - window.frame.origin.y
        )
        dragMoved = false
        dragDelegate?.pillDragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        dragMoved = true
        dragDelegate?.pillDragMoved(toOrigin: NSPoint(
            x: mouse.x - dragGrabOffset.width,
            y: mouse.y - dragGrabOffset.height
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragDelegate?.pillDragEnded(moved: dragMoved)
        dragMoved = false
    }

    // MARK: - Test hooks (layer model values, no window needed)

    func barOpacity(_ i: Int) -> Float { barLayers[i].opacity }
    /// Work joint-layout frames (label, spinner) for the frame-containment
    /// test: the spinner must sit snug to the right edge (no dead space
    /// beyond padding) with the full label left of it.
    func workLayoutFrames() -> (label: CGRect, spinner: CGRect) {
        (label.frame, spinner.frame)
    }
    func chaseOpacity(_ i: Int) -> Float { chaseLayers[i].opacity }
    func barScaleY(_ i: Int) -> CGFloat { barLayers[i].transform.m22 }
    func spinnerHidden() -> Bool { spinner.isHidden }
    func labelText() -> String { label.stringValue }
    func chaseHasAnimation() -> Bool {
        chaseLayers.allSatisfy { $0.animation(forKey: Self.chaseKey) != nil }
    }
    /// Shine-sweep model values (headless-assertable like the chase hooks):
    /// sweep installed, overlay content/visibility/geometry, base dim.
    func shineHasAnimation() -> Bool {
        shineMask.animation(forKey: Self.shineKey) != nil
    }
    func shineOverlayText() -> String { shineLabel.stringValue }
    func shineOverlayHidden() -> Bool { shineLabel.isHidden }
    func shineOverlayFrame() -> CGRect { shineLabel.frame }
    func shineBaseAlpha() -> CGFloat { label.textColor?.alphaComponent ?? -1 }
    /// Gradient sweep direction: the band must travel horizontally. This
    /// pins the exact bug class that animation-existence checks cannot see
    /// (a vertical gradient renders a static stripe and ignores the sweep).
    func shineGradientIsHorizontal() -> Bool {
        shineMask.startPoint == CGPoint(x: 0, y: 0.5)
            && shineMask.endPoint == CGPoint(x: 1, y: 0.5)
    }
    /// Sweep pacing pin: the installed wave must carry the shared linear
    /// pacing (identity — same object, not merely equal behavior), or the
    /// constant-velocity promise in VisualizerMath silently breaks.
    func shineSweepIsLinear() -> Bool {
        (shineMask.animation(forKey: Self.shineKey) as? CABasicAnimation)?.timingFunction === Self.shinePacing
    }
    func chaseAnimationCount() -> Int {
        chaseLayers.filter { $0.animation(forKey: Self.chaseKey) != nil }.count
    }
    func chaseBeginTime(_ i: Int) -> TimeInterval {
        chaseLayers[i].animation(forKey: Self.chaseKey)?.beginTime ?? -1
    }
    func contentMaskedToBounds() -> Bool { layer?.masksToBounds == true }
    /// v3 overflow cage: the artwork is clipped by a CAPSULE mask on `ink`,
    /// not by the pill's bounding rect (a box clip chops the material's own
    /// edge where the capsule touches the bounds).
    func inkMaskIsCapsule() -> Bool {
        guard let mask = ink.layer?.mask as? CAShapeLayer,
              let path = mask.path,
              mask.strokeColor == nil else { return false }
        return path.boundingBox == bounds
    }
    /// Chrome rule pin: no stroked layer touches the silhouette. Every edge
    /// must be a mask's antialiasing or a gradient stop — a 1 pt round stroke
    /// on a 26 pt pill is exactly what read as a drawn black outline
    /// (plan/pill-liquid-chrome-v3.md D1).
    func chromeHasNoStrokedOutline() -> Bool {
        func isStrokedShape(_ layer: CALayer) -> Bool {
            guard let shape = layer as? CAShapeLayer else { return false }
            return shape.strokeColor != nil && shape.fillColor == nil
        }
        for layer in ink.layer?.sublayers ?? [] {
            if isStrokedShape(layer) { return false }
            if let mask = layer.mask, isStrokedShape(mask) { return false }
            for inner in layer.sublayers ?? [] {
                if isStrokedShape(inner) { return false }
                if let mask = inner.mask, isStrokedShape(mask) { return false }
            }
        }
        return true
    }
    /// Glass chrome contracts: the effect is up, capsule-shaped, filled by
    /// its ink content view, and the artwork lives inside that ink (never
    /// layered under the glass, whose z-order AppKit does not guarantee).
    func glassVisible() -> Bool { !glass.isHidden }
    func glassIsCapsule() -> Bool {
        abs(glass.cornerRadius - bounds.height / 2) < 0.001
            && glass.frame == bounds
    }
    func inkFillsGlass() -> Bool {
        glass.contentView === ink && ink.frame == glass.bounds
    }
    func artworkIsInsideInk() -> Bool {
        label.superview === ink && spinner.superview === ink
            && shineLabel.superview === ink
            && barLayers.allSatisfy { $0.superlayer === ink.layer }
            && chaseLayers.allSatisfy { $0.superlayer === ink.layer }
            && bg.superlayer === ink.layer
    }
    /// Scrim opacity: the glass look at scrimAlpha, solid under Reduce
    /// Transparency.
    func scrimOpacity() -> Float { bg.opacity }
    /// Palette hooks: the waist stop (index 4 — the pixel the user judges),
    /// the frost tint and the veil, so the colour contract is assertable
    /// headless (no window, no material).
    func rampWaistColor() -> NSColor? {
        guard let colors = tintGradient.colors as? [CGColor], colors.count > 4 else { return nil }
        return NSColor(cgColor: colors[4])?.usingColorSpace(.sRGB)
    }
    func rampWaistAlpha() -> CGFloat {
        guard let colors = tintGradient.colors as? [CGColor], colors.count > 4 else { return -1 }
        return colors[4].alpha
    }
    func rampStopCount() -> Int { tintGradient.colors?.count ?? 0 }
    func frostTint() -> NSColor? { glass.tintColor }
    func veilColor() -> CGColor? { bg.fillColor }
}
