//
//  DictationPane.swift
//  Oto
//
//  Everything that makes dictation work: speech assets, shortcut, microphone,
//  permissions, and a safe field to try it in. Every row binds a real
//  backend; rows without backends do not exist here.
//

import SwiftUI

struct DictationPane: View {
    let dispatch: ShortcutDispatch
    let uiState: SettingsUIState

    @State private var shortcutRefreshID = UUID()
    @State private var capturePopoverSlot: ShortcutSlot?
    @State private var shortcutMessage: String?

    @State private var trialText = ""
    // Catcher kill-switch (6C1): default ON — the modal teaches the
    // no-textbox flow. Key owned by NoTargetModalSettings; the literal is
    // pinned equal to it by NoTargetModalTests.
    @AppStorage("app.Oto.noTargetModal") private var catcherEnabled = true
    // Media-duck kill-switch (Phase 7, spike-green): default ON — bleed
    // ruins transcripts, resume is automatic. Key owned by
    // MediaDuckSettings; the literal is pinned equal to it by MediaDuckTests.
    @AppStorage("app.Oto.muteMediaWhileDictating") private var muteMedia = true

    var body: some View {
        // No "Dictation" header — the sidebar already says it.

        Section {
            LabeledContent("Readiness") {
                if uiState.speechReady {
                    OtoStatus(text: "Ready", tone: .ok)
                } else {
                    Button(uiState.isPreparing ? "Preparing…" : "Prepare offline speech") {
                        Task { await uiState.runPrepare() }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(uiState.isPreparing)
                }
            }
        } header: {
            Text("Speech")
        } footer: {
            Text(uiState.speechReady ? uiState.languageText : (uiState.prepareFeedback ?? uiState.readinessText))
        }
        .onAppear {
            // Fast only: shortcut summary (the config can change in the
            // modal or onboarding, so re-sync on every visit and on modal
            // close) plus grant-in-System-Settings flows live with no
            // flash (never re-probes speech or devices here).
            syncFromDispatch()
            uiState.refreshPermissions()
        }

        Section("Shortcut") {
            VStack(alignment: .leading, spacing: 12) {
                shortcutRow("Push-to-talk", slot: .hold)
                shortcutRow("Hands-free", slot: .handsFree)

                if requiresAccessibility {
                    Text("Requires Accessibility")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if let shortcutMessage {
                    Text(shortcutMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Button("Restore to default") {
                    dispatch.resetToDefaults()
                    shortcutMessage = nil
                    syncFromDispatch()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
            .id(shortcutRefreshID)
        }

        Section {
            Picker("Input", selection: microphoneSelection) {
                ForEach(uiState.inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .disabled(uiState.inputDevices.isEmpty)
            .help("Choose the Mac's default input device")
            MicStatusRow(uiState: uiState, title: "Status")
        } header: {
            Text("Microphone")
        } footer: {
            Text("Sets the Mac's input — every app follows it.")
        }

        Section("Permissions") {
            AccessibilityRow(uiState: uiState)
            SpeechStatusRow(uiState: uiState)
        }

        Section {
            Toggle("Show catcher when there's nowhere to paste", isOn: $catcherEnabled)
                .accessibilityIdentifier("CatcherToggle")
            Toggle("Mute media while dictating", isOn: $muteMedia)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Catcher: no text field? Oto opens a small window. Off: auto-copies instead.\nMute: silences speakers, restores volume automatically.")
        }

        Section {
            TextEditor(text: $trialText)
                .font(.body)
                .frame(minHeight: 70)
        } header: {
            Text("Try it")
        } footer: {
            Text("Dictate anywhere, or here — Oto captures the frontmost app.")
        }
    }

    // MARK: - Shortcut

    private func syncFromDispatch() {
        shortcutRefreshID = UUID()
    }

    private var requiresAccessibility: Bool {
        func isModifier(_ kind: ShortcutTrigger.Kind) -> Bool {
            if case .modifierHold = kind { return true }
            return false
        }
        return isModifier(dispatch.configuration.hold.kind)
            || isModifier(dispatch.configuration.handsFree.kind)
    }

    private func shortcutRow(_ title: String, slot: ShortcutSlot) -> some View {
        let kind = slot == .hold ? dispatch.configuration.hold.kind : dispatch.configuration.handsFree.kind
        let chips = KeyNames.chips(for: kind)

        return HStack(spacing: 8) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button {
                    shortcutMessage = nil
                    capturePopoverSlot = slot
                } label: {
                    HStack(spacing: 5) {
                        if chips.isEmpty {
                            OtoKey(text: "Not set", compact: true)
                        } else {
                            ForEach(chips, id: \.self) { chip in
                                OtoKey(text: chip, compact: true)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record \(title) shortcut")
                .help("Click to record a shortcut")
                .popover(isPresented: capturePopoverBinding(for: slot), arrowEdge: .trailing) {
                    ShortcutCapturePopover(dispatch: dispatch, slot: slot) {
                        capturePopoverSlot = nil
                        syncFromDispatch()
                    }
                }

                Button {
                    dispatch.setSlotEnabled(false, for: slot)
                    shortcutMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chips.isEmpty || !dispatch.slotEnabled(slot))
                .help("Turn off this shortcut")
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.7)
            }
        }
    }

    private func capturePopoverBinding(for slot: ShortcutSlot) -> Binding<Bool> {
        Binding(
            get: { capturePopoverSlot == slot },
            set: { if !$0, capturePopoverSlot == slot { capturePopoverSlot = nil } }
        )
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: { uiState.defaultInputUID ?? "" },
            set: { uid in
                guard let device = uiState.inputDevices.first(where: { $0.uid == uid }) else { return }
                _ = MicrophoneSelector.setDefaultInput(device)
                uiState.refreshMicrophones()
            }
        )
    }
}

/// Small anchored recorder for custom shortcuts. Keeps the existing capture
/// and conflict rules without presenting the former full-window editor.
private struct ShortcutCapturePopover: View {
    let dispatch: ShortcutDispatch
    let slot: ShortcutSlot
    let onClose: () -> Void

    @State private var isListening = false
    @State private var message: String?
    @State private var modifierFlags: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(heldModifierChips, id: \.self) { chip in
                    OtoKey(text: chip)
                }
                Text("…and a key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 94)
            .modifier(ShortcutRecorderModifier(
                isListening: $isListening,
                onCapture: { modifiers, keyCode, conflicts in
                    finishCapture(kind: .combo(modifiers: modifiers, keyCode: keyCode), conflicts: conflicts)
                },
                onCaptureModifier: { code in
                    finishCapture(kind: .modifierHold(keyCode: code), conflicts: [])
                },
                onClear: {
                    dispatch.setSuspended(false)
                    dispatch.setSlotEnabled(false, for: slot)
                    isListening = false
                    onClose()
                },
                onCancel: {
                    dispatch.setSuspended(false)
                    isListening = false
                    onClose()
                },
                onInvalid: { reason in
                    NSSound.beep()
                    message = reason.message
                }
            ))

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()
            HStack {
                Spacer()
                Button {
                    dispatch.setSuspended(false)
                    isListening = false
                    onClose()
                } label: {
                    HStack(spacing: 6) {
                        Text("Close")
                        OtoKey(text: "esc", compact: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Close shortcut recorder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 252)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(20)
        .onAppear {
            dispatch.setSuspended(true)
            isListening = true
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                modifierFlags = event.modifierFlags
                return event
            }
        }
        .onChange(of: isListening) { _, listening in
            if listening {
                modifierFlags = NSEvent.modifierFlags
            } else {
                modifierFlags = []
            }
        }
        .onDisappear {
            dispatch.setSuspended(false)
            if let modifierMonitor {
                NSEvent.removeMonitor(modifierMonitor)
                self.modifierMonitor = nil
            }
        }
    }

    private var heldModifierChips: [String] {
        var chips: [String] = []
        if modifierFlags.contains(.control) { chips.append("⌃") }
        if modifierFlags.contains(.option) { chips.append("⌥") }
        if modifierFlags.contains(.shift) { chips.append("⇧") }
        if modifierFlags.contains(.command) { chips.append("⌘") }
        return chips
    }

    private func finishCapture(kind: ShortcutTrigger.Kind, conflicts: [RecorderConflict]) {
        dispatch.setSuspended(false)
        isListening = false
        guard !ShortcutRecorderConflicts.blocksSaving(conflicts) else {
            message = ShortcutRecorderConflicts.describe(conflicts)
            return
        }
        let trigger = ShortcutTrigger(kind: kind, interaction: slot == .hold ? .holdToTalk : .handsFree)
        let result = slot == .hold
            ? dispatch.updateHoldTrigger(trigger)
            : dispatch.updateHandsFreeTrigger(trigger)
        if result == .blocked {
            message = "That shortcut is already in use by the other mode."
        } else {
            onClose()
        }
    }
}
