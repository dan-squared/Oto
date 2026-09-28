//
//  WritingPane.swift
//  Oto
//
//  Dictionary + snippets in one page. Subsections ride an in-content
//  segmented control (never a nested TabView). Every control binds a real
//  store; sheets carry validation + test/preview; transfer uses
//  fileImporter/fileExporter; deletion confirms. Same logic as before —
//  only the surface changed.
//

import SwiftUI
import UniformTypeIdentifiers

/// Export wrapper: FileDocument (the fileExporter overload demands it —
/// a plain String does not satisfy the document-based exporter).
struct DictionaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let json: String

    init(json: String) {
        self.json = json
    }

    init(configuration: ReadConfiguration) throws {
        // Reading back is unsupported (import uses fileImporter + decoder).
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(json.utf8))
    }
}

struct WritingPane: View {
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let snippets: SnippetStore

    enum PaneSection: String, CaseIterable, Identifiable {
        case dictionary = "Dictionary"
        case snippets = "Snippets"
        var id: String { rawValue }
    }

    @State private var section: PaneSection = .dictionary
    @State private var editingRule: DictionaryRule?
    @State private var addingRule = false
    @State private var editingSnippet: Snippet?
    @State private var addingSnippet = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: DictionaryExportDocument?
    @State private var importReport: String?
    @State private var showClearDictionaryConfirm = false

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

            if section == .dictionary {
                dictionarySection
            } else {
                snippetSection
            }
        }
        .sheet(isPresented: $addingRule) {
            DictionaryRuleEditor(rule: nil, dictionary: dictionary) { saved in
                addingRule = false
                if saved != nil { pushRules() }
            }
        }
        .sheet(item: $editingRule) { rule in
            DictionaryRuleEditor(rule: rule, dictionary: dictionary) { saved in
                editingRule = nil
                if saved != nil { pushRules() }
            }
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            runImport(result)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "oto-dictionary.json"
        ) { _ in }
        .confirmationDialog(
            "Delete all dictionary rules?",
            isPresented: $showClearDictionaryConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(dictionary.rules.count) rules", role: .destructive) {
                Task {
                    for rule in dictionary.rules {
                        await dictionary.remove(id: rule.id)
                    }
                    pushRules()
                }
            }
        } message: {
            Text("This removes every dictionary rule on this Mac. Cannot be undone.")
        }
    }

    // MARK: - Dictionary

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "Dictionary")
            if dictionary.rules.isEmpty {
                OtoCard {
                    OtoNothing(
                        systemName: "text.book.closed",
                        text: "No dictionary rules",
                        detail: "Add a spoken form and its replacement. Rules apply to future dictation."
                    )
                }
            } else {
                OtoCard {
                    ForEach(Array(dictionary.rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { OtoRule() }
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("“\(rule.spoken)” → “\(rule.replacement)”")
                                    .font(.system(size: 13))
                                    .foregroundStyle(OtoPalette.ink)
                                Text(rule.bundleID ?? "Everywhere")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(OtoPalette.muted)
                            }
                            Spacer(minLength: 8)
                            OtoSwitch(on: Binding(
                                get: { rule.isEnabled },
                                set: { newValue in
                                    _ = Task { await toggleRule(rule, enabled: newValue) }
                                }
                            ))
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 11)
                        HStack {
                            OtoQuick("Delete", tint: .red) {
                                Task {
                                    await dictionary.remove(id: rule.id)
                                    pushRules()
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 11)
                        .contentShape(Rectangle())
                        .onTapGesture { editingRule = rule }
                    }
                }
            }
            HStack(spacing: 12) {
                OtoPill("Add rule") { addingRule = true }
                Spacer(minLength: 0)
                OtoPill("Import") { showImporter = true }
                OtoPill("Export") { runExport() }
                OtoPill("Clear", tint: .red) { showClearDictionaryConfirm = true }
                    .disabled(dictionary.rules.isEmpty)
            }
            if let importReport {
                Text(importReport)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                    .padding(.leading, 2)
            }
            Text("Rules replace whole words only — never inside links, emails, or file paths. App-scoped rules win over global ones in their app.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
        }
    }

    private func toggleRule(_ rule: DictionaryRule, enabled: Bool) async {
        await dictionary.setEnabled(id: rule.id, enabled: enabled)
        pushRules()
    }

    private func pushRules() {
        Task { await coordinator.setDictionaryRules(dictionary.rules) }
    }

    private func runExport() {
        do {
            let data = try dictionary.exportData(snapshot: dictionary.rules)
            exportDocument = DictionaryExportDocument(json: String(decoding: data, as: UTF8.self))
            showExporter = true
        } catch {
            importReport = "Export failed."
        }
    }

    private func runImport(_ result: Result<URL, any Error>) {
        switch result {
        case .failure:
            importReport = "Import cancelled."
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Task {
                    let report = await dictionary.importData(data)
                    var lines = ["Imported \(report.imported)."]
                    if report.skippedDuplicates > 0 {
                        lines.append("Skipped \(report.skippedDuplicates) duplicates.")
                    }
                    for rejected in report.rejected.prefix(3) {
                        lines.append("Row \(rejected.row): \(rejected.reason)")
                    }
                    importReport = lines.joined(separator: " ")
                    pushRules()
                }
            } catch {
                importReport = "Could not read that file."
            }
        }
    }

    // MARK: - Snippets

    private var snippetSection: some View {
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snippet.name)
                                .font(.system(size: 13))
                                .foregroundStyle(OtoPalette.ink)
                            Text(snippet.preview())
                                .font(.system(size: 11.5))
                                .foregroundStyle(OtoPalette.muted)
                                .lineLimit(2)
                            Text(snippet.bundleID ?? "Everywhere")
                                .font(.system(size: 11.5))
                                .foregroundStyle(OtoPalette.faint)
                            HStack(spacing: 12) {
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
            Text("Snippets insert only when you choose — speaking a snippet's name never expands it.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
        }
    }

    private func copySnippet(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.expansion, forType: .string)
    }
}

