//
//  PermissionModal.swift
//  Oto
//
//  Mic-denied mini modal: when dictation fails with .microphoneDenied, the
//  pill stays out of the way and this 388-wide card renders at the pill slot
//  instead (no flash-on-then-melt). One action: "Grant Permission" prompts
//  the system mic dialog when status is notDetermined, otherwise deep-links
//  System Settings at Privacy & Security → Microphone (with fallbacks).
//  Appearance-aware: follows the system light/dark scheme, no in-app toggle.
//  Auto-dismiss: 5s visible, then fades out (no close button, by design).
//

import AppKit
import SwiftUI

/// Grant-button routing. Pure so the branch is headless-tested without
/// touching TCC: undetermined → the system prompt ("access giving window");
/// anything else → Settings (a prompt would no-op once denied).
enum PermissionGrantAction {
    case systemPrompt
    case openSettings
}

/// System Settings deep links, most specific first. The Microphone anchor is
/// the long-standing `com.apple.preference.security` pane path; the two
/// fallbacks keep the button useful even if a future macOS renames the pane.
/// Pure builder — the exact strings are test-pinned.
enum MicSettingsLink {
    nonisolated static func candidates() -> [URL] {
        [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:",
        ].compactMap(URL.init(string:))
    }
}

@Observable @MainActor
final class PermissionModalController {
    nonisolated static let width: CGFloat = 388
    nonisolated static let height: CGFloat = 60
    /// Visible window: long enough to read + reach the button (macOS banner
    /// persistence class), short enough to never linger. Then fades out.
    nonisolated static let visibleDuration: Double = 5.0

    private var panel: NSPanel?
    private var hosting: NSHostingView<PermissionModalView>?
    private var hideTask: Task<Void, Never>?
    private var showGeneration: UInt64 = 0
    /// Internal for tests: prewarm stability.
    var hasPanel: Bool { panel != nil }

    /// MainActor-bound (MicrophoneStatus's synthesized Equatable inherits
    /// default isolation); all callers — grant() and tests — are MainActor.
    static func action(
        for status: PermissionsManager.MicrophoneStatus
    ) -> PermissionGrantAction {
        status == .notDetermined ? .systemPrompt : .openSettings
    }

    /// Build panel + hosting once, off the transition path (catcher precedent).
    /// Never orders front — pure construction cost moved to launch.
    func prewarm() {
        if panel == nil {
            let hosting = NSHostingView(rootView: PermissionModalView(grant: { [weak self] in
                self?.grant()
            }))
            self.hosting = hosting
            panel = FlowBarPanel.makePanel(
                contentView: hosting,
                size: NSSize(width: Self.width, height: Self.height)
            )
        }
    }

    func show(displayID: CGDirectDisplayID?, position: FlowBarPosition) {
        prewarm()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else { return }
        let frame = FlowBarPosition.frame(
            width: Self.width, on: screen.visibleFrame, position: position
        )
        // A fresh show supersedes any pending fade: full 5s, never truncated.
        showGeneration += 1
        let generation = showGeneration
        hideTask?.cancel()
        panel?.setFrame(frame, display: false)
        panel?.alphaValue = 0
        // orderFront, never key: focus must stay wherever the user had it.
        panel?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.visibleDuration))
            guard !Task.isCancelled, generation == self.showGeneration else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel?.animator().alphaValue = 0
            }, completionHandler: {
                // Late hide() already ordered out: only land when still ours.
                if generation == self.showGeneration {
                    self.panel?.orderOut(nil)
                }
            })
        }
    }

    func hide() {
        // Cancel-before-orderOut: a new show after this starts clean.
        showGeneration += 1
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Test seam: opener injectable so tests never launch Settings.
    func grant(opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        switch Self.action(for: PermissionsManager().microphoneStatus()) {
        case .systemPrompt:
            Task { _ = await PermissionsManager().requestMicrophone() }
        case .openSettings:
            for url in MicSettingsLink.candidates() {
                if opener(url) { break }
            }
        }
    }
}

struct PermissionModalView: View {
    let grant: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Explicit clear root: the hosting view must paint nothing
            // behind the card (the pill's v2 frame bug class — never again).
            Color.clear
            RoundedRectangle(cornerRadius: 18)
                .fill(colorScheme == .dark
                    ? Color(red: 0.055, green: 0.055, blue: 0.065)
                    : Color.white)
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.5 : 0.15),
                    radius: 18, y: 4
                )
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.red)
                Text("Microphone Permission Required")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Grant Permission") { grant() }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(colorScheme == .dark
                        ? Color(red: 0.93, green: 0.90, blue: 0.84)
                        : Color(white: 0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 14)
        }
        .frame(
            width: PermissionModalController.width,
            height: PermissionModalController.height
        )
    }
}
