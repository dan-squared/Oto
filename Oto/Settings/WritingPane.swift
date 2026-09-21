//
//  WritingPane.swift
//  Oto
//
//  Phase 6A: dictionary + snippets behind one toolbar tab. Subsections ride
//  an in-content segmented Picker (D3: never a nested TabView, never six flat
//  tabs). Every control binds a real store; sheets carry validation +
//  test/preview; transfer uses fileImporter/fileExporter; deletion confirms.
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
        Form {
            Picker("Writing", selection: $section) {
                ForEach(PaneSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .dictionary {
                dictionarySection
            } else {
                snippetSection
            }
        }
        .formStyle(.grouped)
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
        Section("Dictionary") {
            if dictionary.rules.isEmpty {
                ContentUnavailableView(
                    "No dictionary rules",
                    systemImage: "text.book.closed",
                    description: Text("Add a spoken form and its replacement. Rules apply to future dictation.")
                )
            } else {
                ForEach(dictionary.rules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("“\(rule.spoken)” → “\(rule.replacement)”")
                            Text(rule.bundleID ?? "Everywhere")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { newValue in
                                _ = Task { await toggleRule(rule, enabled: newValue) }
                            }
                        ))
                        .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingRule = rule }
                }
                .onDelete { offsets in
                    Task {
                        for index in offsets {
                            await dictionary.remove(id: dictionary.rules[index].id)
                        }
                        pushRules()
                    }
                }
            }
            HStack {
                Button("Add rule") { addingRule = true }
                Spacer()
                Button("Import") { showImporter = true }
                Button("Export") { runExport() }
                Button("Clear", role: .destructive) { showClearDictionaryConfirm = true }
                    .disabled(dictionary.rules.isEmpty)
            }
            if let importReport {
                Text(importReport)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Rules replace whole words only — never inside links, emails, or file paths. App-scoped rules win over global ones in their app.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        Section("Snippets") {
            if snippets.snippets.isEmpty {
                ContentUnavailableView(
                    "No snippets",
                    systemImage: "text.quote",
                    description: Text("Save repeated text once, then copy it wherever you need it.")
                )
            } else {
                ForEach(snippets.snippets) { snippet in
                    VStack(alignment: .leading) {
                        Text(snippet.name)
                        Text(snippet.preview())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(snippet.bundleID ?? "Everywhere")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingSnippet = snippet }
                    .contextMenu {
                        Button("Copy expansion") { copySnippet(snippet) }
                    }
                }
                .onDelete { offsets in
                    Task {
                        for index in offsets {
                            await snippets.remove(id: snippets.snippets[index].id)
                        }
                    }
                }
            }
            HStack {
                Button("Add snippet") { addingSnippet = true }
                Spacer()
            }
            Text("Snippets insert only when you choose — speaking a snippet's name never expands it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
