//
//  NoTargetModal.swift
//  Oto
//
//  Slice 6C1: the "dictated with nowhere to paste" catcher. Display-only
//  (the references show transcript + Copy, no editor — editing stays
//  6C2-if-wanted). Nonactivating panel, never steals focus: the taught
//  flow is click-a-textbox → ⌘V, which breaks if this surface takes key
//  status. Copy never dismisses (the user may need to find a textbox
//  first); ✕ closes the view only — text survives in recovery + history.
//

import AppKit
import SwiftUI

/// Kill-switch setting. Default ON (the modal is the discovery path for
/// the #1 new-user dead end); OFF → auto-copy path. Absent key means ON
/// so a fresh install teaches the flow.
enum NoTargetModalSettings {
    nonisolated static let key = "app.Oto.noTargetModal"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

@Observable @MainActor
final class NoTargetModalController {
    nonisolated static let width: CGFloat = 464
    nonisolated static let height: CGFloat = 168

    private(set) var text = ""
    private(set) var copied = false
    private var panel: NSPanel?
    private var hosting: NSHostingView<NoTargetModalView>?

    func show(text: String, displayID: CGDirectDisplayID?) {
        self.text = text
        copied = false
        if panel == nil {
            let hosting = NSHostingView(rootView: NoTargetModalView(controller: self))
            self.hosting = hosting
            panel = FlowBarPanel.makePanel(
                contentView: hosting,
                size: NSSize(width: Self.width, height: Self.height)
            )
        } else {
            hosting?.rootView = NoTargetModalView(controller: self)
        }
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - Self.width / 2,
            y: visible.midY - Self.height / 2,
            width: Self.width, height: Self.height
        )
        panel?.setFrame(frame, display: true)
        // orderFront, never key: focus must stay wherever the user had it.
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Manual Copy primitive (same pasteboard discipline as history Copy).
    /// Never dismisses — the user may still need to find a textbox.
    func copy(pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

struct NoTargetModalView: View {
    let controller: NoTargetModalController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(red: 0.055, green: 0.055, blue: 0.065))
                .shadow(color: .black.opacity(0.5), radius: 22, y: 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    // Static waveform mark (fixed arch, no motion).
                    HStack(spacing: 3) {
                        ForEach([0.45, 0.7, 1.0, 0.7, 0.45], id: \.self) { level in
                            Capsule()
                                .fill(.white)
                                .frame(width: 3, height: 24 * level)
                        }
                    }
                    .frame(width: 40, height: 24)
                    Spacer()
                    Text("Select a textbox first, then dictate")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button { controller.hide() } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.6))
                }
                Text(controller.text)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.top, 14)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(controller.copied ? "Copied" : "Copy") {
                        controller.copy()
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .disabled(controller.copied)
                }
            }
            .padding(20)
        }
        .frame(
            width: NoTargetModalController.width,
            height: NoTargetModalController.height
        )
    }
}
