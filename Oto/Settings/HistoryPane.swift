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
    @State private var showDisableConfirm = false
    @State private var confirmCopyOverwrite = false
    @State private var pendingCopyEntry: HistoryEntry?
    @State private var feedback: String?
    @State private var historyPage = 1
    /// Unknown until appear (then read once): unknown ⇒ hidden, so the
    /// button can never appear without a live model behind it.
    @State private var polishAvailability: PolishAvailability = .unavailable(copy: "")
    @State private var polishEntry: HistoryEntry?

    var body: some View {
        // No "History" header — the sidebar already says it.
        Group {
            Section {
                Toggle("Remember transcripts", isOn: Binding(
                    get: { historyEnabled },
                    set: { setHistoryEnabled($0) }
                ))
            } footer: {
                Text("On this Mac only. Newest \(HistoryStore.maxEntries) entries, \(HistoryStore.maxAgeDays) days. Off stops new saves; existing entries stay until cleared; nothing is ever uploaded.")
            }

            if !historyEnabled {
                Section {
                    ContentUnavailableView(
                        "History is off",
                        systemImage: "clock",
                        description: Text("Turn it on to recall past dictation.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            } else if history.entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No remembered transcripts",
                        systemImage: "clock",
                        description: Text("Finished dictation appears here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            } else {
                let pageCount = HistoryPage.pageCount(total: history.entries.count)
                Section {
                    ForEach(HistoryPage.slice(items: history.entries, page: historyPage)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.finalText)
                                .font(.system(size: 13))
                                .lineLimit(3)
                            HStack {
                                Text(AppNames.displayName(forBundleID: entry.bundleIdentifier))
                                Text("·")
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button("Copy") { copyEntry(entry) }
                                    .buttonStyle(.borderless)
                                if polishActionVisible(availability: polishAvailability, enabled: intelligenceEnabled) {
                                    Button("Clean up") { polishEntry = entry }
                                        .buttonStyle(.borderless)
                                }
                                if entry.wasCleaned, entry.rawText != nil {
                                    Button("Undo AI edit") { undoCleanup(entry) }
                                        .buttonStyle(.borderless)
                                }
                                Button("Delete") {
                                    Task { await history.remove(id: entry.id) }
                                }
                                .buttonStyle(.borderless)
                                .tint(.red)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                        }
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        Button("Clear all…") { showClearConfirm = true }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .tint(.red)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Button("Previous") {
                            if historyPage > 1 { historyPage -= 1 }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(historyPage <= 1)
                        ForEach(1...pageCount, id: \.self) { number in
                            pageButton(number: number, isCurrent: number == historyPage)
                        }
                        Button("Next") {
                            if historyPage < pageCount { historyPage += 1 }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(historyPage >= pageCount)
                        Spacer(minLength: 0)
                        Text("Page \(historyPage) of \(pageCount)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let feedback {
                Section {
                    Text(feedback)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
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
        .confirmationDialog(
            "Replace clipboard contents?",
            isPresented: $confirmCopyOverwrite,
            titleVisibility: .visible
        ) {
            Button("Replace") {
                if let entry = pendingCopyEntry { writeEntry(entry) }
                pendingCopyEntry = nil
            }
            Button("Cancel", role: .cancel) { pendingCopyEntry = nil }
        } message: {
            Text("The clipboard holds text Oto didn't place.")
        }
        .confirmationDialog(
            "Turn off History?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(history.entries.count) entries", role: .destructive) {
                Task { await history.clearAll() }
                historyEnabled = false
                historyPage = 1
            }
            Button("Turn off, keep entries") {
                historyEnabled = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Off stops new saves. Existing entries stay on this Mac until cleared.")
        }
    }

    /// Split the conditional button style so the compiler doesn't choke on
    /// ternary `ButtonStyle` inference inside the deeply-nested `ForEach`.
    @ViewBuilder
    private func pageButton(number: Int, isCurrent: Bool) -> some View {
        let button = Button("\(number)") { historyPage = number }
            .controlSize(.small)
        if isCurrent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    /// History toggle with disable disclosure (retention honesty):
    /// turning off with entries on file asks first — off stops new
    /// saves but never deletes, and the panic-toggle must say so.
    /// Empty store flips directly, no dialog.
    private func setHistoryEnabled(_ new: Bool) {
        if !new, !history.entries.isEmpty {
            showDisableConfirm = true
            return
        }
        historyEnabled = new
    }

    private func copyEntry(_ entry: HistoryEntry) {
        // Overwrite guard (clipboard discipline): foreign content confirms,
        // empty/Oto boards write direct. Marker set on every Oto write so
        // Oto-to-Oto copies stay frictionless.
        if ClipboardOverwriteGuard.shouldConfirm(board: .general) {
            pendingCopyEntry = entry
            confirmCopyOverwrite = true
            return
        }
        writeEntry(entry)
    }

    private func writeEntry(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalText, forType: .string)
        ClipboardOverwriteGuard.markAsOto(NSPasteboard.general)
        feedback = "Copied — paste with ⌘V."
    }

    /// Undo AI edit (E1): restores the raw wording on a cleaned entry.
    private func undoCleanup(_ entry: HistoryEntry) {
        Task {
            await history.undoCleanup(id: entry.id)
            feedback = "Original wording restored."
        }
    }
}
