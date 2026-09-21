//
//  OtoApp.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import SwiftUI

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
    private let inserter = RealTextInsertion()

    init() {
        let relay = AudioBufferRelay()
        let audio = AppleAudioCapture(bufferHandler: { buffer in
            relay.receive(buffer)
        })
        let speech = AppleSpeechService(locale: .current, relay: relay)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: RealTargetCapture(),
            inserter: RealTextInsertion()
        )
        self.coordinator = coordinator
        let dispatch = ShortcutDispatch(coordinator: coordinator)
        self.dispatch = dispatch
        // Shortcut layer: Carbon combos + HID tap (right-Option hold
        // default). No NSEvent monitors in the trigger path — they wedge
        // MenuBarExtra menu tracking (bisect-proven, see HIDEventMonitor).
        dispatch.start()
    }

    var body: some Scene {
        MenuBarExtra("Oto", systemImage: "waveform") {
            OtoMenuBarView(coordinator: coordinator, inserter: inserter)
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
    }
}
