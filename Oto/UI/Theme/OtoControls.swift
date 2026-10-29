//
//  OtoControls.swift
//  Oto
//
//  Small semantic adapters around native macOS controls. Use system button,
//  toggle, menu, and segmented picker styles so sizing and interaction stay
//  consistent with macOS, including Liquid Glass on supported systems.
//

import SwiftUI

/// A standard settings action. Glass is reserved for the segmented track and
/// the recorder popover; ordinary actions use the quiet macOS bordered face.
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
                Button(title, action: act).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: act).buttonStyle(.bordered)
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
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
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
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                Button {
                    selection = item.0
                } label: {
                    Text(item.1)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == item.0 || hoveredOption == item.0 ? Color.primary : Color.secondary)
                .animation(.easeOut(duration: 0.12), value: hoveredOption)
                .frame(maxWidth: .infinity)
                .onHover { hovering in hoveredOption = hovering ? item.0 : nil }
                .accessibilityAddTraits(selection == item.0 ? [.isSelected] : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.94))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.10), radius: 2, y: 1)
                    .frame(width: geometry.size.width / CGFloat(max(options.count, 1)))
                    .offset(x: geometry.size.width * CGFloat(selectedIndex) / CGFloat(max(options.count, 1)))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(3)
        .background {
            if #available(macOS 26.0, *), !reduceTransparency {
                Color.clear.glassEffect(.regular, in: .capsule)
            } else {
                Capsule().fill(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Options")
        .onMoveCommand { direction in
            let nextIndex: Int
            switch direction {
            case .left: nextIndex = max(0, selectedIndex - 1)
            case .right: nextIndex = min(options.count - 1, selectedIndex + 1)
            default: return
            }
            guard options.indices.contains(nextIndex) else { return }
            selection = options[nextIndex].0
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @State private var hoveredOption: Option?
    private var selectedIndex: Int { options.firstIndex { $0.0 == selection } ?? 0 }
}

/// A native compact icon button for the shortcut editor.
struct OtoDoor: View {
    let systemName: String
    var on = false
    var help = ""
    let act: () -> Void
    var body: some View {
        Button(action: act) { Image(systemName: systemName) }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(on ? OtoPalette.ink : .secondary)
        .help(help)
    }
}

/// A compact keycap in the quiet filled well used by Firstlight's recorder.
struct OtoKey: View {
    let text: String
    var compact = false
    var dimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10 : 11, weight: .medium, design: .rounded))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 3 : 4)
            .background {
                RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                    .fill(Color.primary.opacity(dimmed ? 0.035 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(dimmed ? 0.08 : 0.12), lineWidth: 0.7)
            }
            .frame(minWidth: compact ? 22 : 30, minHeight: compact ? 22 : 26)
    }
}

/// The compact shortcut face shared by Dictation and Intelligence rows.
/// Its quiet well and keycaps match Firstlight; the glass belongs to the
/// anchored recorder popover, never to the key faces themselves.
struct OtoShortcutField: View {
    let chips: [String]
    var isRecording = false
    var placeholder = "Record Shortcut"
    var recordLabel = "Record shortcut"
    var clearHelp = "Remove shortcut"
    var canClear = false
    let onRecord: () -> Void
    var onClear: (() -> Void)? = nil

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onRecord) {
                HStack(spacing: 4) {
                    if isRecording {
                        Text("…and a key")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if chips.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(chips, id: \.self) { chip in
                            OtoKey(text: chip, compact: true)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Recording shortcut" : recordLabel)

            if canClear, !chips.isEmpty, let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.4)
                .accessibilityLabel("Remove shortcut")
                .help(clearHelp)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(minWidth: 84, minHeight: 22)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering && !isRecording ? 0.07 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(isRecording ? 0.3 : 0.12), lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.5)
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
