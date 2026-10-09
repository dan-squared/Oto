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

    @AppStorage(CleanupSettings.enabledKey) private var enabled = true
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
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "Intelligence")
            OtoCard {
                OtoLine("Apple Intelligence", statusDetail) {
                    OtoStatus(text: statusText, tone: statusTone)
                }
            }
            OtoCard {
                OtoLine(
                    "Use Apple Intelligence",
                    "Off means exactly today's app: no model contact at all."
                ) {
                    OtoSwitch(on: $enabled)
                }
            }
            OtoCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto Cleanup")
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.ink)
                    Text(cleanupFooting(historyEnabled: historyEnabled))
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                    HStack(spacing: 8) {
                        cleanupCard(
                            level: .none, title: "None",
                            detail: "Exact words, mistakes included"
                        )
                        cleanupCard(
                            level: .light, title: "Light",
                            detail: "Fixes fillers and grammar"
                        )
                        cleanupCard(
                            level: .medium, title: "Medium",
                            detail: "Tightens for clarity too"
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            OtoCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("My Transforms")
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.ink)
                    Text("Select text in any app, press the shortcut — the pill shows the rewrite while it runs.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                    ForEach(TransformPreset.allCases, id: \.rawValue) { preset in
                        transformRow(for: preset)
                    }
                    HStack {
                        Spacer()
                        OtoPill("Reset to defaults") {
                            transforms.resetToDefaults()
                            refreshTransforms()
                        }
                        .disabled(recording != nil)
                    }
                    // Reset restores the four shortcuts; the custom name +
                    // instruction are yours and stay untouched.
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            Text("On-device only — transcripts and prompts never leave this Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
        }
        .onAppear {
            CleanupMigrator.migrateIfNeeded()
            availability = polish.availability()
            refreshTransforms()
            if enabled, level.wrappedValue != .none, availability == .available {
                polish.prewarm(job: .cleanup(level.wrappedValue))
            }
        }
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
                        .foregroundStyle(OtoPalette.muted)
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OtoPalette.ink)
                    Text(preset.tagline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                }
                Spacer(minLength: 8)
                Button {
                    if isRecording {
                        transforms.start()
                        recording = nil
                    } else {
                        transforms.stop()
                        recording = preset
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isRecording {
                            Text("Press your shortcut…")
                                .font(.system(size: 12))
                                .foregroundStyle(OtoPalette.muted)
                        } else {
                            ForEach(KeyNames.chips(for: kind), id: \.self) { chip in
                                OtoKey(text: chip)
                            }
                            if KeyNames.chips(for: kind).isEmpty {
                                Text("Set shortcut…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OtoPalette.muted)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(OtoPalette.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(othersRecording)
                .accessibilityLabel("\(preset.displayName) shortcut, \(transformShortcutLabel(kind: kind)). Activate to record a new shortcut.")
                .shortcutRecorder(
                    isListening: Binding(
                        get: { recording == preset },
                        set: { if !$0 { recording = nil } }
                    ),
                    onCapture: { modifiers, keyCode, conflicts in
                        captureTransform(
                            preset: preset,
                            kind: .combo(modifiers: modifiers, keyCode: keyCode),
                            conflicts: conflicts
                        )
                    },
                    onCaptureModifier: { _ in
                        messages[preset] = "Transforms need a combination like ⌘1 — bare keys would fire while you type."
                    },
                    onClear: {
                        transforms.clearShortcut(for: preset)
                        messages[preset] = nil
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
            if let message = messages[preset] ?? auditMessage(for: preset) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(width: 16, height: 16)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OtoPalette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if !transforms.isLive(preset), !isRecording {
                // Registered combos that the OS refused (another app holds
                // the hotkey): named, never silently dead — except empty
                // slots, which claim nothing.
                if kind != .unassigned {
                    Text("Couldn’t register — already used by another app. Pick a different one.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
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
    ) {
        transforms.start()
        recording = nil
        if ShortcutRecorderConflicts.blocksSaving(conflicts) {
            messages[preset] = ShortcutRecorderConflicts.describe(conflicts)
            refreshTransforms()
            return
        }
        let kinds = transforms.currentDictationKinds()
        if let advisory = TransformShortcutGate.advisory(
            kind: kind, preset: preset,
            transforms: shortcuts, hold: kinds.hold, handsFree: kinds.handsFree
        ) {
            messages[preset] = advisory
            refreshTransforms()
            return
        }
        if transforms.updateShortcut(kind, for: preset) == .blocked {
            messages[preset] = "Already in use — pick a different one."
        } else {
            messages[preset] = nil
        }
        if messages[preset] == nil, !conflicts.isEmpty {
            messages[preset] = ShortcutRecorderConflicts.describe(conflicts)
        }
        refreshTransforms()
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

    /// One selectable cleanup card (title + one-line description).
    /// Selected card carries the ink border + wash fill (sidebar-row
    /// language); selection still announces via VoiceOver traits — the
    /// checkmark decoration is deliberately gone (user call: less chrome).
    /// Native Buttons throughout: Tab-focusable, Space/Enter activates.
    /// `contentShape(Rectangle())` hardens hit-testing: plain-styled cards
    /// with spacer content can otherwise have hole-y tap areas.
    private func cleanupCard(level: CleanupLevel, title: String, detail: String) -> some View {
        let selected = level == self.level.wrappedValue
        return Button {
            self.level.wrappedValue = level
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OtoPalette.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? OtoPalette.wash : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? OtoPalette.ink : OtoPalette.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto Cleanup \(title)")
        .accessibilityValue(selected ? "selected" : "not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
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
