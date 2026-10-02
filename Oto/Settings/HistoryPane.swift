//
//  HistoryPane.swift
//  Oto
//
//  Opt-in history, final text only. Recovery is Copy + manual paste (the
//  person picks target and timing) — no re-post path in this pane.
//

import AppKit
import SwiftUI

struct HistoryPane: View {
    let history: HistoryStore
    let polish: any PolishServing

    @AppStorage("app.Oto.historyEnabled") private var historyEnabled = false
    /// Mirrors the Intelligence master switch (same key as IntelligencePane):
    /// off hides every Clean up button — no dead controls.
    @AppStorage(IntelligenceSettings.enabledKey) private var intelligenceEnabled = true
    @State private var showClearConfirm = false
    @State private var feedback: String?
    @State private var historyPage = 1
    /// Unknown until appear (then read once): unknown ⇒ hidden, so the
    /// button can never appear without a live model behind it.
    @State private var polishAvailability: PolishAvailability = .unavailable(copy: "")
    @State private var polishEntry: HistoryEntry?

    var body: some View {
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
                                if polishActionVisible(availability: polishAvailability, enabled: intelligenceEnabled) {
                                    OtoQuick("Clean up") { polishEntry = entry }
                                }
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
        .sheet(item: $polishEntry) { entry in
            PolishSheet(entry: entry, polish: polish)
        }
        .onChange(of: historyEnabled) { _, new in
            history.setEnabled(new)
            if !new { historyPage = 1 }
        }
        .onAppear {
            // Read once per visit (cheap sync property): unknown ⇒ hidden,
            // and prewarm while the user browses so the first tap streams.
            polishAvailability = polish.availability()
            if polishActionVisible(availability: polishAvailability, enabled: intelligenceEnabled) {
                polish.prewarm()
            }
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
    }

    private func copyEntry(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalText, forType: .string)
        feedback = "Copied — paste with ⌘V."
    }
}
