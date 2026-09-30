//
//  OtoControls.swift
//  Oto
//
//  The control kit, cloned pixel-for-pixel from the reference's pieces:
//  Big (primary capsule), Pill (outline capsule), OtoSwitch (ink toggle),
//  OtoSegmented (sliding thumb), OtoDoor (26px square), OtoKey (keycap),
//  OtoHunt (search field), OtoQuick (mini action). All plain-button-style,
//  all hover-aware, all palette-driven.
//

import SwiftUI

/// The primary capsule: filled ink when it is the thing you came to press.
struct OtoBig: View {
    let title: String
    var filled = true
    let act: () -> Void
    @State private var hovering = false

    init(_ title: String, filled: Bool = true, act: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(filled ? OtoPalette.ground : OtoPalette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(filled ? OtoPalette.ink : (hovering ? OtoPalette.hover : OtoPalette.wash), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(OtoBounce())
        .onHover { hovering = $0 }
    }
}

/// A small capsule that does one thing. Outlined; filled ink when primary.
/// `large` is the catcher footer size only — everything else stays compact.
struct OtoPill: View {
    let title: String
    var filled = false
    var tint: Color = OtoPalette.ink
    var large = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = OtoPalette.ink, large: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.large = large
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: large ? 13 : 11.5))
                .foregroundStyle(filled ? OtoPalette.ground : tint)
                .padding(.horizontal, large ? 14 : 10)
                .padding(.vertical, large ? 8 : 5)
                .background(filled ? OtoPalette.ink : (hovering ? OtoPalette.hover : OtoPalette.ground), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(filled ? .clear : OtoPalette.hairline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(OtoBounce())
        .onHover { hovering = $0 }
        .animation(OtoMotion.quick, value: hovering)
    }
}

/// On or off, in ink rather than in blue. 30×18.
struct OtoSwitch: View {
    @Binding var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? OtoPalette.ink : OtoPalette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(OtoPalette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(OtoMotion.settle) { on.toggle() } }
            .animation(OtoMotion.settle, value: on)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "On" : "Off")
    }
}

/// Options in a wash track; the ground thumb slides to the chosen one.
struct OtoSegmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? OtoPalette.ink : OtoPalette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(OtoPalette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(OtoMotion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(OtoMotion.settle, value: selection)
    }
}

/// A small square holding one icon. The panel cross, lit when open.
struct OtoDoor: View {
    let systemName: String
    var on = false
    /// Keeps a wash plate under the icon at rest. Off for the panel cross
    /// (it floats on the card); on for a toolbar control, where a bare
    /// transparent glyph reads as a smudge rather than a button.
    var showsPlate = false
    var help = ""
    let act: () -> Void
    @State private var hovering = false

    /// Square edge. The toolbar compresses anything that does not declare
    /// one, which is what made this control render thin.
    nonisolated static let side: CGFloat = 28

    var body: some View {
        Button(action: act) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? OtoPalette.ink : (hovering ? OtoPalette.ink.opacity(0.7) : OtoPalette.muted))
                .frame(width: Self.side, height: Self.side)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(plateFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(OtoBounce())
        // Belt and braces with the inner frame: the toolbar gets the
        // button's ideal size, not whatever space it thinks it has.
        .frame(width: Self.side, height: Self.side)
        .onHover { hovering = $0 }
        .help(help)
        .animation(OtoMotion.quick, value: hovering)
        .animation(OtoMotion.quick, value: on)
    }

    private var plateFill: Color {
        if on { return OtoPalette.wash }
        if hovering { return OtoPalette.hover }
        return showsPlate ? OtoPalette.wash.opacity(0.7) : .clear
    }
}

/// A keycap chip: shortcut glyphs on wash, rounded-6, 44pt minimum.
struct OtoKey: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(OtoPalette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(minWidth: 44)
    }
}

/// The field for narrowing a list. Wash, glass, clear cross.
struct OtoHunt: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OtoPalette.muted)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).foregroundStyle(OtoPalette.muted.opacity(0.7))
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(OtoPalette.ink)
                    .focused(focus)
            }
            .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OtoPalette.faint)
                }
                .buttonStyle(OtoBounce())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Press physics for every plain button: a small spring squish on click
/// that reads as bounce, never a resize on hover. A `ButtonStyle` — not a
/// DragGesture modifier — so `configuration.isPressed` is the documented
/// press signal and it also fires for keyboard activation, which a drag
/// gesture misses. Deliberately NOT a `PrimitiveButtonStyle`: that
/// configuration type has `role`/`label`/`trigger()` and no `isPressed`
/// (SDK: PrimitiveButtonStyleConfiguration vs ButtonStyleConfiguration),
/// and a `ButtonStyle` still owns the whole appearance — returning the
/// label untouched is what `.plain` does. Reduce Motion drops the scale.
struct OtoBounce: ButtonStyle {
    /// Squish depth. Below ~0.94 the label reads as broken, above ~0.98 it
    /// reads as nothing; 0.96 is the band that reads as bounce.
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(
                OtoMotion.reduced ? nil : .spring(response: 0.25, dampingFraction: 0.55),
                value: configuration.isPressed
            )
    }
}

/// A small text action inside a row — Copy, Remove, Show.
struct OtoQuick: View {
    let title: String
    var tint: Color = OtoPalette.ink
    let act: () -> Void

    init(_ title: String, tint: Color = OtoPalette.ink, act: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(OtoBounce())
    }
}

/// A status readout: colored dot + short label. Dots, never banners —
/// green means go, amber means act, gray means waiting.
struct OtoStatus: View {
    enum Tone {
        case ok
        case warn
        case idle

        var color: Color {
            switch self {
            case .ok: OtoPalette.safe
            case .warn: OtoPalette.unsafe
            case .idle: OtoPalette.faint
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OtoPalette.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(OtoPalette.wash, in: Capsule())
    }
}
