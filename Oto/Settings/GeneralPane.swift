//
//  GeneralPane.swift
//  Oto
//

import AppKit
import ServiceManagement
import SwiftUI

/// Low-frequency app behavior only. No duplication of microphone, speech, or
/// shortcut controls (those live in Dictation). Thin by design: toggles
/// without engines behind them are dead controls, and dead controls are
/// worse than a short pane.
/// Dock visibility preference. One documented call
/// (`setActivationPolicy`), persisted as a scalar — not a model store, so
/// the 12:46 one-store rule is untouched. Default shown: preserves current
/// behavior on upgrade.
enum DockVisibility {
    nonisolated static let defaultsKey = "app.Oto.showInDock"

    /// Pure read with upgrade default: `nonisolated` (Swift 6).
    nonisolated static func isShown(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
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
    @AppStorage("app.Oto.flowBarPosition") private var flowPosition: FlowBarPosition = .bottom

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { newValue in setLogin(enabled: newValue) }
                ))
                .toggleStyle(.switch)
                // Four states, never two: revoked consent and lookup failure
                // both read as guidance, not as a broken toggle.
                if loginStatus == .requiresApproval {
                    Text("Approved in System Settings, then revoked. Re-enable it under System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if loginStatus == .notFound {
                    Text("Login item status is unavailable right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show Oto in Dock", isOn: Binding(
                    get: { showInDock },
                    set: { newValue in setDockVisibility(shown: newValue) }
                ))
                .toggleStyle(.switch)
                .accessibilityIdentifier("ShowInDockToggle")
                Text("Applies immediately. When off, Oto lives in the menu bar only — no Dock icon, no ⌘Tab. Closing Settings never quits the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dockError {
                    Text(dockError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Flow Bar") {
                Picker("Position", selection: $flowPosition) {
                    Text("Top").tag(FlowBarPosition.top)
                    Text("Bottom").tag(FlowBarPosition.bottom)
                }
                .pickerStyle(.segmented)
                Text("Top sits below the notch. You can also drag the pill anytime — it snaps with a tick.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
            }
        }
        .formStyle(.grouped)
        // No .navigationTitle: sections self-label, and a stacked
        // sidebar+detail title inflates the toolbar zone (§11).
        .task { refreshLogin() }
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
