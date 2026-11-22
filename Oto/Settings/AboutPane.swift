//
//  AboutPane.swift
//  Oto
//
//  Identity lives on its own destination, as it does in Firstlight: General
//  stays about behavior, and the one place that answers "what is this app,
//  and which build am I running?" is here.
//

import AppKit
import SwiftUI

struct AboutPane: View {
    let updater: AppUpdater

    var body: some View {
        OtoPaneForm {
            Section {
                VStack(spacing: 4) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .padding(.bottom, 4)
                    Text("Oto")
                        .font(.system(size: 20, weight: .semibold))
                    Text(Self.versionLine)
                        .foregroundStyle(.secondary)
                    Text("Press a shortcut, speak, release. The text lands where you were working.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    Text("© 2026 Daniel Girma. All rights reserved.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }

            Section("Details") {
                LabeledContent("Version", value: Self.versionLine)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
                Button(updater.buttonTitle) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Section("Support") {
                if let source = Self.sourceURL {
                    Link("Source & Releases", destination: source)
                }
                if let report = Self.reportURL {
                    Link("Report a Problem", destination: report)
                }
                OtoPanelNote("Crashes write a small local report in Application Support/Oto/Crashes. Nothing is uploaded unless you attach it yourself.")
            }
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    private static var sourceURL: URL? {
        URL(string: "https://github.com/dan-squared/Oto")
    }

    /// Prefilled, honest issue: version and OS only. The person chooses
    /// whether to attach the local crash report — we never read it into a URL.
    private static var reportURL: URL? {
        var components = URLComponents(string: "https://github.com/dan-squared/Oto/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Oto issue: "),
            URLQueryItem(name: "body", value: """
            App: \(versionLine)
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

            What happened?
            Steps to reproduce?

            If Oto crashed, attach the newest .txt from:
            ~/Library/Application Support/Oto/Crashes/
            """),
        ]
        return components?.url
    }
}
