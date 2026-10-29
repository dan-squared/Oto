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
struct OtoMenuBarView: View {
    let onboarding: OnboardingWindowController
    let settings: OtoSettingsWindowController

    var body: some View {
        // Slice B undo: REMOVED (2026-10-06) — the OS owns undo; History's
        // Undo AI edit + Copy is the single raw-recovery path.
        // Onboarding stays while the first-run flow is being refined: it is
        // the only way to reach the walkthrough on demand.
        Button("Show onboarding…") {
            onboarding.show()
        }
        Button("Settings…") {
            settings.show()
        }
        Divider()
        Button("Quit Oto") {
            NSApplication.shared.terminate(nil)
        }
    }
}
