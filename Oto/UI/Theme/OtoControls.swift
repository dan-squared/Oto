//
//  OtoControls.swift
//  Oto
//
//  Small semantic adapters around native macOS controls. Use system button,
//  toggle, menu, and segmented picker styles so sizing and interaction stay
//  consistent with macOS, including Liquid Glass on supported systems.
//

import SwiftUI

/// A native primary macOS button. The system supplies hover, focus,
/// pressed, disabled, and Liquid Glass treatments for the current OS.
struct OtoBig: View {
    let title: String
    var filled = true
    let act: () -> Void

    init(_ title: String, filled: Bool = true, act: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.act = act
    }

    var body: some View {
        Group {
            if filled {
                Button(title, action: act).buttonStyle(.glassProminent)
            } else {
                Button(title, action: act).buttonStyle(.glass)
            }
        }
        .controlSize(.regular)
        .tint(OtoPalette.ink)
    }
}

/// A native bordered action button. The system supplies its appearance and
/// interaction states; destructive actions retain their red tint.
struct OtoPill: View {
    let title: String
    var filled = false
    var tint: Color = OtoPalette.ink
    var large = false
    let action: () -> Void

    init(_ title: String, filled: Bool = false, tint: Color = OtoPalette.ink, large: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.large = large
        self.action = action
    }

    var body: some View {
        Group {
            if filled {
                Button(title, action: action).buttonStyle(.glassProminent)
            } else {
                Button(title, action: action).buttonStyle(.glass)
            }
        }
        .controlSize(large ? .regular : .small)
        .tint(tint)
    }
}

/// Native macOS switch used by settings rows.
struct OtoSwitch: View {
    @Binding var on: Bool
    let title: String

    init(on: Binding<Bool>, title: String = "Setting") {
        _on = on
        self.title = title
    }

    var body: some View {
        Toggle(title, isOn: $on)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(title)
    }
}

/// Native segmented picker for mutually exclusive options.
struct OtoSegmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option

    var body: some View {
        Picker("Options", selection: $selection) {
            ForEach(options, id: \.0) { option, title in
                Text(title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .labelsHidden()
    }
}

/// A native compact icon button for the shortcut editor.
struct OtoDoor: View {
    let systemName: String
    var on = false
    var help = ""
    let act: () -> Void
    var body: some View {
        Button(action: act) { Image(systemName: systemName) }
        .buttonStyle(.glass)
        .controlSize(.small)
        .tint(on ? OtoPalette.ink : .secondary)
        .help(help)
    }
}

/// A compact keycap display with native Liquid Glass material.
struct OtoKey: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
            .foregroundStyle(OtoPalette.ink)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 4 : 3)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous))
            .frame(minWidth: compact ? 22 : 30)
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

/// A native borderless text action inside a settings row.
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
        Button(title, action: act)
            .foregroundStyle(tint)
            .buttonStyle(.borderless)
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
