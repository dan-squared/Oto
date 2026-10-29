//
//  HistoryPane.swift
//  Oto
//
//  Opt-in history, final text only. Recovery is Copy + manual paste (the
//  person picks target and timing) — no re-post path in this pane.
//
//  A row is the words and four quiet actions. The app, the time and the
//  cleanup state are facts, not headline copy: they live behind the info
//  button instead of under every transcript.
//

import AppKit
import SwiftUI

struct HistoryPane: View {
    let history: HistoryStore
    let polish: any PolishServing
    let dispatch: ShortcutDispatch
    let chrome: SettingsChrome

    @AppStorage("app.Oto.historyEnabled") private var historyEnabled = false
    /// Mirrors the Intelligence master switch (same key as IntelligencePane):
    /// off hides every Clean up button — no dead controls.
    @AppStorage(CleanupSettings.enabledKey) private var intelligenceEnabled = false
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
    @State private var infoEntryID: UUID?
    @State private var copyFlash = OtoCopyFlash()

    var body: some View {
        Group {
            if !historyEnabled {
                OtoPaneCanvas {
                    OtoEmptyState(
                        symbol: "clock.arrow.circlepath",
                        title: "History is off",
                        message: "Oto keeps nothing. Turn it on and your last \(HistoryStore.maxEntries) transcripts stay here, on this Mac, until you clear them.",
                        chips: Self.chips,
                        actionTitle: "Turn On History",
                        action: { setHistoryEnabled(true) },
                        footnote: OtoEmptyFootnote(lead: "Nothing is uploaded. Turning it off again stops new saves and keeps what is already here.")
                    )
                }
            } else if history.entries.isEmpty {
                OtoPaneCanvas {
                    OtoEmptyState(
                        symbol: "clock.arrow.circlepath",
                        title: "Nothing here yet",
                        message: "Finished dictation lands here with the words, the app you were in, and the time.",
                        chips: Self.chips,
                        footnote: holdFootnote()
                    )
                }
            } else {
                self.list
            }
        }
        .onAppear {
            publishAccessory()
            polishAvailability = polish.availability()
            if polishActionVisible(availability: polishAvailability, enabled: intelligenceEnabled) {
                polish.prewarm()
            }
        }
        .onChange(of: historyEnabled) { _, new in
            history.setEnabled(new)
            if !new { historyPage = 1 }
            publishAccessory()
        }
        .onChange(of: history.entries.count) { _, _ in
            historyPage = HistoryPage.clampedPage(historyPage, total: history.entries.count)
            publishAccessory()
        }
        // Probe-only (never posted in normal use): lets the screenshot walk
        // open the first row's details and copy it, so the arrow anchor and
        // the copied tick can be verified from a real window capture.
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeOpenInfo)) { _ in
            infoEntryID = history.entries.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeCloseInfo)) { _ in
            infoEntryID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeCopyFirst)) { _ in
            if let first = history.entries.first { writeEntry(first) }
        }
        .sheet(item: $polishEntry) { entry in
            PolishSheet(entry: entry, polish: polish)
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

    // MARK: - List

    private var list: some View {
        OtoPaneForm {
            let pageCount = HistoryPage.pageCount(total: history.entries.count)
            Section {
                ForEach(HistoryPage.slice(items: history.entries, page: historyPage)) { entry in
                    self.row(for: entry)
                }
            }

            Section {
                HStack(spacing: 12) {
                    Button("Clear all…") { showClearConfirm = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    Spacer(minLength: 0)
                }
                if pageCount > 1 {
                    HStack(spacing: 8) {
                        Button("Previous") {
                            if historyPage > 1 { historyPage -= 1 }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(historyPage <= 1)
                        ForEach(1...pageCount, id: \.self) { number in
                            self.pageButton(number: number, isCurrent: number == historyPage)
                        }
                        Button("Next") {
                            if historyPage < pageCount { historyPage += 1 }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(historyPage >= pageCount)
                        Spacer(minLength: 0)
                        Text("Page \(historyPage) of \(pageCount)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(for entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.finalText)
                .font(.system(size: 13))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())

            OtoRowActions {
                OtoRowButton(
                    symbol: self.copyFlash.isCopied(entry.id) ? "checkmark" : "doc.on.doc",
                    help: self.copyFlash.isCopied(entry.id) ? "Copied" : "Copy transcript",
                    tint: self.copyFlash.isCopied(entry.id) ? OtoStatus.Tone.ok.color : OtoPalette.ink
                ) {
                    copyEntry(entry)
                }
                if polishActionVisible(availability: polishAvailability, enabled: intelligenceEnabled) {
                    OtoRowButton(symbol: "sparkles", help: "Clean up transcript") {
                        polishEntry = entry
                    }
                }
                OtoRowButton(symbol: "info.circle", help: "Transcript details") {
                    infoEntryID = entry.id
                }
                .popover(isPresented: self.infoBinding(for: entry.id), arrowEdge: .top) {
                    OtoInfoPopover(
                        title: AppNames.displayName(forBundleID: entry.bundleIdentifier),
                        rows: [
                            .init(
                                label: "Saved",
                                value: entry.createdAt.formatted(date: .abbreviated, time: .shortened)
                            ),
                            .init(
                                label: "Cleanup",
                                value: entry.wasCleaned ? "Cleaned with Apple Intelligence" : "Original wording"
                            ),
                        ],
                        actionTitle: entry.wasCleaned && entry.rawText != nil ? "Undo AI edit" : nil,
                        action: entry.wasCleaned && entry.rawText != nil ? { undoCleanup(entry) } : nil
                    )
                }
                OtoRowButton(symbol: "trash", help: "Delete transcript", danger: true) {
                    Task { await history.remove(id: entry.id) }
                }
            }
        }
    }

    private func infoBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { infoEntryID == id },
            set: { if !$0, infoEntryID == id { infoEntryID = nil } }
        )
    }

    /// Split the conditional button style so the compiler doesn't choke on
    /// ternary `ButtonStyle` inference inside the deeply-nested `ForEach`.
    @ViewBuilder
    private func pageButton(number: Int, isCurrent: Bool) -> some View {
        let button = Button("\(number)") { historyPage = number }
            .controlSize(.small)
        if isCurrent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    // MARK: - Plumbing

    /// The switch takes the window's top-right corner, the way the reference
    /// puts it. It routes through `setHistoryEnabled`, so turning off with
    /// entries on file still asks first and the switch never lies.
    private func publishAccessory() {
        chrome.publish(
            .toggle(isOn: historyEnabled, help: "Remember transcripts") { new in
                setHistoryEnabled(new)
            }
        )
    }

    private func holdFootnote() -> OtoEmptyFootnote {
        let keys = KeyNames.chips(for: dispatch.configuration.hold.kind)
        return keys.isEmpty
            ? OtoEmptyFootnote(lead: "Dictate anywhere and it appears here.")
            : OtoEmptyFootnote(lead: "Hold", keys: keys, tail: "to dictate.")
    }

    private static let chips: [OtoEmptyChip] = [
        .init(symbol: "text.alignleft", label: "Last \(HistoryStore.maxEntries)", tint: .violet),
        .init(symbol: "calendar", label: "\(HistoryStore.maxAgeDays) days", tint: .blue),
        .init(symbol: "lock", label: "On this Mac", tint: .green),
    ]

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
        // The row's own glyph becomes the tick — no status line underneath.
        self.copyFlash.flash(entry.id)
    }

    /// Undo AI edit (E1): restores the raw wording on a cleaned entry.
    private func undoCleanup(_ entry: HistoryEntry) {
        Task {
            await history.undoCleanup(id: entry.id)
            self.feedback = "Original wording restored."
            // Nothing else owns this line: let it leave on its own instead of
            // lingering as chrome under the list.
            try? await Task.sleep(for: .seconds(3))
            if self.feedback == "Original wording restored." { self.feedback = nil }
        }
    }
}
