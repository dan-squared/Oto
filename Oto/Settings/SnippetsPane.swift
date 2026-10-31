//
//  SnippetsPane.swift
//  Oto
//
//  Saved expansions. Every control binds the real store; the sheet carries
//  validation.
//
//  One name, one preview line, one cluster: edit, delete. The expansion is
//  copied from the editor (the row stays a readable sentence); the scope it
//  applies in lives behind the pencil's sheet.
//

import SwiftUI

struct SnippetsPane: View {
    let snippets: SnippetStore
    let dispatch: ShortcutDispatch
    let chrome: SettingsChrome

    @State private var editingSnippet: Snippet?
    @State private var addingSnippet = false

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
                OtoRowButton(symbol: "pencil", help: "Edit snippet") {
                    editingSnippet = snippet
                }
                OtoRowButton(symbol: "trash", help: "Delete snippet", danger: true) {
                    Task { await snippets.remove(id: snippet.id) }
                }
            }
        }
    }

    // MARK: - Plumbing

    /// The add action takes the corner; the empty state's button mirrors it.
    private func publishAccessory() {
        chrome.publish(.action(symbol: "plus", help: "Add snippet") { addingSnippet = true })
    }

    /// Copy happens in the editor (the row no longer carries a copy button),
    /// so the footnote teaches the path that exists.
    private func dictationFootnote() -> OtoEmptyFootnote {
        let keys = KeyNames.chips(for: dispatch.configuration.hold.kind)
        return keys.isEmpty
            ? OtoEmptyFootnote(lead: "Nothing inserts itself — open a snippet to copy it.")
            : OtoEmptyFootnote(lead: "Dictate first, then save the words here. Your key is", keys: keys, tail: ".")
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
        // clipboard for nothing). Copy is an explicit command, so a filled
        // draft writes straight through.
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter the text to insert before copying."
            return
        }
        ClipboardWrite.text(expansion)
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
