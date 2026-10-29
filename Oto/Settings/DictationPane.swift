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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(uiState.isPreparing)
                }
            }
            OtoPanelNote(uiState.speechReady ? uiState.languageText : (uiState.prepareFeedback ?? uiState.readinessText))
        } header: {
            Text("Speech")
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

                if requiresAccessibility && !uiState.axTrusted {
                    Label("Requires Accessibility", systemImage: "hand.raised")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let shortcutMessage {
                    Label(shortcutMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            OtoPanelNote("Sets the Mac's input — every app follows it.")
        } header: {
            Text("Microphone")
        }

        Section("Permissions") {
            AccessibilityRow(uiState: uiState)
            SpeechStatusRow(uiState: uiState)
        }

        Section {
            Toggle("Show catcher when there's nowhere to paste", isOn: $catcherEnabled)
                .accessibilityIdentifier("CatcherToggle")
            Toggle("Mute media while dictating", isOn: $muteMedia)
            OtoPanelNote("Catcher: no text field? Oto opens a small window. Off: auto-copies instead.\nMute: silences speakers, restores volume automatically.")
        } header: {
            Text("Behavior")
        }

        Section {
            TextEditor(text: $trialText)
                .font(.body)
                .frame(minHeight: 70)
            OtoPanelNote("Dictate anywhere, or here — Oto captures the frontmost app.")
        } header: {
            Text("Try it")
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

            OtoShortcutField(
                chips: chips,
                recordLabel: "Record \(title) shortcut",
                onRecord: {
                    shortcutMessage = nil
                    capturePopoverSlot = slot
                }
            )
            .help("Click to record a shortcut")
            .popover(isPresented: capturePopoverBinding(for: slot), arrowEdge: .top) {
                ShortcutCapturePopover(dispatch: dispatch, slot: slot) {
                    capturePopoverSlot = nil
                    syncFromDispatch()
                }
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
