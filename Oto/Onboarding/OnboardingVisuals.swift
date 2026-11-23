//
//  OnboardingVisuals.swift
//  Oto
//
//  Apple-grade, restrained physics-driven onboarding visualizations.
//  - Uses Oto's own real Pill (`VisualizerMath` 10-bar traveling ripple +
//    `PillColor` / `PillPalette` liquid glass), Oto's real Catcher card
//    (`CatcherPalette` + `NoTargetModal` Cancel/Copy layout), and Oto's exact
//    420 ms `MorphCurve` reveal.
//  - Borrows Hex's core motion physics (`flight.rs` curved Bézier word flights
//    with damped harmonic landing nudges, `keyboard.rs` 14.5u ANSI Apple Magic
//    Keyboard geometry, and `typing.rs` SINK/RISE keystroke envelopes).
//  - Flat, gradient-free Light/Dark surfaces, mathematically centered H & V.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Top-level router

struct OnboardingChapterVisual: View {
    let step: OnboardingStage.Step
    let holdKind: ShortcutTrigger.Kind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: self.reduceMotion)) { timeline in
            let elapsed = self.reduceMotion
                ? self.staticShowcaseTime(for: self.step)
                : max(0, timeline.date.timeIntervalSince(self.startDate))
            self.scene(elapsed: elapsed)
                .id(self.step)
        }
        .onChange(of: self.step) { _, _ in
            self.startDate = Date()
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(elapsed: Double) -> some View {
        switch self.step {
        case .how:
            SpeakAndLandScene(elapsed: elapsed, holdKeyID: Self.keyboardKeyID(for: self.holdKind))
        case .catcher:
            CatcherScene(elapsed: elapsed)
        case .intelligence:
            CleanupScene(elapsed: elapsed)
        case .dictionary:
            DictionaryScene(elapsed: elapsed)
        case .handsFree:
            HandsFreeScene(elapsed: elapsed, holdKeyID: Self.keyboardKeyID(for: self.holdKind))
        case .welcome, .handoff:
            EmptyView()
        }
    }

    private func staticShowcaseTime(for step: OnboardingStage.Step) -> Double {
        switch step {
        case .how: 3.6
        case .catcher: 4.5
        case .intelligence: 4.6
        case .dictionary: 4.5
        case .handsFree: 4.4
        case .welcome, .handoff: 0
        }
    }

    static func keyboardKeyID(for kind: ShortcutTrigger.Kind) -> String {
        switch kind {
        case .modifierHold(let code):
            switch Int(code) {
            case kVK_Function: return "fn"
            case kVK_RightOption: return "option-right"
            case kVK_Option: return "option"
            case kVK_RightCommand: return "command-right"
            case kVK_Command: return "command"
            case kVK_RightShift: return "shift-right"
            case kVK_Shift: return "shift"
            case kVK_Control, kVK_RightControl: return "control"
            default: return "option-right"
            }
        case .functionKey:
            return "fn"
        case .combo, .unassigned:
            return "option-right"
        }
    }
}

// MARK: - Physics primitives (Hex flight.rs + typing.rs + Apple spring curves)

private enum OnboardingPhysics {
    static let handoff: Double = 0.11
    static let keySink: Double = 0.022
    static let keyRise: Double = 0.110

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp01((x - a) / max(1e-6, b - a))
        return t * t * (3 - 2 * t)
    }

    /// Strong Apple/Emil ease-out curve (snappy response, zero sluggishness).
    static func easeOutQuart(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp01((x - a) / max(1e-6, b - a))
        let inv = 1 - t
        return 1 - inv * inv * inv * inv
    }

    /// Smooth quintic ease-in-out for horizontal reflow / morphing.
    static func easeInOutCubic(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp01((x - a) / max(1e-6, b - a))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func seededRandom(_ seed: Int, _ a: Double, _ b: Double) -> Double {
        let s = sin(Double(seed) * 78.233 + 1.7) * 43_758.545
        let frac = abs(s - floor(s))
        return lerp(a, b, frac)
    }

    static func keyDepth(now: Double, down: Double, up: Double) -> Double {
        if now < down { return 0 }
        if now < down + keySink {
            return smoothstep(down, down + keySink, now)
        }
        if now <= up { return 1 }
        if now < up + keyRise {
            return 1 - smoothstep(up, up + keyRise, now)
        }
        return 0
    }

    static func ripple(now: Double, at: Double, duration: Double = 0.50) -> Double? {
        let age = now - at
        guard age >= 0, age <= duration else { return nil }
        return age / duration
    }

    /// Natural syllable-paced loudness level [0, 1] feeding `VisualizerMath.barScale`.
    static func speechLevel(at t: Double) -> Float {
        let a = max(0, sin(t * 7.2))
        let b = max(0, sin(t * 12.6 + 1.1))
        let c = max(0, sin(t * 3.9 + 0.4))
        return Float(clamp01(0.32 + 0.36 * a * c + 0.30 * b))
    }
}

/// Curved quadratic-Bézier word flight ported from Hex's `flight.rs`.
private struct WordFlight {
    let from: CGPoint
    let to: CGPoint
    let start: Double
    let intensity: Double
    let launchSize: CGFloat
    let landSize: CGFloat
    let bend: Double
    let duration: Double
    let back: Double

    struct Pose {
        let position: CGPoint
        let size: CGFloat
        let angleRadians: Double
        let alpha: Double
    }

    struct Landed {
        let fade: Double
        let nudge: CGSize
    }

