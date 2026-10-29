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
    @State private var messages: [TransformPreset: String] = [:]
    /// Custom prompt editors (Phase 9): mirrors of the UserDefaults store,
    /// loaded in refreshTransforms, saved debounced (never per keystroke).
    @State private var customName = ""
    @State private var customInstruction = ""
    @State private var customSaveTask: Task<Void, Never>?

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
            self.publishAccessory()
            CleanupMigrator.migrateIfNeeded()
            availability = polish.availability()
            refreshTransforms()
            if enabled, level.wrappedValue != .none, availability == .available {
                polish.prewarm(job: .cleanup(level.wrappedValue))
            }
        }
        .onChange(of: enabled) { _, on in
            self.publishAccessory()
            guard on else { return }
            self.availability = self.polish.availability()
            self.refreshTransforms()
            if self.level.wrappedValue != .none, self.availability == .available {
                self.polish.prewarm(job: .cleanup(self.level.wrappedValue))
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
                    .init(symbol: "wand.and.stars", label: "Cleanup", tint: .violet),
                    .init(symbol: "arrow.triangle.2.circlepath", label: "Transforms", tint: .blue),
                    .init(symbol: "cpu", label: "On-device", tint: .green),
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
                Toggle("Use Apple Intelligence", isOn: $enabled)
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
    /// History's: the pane's master control is never buried in a card.
    private func publishAccessory() {
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
                    recordLabel: "\(preset.displayName) shortcut, \(transformShortcutLabel(kind: kind)). Activate to record a new shortcut.",
                    onRecord: {
                        transforms.stop()
                        recording = preset
                    }
                )
                .disabled(othersRecording)
                .popover(isPresented: Binding(
                    get: { recording == preset },
                    set: { if !$0, recording == preset { transforms.start(); recording = nil } }
                ), arrowEdge: .top) {
                    TransformShortcutCapturePopover(
                        isListening: Binding(
                            get: { recording == preset },
                            set: { if !$0, recording == preset { transforms.start(); recording = nil } }
                        ),
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
                            refreshTransforms()
                        },
                        onCancel: {
                            transforms.start()
                            recording = nil
                        },
                        onInvalid: { reason in
                            NSSound.beep()
                            messages[preset] = reason.message
                        }
                    )
                }
            }
            if let message = messages[preset] ?? auditMessage(for: preset) {
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
            } else if !transforms.isLive(preset), !isRecording {
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
        refreshTransforms()
        transforms.start()
        // The recorder flashes green and dismisses itself; clearing `recording`
        // here would close the popover before the confirmation is visible.
        return nil
    }

    private func refreshTransforms() {
        shortcuts = transforms.shortcuts
        let kinds = transforms.currentDictationKinds()
        audit = ShortcutAudit.violations(
            hold: kinds.hold, handsFree: kinds.handsFree, transforms: shortcuts
        )
        // Custom editors mirror the store (typing never triggers a
        // refresh, so this cannot clobber in-flight edits).
        let custom = CustomPrompt.load()
        customName = custom.name
        customInstruction = custom.instruction
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
