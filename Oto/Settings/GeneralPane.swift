//
//  GeneralPane.swift
//  Oto
//

import ServiceManagement
import SwiftUI

/// Low-frequency app behavior only. No duplication of microphone, speech, or
/// shortcut controls (those live in Dictation). Thin by design: toggles
/// without engines behind them are dead controls, and dead controls are
/// worse than a short pane.
struct GeneralPane: View {
    let login: any LoginItemManaging

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?

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
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
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
}
