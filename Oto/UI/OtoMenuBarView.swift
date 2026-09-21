//
//  OtoMenuBarView.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import SwiftUI

/// Production menu (Phase 5): status, recovery, Settings, Quit. No
/// diagnostics items — the probe/prepare buttons died with the old
/// diagnostics section (prepare lives in Settings now). Status is a one-shot read per menu open: live session
/// status belongs to the Flow Bar (Phase 6), not to a poll loop.
struct OtoMenuBarView: View {
    let coordinator: DictationCoordinator
    let inserter: RealTextInsertion

    @State private var status = "No session yet"
    @State private var recoveryAvailable = false
    @State private var feedback: String?

    var body: some View {
        Text(feedback ?? status)
            .task {
                // One shot: the menu rebuilds on every open, so a single
                // read is always fresh. No poll loop (that was diagnostics
                // scaffolding for a label that lied).
                status = await coordinator.lastSessionSummary()
                recoveryAvailable = await coordinator.recoveryText() != nil
            }

        // Recovery lives here until the Flow Bar (Phase 6): 02 demands a
        // product home for Copy/Retry, and the diagnostics section is dead. Shown only while
        // a kept transcript exists — no dead buttons.
        if recoveryAvailable {
            Button("Copy recovery transcript") {
                Task {
                    if let text = await coordinator.recoveryText() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        feedback = "Recovery transcript copied — paste with ⌘V."
                    } else {
                        recoveryAvailable = false
                        feedback = nil
                    }
                }
            }
            Button("Retry paste to frontmost app") {
                Task {
                    guard let text = await coordinator.recoveryText() else {
                        recoveryAvailable = false
                        feedback = nil
                        return
                    }
                    // The person pressed this while looking at the target —
                    // they are the check (same contract as Settings retry).
                    let posted = await inserter.retryPostToFrontmost(text)
                    feedback = posted
                        ? "Posted — check the frontmost app."
                        : "Retry failed — clipboard unavailable."
                }
            }
            Divider()
        }

        SettingsLink()
        Divider()
        Button("Quit Oto") {
            NSApplication.shared.terminate(nil)
        }
    }
}
