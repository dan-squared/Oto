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
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("“\(rule.spoken)” → “\(rule.replacement)”")
                                    .font(.system(size: 13))
                                    .foregroundStyle(OtoPalette.ink)
                                if let scope = rule.bundleID {
                                    Text(scope)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(OtoPalette.muted)
                                }
                            }
                            .opacity(rule.isEnabled ? 1 : 0.45)
                            Spacer(minLength: 8)
                            OtoQuick("Edit") { editingRule = rule }
                            OtoQuick("Delete", tint: .red) {
                                Task {
                                    await dictionary.remove(id: rule.id)
                                    pushRules()
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .onTapGesture { editingRule = rule }
                    }
                }
            }
            HStack(spacing: 12) {
                OtoPill("Add rule") { addingRule = true }
                Spacer(minLength: 0)
                OtoPill("Clear", tint: .red) { showClearDictionaryConfirm = true }
                    .disabled(dictionary.rules.isEmpty)
            }
            Text("Whole words only — never inside links or paths. App rules win in their app.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
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
                    // Scope is typed by hand: a "use frontmost" button
                    // cannot work from Settings (clicking it makes Oto
                    // frontmost, so it would capture app.Oto). Removed
                    // until capture happens while the target app is front.
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
