//
//  DictionaryPane.swift
//  Oto
//
//  Spoken-form → replacement rules. Every control binds the real store;
//  the sheet carries validation + test/preview; deletion confirms.
//

import SwiftUI

struct DictionaryPane: View {
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore

    @State private var editingRule: DictionaryRule?
    @State private var addingRule = false
    @State private var showClearDictionaryConfirm = false

    var body: some View {
        // No "Dictionary" header — the sidebar already says it.
        if dictionary.rules.isEmpty {
            Section {
                ContentUnavailableView(
                    "No dictionary rules",
                    systemImage: "text.book.closed",
                    description: Text("Add a spoken form and its replacement. Rules apply to future dictation.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        } else {
            Section {
                ForEach(dictionary.rules) { rule in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\"\(rule.spoken)\" → \"\(rule.replacement)\"")
                                .font(.system(size: 13))
                            if !rule.bundleIDs.isEmpty {
                                Text(InstalledApps.names(for: rule.bundleIDs))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .opacity(rule.isEnabled ? 1 : 0.45)
                        Spacer(minLength: 8)
                        Button("Edit") { editingRule = rule }
                            .buttonStyle(.borderless)
                        Button("Delete") {
                            Task {
                                await dictionary.remove(id: rule.id)
                                pushRules()
                            }
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingRule = rule }
                }
            }
        }

        Section {
            HStack(spacing: 12) {
                Button("Add rule") { addingRule = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
                Button("Clear") { showClearDictionaryConfirm = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(dictionary.rules.isEmpty)
            }
            OtoPanelNote("Whole words only — never inside links or paths. App rules win in their app.")
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

    private func pushRules() {
        Task { await coordinator.setDictionaryRules(dictionary.rules) }
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
    @State private var bundleIDs: [String] = []
    @State private var isEnabled = true
    @State private var sample = ""
    @State private var error: String?
    @State private var warning: String?

    var body: some View {
        Form {
            Section("Rule") {
                TextField("What you say", text: $spoken)
                TextField("Replacement", text: $replacement)
                // Scope is picked, never typed: names are what people know.
                OtoAppScopePicker(isGlobal: $scopeGlobal, bundleIDs: $bundleIDs)
                Toggle("Enabled", isOn: $isEnabled)
            }
            Section("Try it") {
                TextField("Sample sentence", text: $sample)
                // Same apply path, explicit scope: the preview never lies
                // about app-scoped rules.
                let probe = dictionary.test(
                    sample: sample.isEmpty ? "Type a sentence containing \"\(spoken)\"" : sample,
                    scope: scopeGlobal ? nil : bundleIDs.first,
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
            scopeGlobal = rule.bundleIDs.isEmpty
            bundleIDs = rule.bundleIDs
            isEnabled = rule.isEnabled
            warning = dictionary.precedenceWarning(for: rule)
        }
    }

    private func previewRules() -> [DictionaryRule] {
        var draft = rule ?? DictionaryRule(spoken: " ", replacement: " ")
        draft.spoken = spoken
        draft.replacement = replacement
        draft.bundleIDs = scopeGlobal ? [] : bundleIDs
        draft.isEnabled = true
        return dictionary.rules.filter { $0.id != draft.id } + [draft]
    }

    private func save() {
        Task {
            let scopes = scopeGlobal ? [] : bundleIDs
            if let rule {
                var edited = rule
                edited.spoken = spoken
                edited.replacement = replacement
                edited.bundleIDs = scopes
                edited.isEnabled = isEnabled
                switch await dictionary.update(edited) {
                case .success(let saved): onDone(saved)
                case .failure(let failure): error = failure.errorDescription
                }
            } else {
                switch await dictionary.add(
                    spoken: spoken, replacement: replacement,
                    bundleIDs: scopes, isEnabled: isEnabled
                ) {
                case .success(let saved): onDone(saved)
                case .failure(let failure): error = failure.errorDescription
                }
            }
        }
    }
}
