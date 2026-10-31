//
//  GeneralPane.swift
//  Oto
//
//  Low-frequency app behavior only. No duplication of microphone, speech, or
//  shortcut controls (those live in Dictation). Same logic as before — only
//  the surface changed.
//

import AppKit
import ServiceManagement
import SwiftUI

/// Dock visibility preference. One documented call
/// (`setActivationPolicy`), persisted as a scalar — not a model store, so
/// the 12:46 one-store rule is untouched. Default hidden: fresh installs
/// are menu-bar-only; an explicitly stored value still wins on upgrade.
enum DockVisibility {
    nonisolated static let defaultsKey = "app.Oto.showInDock"

    /// Pure read with fresh-install default: `nonisolated` (Swift 6).
    nonisolated static func isShown(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    /// Pure mapping: `nonisolated` (Swift 6).
    nonisolated static func policy(for shown: Bool) -> NSApplication.ActivationPolicy {
        shown ? .regular : .accessory
    }

    @discardableResult
    static func apply(shown: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard NSApp.setActivationPolicy(policy(for: shown)) else { return false }
        defaults.set(shown, forKey: defaultsKey)
        return true
    }
}

struct GeneralPane: View {
    let login: any LoginItemManaging

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var showInDock = DockVisibility.isShown()
    @State private var dockError: String?
    // Default is the shared freshDefault (Top) — the same constant
    // current() falls back to, so a fresh profile shows the truth.
    @AppStorage("app.Oto.flowBarPosition") private var flowPosition: FlowBarPosition = .freshDefault
    // Catcher kill-switch (6C1): default ON — the modal teaches the
    // no-textbox flow. Key owned by NoTargetModalSettings; the literal is
    // pinned equal to it by NoTargetModalTests.
    @AppStorage("app.Oto.noTargetModal") private var catcherEnabled = true
    // Media-duck kill-switch (Phase 7, spike-green): default ON — bleed
    // ruins transcripts, resume is automatic. Key owned by
    // MediaDuckSettings; the literal is pinned equal to it by MediaDuckTests.
    @AppStorage("app.Oto.muteMediaWhileDictating") private var muteMedia = true

    var body: some View {
        OtoPaneForm {
            // No "General" header — the sidebar already says it.
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { newValue in setLogin(enabled: newValue) }
                ))
                if let loginError {
                    Text(loginError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Oto in Dock", isOn: Binding(
                    get: { showInDock },
                    set: { newValue in setDockVisibility(shown: newValue) }
                ))
                .accessibilityIdentifier("ShowInDockToggle")
                if let dockError {
                    Text(dockError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .task { refreshLogin() }

            Section {
                // Label left, compact control right — the grouped-settings
                // segmented row, not a track stretched across the card.
                // HStack, not LabeledContent: the system label/content pair
                // pins the label to the row's top edge while the control
                // centres, so "Position" floated above the pill.
                HStack(spacing: 12) {
                    Text("Position")
                    Spacer(minLength: 8)
                    OtoSegmented(
                        options: [(.top, "Top"), (.bottom, "Bottom")],
                        selection: $flowPosition,
                        segmentWidth: 84
                    )
                }
                OtoPanelNote(
                    "Top places the pill under the menu bar. Bottom places it above the Dock. "
                        + "Drag the pill to move it and it snaps into place."
                )
            } header: {
                Text("Flow Bar")
            }

            // Behavior lives here, not in Dictation: it is how the app acts
            // when dictation lands, not what makes dictation work. Each switch
            // carries its own one-line explanation in the same row: as a row
            // of its own the note sat under a divider, which read as a second,
            // unrelated setting instead of the switch's own words.
            Section {
                self.toggle(
                    "Show catcher when there's nowhere to paste", isOn: $catcherEnabled,
                    note: "No text field? Oto opens a small window. Off: the text is copied instead.",
                    identifier: "CatcherToggle"
                )
                self.toggle(
                    "Mute media while dictating", isOn: $muteMedia,
                    note: "Silences speakers while you dictate, then restores the volume.",
                    identifier: "MuteToggle"
                )
            } header: {
                Text("Behavior")
            }
        }
    }

    // MARK: Private

    /// A switch and the one line that says what it does, in one row, so no
    /// divider falls between a setting and its own explanation. The toggle
    /// fills the row to keep its switch at the trailing edge. The identifier
    /// goes on the switch itself: on the row it would also land on the note
    /// and make the element ambiguous.
    private func toggle(
        _ title: String, isOn: Binding<Bool>, note: String, identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
                .accessibilityIdentifier(identifier)
                .frame(maxWidth: .infinity)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read the live login-item status on every visit: System Settings can
    /// revoke approval behind the app's back. The card carries no permanent
    /// caption — only failed actions speak (toggle, Dock error).
    private func refreshLogin() {
        loginStatus = login.status()
        loginError = nil
    }

    private func setLogin(enabled: Bool) {
        do {
            try login.setEnabled(enabled)
            refreshLogin()
        } catch {
            loginError = error.localizedDescription
            refreshLogin()
        }
    }

    private func setDockVisibility(shown: Bool) {
        // Binding-set (not onChange): on failure the state is left untouched
        // so the toggle never lies, and no revert loop is possible.
        dockError = nil
        guard DockVisibility.apply(shown: shown) else {
            dockError = "Could not change Dock visibility right now."
            return
        }
        showInDock = shown
    }
}
