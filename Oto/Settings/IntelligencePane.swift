//
//  IntelligencePane.swift
//  Oto
//
//  Apple Intelligence: status + master switch + Auto Cleanup levels.
//  E1: None/Light/Medium pre-insertion cleanup (the writing question, never
//  a timing question). The Transforms card (E2) joins below the cleanup card
//  — no dead rows: every row here binds a live backend today.
//

import AppKit
import SwiftUI

struct IntelligencePane: View {
    let polish: any PolishServing
    let transforms: TransformDispatch
    let chrome: SettingsChrome

    /// Off until the person asks for it: the same opt-in shape as History.
    /// Cleanup and transforms both read this key at run time, so "off" is
    /// honest — no shortcut fires, no cleanup runs.
    @AppStorage(CleanupSettings.enabledKey) private var enabled = false
    @AppStorage(CleanupSettings.levelKey) private var levelRaw = CleanupLevel.none.rawValue
    /// History switch mirror (same key as HistoryPane): the Auto Cleanup
    /// footnote below must not promise raw-word recovery while History is
    /// off — with History off, cleaned wording inserts and the original
    /// exists nowhere.
    @AppStorage("app.Oto.historyEnabled") private var historyEnabled = false
    @State private var availability: PolishAvailability = .available
    @State private var shortcuts = TransformShortcuts.default()
    @State private var audit: [(slot: ShortcutSlotID, message: String)] = []
    @State private var recording: TransformPreset?
    @State private var acceptedRecording: TransformPreset?
    @State private var messages: [TransformPreset: String] = [:]
    /// Custom prompt editors (Phase 9): mirrors of the UserDefaults store,
    /// loaded in refreshTransforms, saved debounced (never per keystroke).
    @State private var customName = ""
    @State private var customInstruction = ""
    @State private var customSaveTask: Task<Void, Never>?
    @State private var appOverrides: [AppCleanupOverride] = []
    @State private var installedApps: [InstalledApp] = InstalledApps.cached
    @State private var addingAppRule = false
    @State private var editingAppRule: AppCleanupOverride?