    init(
        from: CGPoint,
        to: CGPoint,
        start: Double,
        intensity: Double = 0.24,
        landSize: CGFloat = 16,
        index: Int
    ) {
        let side: Double = index.isMultiple(of: 2) ? -1.0 : 1.0
        let origin = CGPoint(x: from.x, y: from.y + 1)
        let dist = hypot(Double(to.x - origin.x), Double(to.y - origin.y))
        self.from = origin
        self.to = to
        self.start = start
        self.intensity = intensity
        self.launchSize = CGFloat(OnboardingPhysics.lerp(13, 21, pow(intensity, 1.15)))
        self.landSize = landSize
        self.bend = side * OnboardingPhysics.lerp(0.08, 0.18, intensity)
            * OnboardingPhysics.seededRandom(index, 0.65, 1.0)
        let speed = OnboardingPhysics.lerp(720, 1650, intensity)
        self.duration = min(0.46, max(0.20, (dist / speed) * 1.12))
        self.back = cbrt(16.0 * OnboardingPhysics.lerp(1.2, 2.4, intensity) / (4.0 * max(dist, 60.0)))
    }

    var arrives: Double { self.start + self.duration }

    private func ease(_ u: Double) -> Double {
        let x1 = 1.0 - u
        return 1.0 - (self.back + 1.0) * x1 * x1 * x1 + self.back * x1 * x1
    }

    private func point(atAge age: Double) -> CGPoint {
        let u = OnboardingPhysics.clamp01(age / self.duration)
        let s = self.ease(u)
        let sx = Double(self.from.x), sy = Double(self.from.y)
        let gx = Double(self.to.x), gy = Double(self.to.y)
        let dx = gx - sx, dy = gy - sy
        let cx = sx + dx * 0.5 - dy * self.bend
        let cy = sy + dy * 0.5 + dx * self.bend
        let a = (1 - s) * (1 - s)
        let b = 2 * (1 - s) * s
        let c = s * s
        return CGPoint(x: a * sx + b * cx + c * gx, y: a * sy + b * cy + c * gy)
    }

    private func velocity(atAge age: Double) -> CGVector {
        let dt = 1.0 / 60.0
        if age < dt * 0.5 {
            let dx = Double(self.to.x - self.from.x)
            let dy = Double(self.to.y - self.from.y)
            let d = max(1e-3, hypot(dx, dy))
            return CGVector(dx: dx / d * 800, dy: dy / d * 800)
        }
        let p0 = self.point(atAge: age - dt)
        let p1 = self.point(atAge: age)
        return CGVector(dx: Double(p1.x - p0.x) / dt, dy: Double(p1.y - p0.y) / dt)
    }

    private var arrivalHeading: CGVector {
        let p0 = self.point(atAge: self.duration - 1.0 / 60.0)
        let dx = Double(self.to.x - p0.x)
        let dy = Double(self.to.y - p0.y)
        let d = max(1e-3, hypot(dx, dy))
        return CGVector(dx: dx / d, dy: dy / d)
    }

    func pose(at now: Double) -> Pose? {
        let age = now - self.start
        guard age >= 0, age <= self.duration + OnboardingPhysics.handoff else { return nil }
        let slotRatio = Double(self.landSize / self.launchSize)
        if age >= self.duration {
            let k = OnboardingPhysics.clamp01((age - self.duration) / OnboardingPhysics.handoff)
            return Pose(position: self.to, size: self.landSize, angleRadians: 0, alpha: 1 - k)
        }
        let u = age / self.duration
        let pt = self.point(atAge: age)
        let vel = self.velocity(atAge: age)
        let grow = min(1.0, age * 12.0)
        var ang = atan2(vel.dy, vel.dx)
        if ang > .pi / 2 { ang -= .pi }
        if ang < -.pi / 2 { ang += .pi }
        let e = OnboardingPhysics.smoothstep(0.15, 0.85, u)
        let size = Double(self.launchSize) * OnboardingPhysics.lerp(0.42, 1.0, grow)
            * OnboardingPhysics.lerp(1.0, slotRatio, e)
        return Pose(
            position: pt,
            size: CGFloat(size),
            angleRadians: OnboardingPhysics.lerp(ang * 0.18, 0.0, e),
            alpha: OnboardingPhysics.smoothstep(0.0, 0.08, u)
        )
    }

    func landed(at now: Double) -> Landed? {
        let since = now - self.arrives
        guard since >= 0 else { return nil }
        let fade = OnboardingPhysics.clamp01(since / OnboardingPhysics.handoff)
        let hz = 7.2
        let zeta = 0.62
        let w = 2.0 * .pi * hz
        let wd = w * sqrt(1.0 - zeta * zeta)
        let push = OnboardingPhysics.lerp(10.0, 18.0, self.intensity)
        let k = push * exp(-zeta * w * since) * sin(wd * since) / wd
        let h = self.arrivalHeading
        return Landed(fade: fade, nudge: CGSize(width: h.dx * k, height: h.dy * k))
    }
}

// MARK: - Word slot measurement

private struct MeasuredWord: Identifiable {
    let id: Int
    let text: String
    let rect: CGRect
}

private enum WordSlotLayout {
    static func measure(
        words: [String],
        fontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        origin: CGPoint,
        maxWidth: CGFloat,
        lineHeight: CGFloat
    ) -> [MeasuredWord] {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        var cursorX = origin.x
        var cursorY = origin.y
        var result: [MeasuredWord] = []
        for (i, word) in words.enumerated() {
            let sz = (word as NSString).size(withAttributes: [.font: font])
            if cursorX > origin.x && (cursorX - origin.x) + sz.width > maxWidth {
                cursorX = origin.x
                cursorY += lineHeight
            }
            let rect = CGRect(x: cursorX, y: cursorY, width: sz.width, height: sz.height)
            result.append(MeasuredWord(id: i, text: word, rect: rect))
            cursorX += sz.width + spaceWidth
        }
        return result
    }
}

