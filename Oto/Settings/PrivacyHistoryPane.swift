//
//  PrivacyHistoryPane.swift
//  Oto
//
//  Opt-in history + privacy in one page. History is off by default and
//  stores final text only; recovery is Copy + manual paste (the person picks
//  target and timing) — no re-post path in this pane. Same logic as before —
//  only the surface changed.
//

import AppKit
import ApplicationServices
import Speech
import SwiftUI

struct PrivacyHistoryPane: View {
    let history: HistoryStore
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer(minLength: 0)
                OtoSegmented(
                    options: PaneSection.allCases.map { ($0, $0.rawValue) },
                    selection: $section
                )
                Spacer(minLength: 0)
            }

            if section == .history {
                historySection
            } else {
                privacySection
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "History")
            OtoCard {
                OtoLine(
                    "Remember transcripts",
                    "Kept on this Mac only. Newest \(HistoryStore.maxEntries) entries, \(HistoryStore.maxAgeDays) days. Turning off stops new saves; nothing is uploaded, ever."
                ) {
                    OtoSwitch(on: $historyEnabled)
                }
            }

            if !historyEnabled {
                OtoCard {
                    OtoNothing(
                        icon: .clock,
                        text: "History is off",
                        detail: "Turn it on to recall past dictation."
                    )
                }
            } else if history.entries.isEmpty {
                OtoCard {
                    OtoNothing(
                        icon: .clock,
                        text: "No remembered transcripts",
                        detail: "Finished dictation appears here."
                    )
                }
            } else {
                let pageCount = HistoryPage.pageCount(total: history.entries.count)
                OtoCard {
                    ForEach(Array(HistoryPage.slice(items: history.entries, page: historyPage).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { OtoRule() }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.finalText)
                                .font(.system(size: 13))
                                .foregroundStyle(OtoPalette.ink)
                                .lineLimit(3)
                            HStack {
                                Text(entry.bundleIdentifier ?? "Unknown app")
                                Text("·")
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(OtoPalette.muted)
                            HStack(spacing: 12) {
                                OtoQuick("Copy") { copyEntry(entry) }
                                OtoQuick("Delete", tint: .red) {
                                    Task { await history.remove(id: entry.id) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                }
                HStack(spacing: 12) {
                    OtoPill("Clear all…", tint: .red) { showClearConfirm = true }
                    Spacer(minLength: 0)
                }
                // Footer: newest-first pages, 10 per page. Page count caps at
                // 10 by construction (100-entry bound), so numbered buttons
                // never need ellipsis logic.
                HStack(spacing: 8) {
                    OtoPill("Previous") {
                        if historyPage > 1 { historyPage -= 1 }
                    }
                    .disabled(historyPage <= 1)
                    ForEach(1...pageCount, id: \.self) { number in
                        if number == historyPage {
                            OtoPill("\(number)", filled: true) { historyPage = number }
                        } else {
                            OtoPill("\(number)") { historyPage = number }
                        }
                    }
                    OtoPill("Next") {
                        if historyPage < pageCount { historyPage += 1 }
                    }
                    .disabled(historyPage >= pageCount)
                    Spacer(minLength: 0)
                    Text("Page \(historyPage) of \(pageCount)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                }
            }
            if let feedback {
                Text(feedback)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                    .padding(.leading, 2)
            }
        }
    }

    private func copyEntry(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalText, forType: .string)
        feedback = "Copied — paste with ⌘V."
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "Privacy")
            OtoCard {
                OtoLine("Microphone", micText) {
                    if micText != "Allowed" {
                        OtoPill("Allow microphone access") {
                            Task {
                                _ = await permissions.ensureMicrophone()
                                refreshPermissions()
                            }
                        }
                    }
                }
                OtoRule()
                OtoLine("Accessibility", axTrusted ? "Allowed" : "Not allowed") {
                    if !axTrusted {
                        OtoPill("Open Accessibility settings") {
                            requestAccessibilityPrompt()
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                refreshPermissions()
                            }
                        }
                    }
                }
                OtoRule()
                OtoLine("Speech recognition", speechText) { EmptyView() }
            }
            Text("Oto stores what you choose: dictionary rules, snippets, and — only if you turn it on — final transcripts. Never audio, never other apps' contents, never clipboard snapshots. Intelligence features would ask separately; none exist in this build.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
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