    /// Bound through the raw string so a future value stored by a newer
    /// build never crashes this one — unknown reads as None (fail-safe:
    /// future values can never trigger unbuilt behavior, same rule as
    /// `CleanupBehavior.current`).
    private var level: Binding<CleanupLevel> {
        Binding(
            get: { CleanupLevel(rawValue: levelRaw) ?? .none },
            set: { levelRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if !enabled {
                self.offState
            } else {
                self.settings
            }
        }
        .onAppear {
            CleanupMigrator.migrateIfNeeded()
            availability = polish.availability()
            self.publishAccessory()
            refreshTransforms()
            refreshAppOverrides()
            if enabled, level.wrappedValue != .none, availability == .available {
                polish.prewarm(job: .cleanup(level.wrappedValue))
            }
        }
        .task {
            installedApps = await InstalledApps.load()
        }
        .onChange(of: enabled) { _, on in
            self.availability = self.polish.availability()
            self.publishAccessory()
            guard on else { return }
            self.refreshTransforms()
            self.refreshAppOverrides()
            if self.level.wrappedValue != .none, self.availability == .available {
                self.polish.prewarm(job: .cleanup(self.level.wrappedValue))
            }
        }
        .onDisappear {
            flushCustomSave()
            if recording != nil {
                recording = nil
                acceptedRecording = nil
                transforms.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAppOverrides()
        }
        .sheet(isPresented: $addingAppRule) {
            AppCleanupRuleEditor(
                existingRule: nil,
                blockedBundleIDs: Set(appOverrides.map(\.bundleID))
            ) { saved in
                addingAppRule = false
                if let saved {
                    CleanupAppOverrides.upsert(saved)
                    refreshAppOverrides()
                }
            }
        }
        .sheet(item: $editingAppRule) { rule in
            AppCleanupRuleEditor(
                existingRule: rule,
                blockedBundleIDs: Set(appOverrides.map(\.bundleID)).subtracting([rule.bundleID])
            ) { saved in
                editingAppRule = nil
                if let saved {
                    if saved.bundleID != rule.bundleID {
                        CleanupAppOverrides.remove(bundleID: rule.bundleID)
                    }
                    CleanupAppOverrides.upsert(saved)
                    refreshAppOverrides()
                }
            }
        }
    }

    // MARK: - Off state

    /// The pane's opt-in state, in the same vocabulary as Dictionary,
    /// Snippets and History: what it does, what it runs on, one button.
    private var offState: some View {
        OtoPaneCanvas {
            OtoEmptyState(
                symbol: "sparkles",
                title: self.unavailableCopy == nil ? "Apple Intelligence is off" : "Not available",
                message: self.unavailableCopy
                    ?? "Oto can tidy your words on this Mac — fillers, grammar, and a light rewrite. Nothing is uploaded.",
                chips: [
                    .init(symbol: "wand.and.stars", label: "Cleanup", color: .crimson),
                    .init(symbol: "arrow.triangle.2.circlepath", label: "Transforms", color: .ocean),
                    .init(symbol: "cpu", label: "On-device", color: .violet),
                ],
                actionTitle: self.unavailableCopy == nil ? "Turn On Apple Intelligence" : nil,
                action: self.unavailableCopy == nil ? { enabled = true } : nil,
                footnote: OtoEmptyFootnote(
                    lead: "Runs on this Mac's Neural Engine. Turn it off anytime."
                )
            )
        }
    }

    private var unavailableCopy: String? {
        if case .unavailable(let copy) = availability { return copy }
        return nil
    }

    // MARK: - Settings

    private var settings: some View {
        OtoPaneForm {
            // No "Intelligence" header — the sidebar already says it.

            Section {
                LabeledContent("Apple Intelligence") {
                    OtoStatus(text: statusText, tone: statusTone)
                }
                if let statusDetail {
                    OtoPanelNote(statusDetail)
                }
            }

            Section {
                OtoSegmented(
                    options: [(.none, "None"), (.light, "Light"), (.medium, "Medium")],
                    selection: level
                )
                Text(cleanupDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                OtoPanelNote(cleanupFooting(historyEnabled: historyEnabled))
            } header: {
                Text("Auto Cleanup")
            }
            .disabled(!enabled)

            Section {
                ForEach(sortedAppOverrides) { rule in
                    appOverrideRow(for: rule)
                }
                HStack {
                    Button("Add App Rule…") {
                        addingAppRule = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                OtoPanelNote("Override cleanup per app — like Off in Terminal or a custom style in Slack.")
            } header: {
                Text("Per-App Rules")
            }
            .disabled(!enabled)

            Section {
                OtoPanelNote("Select text in any app, press the shortcut — the pill shows the rewrite while it runs.")
                ForEach(TransformPreset.allCases, id: \.rawValue) { preset in
                    transformRow(for: preset)
                }
                OtoPanelNote("On-device only — transcripts and prompts never leave this Mac.")
            } header: {
                Text("My Transforms")
            }
            .disabled(!enabled)
        }
    }

    /// The switch takes the detail column's top-right corner, exactly like
    /// History's: the pane's master control is never buried in a card. Hidden
    /// when Apple Intelligence is unavailable and off so an unsupported Mac
    /// never exposes an enable switch that cannot do anything.
    private func publishAccessory() {
        if case .unavailable = availability, !enabled {
            chrome.publish(nil)
            return
        }
        chrome.publish(
            .toggle(isOn: enabled, help: "Use Apple Intelligence") { new in
                enabled = new
            }
        )
    }

    // MARK: - Transforms

    private func transformRow(for preset: TransformPreset) -> some View {
        let kind = shortcuts.kind(for: preset)
        let isRecording = recording == preset
        let othersRecording = recording != nil && !isRecording
        return VStack(alignment: .leading, spacing: 6) {
            // Custom editors (Phase 9): name + instruction above the chip.
            // Fixed presets show title/tagline only — one branch, same row.
            if preset == .custom {
                TextField("Name (e.g. Bullets)", text: $customName)
                    .font(.system(size: 13))
                    .accessibilityLabel("Custom transform name")
                    .onChange(of: customName) { _, _ in scheduleCustomSave() }
                TextEditor(text: $customInstruction)
                    .font(.system(size: 12))
                    .frame(minHeight: 56)
                    .accessibilityLabel("Custom transform instruction")
                    .onChange(of: customInstruction) { _, _ in scheduleCustomSave() }
                if customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Names the LIVE shortcut, never a hardcoded ⌘4: the
                    // guidance must survive a re-record.
                    Text("Write your instruction — \(transformShortcutLabel(kind: kind)) stays idle until you do.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(preset.tagline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                OtoShortcutField(
                    chips: KeyNames.chips(for: kind),
                    isRecording: false,
                    active: recording == preset,
                    recordLabel: "\(preset.displayName) shortcut, \(transformShortcutLabel(kind: kind)). Activate to record a new shortcut.",
                    onRecord: {
                        transforms.stop()
                        acceptedRecording = nil
                        recording = preset
                    }
                )
                .disabled(othersRecording)
                .popover(isPresented: Binding(
                    get: { recording == preset },
                    set: {
                        guard !$0, recording == preset else { return }
                        dismissRecorder(for: preset)
                    }
                ), arrowEdge: .top) {
                    TransformShortcutCapturePopover(
                        isListening: Binding(
                            get: { recording == preset },
                            set: {
                                guard !$0, recording == preset else { return }
                                dismissRecorder(for: preset)
                            }
                        ),
                        hasShortcut: !KeyNames.chips(for: kind).isEmpty,
                        onCapture: { modifiers, keyCode, conflicts in
                            captureTransform(
                                preset: preset,
                                kind: .combo(modifiers: modifiers, keyCode: keyCode),
                                conflicts: conflicts
                            )
                        },
                        onCaptureModifier: { _ in
                            let message = "Transforms need a combination like ⌘1 — bare keys would fire while you type."
                            messages[preset] = message
                            return message
                        },
                        onClear: {
                            transforms.clearShortcut(for: preset)
                            transforms.start()
                            recording = nil
                            acceptedRecording = nil
                            messages[preset] = nil
                            refreshTransforms()
                        },
                        onCancel: {
                            transforms.start()
                            recording = nil
                            acceptedRecording = nil
                            messages[preset] = nil
                        },
                        onInvalid: { reason in
                            NSSound.beep()
                            messages[preset] = reason.message
                        }
                    )
                }
            }
            // Only while no recorder is open: during recording the monitors
            // are stopped on purpose, so every "couldn't register" would be a
            // false alarm, and the recorder's glass already states refusals.
            if recording == nil, let message = messages[preset] ?? auditMessage(for: preset) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(width: 16, height: 16)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else if recording == nil, !transforms.isLive(preset) {
                // Registered combos that the OS refused (another app holds
                // the hotkey): named, never silently dead — except empty
                // slots, which claim nothing.
                if kind != .unassigned {
                    Text("Couldn't register — already used by another app. Pick a different one.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// VoiceOver label for a transform chip ("no shortcut" for empty slots —
    /// `shortLabel` has no unassigned wording, so it lives here, next to
    /// its only caller).
    private func transformShortcutLabel(kind: ShortcutTrigger.Kind) -> String {
        if case .unassigned = kind { return "no shortcut" }
        return KeyNames.shortLabel(for: kind)
    }

    /// Load-time audit message for one preset's slot, if any (grandfathered
    /// violations are named, never silently cleared).
    private func auditMessage(for preset: TransformPreset) -> String? {
        audit.first { $0.slot == .transform(preset) }?.message
    }

    private func captureTransform(
        preset: TransformPreset,
        kind: ShortcutTrigger.Kind,
        conflicts: [RecorderConflict]
    ) -> String? {
        if ShortcutRecorderConflicts.blocksSaving(conflicts) {
            let message = ShortcutRecorderConflicts.describe(conflicts)
            messages[preset] = message
            refreshTransforms()
            return message
        }
        let kinds = transforms.currentDictationKinds()
        if let advisory = TransformShortcutGate.advisory(
            kind: kind, preset: preset,
            transforms: shortcuts, hold: kinds.hold, handsFree: kinds.handsFree
        ) {
            messages[preset] = advisory
            refreshTransforms()
            return advisory
        }
        if transforms.updateShortcut(kind, for: preset) == .blocked {
            let message = "Already in use — pick a different one."
            messages[preset] = message
            refreshTransforms()
            return message
        } else {
            messages[preset] = nil
        }
        if messages[preset] == nil, !conflicts.isEmpty {
            messages[preset] = ShortcutRecorderConflicts.describe(conflicts)
        }
        acceptedRecording = preset
        refreshTransforms()
        transforms.start()
        // The recorder flashes green and dismisses itself; clearing `recording`
        // here would close the popover before the confirmation is visible.
        return nil
    }

    private func dismissRecorder(for preset: TransformPreset) {
        transforms.start()
        recording = nil
        // Keep non-blocking conflict warnings produced by an accepted save;
        // clear only refusal copy left over from an unaccepted attempt.
        if acceptedRecording != preset {
            messages[preset] = nil
        }
        acceptedRecording = nil
    }

    private func refreshTransforms() {
        shortcuts = transforms.shortcuts
        let kinds = transforms.currentDictationKinds()
        audit = ShortcutAudit.violations(
            hold: kinds.hold, handsFree: kinds.handsFree, transforms: shortcuts
        )
        // Custom editors mirror the store, but never clobber in-flight edits
        // while a debounced save is pending.
        if customSaveTask == nil {
            let custom = CustomPrompt.load()
            customName = custom.name
            customInstruction = custom.instruction
        }
    }

    /// Debounced custom-prompt save: 0.5s after the last keystroke.
    /// Sanitizes on write only — the fields never yank in-flight text.
    private func scheduleCustomSave() {
        customSaveTask?.cancel()
        customSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            CustomPrompt(
                name: CustomPrompt.sanitizeName(customName),
                instruction: CustomPrompt.sanitizeInstruction(customInstruction)
            ).save()
            customSaveTask = nil
        }
    }

    private func flushCustomSave() {
        guard let task = customSaveTask else { return }
        task.cancel()
        customSaveTask = nil
        CustomPrompt(
            name: CustomPrompt.sanitizeName(customName),
            instruction: CustomPrompt.sanitizeInstruction(customInstruction)
        ).save()
    }

    // MARK: - Per-App Rules

    private func refreshAppOverrides() {
        appOverrides = CleanupAppOverrides.load()
    }

    private var sortedAppOverrides: [AppCleanupOverride] {
        appOverrides.sorted { lhs, rhs in
            let lhsName = displayName(for: lhs.bundleID)
            let rhsName = displayName(for: rhs.bundleID)
            let order = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.bundleID < rhs.bundleID
        }
    }

    private func displayName(for normalizedBundleID: String) -> String {
        if let app = resolvedApp(for: normalizedBundleID) {
            return app.name
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier.map(AppCleanupOverride.normalizeBundleID) == normalizedBundleID
        }), let name = running.localizedName, !name.isEmpty {
            return name
        }
        return InstalledApps.name(forBundleID: normalizedBundleID) ?? normalizedBundleID
    }

    private func appOverrideRow(for rule: AppCleanupOverride) -> some View {
        let app = resolvedApp(for: rule.bundleID)
        let appName = displayName(for: rule.bundleID)
        return HStack(spacing: 10) {
            appIcon(path: app?.path, bundleID: rule.bundleID, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if rule.mode == .custom, !rule.customPrompt.isEmpty {
                    Text(rule.customPrompt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editingAppRule = rule }

            Text(rule.mode.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OtoPalette.wash, in: Capsule())

            OtoRowActions {
                OtoRowButton(symbol: "pencil", help: "Edit app rule") {
                    editingAppRule = rule
                }
                OtoRowButton(symbol: "trash", help: "Delete app rule", danger: true) {
                    CleanupAppOverrides.remove(bundleID: rule.bundleID)
                    refreshAppOverrides()
                }
            }
        }
    }

    private func resolvedApp(for normalizedBundleID: String) -> InstalledApp? {
        installedApps.first {
            AppCleanupOverride.normalizeBundleID($0.bundleID) == normalizedBundleID
        }
    }

    @ViewBuilder
    private func appIcon(path: String?, bundleID: String, size: CGFloat) -> some View {
        let resolvedPath = (path?.isEmpty == false ? path : nil)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        if let resolvedPath {
            Image(nsImage: InstalledApps.icon(forPath: resolvedPath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .font(.system(size: size * 0.78))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private var cleanupDescription: String {
        switch level.wrappedValue {
        case .none: "Exact words, mistakes included"
        case .light: "Fixes fillers and grammar"
        case .medium: "Tightens for clarity too"
        }
    }

    private var statusText: String {
        availability == .available ? "Ready" : "Not available"
    }

    private var statusTone: OtoStatus.Tone {
        availability == .available ? .ok : .idle
    }

    private var statusDetail: String? {
        if case .unavailable(let copy) = availability { return copy }
        return enabled ? nil : "Turned off — turn it on to use cleanup."
    }
}

// MARK: - App rule editor sheet

private struct AppCleanupRuleEditor: View {
    private static let starterPrompts: [(title: String, prompt: String)] = [
        ("Casual chat", "Keep it casual and concise for chat. Remove filler words and fix obvious typos."),
        ("Formal email", "Write in a polite, clear, professional email tone while keeping the exact meaning."),
        ("Bullet points", "Organize the key points into concise bullet points. Keep every fact."),
    ]

    let existingRule: AppCleanupOverride?
    let blockedBundleIDs: Set<String>
    let onDone: (AppCleanupOverride?) -> Void

    @State private var selectedBundleID = ""
    @State private var mode: AppCleanupMode = .off
    @State private var customPrompt = ""
    @State private var isChoosingApp = false
    @State private var query = ""
    @State private var installedApps: [InstalledApp] = InstalledApps.cached

    var body: some View {
        Form {
            Section("App") {
                Button {
                    isChoosingApp = true
                } label: {
                    HStack(spacing: 8) {
                        if let app = selectedApp {
                            appIcon(for: app)
                            Text(app.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text("Choose an app…")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("App for cleanup rule")
                .popover(isPresented: $isChoosingApp, arrowEdge: .bottom) {
                    appChooser
                }
            }

            Section("Cleanup") {
                OtoSegmented(
                    options: [(.off, "Off"), (.light, "Light"), (.medium, "Medium"), (.custom, "Custom")],
                    selection: $mode,
                    accessibilityLabel: "App cleanup mode"
                )
                Text(modeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if mode == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(Self.starterPrompts, id: \.title) { starter in
                                Button(starter.title) {
                                    customPrompt = starter.prompt
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Spacer(minLength: 0)
                        }

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $customPrompt)
                                .font(.system(size: 12))
                                .frame(minHeight: 56)
                                .accessibilityLabel("Per-app custom cleanup instruction")
                            if customPrompt.isEmpty {
                                Text("Describe how dictation should be cleaned up in this app…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                        if sanitizedCustomPrompt.isEmpty {
                            Text("Enter an instruction or choose a starter above.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else if customPrompt.count > CustomPrompt.instructionCap - 60 {
                            let over = customPrompt.count > CustomPrompt.instructionCap
                            Text("\(customPrompt.count) / \(CustomPrompt.instructionCap) characters\(over ? " — extra text will be trimmed on save" : "")")
                                .font(.system(size: 11))
                                .foregroundStyle(over ? .orange : .secondary)
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { onDone(nil) }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: mode == .custom ? 390 : 270)
        .onAppear { seed() }
        .onChange(of: isChoosingApp) { _, open in
            if !open { query = "" }
        }
    }

    private var normalizedSelectedID: String {
        AppCleanupOverride.normalizeBundleID(selectedBundleID)
    }

    private var sanitizedCustomPrompt: String {
        CustomPrompt.sanitizeInstruction(customPrompt)
    }

    private var canSave: Bool {
        guard !normalizedSelectedID.isEmpty,
              !blockedBundleIDs.contains(normalizedSelectedID)
        else { return false }
        if mode == .custom {
            return !sanitizedCustomPrompt.isEmpty
        }
        return true
    }

    private var modeDescription: String {
        switch mode {
        case .off: "Exact words — no AI cleanup in this app"
        case .light: "Fixes fillers and grammar"
        case .medium: "Tightens for clarity too"
        case .custom: "Follows your own cleanup instruction"
        }
    }

    private var availableApps: [InstalledApp] {
        var list = installedApps
        let known = Set(list.map { AppCleanupOverride.normalizeBundleID($0.bundleID) })
        if !normalizedSelectedID.isEmpty, !known.contains(normalizedSelectedID) {
            list.append(InstalledApp(
                bundleID: normalizedSelectedID,
                name: InstalledApps.name(forBundleID: normalizedSelectedID) ?? normalizedSelectedID,
                path: NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedSelectedID)?.path ?? ""
            ))
        }
        return list
    }

    private var selectedApp: InstalledApp? {
        guard !normalizedSelectedID.isEmpty else { return nil }
        return availableApps.first {
            AppCleanupOverride.normalizeBundleID($0.bundleID) == normalizedSelectedID
        }
    }

    private var filteredApps: [InstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return availableApps }
        return availableApps.filter {
            $0.name.localizedLowercase.contains(needle)
                || $0.bundleID.localizedLowercase.contains(needle)
        }
    }

    private var appChooser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search apps")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(.quaternary, in: Capsule())
            .padding(10)

            Divider()

            if filteredApps.isEmpty {
                Text("No apps found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            let normalizedID = AppCleanupOverride.normalizeBundleID(app.bundleID)
                            let isSelected = normalizedID == normalizedSelectedID
                            let isBlocked = blockedBundleIDs.contains(normalizedID)
                            Button {
                                guard !isBlocked else { return }
                                selectedBundleID = normalizedID
                                isChoosingApp = false
                            } label: {
                                HStack(spacing: 8) {
                                    appIcon(for: app)
                                    Text(app.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.tint)
                                    } else if isBlocked {
                                        Text("Added")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .opacity(isBlocked ? 0.45 : 1)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isBlocked)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 264, height: 300)
        .task {
            installedApps = await InstalledApps.load(forceRefresh: true)
        }
    }

    @ViewBuilder
    private func appIcon(for app: InstalledApp) -> some View {
        if app.path.isEmpty {
            Image(systemName: "app")
                .frame(width: 16, height: 16)
        } else {
            Image(nsImage: InstalledApps.icon(forPath: app.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }

    private func seed() {
        guard let existingRule else { return }
        selectedBundleID = existingRule.bundleID
        mode = existingRule.mode
        customPrompt = existingRule.customPrompt
    }

    private func save() {
        guard canSave else { return }
        let prompt = mode == .custom ? sanitizedCustomPrompt : ""
        onDone(AppCleanupOverride(
            bundleID: normalizedSelectedID,
            mode: mode,
            customPrompt: prompt
        ))
    }
}

/// Auto Cleanup footnote, conditional on History (clipboard honesty):
/// the "never lost" promise holds only while History keeps the raw
/// wording — with History off, cleaned text inserts and the original
/// exists nowhere. Pure — unit-tested.
nonisolated func cleanupFooting(historyEnabled: Bool) -> String {
    if historyEnabled {
        return "Applies to every dictation. Your original words are never lost — Undo AI edit in History."
    }
    return "Applies to every dictation. Your original words are only kept while History is on — turn it on in History to keep originals."
}
