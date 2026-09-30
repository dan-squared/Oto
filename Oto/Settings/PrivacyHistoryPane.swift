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
import SwiftUI

struct PrivacyHistoryPane: View {
    let history: HistoryStore
    let uiState: SettingsUIState

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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
            // Slow state is hoisted (loaded once per window open) — keep
            // only the fast grant-flow refresh on appear.
            uiState.refreshPermissions()
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "History")
            OtoCard {
                OtoLine(
                    "Remember transcripts",
                    "On this Mac only. Newest \(HistoryStore.maxEntries) entries, \(HistoryStore.maxAgeDays) days. Off stops new saves; nothing is ever uploaded."
                ) {
                    OtoSwitch(on: $historyEnabled)
                }
            }

            if !historyEnabled {
                OtoCard {
                    OtoNothing(
                        systemName: "clock",
                        text: "History is off",
                        detail: "Turn it on to recall past dictation."
                    )
                }
            } else if history.entries.isEmpty {
                OtoCard {
                    OtoNothing(
                        systemName: "clock",
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
                OtoLine("Microphone", uiState.micDeniedGuidance) {
                    VStack(alignment: .trailing, spacing: 8) {
                        OtoStatus(text: uiState.micText, tone: uiState.micTone)
                        if !uiState.micAllowed {
                            OtoBig("Allow microphone access") {
                                Task {
                                    _ = await uiState.ensureMicrophoneGrant()
                                    uiState.refreshPermissions()
                                }
                            }
                        }
                    }
                }
                OtoRule()
                OtoLine("Accessibility", uiState.axTrusted ? nil : "Global keys and insertion need it.") {
                    VStack(alignment: .trailing, spacing: 8) {
                        OtoStatus(text: uiState.axTrusted ? "Allowed" : "Not allowed", tone: uiState.axTrusted ? .ok : .warn)
                        if !uiState.axTrusted {
                            OtoBig("Open Accessibility settings") {
                                uiState.requestAccessibilityPrompt()
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    uiState.refreshPermissions()
                                }
                            }
                        }
                    }
                }
                OtoRule()
                OtoLine("Speech recognition", nil) {
                    OtoStatus(text: uiState.speechText, tone: uiState.speechTone)
                }
            }
            Text("Oto stores what you choose: rules, snippets, and transcripts only if you enable history. Never audio or other apps' content.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
        }
    }
}
