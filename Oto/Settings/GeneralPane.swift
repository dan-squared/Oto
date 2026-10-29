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
                OtoSegmented(
                    options: [(.top, "Top"), (.bottom, "Bottom")],
                    selection: $flowPosition
                )
                OtoPanelNote("Top sits below the notch. Drag the pill anytime — it snaps.")
            } header: {
                Text("Flow Bar")
            }

            // Behavior lives here, not in Dictation: it is how the app acts
            // when dictation lands, not what makes dictation work.
            Section {
                Toggle("Show catcher when there's nowhere to paste", isOn: $catcherEnabled)
                    .accessibilityIdentifier("CatcherToggle")
                Toggle("Mute media while dictating", isOn: $muteMedia)
                OtoPanelNote("Catcher: no text field? Oto opens a small window. Off: auto-copies instead.\nMute: silences speakers, restores volume automatically.")
            } header: {
                Text("Behavior")
            }
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
