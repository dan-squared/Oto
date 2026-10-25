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

    var body: some View {
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
        } footer: {
            if let loginCaption {
                Text(loginCaption)
            }
            Text("Off: menu bar only — no Dock, no ⌘Tab.")
        }
        .task { refreshLogin() }

        Section {
            Picker("Position", selection: $flowPosition) {
                Text("Top").tag(FlowBarPosition.top)
                Text("Bottom").tag(FlowBarPosition.bottom)
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
        } header: {
            Text("Flow Bar")
        } footer: {
            Text("Top sits below the notch. Drag the pill anytime — it snaps.")
        }

        Section("About") {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
        }
    }

    /// Four states, never two: revoked consent and lookup failure both
    /// read as guidance, not as a broken toggle.
    private var loginCaption: String? {
        if loginStatus == .requiresApproval {
            return "Approved in System Settings, then revoked. Re-enable it under System Settings → General → Login Items."
        }
        if loginStatus == .notFound {
            return "Login item status is unavailable right now."
        }
        return nil
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

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
