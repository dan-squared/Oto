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
    let dispatch: ShortcutDispatch

    @State private var status = "idle — no session yet"
    @State private var recoveryAvailable = false
    @State private var feedback: String?
    @State private var escapeUnavailable = false

    var body: some View {
        Text(feedback ?? status)
            .task {
                // One shot: the menu rebuilds on every open, so a single
                // read is always fresh. No poll loop (that was diagnostics
                // scaffolding for a label that lied). Feedback is cleared
                // here so a previous "Posted" line never greets the next open.
                feedback = nil
                dispatch.refreshAvailability()
                escapeUnavailable = !dispatch.isEscapeCancelAvailable
                status = await coordinator.lastSessionSummary()
                recoveryAvailable = await coordinator.recoveryText() != nil
            }

        // Escape rides the HID tap (needs Accessibility); combo triggers
        // work without it — so on a combo with no tap, dictation works
        // while Escape cancel silently wouldn't. Name it (menu row only,
        // never a new surface) instead of failing silent.
        if escapeUnavailable {
            Text("Escape cancel unavailable — grant Accessibility in Settings")
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
                    // they are the check: only someone facing the app they
                    // want the text in presses Retry.
                    let posted = await inserter.retryPostToFrontmost(text)
                    feedback = posted
                        ? "Posted — check the frontmost app."
                        : "Retry failed — secure input may be blocking it, or the clipboard was unavailable."
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
