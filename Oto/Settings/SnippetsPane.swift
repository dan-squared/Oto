//
//  SnippetsPane.swift
//  Oto
//
//  Saved expansions. Every control binds the real store; the sheet
//  carries validation; deletion is per-row.
//

import AppKit
import SwiftUI

struct SnippetsPane: View {
    let snippets: SnippetStore

    @State private var editingSnippet: Snippet?
    @State private var addingSnippet = false
    @State private var confirmCopyOverwrite = false
    @State private var pendingCopySnippet: Snippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "Snippets")
            if snippets.snippets.isEmpty {
                OtoCard {
                    OtoNothing(
                        systemName: "text.quote",
                        text: "No snippets",
                        detail: "Save repeated text once, then copy it wherever you need it."
                    )
                }
            } else {
                OtoCard {
                    ForEach(Array(snippets.snippets.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { OtoRule() }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(snippet.name)
                                .font(.system(size: 13))
                                .foregroundStyle(OtoPalette.ink)
                            Text(snippet.preview())
                                .font(.system(size: 11.5))
                                .foregroundStyle(OtoPalette.muted)
                                .lineLimit(2)
                            if let scope = snippet.bundleID {
                                Text(scope)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(OtoPalette.faint)
                            }
                            HStack(spacing: 16) {
                                OtoQuick("Edit") { editingSnippet = snippet }
                                OtoQuick("Copy") { copySnippet(snippet) }
                                OtoQuick("Delete", tint: .red) {
                                    Task { await snippets.remove(id: snippet.id) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .onTapGesture { editingSnippet = snippet }
                    }
                }
            }
            HStack {
                OtoPill("Add snippet") { addingSnippet = true }
                Spacer(minLength: 0)
            }
            Text("Snippets only insert when you choose — saying the name never expands it.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
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
    @State private var bundleID = ""
    @State private var error: String?
    @State private var confirmCopyOverwrite = false

    var body: some View {
        Form {
            Section("Snippet") {
                TextField("Name", text: $name)
                TextEditor(text: $expansion)
                    .frame(minHeight: 90)
                Picker("Applies", selection: $scopeGlobal) {
                    Text("Everywhere").tag(true)
                    Text("One app").tag(false)
                }
                .pickerStyle(.segmented)
                if !scopeGlobal {
                    TextField("App bundle ID", text: $bundleID)
                        .font(.caption)
                    // Frontmost Fill (mirrors the dictionary editor):
                    // manual field stays for the rest.
                    Button("Use frontmost app") {
                        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                            bundleID = id
                        }
                    }
                    .font(.caption)
                }
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
            scopeGlobal = snippet.bundleID == nil
            bundleID = snippet.bundleID ?? ""
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
            let scope = scopeGlobal ? nil : bundleID
            let result: Result<Snippet, SnippetValidationError>
            if var snippet {
                snippet.name = name
                snippet.expansion = expansion
                snippet.bundleID = scope
                result = await snippets.update(snippet)
            } else {
                result = await snippets.add(name: name, expansion: expansion, bundleID: scope)
            }
            switch result {
            case .success: onDone()
            case .failure(let failure): error = failure.errorDescription
            }
        }
    }
}
