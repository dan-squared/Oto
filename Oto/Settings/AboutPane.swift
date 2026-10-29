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
    var body: some View {
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
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}
