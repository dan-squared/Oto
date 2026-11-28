//
//  DictationPane.swift
//  Oto
//
//  Everything that makes dictation work: speech assets, shortcut, microphone,
//  and a safe field to try it in. Permissions are not repeated here — Privacy
//  is their one home (round 2, 2026-10-31). Every row binds a real backend;
//  rows without backends do not exist here.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

private enum KeyboardSettingsLink {
    nonisolated static func candidates() -> [URL] {
        [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
            "x-apple.systempreferences:",
        ].compactMap(URL.init(string:))
    }
}

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
    @State private var fnUsage: SystemFnUsage = SystemFnUsage.read()
    @AppStorage(SmartSpacing.defaultsKey) private var smartSpacingEnabled = true

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
                let localeNames = SpeechLocalePreference.displayNames(for: pickerLocales.map(\.locale))
                let systemLabel: String = {
                    if let resolved = SpeechLocaleMatching.bestMatch(for: .current, in: uiState.supportedLocales) {
                        let name = localeNames[resolved.identifier(.bcp47)]
                            ?? SpeechLocalePreference.displayName(for: resolved)
                        return "System (\(name))"
                    }
                    return "System"
                }()

                Picker("Language", selection: languageSelection) {
                    Text(systemLabel)
                        .tag(SpeechLocalePreference.systemTag)
                    if !pickerLocales.isEmpty {
                        Divider()
                        ForEach(pickerLocales, id: \.tag) { option in
                            Text(localeNames[option.tag] ?? SpeechLocalePreference.displayName(for: option.locale))
                                .tag(option.tag)
                        }
                    }
                }
                .disabled(uiState.isPreparing)

                LabeledContent("Readiness") {
                    if uiState.isPreparing {
                        OtoProgressStatus(progress: uiState.prepareProgress) {
                            uiState.cancelPrepare()
                        }
                    } else if uiState.speechReady {
                        OtoStatus(text: "Ready", tone: .ok)
                    } else if uiState.speechReadiness == nil {
                        OtoStatus(text: "Checking…", tone: .idle)
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
#if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .otoProbeOpenRecorder)) { note in
                // Probe-only (never posted in normal use): opens a recorder so
                // the popover's footer and ⌫ path can be captured.
                guard let raw = note.object as? String else { return }
                capturePopoverSlot = raw == "handsFree" ? .handsFree : .hold
            }
#endif
            .onAppear {
                // Re-sync shortcuts, permissions, audio inputs, and fn key
                // system usage on every visit without resetting hoisted state.
                syncFromDispatch()
                uiState.refreshPermissions()
                uiState.refreshMicrophones()
                fnUsage = SystemFnUsage.read()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                fnUsage = SystemFnUsage.read()
            }

            // One row per shortcut: the grouped Form draws the same divider
            // between them that every other section gets. A single VStack
            // row read as one control with two keycaps.
            Section("Shortcut") {
                shortcutRow("Push-to-talk", slot: .hold)
                shortcutRow("Hands-free", slot: .handsFree)

                // Teaching, not a control: double-tapping the hold key is the
                // only route into hands-free without a second shortcut, and
                // Settings was silent about it (only onboarding said so). One
                // short line, same weight as the conditional warning below,
                // naming the key as recorded — never a hard-coded glyph.
                Label(
                    "Double-tap \(KeyNames.shortLabel(for: holdKind)) to record without holding.",
                    systemImage: "hand.tap"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("DoubleTapHint")

                if requiresAccessibility && !uiState.axTrusted {
                    Label("Requires Accessibility", systemImage: "hand.raised")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if usesFnKey && fnUsage != .none {
                    HStack(spacing: 8) {
                        Label(
                            "Set “Press 🌐 key to” → “Do Nothing” in Keyboard Settings for instant fn dictation.",
                            systemImage: "globe"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Keyboard Settings") {
                            SettingsLinkOpener.open(KeyboardSettingsLink.candidates())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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

            Section {
                Toggle("Smart spacing", isOn: $smartSpacingEnabled)
                OtoPanelNote("Automatically adds a leading space when dictating after a word or punctuation mark.")
            } header: {
                Text("Formatting")
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
        func needsAX(_ kind: ShortcutTrigger.Kind) -> Bool {
            switch kind {
            case .modifierHold, .functionKey: return true
            case .combo, .unassigned: return false
            }
        }
        return needsAX(holdKind) || needsAX(handsFreeKind)
    }

    private var usesFnKey: Bool {
        let fn = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_Function))
        return holdKind == fn || handsFreeKind == fn
    }

    private func shortcutRow(_ title: String, slot: ShortcutSlot) -> some View {
        let kind = slot == .hold ? holdKind : handsFreeKind
        let chips = KeyNames.chips(for: kind)

        return HStack(spacing: 8) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            OtoShortcutField(
                chips: chips,
                active: capturePopoverSlot == slot,
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

    private struct PickerLocaleOption {
        let tag: String
        let locale: Locale
    }

    private var pickerLocales: [PickerLocaleOption] {
        var options = uiState.supportedLocales.map {
            PickerLocaleOption(tag: $0.identifier(.bcp47), locale: $0)
        }
        if let selected = uiState.selectedLocaleIdentifier,
           !selected.isEmpty,
           !options.contains(where: { $0.tag == selected })
        {
            options.insert(
                PickerLocaleOption(tag: selected, locale: Locale(identifier: selected)),
                at: 0
            )
        }
        return options
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { uiState.selectedLocaleIdentifier ?? SpeechLocalePreference.systemTag },
            set: { tag in
                uiState.selectLocale(tag.isEmpty ? nil : tag)
            }
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
