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
    @State private var availability: PolishAvailability = .available
    @State private var shortcuts = TransformShortcuts.default()
    @State private var audit: [(slot: ShortcutSlotID, message: String)] = []
    @State private var recording: TransformPreset?
    @State private var messages: [TransformPreset: String] = [:]

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
                    Text("Applies to every dictation. Your original words are never lost — Undo AI edit in History.")
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
