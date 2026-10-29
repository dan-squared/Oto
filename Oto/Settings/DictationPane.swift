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

    @State private var capturePopoverSlot: ShortcutSlot?
    @State private var shortcutMessage: String?
    /// Row snapshots of the two live kinds. `ShortcutDispatch` is not
    /// observable, so the rows read these (seeded in `init`, refreshed on
    /// every recorder change) — the pane body then redraws even while the
    /// recorder popover is still open.
    @State private var holdKind: ShortcutTrigger.Kind
    @State private var handsFreeKind: ShortcutTrigger.Kind

    @State private var trialText = ""

    init(dispatch: ShortcutDispatch, uiState: SettingsUIState) {
        self.dispatch = dispatch
        self.uiState = uiState
        _holdKind = State(initialValue: dispatch.configuration.hold.kind)
        _handsFreeKind = State(initialValue: dispatch.configuration.handsFree.kind)
    }

    var body: some View {
        OtoPaneForm {
            // No "Dictation" header — the sidebar already says it.

            Section {
                LabeledContent("Readiness") {
                    if uiState.speechReady {
                        OtoStatus(text: "Ready", tone: .ok)
                    } else if uiState.speechReadiness == nil {
                        OtoStatus(text: "Checking…", tone: .idle)
                    } else if uiState.isPreparing {
                        OtoStatusAction(text: "Preparing…", tone: .idle, busy: true) {}
                    } else {
                        // The state is the button: one control, no second
                        // "Prepare" button under a "Not prepared" pill.
                        OtoStatusAction(
                            text: "Not prepared",
                            tone: .warn,
                            help: "Download the on-device speech model for this language"
                        ) {
                            Task { await uiState.runPrepare() }
                        }
                    }
                }
                OtoPanelNote(uiState.speechReady ? uiState.languageText : (uiState.prepareFeedback ?? uiState.readinessText))
            } header: {
                Text("Speech")
            }
            .onReceive(NotificationCenter.default.publisher(for: .otoProbeOpenRecorder)) { note in
                // Probe-only (never posted in normal use): opens a recorder so
                // the popover's footer and ⌫ path can be captured.
                guard let raw = note.object as? String else { return }
                capturePopoverSlot = raw == "handsFree" ? .handsFree : .hold
            }
            .onAppear {
                // Fast only: shortcut summary (the config can change in the
                // modal or onboarding, so re-sync on every visit and on modal
                // close) plus grant-in-System-Settings flows live with no
                // flash (never re-probes speech or devices here).
                syncFromDispatch()
                uiState.refreshPermissions()
            }

            // One row per shortcut: the grouped Form draws the same divider
            // between them that every other section gets. A single VStack
            // row read as one control with two keycaps.
            Section("Shortcut") {
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
                TextEditor(text: $trialText)
                    .font(.body)
                    .frame(minHeight: 70)
                OtoPanelNote("Dictate anywhere, or here — Oto captures the frontmost app.")
            } header: {
                Text("Try it")
            }
        }
    }

    // MARK: - Shortcut

    private func syncFromDispatch() {
        holdKind = dispatch.configuration.hold.kind
        handsFreeKind = dispatch.configuration.handsFree.kind
    }

    private var requiresAccessibility: Bool {
        func isModifier(_ kind: ShortcutTrigger.Kind) -> Bool {
            if case .modifierHold = kind { return true }
            return false
        }
        return isModifier(holdKind) || isModifier(handsFreeKind)
    }

    private func shortcutRow(_ title: String, slot: ShortcutSlot) -> some View {
        let kind = slot == .hold ? holdKind : handsFreeKind
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
                ShortcutCapturePopover(
                    dispatch: dispatch,
                    slot: slot,
                    onChange: syncFromDispatch,
                    onClose: {
                        capturePopoverSlot = nil
                        syncFromDispatch()
                    }
                )
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
