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
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "General")
                OtoCard {
                    OtoLine("Launch at login", loginCaption) {
                        OtoSwitch(on: Binding(
                            get: { loginStatus == .enabled },
                            set: { newValue in setLogin(enabled: newValue) }
                        ))
                    }
                    if let loginError {
                        Text(loginError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(OtoPalette.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                    }
                    OtoRule()
                    OtoLine("Show Oto in Dock", "Applies now. Off: menu bar only — no Dock, no ⌘Tab.") {
                        OtoSwitch(on: Binding(
                            get: { showInDock },
                            set: { newValue in setDockVisibility(shown: newValue) }
                        ))
                        .accessibilityIdentifier("ShowInDockToggle")
                    }
                    if let dockError {
                        Text(dockError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(OtoPalette.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Flow Bar")
                OtoCard {
                    HStack {
                        Text("Position")
                            .font(.system(size: 13))
                            .foregroundStyle(OtoPalette.ink)
                        Spacer(minLength: 8)
                        OtoSegmented(
                            options: [(FlowBarPosition.top, "Top"), (FlowBarPosition.bottom, "Bottom")],
                            selection: $flowPosition
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                Text("Top sits below the notch. Drag the pill anytime — it snaps.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "About")
                OtoCard {
                    OtoLine("Version", appVersion) { EmptyView() }
                    OtoRule()
                    OtoLine("Bundle identifier", Bundle.main.bundleIdentifier ?? "—") { EmptyView() }
                }
            }
        }
        .task { refreshLogin() }
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
