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
        // No "Snippets" header — the sidebar already says it.
        if snippets.snippets.isEmpty {
            Section {
                ContentUnavailableView(
                    "No snippets",
                    systemImage: "text.quote",
                    description: Text("Save repeated text once, then copy it wherever you need it.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        } else {
            Section {
                ForEach(snippets.snippets) { snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snippet.name)
                            .font(.system(size: 13))
                        Text(snippet.preview())
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if !snippet.bundleIDs.isEmpty {
                            Text(InstalledApps.names(for: snippet.bundleIDs))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 16) {
                            Button("Edit") { editingSnippet = snippet }
                                .buttonStyle(.borderless)
                            Button("Copy") { copySnippet(snippet) }
                                .buttonStyle(.borderless)
                            Button("Delete") {
                                Task { await snippets.remove(id: snippet.id) }
                            }
                            .buttonStyle(.borderless)
                            .tint(.red)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 4)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingSnippet = snippet }
                }
            }
        }

        Section {
            HStack {
                Button("Add snippet") { addingSnippet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            OtoPanelNote("Snippets only insert when you choose — saying the name never expands it.")
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