// MARK: - Rule editor sheet

private struct DictionaryRuleEditor: View {
    let rule: DictionaryRule?
    let dictionary: DictionaryStore
    let onDone: (DictionaryRule?) -> Void

    @State private var spoken = ""
    @State private var replacement = ""
    @State private var scopeGlobal = true
    @State private var bundleID = ""
    @State private var isEnabled = true
    @State private var sample = ""
    @State private var error: String?
    @State private var warning: String?

    var body: some View {
        Form {
            Section("Rule") {
                TextField("What you say", text: $spoken)
                TextField("Replacement", text: $replacement)
                Picker("Applies", selection: $scopeGlobal) {
                    Text("Everywhere").tag(true)
                    Text("One app").tag(false)
                }
                .pickerStyle(.segmented)
                if !scopeGlobal {
                    TextField("App bundle ID (e.g. com.apple.Mail)", text: $bundleID)
                        .font(.caption)
                }
                Toggle("Enabled", isOn: $isEnabled)
            }
            Section("Try it") {
                TextField("Sample sentence", text: $sample)
                // Same apply path, explicit scope: the preview never lies
                // about app-scoped rules.
                let probe = dictionary.test(
                    sample: sample.isEmpty ? "Type a sentence containing “\(spoken)”" : sample,
                    scope: scopeGlobal ? nil : bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                    rules: previewRules()
                )
                Text(probe)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { onDone(nil) }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
        .onAppear { seed() }
    }

    private func seed() {
        if let rule {
            spoken = rule.spoken
            replacement = rule.replacement
            scopeGlobal = rule.bundleID == nil
            bundleID = rule.bundleID ?? ""
            isEnabled = rule.isEnabled
            warning = dictionary.precedenceWarning(for: rule)
        }
    }

    private func previewRules() -> [DictionaryRule] {
        var draft = rule ?? DictionaryRule(spoken: " ", replacement: " ")
        draft.spoken = spoken
        draft.replacement = replacement
        draft.bundleID = scopeGlobal ? nil : bundleID
        draft.isEnabled = true
        return dictionary.rules.filter { $0.id != draft.id } + [draft]
    }

    private func save() {
        Task {
            let scope = scopeGlobal ? nil : bundleID
            if let rule {
                var edited = rule
                edited.spoken = spoken
                edited.replacement = replacement
                edited.bundleID = scope
                edited.isEnabled = isEnabled
                switch await dictionary.update(edited) {
                case .success(let saved): onDone(saved)
                case .failure(let failure): error = failure.errorDescription
                }
            } else {
                switch await dictionary.add(
                    spoken: spoken, replacement: replacement,
                    bundleID: scope, isEnabled: isEnabled
                ) {
                case .success(let saved): onDone(saved)
                case .failure(let failure): error = failure.errorDescription
                }
            }
        }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(expansion, forType: .string)
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
