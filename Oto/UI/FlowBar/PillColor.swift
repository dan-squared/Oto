//
//  PillColor.swift
//  Oto
//
//  The pill's colour, and the ramp it drives. One choice, one persisted key,
//  one recipe: a capsule's body is the chosen hue at its waist, lightened
//  toward white at the two tips, and every pill colour is built by the same
//  five stops so the look can never drift between hues.
//
//  Default is graphite — black glass. Chromatic pills are opt-in (user ask,
//  2026-11-01: "make the default black... a colour palette they can choose
//  in the settings").
//
//  Why an enum and not a free colour picker: the ramp is derived from the
//  waist hue, and a free picker would happily produce a pill whose white
//  bars vanish (a pale yellow waist) or whose tips read neon. A fixed,
//  measured palette keeps the contrast promise for every choice, and a
//  palette of five is a one-row control in Settings, not a colour wheel.
//
//  Palette (2026-11-01, after the user's review): graphite, crimson, pink,
//  violet, ocean. Green and amber were cut at the user's request; the blue
//  was re-hued to their reference glass button (hue 197°) and pink added.
//

import AppKit

/// The pill's body colour. Raw values are the persisted strings — never
/// rename them.
enum PillColor: String, CaseIterable, Identifiable, Sendable, Hashable {
    /// Near-black smoked glass. The default.
    case graphite
    case crimson
    /// Soft pink (user ask, 2026-11-01).
    case pink
    case violet
    /// The reference's sky blue (user-supplied glass button, 2026-11-01).
    case ocean

    nonisolated var id: String { rawValue }

    nonisolated static let defaultsKey = "app.Oto.pillColor"

    /// Fresh-install colour: graphite, i.e. black glass (user ask,
    /// 2026-11-01). Single source of truth for BOTH readers — `current()`
    /// and the Settings picker's default — so they cannot disagree.
    nonisolated static let freshDefault: PillColor = .graphite

    /// Missing key or an unknown raw value falls back to `freshDefault`
    /// (FlowBarPosition precedent: a stale stored string never wedges the
    /// pill on a colour that no longer exists).
    nonisolated static func current(defaults: UserDefaults = .standard) -> PillColor {
        guard let raw = defaults.object(forKey: defaultsKey) as? String else { return .freshDefault }
        return PillColor(rawValue: raw) ?? .freshDefault
    }

    nonisolated static func save(_ color: PillColor, defaults: UserDefaults = .standard) {
        defaults.set(color.rawValue, forKey: defaultsKey)
    }

    /// Settings label. Also the picker's tooltip and AX label.
    nonisolated var displayName: String {
        switch self {
        case .graphite: "Graphite"
        case .crimson: "Crimson"
        case .pink: "Pink"
        case .violet: "Violet"
        case .ocean: "Ocean"
        }
    }

    /// The waist colour — the deepest, most saturated pixel of the body.
    /// Hues are picked at comparable luminance (0.10–0.21 relative) so the
    /// white bars keep the same weight in every pill: crimson 5.2 : 1,
    /// pink 4.0 : 1, ocean 4.0 : 1, violet 7.0 : 1 against white (sRGB,
    /// computed from these literals — see plan/pill-color-palette.md).
    nonisolated var base: NSColor {
        switch self {
        case .graphite: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        case .crimson: NSColor(srgbRed: 0.85, green: 0.07, blue: 0.13, alpha: 1)
        // Hue 337°, soft rose — not a hot magenta: the pill still has to
        // read as glass, not as a notification badge.
        case .pink: NSColor(srgbRed: 0.86, green: 0.28, blue: 0.50, alpha: 1)
        case .violet: NSColor(srgbRed: 0.42, green: 0.16, blue: 0.88, alpha: 1)
        // Hue 199°, the user's reference at 197° (its own waist is 0.22 /
        // 0.77 / 0.99, luminance 0.47 — white bars would vanish on it, so
        // the waist keeps the hue and drops the lightness; the frost tint
        // below is the reference colour nearly verbatim).
        case .ocean: NSColor(srgbRed: 0.06, green: 0.53, blue: 0.74, alpha: 1)
        }
    }

    /// How far the tips are lightened toward white. Chromatic pills get pale,
    /// light-catching caps (the reference's structure). Graphite gets almost
    /// none: lightening black at 80 % produces a silver capsule, which is not
    /// "black glass" — its shape has to come from the sheen instead.
    nonisolated var tipDepth: CGFloat {
        switch self {
        case .graphite: 0.22
        case .crimson: 0.80
        case .pink: 0.76
        case .violet: 0.72
        case .ocean: 0.80
        }
    }

