//
//  SnippetsPane.swift
//  Oto
//
//  Saved expansions. Every control binds the real store; the sheet carries
//  validation; copying keeps the clipboard discipline.
//
//  One name, one preview line, one cluster: copy, details, edit, delete. The
//  full expansion and the apps it applies in live behind the info button.
//

import AppKit
import SwiftUI

struct SnippetsPane: View {
    let snippets: SnippetStore
    let dispatch: ShortcutDispatch
    let chrome: SettingsChrome

    @State private var editingSnippet: Snippet?
    @State private var addingSnippet = false
    @State private var confirmCopyOverwrite = false
    @State private var pendingCopySnippet: Snippet?
    @State private var infoSnippetID: UUID?
    @State private var copyFlash = OtoCopyFlash()

    var body: some View {
        Group {
            if snippets.snippets.isEmpty {
                OtoPaneCanvas {
                    OtoEmptyState(
                        symbol: "text.quote",
                        title: "Text you say once, use often",
                        message: "Save the paragraph, the address, the signature. Copy it from here whenever you need it.",
                        chips: [
                            .init(symbol: "signature", label: "Signature", tint: .violet),
                            .init(symbol: "mappin.and.ellipse", label: "Address", tint: .blue),
                            .init(symbol: "link", label: "Meeting link", tint: .green),
                        ],
                        actionTitle: "Save your first snippet",
                        action: { addingSnippet = true },
                        footnote: dictationFootnote()
                    )
                }
            } else {
                OtoPaneForm {
                    Section {
                        ForEach(snippets.snippets) { snippet in
                            self.row(for: snippet)
                        }
                    }

                    Section {
                        OtoPanelNote("Snippets only insert when you choose — saying the name never expands it.")
                    }
                }
            }
        }
        .onAppear { publishAccessory() }
        .onChange(of: snippets.snippets.count) { _, _ in publishAccessory() }
        // Probe-only (never posted in normal use): first row's details + copy.
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeOpenInfo)) { _ in
            infoSnippetID = snippets.snippets.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeCloseInfo)) { _ in
            infoSnippetID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeCopyFirst)) { _ in
            if let first = snippets.snippets.first { writeSnippet(first) }
        }
        .sheet(isPresented: $addingSnippet) {
            SnippetEditor(snippet: nil, snippets: snippets) {
                addingSnippet = false
            }
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditor(snippet: snippet, snippets: snippets) {
                editingSnippet = nil
            }
        }
        .confirmationDialog(
            "Replace clipboard contents?",
            isPresented: $confirmCopyOverwrite,
            titleVisibility: .visible
        ) {
            Button("Replace") {
                if let snippet = pendingCopySnippet { writeSnippet(snippet) }
                pendingCopySnippet = nil
            }
            Button("Cancel", role: .cancel) { pendingCopySnippet = nil }
        } message: {
            Text("The clipboard holds text Oto didn't place.")
        }
    }

    // MARK: - Row

    private func row(for snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(snippet.preview())
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editingSnippet = snippet }

            OtoRowActions {
                OtoRowButton(
                    symbol: self.copyFlash.isCopied(snippet.id) ? "checkmark" : "doc.on.doc",
                    help: self.copyFlash.isCopied(snippet.id) ? "Copied" : "Copy snippet",
                    tint: self.copyFlash.isCopied(snippet.id) ? OtoStatus.Tone.ok.color : OtoPalette.ink
                ) {
                    copySnippet(snippet)
                }
                OtoRowButton(symbol: "info.circle", help: "Snippet details") {
                    infoSnippetID = snippet.id
                }
                .popover(isPresented: self.infoBinding(for: snippet.id), arrowEdge: .top) {
                    OtoInfoPopover(
                        title: snippet.name,
                        rows: [
                            .init(label: "Applies in", value: snippet.bundleIDs.isEmpty
                                ? "Everywhere"
                                : InstalledApps.names(for: snippet.bundleIDs)),
                            .init(label: "Length", value: "\(snippet.expansion.count) characters"),
                        ],
                        note: snippet.expansion
                    )
                }
                OtoRowButton(symbol: "pencil", help: "Edit snippet") {
                    editingSnippet = snippet
                }
                OtoRowButton(symbol: "trash", help: "Delete snippet", danger: true) {
                    Task { await snippets.remove(id: snippet.id) }
                }
            }
        }
    }

    private func infoBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { infoSnippetID == id },
            set: { if !$0, infoSnippetID == id { infoSnippetID = nil } }
        )
    }

    // MARK: - Plumbing

    /// The add action takes the corner; the empty state's button mirrors it.
    private func publishAccessory() {
        chrome.publish(.action(symbol: "plus", help: "Add snippet") { addingSnippet = true })
    }

    private func dictationFootnote() -> OtoEmptyFootnote {
        let keys = KeyNames.chips(for: dispatch.configuration.hold.kind)
        return keys.isEmpty
            ? OtoEmptyFootnote(lead: "Nothing inserts itself — you choose when to copy.")
            : OtoEmptyFootnote(lead: "Dictate first, then copy. Your key is", keys: keys, tail: ".")
    }

    private func copySnippet(_ snippet: Snippet) {
        // Overwrite guard (clipboard discipline): foreign content confirms.
        if ClipboardOverwriteGuard.shouldConfirm(board: .general) {
            pendingCopySnippet = snippet
            confirmCopyOverwrite = true
            return
        }
        writeSnippet(snippet)
    }

    private func writeSnippet(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.expansion, forType: .string)
        ClipboardOverwriteGuard.markAsOto(NSPasteboard.general)
        self.copyFlash.flash(snippet.id)
    }
}

