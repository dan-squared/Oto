//
//  PrivacyHistoryPane.swift
//  Oto
//
//  Phase 6A: opt-in history + privacy behind one toolbar tab. Subsections
//  ride an in-content segmented Picker (D3). History is off by default and
//  stores final text only; Reinsert goes through retryPostToFrontmost (the
//  user-is-the-check path) — never a reconstructed target.
//

import AppKit
import ApplicationServices
import Speech
import SwiftUI

struct PrivacyHistoryPane: View {
    let history: HistoryStore
    let inserter: RealTextInsertion
    let permissions: PermissionsManager

    enum PaneSection: String, CaseIterable, Identifiable {
        case history = "History"
        case privacy = "Privacy"
        var id: String { rawValue }
    }

    @State private var section: PaneSection = .history
    @AppStorage("app.Oto.historyEnabled") private var historyEnabled = false
    @State private var showClearConfirm = false
    @State private var feedback: String?
    @State private var historyPage = 1

    @State private var micText = "Checking…"
    @State private var axTrusted = false
    @State private var speechText = "Checking…"

    var body: some View {
        Form {
            Picker("Privacy & History", selection: $section) {
                ForEach(PaneSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .history {
                historySection
            } else {
                privacySection
            }
        }
        .formStyle(.grouped)
        .onChange(of: historyEnabled) { _, new in
            history.setEnabled(new)
            if !new { historyPage = 1 }
        }
        .onChange(of: history.entries.count) { _, _ in
            historyPage = HistoryPage.clampedPage(historyPage, total: history.entries.count)
        }
        .confirmationDialog(
            "Delete all history on this Mac?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(history.entries.count) entries", role: .destructive) {
                Task {
                    await history.clearAll()
                    historyPage = 1
                }
            }
        } message: {
            Text("This removes every remembered transcript on this Mac. Cannot be undone.")
        }
        .task {
            refreshPermissions()
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section("History") {
            Toggle("Remember transcripts", isOn: $historyEnabled)
            Text("Kept on this Mac only. Newest \(HistoryStore.maxEntries) entries, \(HistoryStore.maxAgeDays) days. Turning off stops new saves; nothing is uploaded, ever.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !historyEnabled {
                ContentUnavailableView(
                    "History is off",
                    systemImage: "clock",
                    description: Text("Turn it on to recall past dictation.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if history.entries.isEmpty {
                ContentUnavailableView(
                    "No remembered transcripts",
                    systemImage: "clock",
                    description: Text("Finished dictation appears here.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                let pageCount = HistoryPage.pageCount(total: history.entries.count)
                ForEach(HistoryPage.slice(items: history.entries, page: historyPage)) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.finalText)
                            .lineLimit(3)
                        HStack {
                            Text(entry.bundleIdentifier ?? "Unknown app")
                            Text("·")
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy") { copyEntry(entry) }
                            Button("Reinsert") { reinsert(entry) }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                Task { await history.remove(id: entry.id) }
                            }
                        }
                        .font(.caption)
                    }
                }
                HStack {
                    Button("Clear all…", role: .destructive) { showClearConfirm = true }
                    Spacer()
                }
                // Footer: newest-first pages, 10 per page. Page count caps at
                // 10 by construction (100-entry bound), so numbered buttons
                // never need ellipsis logic.
                HStack {
                    Button("Previous") {
                        if historyPage > 1 { historyPage -= 1 }
                    }
                    .disabled(historyPage <= 1)
                    ForEach(1...pageCount, id: \.self) { number in
                        if number == historyPage {
                            Button("\(number)") { historyPage = number }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("\(number)") { historyPage = number }
                                .buttonStyle(.link)
                        }
                    }
                    Button("Next") {
                        if historyPage < pageCount { historyPage += 1 }
                    }
                    .disabled(historyPage >= pageCount)
                    Spacer()
                    Text("Page \(historyPage) of \(pageCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyEntry(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalText, forType: .string)
        feedback = "Copied — paste with ⌘V."
    }

    private func reinsert(_ entry: HistoryEntry) {
        // The person pressed this while facing the target — they are the
        // check (menu Retry precedent). Never a reconstructed TargetApplication.
        Task {
            let posted = await inserter.retryPostToFrontmost(entry.finalText)
            feedback = posted
                ? "Posted — check the frontmost app."
                : "Retry failed — secure input may be blocking it, or the clipboard was unavailable."
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            LabeledContent("Microphone", value: micText)
            if micText != "Allowed" {
                Button("Allow microphone access") {
                    Task {
                        _ = await permissions.ensureMicrophone()
                        refreshPermissions()
                    }
                }
            }
            LabeledContent("Accessibility", value: axTrusted ? "Allowed" : "Not allowed")
            if !axTrusted {
                Button("Open Accessibility settings") {
                    requestAccessibilityPrompt()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        refreshPermissions()
                    }
                }
            }
            LabeledContent("Speech recognition", value: speechText)
            Text("Oto stores what you choose: dictionary rules, snippets, and — only if you turn it on — final transcripts. Never audio, never other apps' contents, never clipboard snapshots. Intelligence features would ask separately; none exist in this build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        switch permissions.microphoneStatus() {
        case .granted:
            micText = "Allowed"
        case .denied:
            micText = "Denied — allow in System Settings → Privacy & Security → Microphone."
        case .notDetermined:
            micText = "Not asked yet"
        }
        axTrusted = AXIsProcessTrusted()
        switch permissions.speechStatus() {
        case .authorized:
            speechText = "Allowed"
        case .denied, .restricted:
            speechText = "Not allowed"
        case .notDetermined:
            speechText = "Not asked yet"
        @unknown default:
            speechText = "Unknown"
        }
    }

    private func requestAccessibilityPrompt() {
        _ = AXIsProcessTrustedWithOptions([
            PermissionsManager.axPromptKey: true,
        ] as CFDictionary)
    }
}