// MARK: - Oto's Original Pill (exact VisualizerMath + PillColor liquid glass)

private struct OtoOriginalPill: View {
    let active: Bool
    let level: Float
    let elapsed: Double
    var scale: CGFloat = 1.08

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pillColor = PillColor.current()
        let palette = PillPalette(color: pillColor)
        let pillW = VisualizerMath.dictationWidth * self.scale
        let pillH = VisualizerMath.pillHeight * self.scale
        let barW = VisualizerMath.barWidth * self.scale
        let barPitch = VisualizerMath.barPitch * self.scale
        let barFullH = VisualizerMath.barFullHeight * self.scale
        let effectiveLevel: Float = self.active ? self.level : 0.0

        ZStack {
            // 1. Subtle density scrim (inset 1 pt, matching PillLayers)
            Capsule(style: .continuous)
                .fill(Color(cgColor: palette.scrim).opacity(self.reduceTransparency ? 0.92 : PillChrome.scrimAlpha))
                .padding(PillChrome.scrimInset)

            // 2. Authentic PillPalette axial body wash (tip -> waist -> tip)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        stops: palette.bodyStops.map { stop in
                            let c = stop.color.withAlphaComponent(
                                self.reduceTransparency ? 1.0 : stop.color.alphaComponent
                            )
                            return Gradient.Stop(color: Color(nsColor: c), location: stop.location)
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // 3. Curved-glass top & bottom rim sheen (zero stroked outline, matching PillChrome)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        stops: PillChrome.sheenStops.map { stop in
                            Gradient.Stop(color: Color(nsColor: stop.color), location: stop.location)
                        },
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 4. Exact 10-bar traveling parabolic wave (`VisualizerMath.barScale`)
            Canvas { ctx, size in
                let count = VisualizerMath.barCount
                let rowWidth = CGFloat(count - 1) * barPitch + barW
                let startX = (size.width - rowWidth) * 0.5
                let midY = size.height * 0.5
                for i in 0..<count {
                    let s: Float = self.reduceMotion
                        ? VisualizerMath.staticScale(index: i)
                        : VisualizerMath.barScale(index: i, level: effectiveLevel, time: self.elapsed)
                    let h = max(barW, barFullH * CGFloat(s))
                    let x = startX + CGFloat(i) * barPitch
                    let rect = CGRect(x: x, y: midY - h * 0.5, width: barW, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: barW * 0.5)
                    ctx.fill(path, with: .color(.white))
                }
            }
        }
        .frame(width: pillW, height: pillH)
        .clipShape(Capsule(style: .continuous))
        .glassEffect(.regular, in: .capsule)
        .shadow(color: Color.black.opacity(0.22), radius: 10, y: 4)
    }
}

// MARK: - Exact 14.5u ANSI Apple Magic Keyboard (ported from Hex's keyboard.rs)

private struct AppleMagicKeyboardView: View {
    let activeKeyID: String
    let pressDepth: Double
    let glowAmount: Double
    let ripples: [Double]
    var deckOpacity: Double = 1.0

    @Environment(\.colorScheme) private var colorScheme

    private struct Cap {
        let id: String
        let legend: String
        let units: CGFloat
        let cornerAlign: Bool
        init(_ id: String, _ legend: String? = nil, _ units: CGFloat = 1.0, corner: Bool = false) {
            self.id = id
            self.legend = legend ?? id
            self.units = units
            self.cornerAlign = corner
        }
    }

    private static let rows: [[Cap]] = [
        [
            Cap("`"), Cap("1"), Cap("2"), Cap("3"), Cap("4"), Cap("5"), Cap("6"),
            Cap("7"), Cap("8"), Cap("9"), Cap("0"), Cap("-"), Cap("="),
            Cap("delete", "delete", 1.5, corner: true),
        ],
        [
            Cap("tab", "tab", 1.5, corner: true),
            Cap("Q"), Cap("W"), Cap("E"), Cap("R"), Cap("T"), Cap("Y"),
            Cap("U"), Cap("I"), Cap("O"), Cap("P"), Cap("["), Cap("]"), Cap("\\"),
        ],
        [
            Cap("caps", "caps", 1.75, corner: true),
            Cap("A"), Cap("S"), Cap("D"), Cap("F"), Cap("G"), Cap("H"),
            Cap("J"), Cap("K"), Cap("L"), Cap(";"), Cap("'"),
            Cap("return", "return", 1.75, corner: true),
        ],
        [
            Cap("shift", "shift", 2.25, corner: true),
            Cap("Z"), Cap("X"), Cap("C"), Cap("V"), Cap("B"), Cap("N"), Cap("M"),
            Cap(","), Cap("."), Cap("/"),
            Cap("shift-right", "shift", 2.25, corner: true),
        ],
        [
            Cap("fn", "fn", 1.0, corner: true),
            Cap("control", "⌃", 1.0),
            Cap("option", "⌥", 1.0),
            Cap("command", "⌘", 1.25),
            Cap("space", "", 5.0),
            Cap("command-right", "⌘", 1.25),
            Cap("option-right", "⌥", 1.0),
            Cap("left", "←", 1.0),
            Cap("updown", "", 1.0),
            Cap("right", "→", 1.0),
        ],
    ]

    private struct Slot {
        let id: String
        let legend: String
        let rect: CGRect
        let cornerAlign: Bool
    }

    private static let deckW: CGFloat = 336
    private static let deckH: CGFloat = 122
    private static let wellInset: CGFloat = 5
    private static let keyInset: CGFloat = 7.5
    private static let gap: CGFloat = 2.6
    private static let rowGap: CGFloat = 2.6

