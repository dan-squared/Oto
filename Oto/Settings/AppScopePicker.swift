//
//  AppScopePicker.swift
//  Oto
//
//  Shared scope editor for dictionary rules and snippets: Everywhere, or a
//  checklist of installed apps. Replaces typed bundle IDs — the person picks
//  the app they recognise, and one rule can serve several apps.
//

import AppKit
import SwiftUI

struct OtoAppScopePicker: View {
    @Binding var isGlobal: Bool
    @Binding var bundleIDs: [String]

    @State private var isChoosing = false
    @State private var query = ""

    var body: some View {
        OtoSegmented(
            options: [(true, "Everywhere"), (false, "Selected apps")],
            selection: $isGlobal
        )
        if !isGlobal {
            Button {
                isChoosing = true
            } label: {
                HStack(spacing: 6) {
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apps this applies to")
            .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
                chooser
            }
        }
    }

    private var summary: String {
        let names = bundleIDs.map { InstalledApps.name(forBundleID: $0) ?? $0 }
        switch names.count {
        case 0: return "Choose apps…"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names.count) apps"
        }
    }

    /// Installed apps plus any stored scope this Mac no longer has, so a
    /// legacy bundle ID can always be seen and unchecked.
    private var apps: [InstalledApp] {
        var list = InstalledApps.all
        let known = Set(list.map(\.bundleID))
        for id in bundleIDs where !known.contains(id) {
            list.append(InstalledApp(bundleID: id, name: id, path: ""))
        }
        return list
    }

    private var filteredApps: [InstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedLowercase.contains(needle)
                || $0.bundleID.localizedLowercase.contains(needle)
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search apps")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(.quaternary, in: Capsule())
            .padding(10)

            Divider()

            if filteredApps.isEmpty {
                Text("No apps found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            Toggle(isOn: binding(for: app.bundleID)) {
                                HStack(spacing: 8) {
                                    icon(for: app)
                                    Text(app.name)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
            HStack {
                Button("Clear") { bundleIDs = [] }
                    .buttonStyle(.borderless)
                    .disabled(bundleIDs.isEmpty)
                Spacer()
                Text(bundleIDs.count == 1 ? "1 app" : "\(bundleIDs.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .frame(width: 264, height: 300)
    }

    @ViewBuilder
    private func icon(for app: InstalledApp) -> some View {
        if app.path.isEmpty {
            Image(systemName: "app")
                .frame(width: 16, height: 16)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }

    private func binding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { bundleIDs.contains(bundleID) },
            set: { selected in
                if selected {
                    if !bundleIDs.contains(bundleID) { bundleIDs.append(bundleID) }
                } else {
                    bundleIDs.removeAll { $0 == bundleID }
                }
            }
        )
    }
}
