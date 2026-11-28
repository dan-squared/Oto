//
//  OtoMenuBarView.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import SwiftUI

/// Production menu: entry points only. Recovery (copy / retry) belongs to
/// the catcher and auto-copy — duplicating it here meant a second home for
/// the same decision, and the Escape / status rows described internals the
/// person cannot act on. Live session state belongs to the Flow Bar.
///
/// One exception: a failed last session is a durable, readable status. The
/// pill notice fades after a few seconds; the menu keeps the failure text
/// and one row to act on it until the next session starts.
struct OtoMenuBarView: View {
    let coordinator: DictationCoordinator
    let settings: OtoSettingsWindowController
    let updater: AppUpdater
    let snippets: SnippetStore
    let uiState: SettingsUIState

    @State private var lastError: String?
    @State private var lastTranscript: String?

    private static let maxMenuSnippets = 25

    private var languageSelection: Binding<String> {
        Binding(
            get: { uiState.selectedLocaleIdentifier ?? SpeechLocalePreference.systemTag },
            set: { tag in
                uiState.selectLocale(tag.isEmpty ? nil : tag)
            }
        )
    }

    var body: some View {
        // Slice B undo: REMOVED (2026-10-06) — the OS owns undo; History's
        // Undo AI edit + Copy is the single raw-recovery path.
        if let lastError {
            Text(lastError)
            Button("Open Settings…") {
                settings.show()
            }
            Divider()
        }
        let hasQuickActions = lastTranscript != nil
            || uiState.installedLocales.count >= 2
            || !snippets.snippets.isEmpty
        if let lastTranscript {
            Button("Copy Last Dictation") {
                ClipboardWrite.text(lastTranscript)
            }
        }
        if uiState.installedLocales.count >= 2 {
            let nameSource = uiState.supportedLocales.isEmpty
                ? uiState.installedLocales
                : uiState.supportedLocales
            let localeNames = SpeechLocalePreference.displayNames(for: nameSource)
            Menu("Language") {
                Picker("Language", selection: languageSelection) {
                    Text("System")
                        .tag(SpeechLocalePreference.systemTag)
                    Divider()
                    ForEach(uiState.installedLocales.map { (tag: $0.identifier(.bcp47), locale: $0) }, id: \.tag) { item in
                        Text(localeNames[item.tag] ?? SpeechLocalePreference.displayName(for: item.locale))
                            .tag(item.tag)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(uiState.isPreparing)
        }
        if !snippets.snippets.isEmpty {
            Menu("Snippets") {
                ForEach(snippets.snippets.prefix(Self.maxMenuSnippets)) { snippet in
                    Button(snippet.name) {
                        ClipboardWrite.text(snippet.expansion)
                    }
                }
                if snippets.snippets.count > Self.maxMenuSnippets {
                    Divider()
                    Button("Show All in Settings…") {
                        settings.show()
                    }
                }
            }
        }
        if hasQuickActions {
            Divider()
        }
        // The button itself changes label (Checking… / Up to date / error);
        // there is intentionally no second row under it.
        Button(updater.buttonTitle) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Button("Settings…") {
            settings.show()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Oto") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        .task {
            await refreshStatus()
            let stream = await coordinator.stateChanges()
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await refreshStatus()
            }
        }
    }

    @MainActor
    private func refreshStatus() async {
        lastError = await coordinator.menuErrorSummary()
        lastTranscript = await coordinator.lastTranscriptText()
    }
}