    private static let slots: [Slot] = {
        let innerW = deckW - 2 * keyInset
        let innerH = deckH - 2 * keyInset
        let pitch = (innerW + gap) / 14.5
        let rowH = (innerH - 4 * rowGap) / 5.0
        var out: [Slot] = []
        for (r, rowCaps) in rows.enumerated() {
            let y = keyInset + CGFloat(r) * (rowH + rowGap)
            var uAcc: CGFloat = 0
            for cap in rowCaps {
                let x = keyInset + uAcc * pitch
                let w = cap.units * pitch - gap
                if cap.id == "updown" {
                    let split: CGFloat = 1.5
                    let hh = (rowH - split) * 0.5
                    out.append(Slot(id: "up", legend: "▲", rect: CGRect(x: x, y: y, width: w, height: hh), cornerAlign: false))
                    out.append(Slot(id: "down", legend: "▼", rect: CGRect(x: x, y: y + hh + split, width: w, height: hh), cornerAlign: false))
                } else {
                    out.append(Slot(id: cap.id, legend: cap.legend, rect: CGRect(x: x, y: y, width: w, height: rowH), cornerAlign: cap.cornerAlign))
                }
                uAcc += cap.units
            }
        }
        return out
    }()

    var body: some View {
        let isDark = self.colorScheme == .dark
        let deckFill = isDark ? Color(white: 0.155) : Color(white: 0.905)
        let wellFill = isDark ? Color(white: 0.105) : Color(white: 0.86)
        let capFill = isDark ? Color(white: 0.215) : Color.white
        let capEdge = isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
        let legendColor = isDark ? Color.white.opacity(0.42) : Color.black.opacity(0.38)
        let activeFill = isDark ? Color.white : Color(white: 0.10)
        let activeLegend = isDark ? Color.black : Color.white

        Canvas { ctx, size in
            let scale = min(size.width / Self.deckW, size.height / Self.deckH)
            let ox = (size.width - Self.deckW * scale) * 0.5
            let oy = (size.height - Self.deckH * scale) * 0.5
            ctx.translateBy(x: ox, y: oy)
            ctx.scaleBy(x: scale, y: scale)

            let deckRect = CGRect(x: 0, y: 0, width: Self.deckW, height: Self.deckH)
            let deckPath = Path(roundedRect: deckRect, cornerRadius: 11, style: .continuous)
            ctx.fill(deckPath, with: .color(deckFill))
            ctx.stroke(deckPath, with: .color(capEdge), lineWidth: 0.75)

            let wellRect = deckRect.insetBy(dx: Self.wellInset, dy: Self.wellInset)
            let wellPath = Path(roundedRect: wellRect, cornerRadius: 7.5, style: .continuous)
            ctx.fill(wellPath, with: .color(wellFill))

            var activeSlot: Slot?
            for slot in Self.slots {
                let isActive = slot.id == self.activeKeyID
                if isActive { activeSlot = slot }

                let depth = isActive ? CGFloat(self.pressDepth) : 0
                let travel = depth * 1.4
                let r = slot.rect.offsetBy(dx: 0, dy: travel)
                let radius: CGFloat = slot.rect.height < 14 ? 2.2 : 4.2

                if !isActive || depth < 0.85 {
                    let shadowRect = slot.rect.offsetBy(dx: 0, dy: 0.9)
                    let shadowPath = Path(roundedRect: shadowRect, cornerRadius: radius, style: .continuous)
                    ctx.fill(shadowPath, with: .color(Color.black.opacity(isDark ? 0.38 : 0.07)))
                }

                let capPath = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
                let lit = isActive && self.glowAmount > 0.15
                ctx.fill(capPath, with: .color(lit ? activeFill : capFill))
                ctx.stroke(
                    capPath,
                    with: .color(isActive ? OnboardingTheme.ink.opacity(0.32) : capEdge),
                    lineWidth: isActive ? 0.9 : 0.55
                )

                if !slot.legend.isEmpty {
                    let fontSize: CGFloat = slot.cornerAlign ? 5.5 : (slot.rect.height < 14 ? 4.8 : 7.4)
                    let weight: Font.Weight = isActive ? .semibold : .medium
                    let color = lit ? activeLegend : (isActive ? OnboardingTheme.ink : legendColor)
                    let resolved = ctx.resolve(
                        Text(slot.legend)
                            .font(.system(size: fontSize, weight: weight, design: .rounded))
                            .foregroundStyle(color)
                    )
                    ctx.draw(resolved, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
                }
            }

            if let activeSlot {
                for p in self.ripples {
                    let easeOut = 1 - pow(1 - p, 3)
                    let expand = 14.0 * easeOut
                    let rr = activeSlot.rect.insetBy(dx: -expand, dy: -expand)
                    let rp = Path(roundedRect: rr, cornerRadius: 5 + expand * 0.45, style: .continuous)
                    ctx.stroke(
                        rp,
                        with: .color(OnboardingTheme.ink.opacity(0.28 * (1 - p) * (1 - p))),
                        lineWidth: 1.15 * (1 - p * 0.5)
                    )
                }
            }
        }
        .opacity(self.deckOpacity)
    }
}

// MARK: - Clean flat Apple card chrome (zero gradients)

private struct FlatStageCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        let isDark = self.colorScheme == .dark
        self.content()
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .fill(isDark ? Color(white: 0.145) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .strokeBorder(OnboardingTheme.ink.opacity(isDark ? 0.10 : 0.07), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(isDark ? 0.28 : 0.055), radius: 14, y: 6)
    }
}

// MARK: - Chapter 1: Speak. It lands. (Centered H & V, original pill, curved flights)

private struct SpeakAndLandScene: View {
    let elapsed: Double
    let holdKeyID: String

    private static let loopDuration: Double = 6.2
    private static let words = ["Let’s", "ship", "the", "update", "on", "Friday."]
    private static let holdDown: Double = 0.45
    private static let holdUp: Double = 3.15
    private static let launchTimes: [Double] = [0.92, 1.28, 1.62, 1.94, 2.34, 2.68]

