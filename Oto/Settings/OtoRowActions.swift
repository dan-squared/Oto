//
//  OtoRowActions.swift
//  Oto
//
//  A settings row is one line of content and one quiet cluster of actions.
//  Text buttons ("Edit", "Delete", "Clean up") bloated the row and pushed the
//  data it described out of the card; the cluster keeps the line readable and
//  puts the rare facts behind an info button.
//
//  The info button opens the recorder's glass — same width, same material,
//  same corner, same "Close esc" footing — so a detail popover and a shortcut
//  recorder read as one family.
//

import SwiftUI

/// A quiet icon action inside a settings row: 22 pt hit area, hover wash,
/// tooltip + VoiceOver label from the same string.
struct OtoRowButton: View {
    let symbol: String
    let help: String
    var tint: Color = OtoPalette.ink
    /// Destructive actions read red on hover only, never at rest.
    var danger = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(danger && hovering ? Color.red : tint)
                .frame(width: 22, height: 22)
                .background(
                    hovering ? OtoPalette.wash : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(OtoBounce(scale: 0.93))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The cluster at a row's trailing edge. Spacing is 2 so the glyphs read as
/// one group; the 4 pt leading gap keeps it off the text on narrow panes.
struct OtoRowActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) { content() }
            .padding(.leading, 4)
    }
}

/// Copy feedback where the click happened: the row's copy glyph becomes a
/// tick for a beat. That tick is the whole confirmation — the list carries no
/// status line underneath.
@MainActor
@Observable
final class OtoCopyFlash {
    private(set) var id: UUID?
    private var reset: Task<Void, Never>?

    func flash(_ id: UUID) {
        self.id = id
        self.reset?.cancel()
        self.reset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.id == id else { return }
            self.id = nil
        }
    }

    func isCopied(_ id: UUID) -> Bool { self.id == id }
}

/// A detail panel on the recorder's glass. Read-only by design: editing is
/// the pencil's job, and this never grows a second way to change a value.
struct OtoInfoPopover: View {
    struct Row: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    let title: String
    var rows: [Row] = []
    /// A quiet block under the rows: a replacement, an expansion preview.
    var note: String?
    /// One inline action, for things too rare to earn a permanent icon.
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OtoPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .foregroundStyle(OtoPalette.muted)
                            .frame(width: 74, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(OtoPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5))
                }

                if let note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                if let actionTitle, let action {
                    Button(actionTitle) {
                        action()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OtoPalette.ink)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Text("Close")
                        OtoKey(text: "esc", compact: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Close details")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 252)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(20)
    }
}
