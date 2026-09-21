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

    init() {
        let relay = AudioBufferRelay()
        let audio = AppleAudioCapture(bufferHandler: { buffer in
            relay.receive(buffer)
        })
        let speech = AppleSpeechService(relay: relay)
        let inserter = RealTextInsertion()
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: RealTargetCapture(),
            inserter: inserter
        )
        self.coordinator = coordinator
        self.inserter = inserter
        let dispatch = ShortcutDispatch(coordinator: coordinator)
        self.dispatch = dispatch
        // Shortcut layer: Carbon combos + HID tap (right-Option hold
        // default). No NSEvent monitors in the trigger path — they wedge
        // MenuBarExtra menu tracking (bisect-proven, see HIDEventMonitor).
        dispatch.start()
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
                login: login
            )
        }
        .defaultSize(width: 760, height: 620)
    }
}