    var body: some View {
        let t = self.elapsed.truncatingRemainder(dividingBy: Self.loopDuration)
        let isHolding = t >= Self.holdDown && t <= Self.holdUp
        let depth = OnboardingPhysics.keyDepth(now: t, down: Self.holdDown, up: Self.holdUp)
        let speech = isHolding ? OnboardingPhysics.speechLevel(at: t) : 0
        let resetFade = t > 5.45 ? 1.0 - OnboardingPhysics.smoothstep(5.45, 6.0, t) : 1.0

        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            let cardW = min(312, w - 48)
            let cardH: CGFloat = 88
            let pillH: CGFloat = VisualizerMath.pillHeight * 1.08
            let kbW = min(324, w - 40)
            let kbH = kbW * (122.0 / 336.0)
            let gap1: CGFloat = 24
            let gap2: CGFloat = 24

            // Mathematically centered horizontally and vertically
            let totalH = cardH + gap1 + pillH + gap2 + kbH
            let topY = (h - totalH) * 0.5
            let cardOrigin = CGPoint(x: (w - cardW) * 0.5, y: topY)
            let pillCenter = CGPoint(x: w * 0.5, y: topY + cardH + gap1 + pillH * 0.5)
            let kbCenter = CGPoint(x: w * 0.5, y: topY + cardH + gap1 + pillH + gap2 + kbH * 0.5)

            let textOrigin = CGPoint(x: cardOrigin.x + 20, y: cardOrigin.y + (cardH - 22) * 0.5)
            let slots = WordSlotLayout.measure(
                words: Self.words,
                fontSize: 16,
                weight: .regular,
                origin: textOrigin,
                maxWidth: cardW - 40,
                lineHeight: 24
            )
            let flights: [WordFlight] = slots.enumerated().map { idx, slot in
                WordFlight(
                    from: pillCenter,
                    to: CGPoint(x: slot.rect.midX, y: slot.rect.midY),
                    start: Self.launchTimes[idx],
                    intensity: 0.25,
                    landSize: 16,
                    index: idx
                )
            }

            ZStack(alignment: .topLeading) {
                // Minimal flat document surface
                FlatStageCard(cornerRadius: 16) {
                    Color.clear.frame(width: cardW, height: cardH)
                }
                .position(x: w * 0.5, y: cardOrigin.y + cardH * 0.5)

                // Landed words with damped spring nudge
                ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                    if let landed = flights[idx].landed(at: t) {
                        Text(slot.text)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(OnboardingTheme.ink)
                            .opacity(landed.fade * resetFade)
                            .offset(landed.nudge)
                            .position(x: slot.rect.midX, y: slot.rect.midY)
                    }
                }

                // Subtle blinking caret
                let caretPos: CGPoint = {
                    if let lastIdx = flights.lastIndex(where: { $0.landed(at: t) != nil }) {
                        let r = slots[lastIdx].rect
                        return CGPoint(x: r.maxX + 2.5, y: r.midY)
                    }
                    return CGPoint(x: textOrigin.x + 1, y: textOrigin.y + 10)
                }()
                let caretAlpha = (sin(t * .pi * 2.1) > -0.15 ? 0.85 : 0.12) * resetFade
                RoundedRectangle(cornerRadius: 1)
                    .fill(OnboardingTheme.ink.opacity(caretAlpha))
                    .frame(width: 1.6, height: 18)
                    .position(caretPos)

                // Original Oto pill (VisualizerMath + PillPalette liquid glass)
                OtoOriginalPill(active: isHolding, level: speech, elapsed: t)
                    .scaleEffect(isHolding ? 1.0 : 0.96)
                    .opacity(isHolding ? 1.0 : 0.55)
                    .position(pillCenter)

                // Curved flying words from pill into document
                ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                    if let pose = flights[idx].pose(at: t) {
                        Text(slot.text)
                            .font(.system(size: pose.size, weight: .medium))
                            .foregroundStyle(OnboardingTheme.ink)
                            .rotationEffect(.radians(pose.angleRadians))
                            .opacity(pose.alpha)
                            .position(pose.position)
                    }
                }

                // 14.5u ANSI Apple Magic Keyboard
                AppleMagicKeyboardView(
                    activeKeyID: self.holdKeyID,
                    pressDepth: depth,
                    glowAmount: depth,
                    ripples: OnboardingPhysics.ripple(now: t, at: Self.holdDown).map { [$0] } ?? []
                )
                .frame(width: kbW, height: kbH)
                .position(kbCenter)
            }
        }
    }
}

// MARK: - Chapter 2: Nowhere to paste? (Real Oto Catcher + exact MorphCurve reveal)

private struct CatcherScene: View {
    let elapsed: Double
    @Environment(\.colorScheme) private var colorScheme

    private static let loopDuration: Double = 6.6
    private static let transcript = "Send the notes right after lunch."

