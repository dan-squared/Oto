//
//  DictionaryPane.swift
//  Oto
//
//  Spoken-form → replacement rules. Every control binds the real store;
//  the sheet carries validation + test/preview; deletion confirms.
//
//  A rule is one line and a cluster of actions. The scope it applies in and
//  whether it is on live behind the info button — the row itself stays a
//  readable sentence.
//

import SwiftUI

struct DictionaryPane: View {
    let coordinator: DictationCoordinator
    let dictionary: DictionaryStore
    let dispatch: ShortcutDispatch
    let chrome: SettingsChrome

    @State private var editingRule: DictionaryRule?
    @State private var addingRule = false
    @State private var showClearDictionaryConfirm = false
    @State private var infoRuleID: UUID?

    var body: some View {
        Group {
            if dictionary.rules.isEmpty {
                OtoPaneCanvas {
                    OtoEmptyState(
                        symbol: "character.book.closed",
                        title: "Your words, your way",
                        message: "Teach Oto how you say things. A spoken form becomes the replacement every time you dictate.",
                        chips: [
                            .init(symbol: "person.text.rectangle", label: "Names", tint: .violet),
                            .init(symbol: "textformat.abc", label: "Jargon", tint: .blue),
                            .init(symbol: "arrow.right", label: "Shorthand", tint: .green),
                        ],
                        actionTitle: "Add your first rule",
                        action: { addingRule = true },
                        footnote: dictationFootnote("Applies whenever you dictate with")
                    )
                }
            } else {
                OtoPaneForm {
                    Section {
                        ForEach(dictionary.rules) { rule in
                            self.row(for: rule)
                        }
                    }

                    Section {
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            Button("Clear") { showClearDictionaryConfirm = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)
                        }
                        OtoPanelNote("Whole words only — never inside links or paths. App rules win in their app.")
                    }
                }
            }
        }
        .onAppear { publishAccessory() }
        .onChange(of: dictionary.rules.count) { _, _ in publishAccessory() }
        // Probe-only (never posted in normal use): opens the first rule's
        // details so the popover anchor can be checked from a real capture.
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeOpenInfo)) { _ in
            infoRuleID = dictionary.rules.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeCloseInfo)) { _ in
            infoRuleID = nil
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

    // MARK: - Row

    private func row(for rule: DictionaryRule) -> some View {
        HStack(spacing: 10) {
            Text("\"\(rule.spoken)\" → \"\(rule.replacement)\"")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(rule.isEnabled ? 1 : 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editingRule = rule }

            OtoRowActions {
                OtoRowButton(symbol: "info.circle", help: "Rule details") {
                    infoRuleID = rule.id
                }
                // Anchored to the button that opens it: the glass arrow must
                // point at the eye, never at the row's leading edge.
                .popover(isPresented: self.infoBinding(for: rule.id), arrowEdge: .top) {
                    OtoInfoPopover(
                        title: rule.spoken,
                        rows: [
                            .init(label: "Applies in", value: rule.bundleIDs.isEmpty
                                ? "Everywhere"
                                : InstalledApps.names(for: rule.bundleIDs)),
                            .init(label: "Status", value: rule.isEnabled ? "On" : "Off"),
                        ],
                        note: "Becomes “\(rule.replacement)”"
                    )
                }
                OtoRowButton(symbol: "pencil", help: "Edit rule") {
                    editingRule = rule
                }
                OtoRowButton(symbol: "trash", help: "Delete rule", danger: true) {
                    Task {
                        await dictionary.remove(id: rule.id)
                        pushRules()
                    }
                }
            }
        }
    }

    private func infoBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { infoRuleID == id },
            set: { if !$0, infoRuleID == id { infoRuleID = nil } }
        )
    }

    // MARK: - Plumbing

    /// The add action takes the corner: it is this pane's master control, and
    /// the empty state's button does exactly the same thing.
    private func publishAccessory() {
        chrome.publish(.action(symbol: "plus", help: "Add rule") { addingRule = true })
    }

    /// The real hold key, so the footnote teaches the gesture the app is
    /// actually using.
    private func dictationFootnote(_ lead: String) -> OtoEmptyFootnote {
        let keys = KeyNames.chips(for: dispatch.configuration.hold.kind)
        return keys.isEmpty
            ? OtoEmptyFootnote(lead: "\(lead) your shortcut.")
            : OtoEmptyFootnote(lead: lead, keys: keys, tail: ".")
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
