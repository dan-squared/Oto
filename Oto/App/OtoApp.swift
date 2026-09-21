//
//  OtoApp.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import SwiftUI

/// Restores the persisted Dock visibility once NSApplication exists.
/// NSApp is nil in App.init (crash-proven 2026-09-21), so this lives in
/// the delegate — silent on failure by design: Regular remains and the
/// stored pref is untouched for next launch (apply writes only on success).
final class DockRestoreDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = DockVisibility.apply(shown: DockVisibility.isShown())
    }
}

@main
struct OtoApp: App {
    /// Phase 5 wiring: REAL audio + REAL Apple Speech behind the unchanged
    /// coordinator seams, the shortcut dispatch layer, and the native
    /// Settings product (General + Dictation) with a production menu.
    /// Default trigger is right-Option hold-to-talk; trigger config
    /// persists via `ShortcutConfiguration` (loaded in dispatch init).
    /// Fakes stay for tests.
    private let coordinator: DictationCoordinator
    private let dispatch: ShortcutDispatch
    private let preparer = SpeechAssetPreparer()
    private let permissions = PermissionsManager()
    private let login: any LoginItemManaging = LiveLoginItemManager()
    // One instance shared by the coordinator pipeline and the menu Retry
    // path — two instances could never diverge in behavior, but one is
    // the honest shape (audit S2).
    private let inserter: RealTextInsertion
    @NSApplicationDelegateAdaptor(DockRestoreDelegate.self) private var dockRestore
    // Phase 6A writing stores. One persistence service; three observable
    // owners passed to Settings. The coordinator receives rule snapshots
    // (values, never store references) and the history sink.
    private let persistence: LocalPersistence
    private let dictionaryStore: DictionaryStore
    private let snippetStore: SnippetStore
    private let historyStore: HistoryStore

    init() {
        let relay = AudioBufferRelay()
        let audio = AppleAudioCapture(bufferHandler: { buffer in
            relay.receive(buffer)
        })
        let speech = AppleSpeechService(relay: relay)
        let inserter = RealTextInsertion()
        let persistence = LocalPersistence()
        let dictionaryStore = DictionaryStore(persistence: persistence)
        let snippetStore = SnippetStore(persistence: persistence)
        let historyStore = HistoryStore(persistence: persistence)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: RealTargetCapture(),
            inserter: inserter,
            history: historyStore
        )
        self.coordinator = coordinator
        self.inserter = inserter
        self.persistence = persistence
        self.dictionaryStore = dictionaryStore
        self.snippetStore = snippetStore
        self.historyStore = historyStore
        let dispatch = ShortcutDispatch(coordinator: coordinator)
        self.dispatch = dispatch
        // Shortcut layer: Carbon combos + HID tap (right-Option hold
        // default). No NSEvent monitors in the trigger path — they wedge
        // MenuBarExtra menu tracking (bisect-proven, see HIDEventMonitor).
        dispatch.start()
        // Stores load off the launch path; rules push when ready. Dictation
        // before this lands uses trim-only (today's behavior), never blocks.
        Task {
            await dictionaryStore.load()
            await snippetStore.load()
            await historyStore.load()
            await coordinator.setDictionaryRules(dictionaryStore.rules)
        }
    }

    var body: some Scene {
        MenuBarExtra("Oto", systemImage: "waveform") {
            OtoMenuBarView(coordinator: coordinator, inserter: inserter, dispatch: dispatch)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRoot(
                dispatch: dispatch,
                preparer: preparer,
                permissions: permissions,
                login: login,
                coordinator: coordinator,
                dictionary: dictionaryStore,
                snippets: snippetStore,
                history: historyStore,
                inserter: inserter
            )
        }
        .defaultSize(width: 760, height: 620)
    }
}