    var body: some View {
        let t = self.elapsed.truncatingRemainder(dividingBy: Self.loopDuration)
        // 0.00–1.75: original Oto pill recording on a clean empty surface
        // 1.75–2.17: exact 420 ms `MorphCurve.value(at:)` pill -> real Catcher card reveal
        // 1.85–2.03: card content fades in 100 ms into the morph over 180 ms (exact NoTargetModal timing)
        // 4.15–4.28: Copy pill depresses -> flips to "Copied"
        // 5.95–6.50: clean fade back to start
        let morphStart = 1.75
        let morphDuration = NoTargetModalController.morphDuration // 0.42 s
        let morphT = OnboardingPhysics.clamp01((t - morphStart) / morphDuration)
        let morph = MorphCurve.value(at: morphT)

        let isSpeaking = t < morphStart + 0.04
        let speech = isSpeaking ? OnboardingPhysics.speechLevel(at: t) : 0
        let contentFade = OnboardingPhysics.easeOutQuart(
            morphStart + NoTargetModalController.contentFadeDelay,
            morphStart + NoTargetModalController.contentFadeDelay + NoTargetModalController.contentFadeDuration,
            t
        )
        let copied = t >= 4.26
        let copyPress = OnboardingPhysics.keyDepth(now: t, down: 4.14, up: 4.26)
        let resetFade = t > 5.95 ? 1.0 - OnboardingPhysics.smoothstep(5.95, 6.50, t) : 1.0
        let palette = CatcherPalette.current(self.colorScheme)

        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            let cardW = min(312, w - 48)
            let cardH: CGFloat = 144
            let pillScale: CGFloat = 1.08
            let pillW = VisualizerMath.dictationWidth * pillScale
            let pillH = VisualizerMath.pillHeight * pillScale

            // Real MorphGeometry: bottom edge anchored in place, card grows upward out of the pill!
            let currentW = pillW + (cardW - pillW) * CGFloat(morph)
            let currentH = pillH + (cardH - pillH) * CGFloat(morph)
            let currentR = MorphGeometry.radius(
                pillHeight: pillH,
                cardRadius: NoTargetModalController.cornerRadius,
                progress: morph
            )
            // Anchor bottom edge so the settled card sits dead-center vertically
            let settledBottomY = (h + cardH) * 0.5
            let currentCenterY = settledBottomY - currentH * 0.5
            let pillCenterY = settledBottomY - pillH * 0.5

            ZStack {
                // 1. Original Oto pill melting smoothly as the catcher reveals in place
                if morph < 0.72 {
                    let pillAlpha = 1.0 - OnboardingPhysics.smoothstep(0.02, 0.45, morphT)
                    OtoOriginalPill(active: isSpeaking, level: speech, elapsed: t, scale: pillScale)
                        .opacity(pillAlpha * resetFade)
                        .position(x: w * 0.5, y: pillCenterY)
                }

                // 2. Real Catcher surface (`CatcherPalette` + `NoTargetModalView` layout)
                if morph > 0.01 {
                    let surfaceAlpha = OnboardingPhysics.smoothstep(0.0, 0.14, morphT) * resetFade
                    ZStack {
                        RoundedRectangle(cornerRadius: currentR, style: .continuous)
                            .fill(palette.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: currentR, style: .continuous)
                                    .strokeBorder(
                                        palette.ink.opacity(self.colorScheme == .dark ? 0.10 : 0.07),
                                        lineWidth: 0.75
                                    )
                            )
                            .shadow(
                                color: Color.black.opacity(palette.shadowOpacity * 0.35),
                                radius: 18,
                                y: 8
                            )

                        // Real NoTargetModalView content laid out at final size, masked by the growing card
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.transcript)
                                .font(.system(size: 16.5, weight: .regular))
                                .foregroundStyle(palette.transcript)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)

                            HStack(spacing: 8) {
                                Spacer()
                                // Ghost Cancel pill (matching real NoTargetModalView)
                                Text("Cancel")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(palette.ink.opacity(0.72))
                                    .padding(.horizontal, 13)
                                    .frame(height: 28)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(palette.ink.opacity(self.colorScheme == .dark ? 0.10 : 0.06))
                                    )

                                // Filled Copy / Copied pill (matching real NoTargetModalView)
                                Text(copied ? "Copied" : "Copy")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(self.colorScheme == .dark ? Color.black : Color.white)
                                    .padding(.horizontal, 14)
                                    .frame(height: 28)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(palette.ink)
                                    )
                                    .scaleEffect(1.0 - 0.06 * copyPress)
                            }
                        }
                        .padding(CatcherLayout.cardPadding)
                        .frame(width: cardW, height: cardH)
                        .opacity(contentFade)
                    }
                    .frame(width: currentW, height: currentH)
                    .clipShape(RoundedRectangle(cornerRadius: currentR, style: .continuous))
                    .opacity(surfaceAlpha)
                    .position(x: w * 0.5, y: currentCenterY)
                }
            }
        }
    }
}

// MARK: - Chapter 3: Cleaned up as you speak (Left-aligned, zero clutter, no underline, no pill)

private struct CleanupScene: View {
    let elapsed: Double

    private struct Token {
        let raw: String
        let clean: String?
        let isFiller: Bool
    }

    private static let loopDuration: Double = 6.4
    private static let tokens: [Token] = [
        Token(raw: "Um,", clean: nil, isFiller: true),
        Token(raw: "so", clean: nil, isFiller: true),
        Token(raw: "we", clean: "We", isFiller: false),
        Token(raw: "should", clean: "should", isFiller: false),
        Token(raw: "like,", clean: nil, isFiller: true),
        Token(raw: "ship", clean: "ship", isFiller: false),
        Token(raw: "it", clean: "it", isFiller: false),
        Token(raw: "Friday.", clean: "Friday.", isFiller: false),
    ]