    /// The frost tint. Nil for graphite: the system material, untinted, is
    /// the most convincing black glass — and it adapts to the wallpaper
    /// instead of forcing a colour through the blur.
    nonisolated var tint: NSColor? {
        switch self {
        case .graphite: nil
        case .crimson: NSColor(srgbRed: 0.95, green: 0.10, blue: 0.15, alpha: 1)
        case .pink: NSColor(srgbRed: 0.98, green: 0.46, blue: 0.66, alpha: 1)
        case .violet: NSColor(srgbRed: 0.52, green: 0.24, blue: 0.98, alpha: 1)
        // Sampled from the user's reference button (57, 196, 253).
        case .ocean: NSColor(srgbRed: 0.10, green: 0.66, blue: 0.98, alpha: 1)
        }
    }

    /// Swatch for Settings — the waist colour as it reads on the pill, not
    /// the raw base: a graphite chip drawn at 0.10 white would be invisible
    /// on a dark card.
    nonisolated var swatch: NSColor {
        let palette = PillPalette(color: self)
        let waist = palette.bodyStops[4].color.usingColorSpace(.sRGB) ?? base
        return waist.withAlphaComponent(1)
    }
}

/// One colour's whole glass recipe. Five stops, symmetric by construction
/// (mirrored author values, never a reflected gradient), so the two caps can
/// never drift apart.
///
/// Every stop is deliberately translucent: the frosted glass behind it is the
/// material, the ramp is only the wash on top. Under Reduce Transparency the
/// frost is gone, so `bodyColors(opaque: true)` drops every stop to alpha 1
/// and the fallback is *flat colour glass*, never grey.
/// `nonisolated` so `PillColor.swatch` and the tests can build a palette off
/// the main actor; the value is immutable after `init`.
nonisolated struct PillPalette {
    /// Alphas, tip → waist. Shared by every colour: density is a property of
    /// the pill, hue is the property the user picks.
    nonisolated static let tipAlpha: CGFloat = 0.16
    nonisolated static let softAlpha: CGFloat = 0.34
    nonisolated static let midAlpha: CGFloat = 0.52
    nonisolated static let deepAlpha: CGFloat = 0.66
    nonisolated static let waistAlpha: CGFloat = 0.74

    /// Stop positions along the capsule's long axis.
    nonisolated static let stops: [CGFloat] = [0.00, 0.06, 0.20, 0.42, 0.50, 0.58, 0.80, 0.94, 1.00]

    /// How far white is mixed into the tip stops, per `PillColor.tipDepth`:
    /// the authored ramp for red is reproduced to within a couple of points
    /// (1.00/0.80/0.83 → 0.97/0.81/0.83), so the palette is a generalisation
    /// of the colour the pill already shipped, not a new look.
    nonisolated private static let depthRamp: [CGFloat] = [1.00, 0.78, 0.50, 0.12, 0.00]
    nonisolated private static let alphaRamp: [CGFloat] = [tipAlpha, softAlpha, midAlpha, deepAlpha, waistAlpha]

    let color: PillColor
    /// Tip → waist → tip, 9 stops (the 5 authored values mirrored).
    let bodyStops: [(location: CGFloat, color: NSColor)]
    /// The veil under the ramp.
    let scrim: CGColor
    /// The frost tint, or nil (graphite).
    let tint: NSColor?

    init(color: PillColor) {
        self.color = color
        let base = color.base
        var authored: [NSColor] = []
        for (depth, alpha) in zip(Self.depthRamp, Self.alphaRamp) {
            let lifted = Self.mix(base, toward: .white, by: color.tipDepth * depth)
            authored.append(lifted.withAlphaComponent(alpha))
        }
        // Mirror for the right half: waist in the middle, tips at both ends.
        let order = [0, 1, 2, 3, 4, 3, 2, 1, 0]
        self.bodyStops = zip(Self.stops, order).map { ($0.0, authored[$0.1]) }
        // The veil is red-density for chromatic pills and neutral for
        // graphite: it may darken the body but never grey it.
        self.scrim = Self.mix(base, toward: .black, by: 0.45).cgColor
        self.tint = color.tint
    }

    nonisolated var bodyLocations: [NSNumber] {
        bodyStops.map { NSNumber(value: Double($0.location)) }
    }

    /// `opaque` is the Reduce Transparency case: the frost is hidden, so the
    /// ramp alone has to carry the colour.
    nonisolated func bodyColors(opaque: Bool) -> [CGColor] {
        bodyStops.map {
            $0.color.withAlphaComponent(opaque ? 1 : $0.color.alphaComponent).cgColor
        }
    }

    // MARK: - Colour math

    /// Mix `color` toward `target` by `amount` (0 = untouched, 1 = target),
    /// in sRGB. Deliberately linear-in-bytes, not perceptual: the stops it
    /// produces are the ones the device already showed (see depthRamp).
    nonisolated static func mix(_ color: NSColor, toward target: NSColor, by amount: CGFloat) -> NSColor {
        let a = color.usingColorSpace(.sRGB) ?? color
        let b = target.usingColorSpace(.sRGB) ?? target
        let t = min(1, max(0, amount))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        )
    }
}