// MARK: - Snippet editor sheet

private struct SnippetEditor: View {
    let snippet: Snippet?
    let snippets: SnippetStore
    let onDone: () -> Void

    @State private var name = ""
    @State private var expansion = ""
    @State private var scopeGlobal = true
    @State private var bundleIDs: [String] = []
    @State private var error: String?
    @State private var confirmCopyOverwrite = false

    var body: some View {
        Form {
            Section("Snippet") {
                TextField("Name", text: $name)
                TextEditor(text: $expansion)
                    .frame(minHeight: 90)
                // Scope is picked, never typed (see DictionaryPane).
                OtoAppScopePicker(isGlobal: $scopeGlobal, bundleIDs: $bundleIDs)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { onDone() }
                Spacer()
                Button("Copy expansion") { copyDraft() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { seed() }
        .confirmationDialog(
            "Replace clipboard contents?",
            isPresented: $confirmCopyOverwrite,
            titleVisibility: .visible
        ) {
            Button("Replace") { writeDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clipboard holds text Oto didn't place.")
        }
    }

    private func seed() {
        if let snippet {
            name = snippet.name
            expansion = snippet.expansion
            scopeGlobal = snippet.bundleIDs.isEmpty
            bundleIDs = snippet.bundleIDs
        }
    }

    private func copyDraft() {
        // Empty drafts refuse with guidance (writing "" would destroy the
        // clipboard for nothing). Otherwise the overwrite guard decides.
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter the text to insert before copying."
            return
        }
        if ClipboardOverwriteGuard.shouldConfirm(board: .general) {
            confirmCopyOverwrite = true
            return
        }
        writeDraft()
    }

    private func writeDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(expansion, forType: .string)
        ClipboardOverwriteGuard.markAsOto(NSPasteboard.general)
    }

    private func save() {
        Task {
            let scopes = scopeGlobal ? [] : bundleIDs
            let result: Result<Snippet, SnippetValidationError>
            if var snippet {
                snippet.name = name
                snippet.expansion = expansion
                snippet.bundleIDs = scopes
                result = await snippets.update(snippet)
            } else {
                result = await snippets.add(name: name, expansion: expansion, bundleIDs: scopes)
            }
            switch result {
            case .success: onDone()
            case .failure(let failure): error = failure.errorDescription
            }
        }
    }
}