    var body: some View {
        let t = self.elapsed.truncatingRemainder(dividingBy: Self.loopDuration)
        // 0.25–1.35: spoken words appear flush-left
        // 2.00–2.45: fillers soften & dissolve out cleanly (no harsh strikethrough, no underline)
        // 2.40–3.15: kept words smoothly glide LEFT to flush-left alignment, "we" -> "We"
        // 5.65–6.25: gentle fade out before loop
        let fillerFade = 1.0 - OnboardingPhysics.smoothstep(2.05, 2.55, t)
        let collapse = OnboardingPhysics.easeInOutCubic(2.40, 3.15, t)
        let resetFade = t > 5.65 ? 1.0 - OnboardingPhysics.smoothstep(5.65, 6.25, t) : 1.0

        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let cardW = min(332, w - 44)
            let cardH: CGFloat = 104
            let cardCenter = CGPoint(x: w * 0.5, y: h * 0.5)
            let leftEdge = cardCenter.x - cardW * 0.5 + 22

            let font = NSFont.systemFont(ofSize: 16.5, weight: .regular)
            let spaceW = (" " as NSString).size(withAttributes: [.font: font]).width
            let rawWidths: [CGFloat] = Self.tokens.map {
                ($0.raw as NSString).size(withAttributes: [.font: font]).width
            }

            // Both raw and cleaned lines are flush-left aligned at `leftEdge`
            let positions: [(rawX: CGFloat, cleanX: CGFloat)] = {
                var rX = leftEdge
                var cX = leftEdge
                var out: [(CGFloat, CGFloat)] = []
                for (i, tok) in Self.tokens.enumerated() {
                    let rw = rawWidths[i]
                    let rawCenter = rX + rw * 0.5
                    rX += rw + spaceW
                    if tok.isFiller {
                        out.append((rawCenter, rawCenter))
                    } else {
                        let cw = ((tok.clean ?? tok.raw) as NSString).size(withAttributes: [.font: font]).width
                        let cleanCenter = cX + cw * 0.5
                        cX += cw + spaceW
                        out.append((rawCenter, cleanCenter))
                    }
                }
                return out
            }()

            ZStack {
                FlatStageCard(cornerRadius: 16) {
                    Color.clear.frame(width: cardW, height: cardH)
                }
                .position(cardCenter)

                ForEach(Array(Self.tokens.enumerated()), id: \.offset) { idx, tok in
                    let arrive = OnboardingPhysics.easeOutQuart(
                        0.25 + Double(idx) * 0.09,
                        0.50 + Double(idx) * 0.09,
                        t
                    )
                    let pos = positions[idx]
                    let displayText = (collapse > 0.50 && tok.clean != nil) ? tok.clean! : tok.raw
                    let x = tok.isFiller
                        ? pos.rawX
                        : CGFloat(OnboardingPhysics.lerp(Double(pos.rawX), Double(pos.cleanX), collapse))
                    let alpha = arrive * (tok.isFiller ? fillerFade : 1.0) * resetFade
                    let scale = tok.isFiller ? (0.86 + 0.14 * fillerFade) : 1.0

                    Text(displayText)
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundStyle(tok.isFiller ? OnboardingTheme.muted : OnboardingTheme.ink)
                        .scaleEffect(scale)
                        .opacity(alpha)
                        .offset(y: CGFloat((1 - arrive) * 4))
                        .position(x: x, y: cardCenter.y)
                }
            }
        }
    }
}

// MARK: - Chapter 4: Your words, spelled right (Clean Dictionary match + snap)

private struct DictionaryScene: View {
    let elapsed: Double

    private static let loopDuration: Double = 6.4
    private static let terms = ["PostgreSQL", "Kubernetes", "TypeScript", "SwiftUI"]

    var body: some View {
        let t = self.elapsed.truncatingRemainder(dividingBy: Self.loopDuration)
        let appear = OnboardingPhysics.easeOutQuart(0.30, 0.72, t)
        let matchPulse = OnboardingPhysics.smoothstep(2.05, 2.50, t) * (1.0 - OnboardingPhysics.smoothstep(4.7, 5.3, t))
        let snap = OnboardingPhysics.easeInOutCubic(2.65, 3.10, t)
        let resetFade = t > 5.75 ? 1.0 - OnboardingPhysics.smoothstep(5.75, 6.30, t) : 1.0

        let nudgeY: CGFloat = {
            let since = t - 2.88
            guard since >= 0, since < 0.65 else { return 0 }
            let w = 2.0 * .pi * 6.8
            let zeta = 0.60
            let wd = w * sqrt(1 - zeta * zeta)
            return CGFloat(-13.0 * exp(-zeta * w * since) * sin(wd * since) / wd)
        }()

        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let cardW = min(312, w - 48)

            VStack(spacing: 14) {
                // Clean Dictionary list card
                FlatStageCard(cornerRadius: 16) {
                    VStack(spacing: 2) {
                        ForEach(Self.terms, id: \.self) { term in
                            let isMatched = term == "Kubernetes"
                            let highlight = isMatched ? matchPulse : 0
                            HStack {
                                Text(term)
                                    .font(.system(size: 14, weight: isMatched && highlight > 0.3 ? .semibold : .regular))
                                    .foregroundStyle(OnboardingTheme.ink)
                                Spacer()
                                if isMatched && highlight > 0.2 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(OnboardingTheme.ink)
                                        .opacity(highlight)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(OnboardingTheme.ink.opacity(0.065 * highlight))
                            )
                        }
                    }
                    .padding(8)
                    .frame(width: cardW)
                }

                // Flush-left live transcription line snapping to exact spelling
                let rawTermW = ("cooper netties" as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: 15.5, weight: .regular)]).width
                let cleanTermW = ("Kubernetes" as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: 15.5, weight: .medium)]).width
                let animatedTermW = CGFloat(OnboardingPhysics.lerp(Double(rawTermW), Double(cleanTermW), snap))

                FlatStageCard(cornerRadius: 16) {
                    HStack(spacing: 5) {
                        Text("Deploy to")
                            .font(.system(size: 15.5))
                            .foregroundStyle(OnboardingTheme.ink)
                            .fixedSize()

                        ZStack(alignment: .leading) {
                            Text("cooper netties")
                                .font(.system(size: 15.5))
                                .foregroundStyle(OnboardingTheme.muted)
                                .fixedSize()
                                .opacity(1 - snap)
                                .offset(y: CGFloat(-5 * snap))

                            Text("Kubernetes")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(OnboardingTheme.ink)
                                .fixedSize()
                                .opacity(snap)
                                .offset(y: CGFloat(5 * (1 - snap)) + nudgeY)
                        }
                        .frame(width: animatedTermW, alignment: .leading)

                        Text("tonight.")
                            .font(.system(size: 15.5))
                            .foregroundStyle(OnboardingTheme.ink)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(width: cardW, height: 54)
                    .opacity(appear * resetFade)
                }
            }
            .position(x: w * 0.5, y: h * 0.5)
        }
    }
}

