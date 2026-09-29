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
                .background(filled ? OtoPalette.ink : (hovering ? OtoPalette.hover : OtoPalette.wash), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small capsule that does one thing. Outlined; filled ink when primary.
struct OtoPill: View {
    let title: String
    var filled = false
    var tint: Color = OtoPalette.ink
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = OtoPalette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? OtoPalette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? OtoPalette.ink : (hovering ? OtoPalette.hover : OtoPalette.ground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(filled ? .clear : OtoPalette.hairline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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
    var help = ""
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? OtoPalette.ink : (hovering ? OtoPalette.ink.opacity(0.7) : OtoPalette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? OtoPalette.wash : (hovering ? OtoPalette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(OtoMotion.quick, value: hovering)
        .animation(OtoMotion.quick, value: on)
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
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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