// MARK: - Chapter 5: Double-tap, keep talking (Centered H & V, original pill, double-tap -> hands off -> single tap)

private struct HandsFreeScene: View {
    let elapsed: Double
    let holdKeyID: String

    private static let loopDuration: Double = 7.4
    private static let words = ["Draft", "the", "launch", "notes", "and", "send", "them", "before", "noon."]
    private static let tap1Down: Double = 0.45
    private static let tap1Up: Double = 0.56
    private static let tap2Down: Double = 0.72
    private static let tap2Up: Double = 0.83
    private static let stopDown: Double = 5.75
    private static let stopUp: Double = 5.87

    var body: some View {
        let t = self.elapsed.truncatingRemainder(dividingBy: Self.loopDuration)
        let d1 = OnboardingPhysics.keyDepth(now: t, down: Self.tap1Down, up: Self.tap1Up)
        let d2 = OnboardingPhysics.keyDepth(now: t, down: Self.tap2Down, up: Self.tap2Up)
        let d3 = OnboardingPhysics.keyDepth(now: t, down: Self.stopDown, up: Self.stopUp)
        let depth = max(d1, max(d2, d3))
        let isHandsFree = t >= Self.tap2Up && t < Self.stopDown
        let speech = isHandsFree ? OnboardingPhysics.speechLevel(at: t) : 0
        let resetFade = t > 6.65 ? 1.0 - OnboardingPhysics.smoothstep(6.65, 7.20, t) : 1.0

        let handsOffRecede = OnboardingPhysics.smoothstep(1.05, 1.55, t)
            * (1.0 - OnboardingPhysics.smoothstep(5.35, 5.70, t))
        let deckOpacity = 1.0 - 0.50 * handsOffRecede

        let ripples = [Self.tap1Down, Self.tap2Down, Self.stopDown].compactMap {
            OnboardingPhysics.ripple(now: t, at: $0, duration: 0.48)
        }

        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            let cardW = min(312, w - 48)
            let cardH: CGFloat = 88
            let pillH: CGFloat = VisualizerMath.pillHeight * 1.08
            let kbW = min(324, w - 40)
            let kbH = kbW * (122.0 / 336.0)
            let gap1: CGFloat = 24
            let gap2: CGFloat = 24

            // Centered horizontally & vertically
            let totalH = cardH + gap1 + pillH + gap2 + kbH
            let topY = (h - totalH) * 0.5
            let cardOrigin = CGPoint(x: (w - cardW) * 0.5, y: topY)
            let pillCenter = CGPoint(x: w * 0.5, y: topY + cardH + gap1 + pillH * 0.5)
            let kbCenter = CGPoint(x: w * 0.5, y: topY + cardH + gap1 + pillH + gap2 + kbH * 0.5)

            let textOrigin = CGPoint(x: cardOrigin.x + 20, y: cardOrigin.y + 20)
            let slots = WordSlotLayout.measure(
                words: Self.words,
                fontSize: 15.5,
                weight: .regular,
                origin: textOrigin,
                maxWidth: cardW - 40,
                lineHeight: 24
            )
            let flights: [WordFlight] = slots.enumerated().map { idx, slot in
                WordFlight(
                    from: pillCenter,
                    to: CGPoint(x: slot.rect.midX, y: slot.rect.midY),
                    start: 1.12 + Double(idx) * 0.44,
                    intensity: 0.22,
                    landSize: 15.5,
                    index: idx
                )
            }

            ZStack(alignment: .topLeading) {
                FlatStageCard(cornerRadius: 16) {
                    Color.clear.frame(width: cardW, height: cardH)
                }
                .position(x: w * 0.5, y: cardOrigin.y + cardH * 0.5)

                ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                    if let landed = flights[idx].landed(at: t) {
                        Text(slot.text)
                            .font(.system(size: 15.5, weight: .regular))
                            .foregroundStyle(OnboardingTheme.ink)
                            .opacity(landed.fade * resetFade)
                            .offset(landed.nudge)
                            .position(x: slot.rect.midX, y: slot.rect.midY)
                    }
                }

                // Pure original Oto pill (identical to FlowBar)
                OtoOriginalPill(active: isHandsFree, level: speech, elapsed: t)
                    .scaleEffect(isHandsFree ? 1.0 : 0.96)
                    .opacity(isHandsFree ? 1.0 : 0.50)
                    .position(pillCenter)

                ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                    if let pose = flights[idx].pose(at: t) {
                        Text(slot.text)
                            .font(.system(size: pose.size, weight: .medium))
                            .foregroundStyle(OnboardingTheme.ink)
                            .rotationEffect(.radians(pose.angleRadians))
                            .opacity(pose.alpha)
                            .position(pose.position)
                    }
                }

                AppleMagicKeyboardView(
                    activeKeyID: self.holdKeyID,
                    pressDepth: depth,
                    glowAmount: isHandsFree ? 0.0 : depth,
                    ripples: ripples,
                    deckOpacity: deckOpacity
                )
                .frame(width: kbW, height: kbH)
                .position(kbCenter)
            }
        }
    }
}
