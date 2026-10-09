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
    let onboarding: OnboardingWindowController

    @Environment(\.openWindow) private var openWindow

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
                    guard let text = await coordinator.recoveryText() else {
                        recoveryAvailable = false
                        feedback = nil
                        return
                    }
                    // Overwrite guard (clipboard discipline): explicit click,
                    // so a brief modal confirm is standard behavior — the
                    // focus defense covers uninvited UI, not this.
                    if ClipboardOverwriteGuard.shouldConfirm(board: .general) {
                        let alert = NSAlert()
                        alert.messageText = "Replace clipboard contents?"
                        alert.informativeText = "The clipboard holds text Oto didn't place."
                        alert.addButton(withTitle: "Replace")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ClipboardOverwriteGuard.markAsOto(NSPasteboard.general)
                    feedback = "Recovery transcript copied — paste with ⌘V."
                }
            }
            Button("Retry paste to frontmost app") {
                Task {
                    guard let text = await coordinator.recoveryText() else {
                        recoveryAvailable = false
                        feedback = nil
                        return
                    }
                    let expectedID = await coordinator.recoveryExpectedBundleID
                    let front = NSWorkspace.shared.frontmostApplication
                    let frontID = front?.bundleIdentifier
                    // Mismatch confirm: the transcript was dictated for a
                    // different app than the one facing the user now.
                    // Unknown on either side posts without interrogating —
                    // the person pressed Retry looking at their target.
                    if AppNames.shouldConfirmRetry(frontmost: frontID, expected: expectedID) {
                        let frontName = front?.localizedName ?? frontID ?? "frontmost app"
                        let expectedName = AppNames.displayName(forBundleID: expectedID)
                        let alert = NSAlert()
                        alert.messageText = "Paste into \(frontName)?"
                        alert.informativeText = "This transcript was dictated for \(expectedName)."
                        alert.addButton(withTitle: "Paste")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    switch await inserter.retryPostToFrontmost(text) {
                    case .posted:
                        let name = front?.localizedName ?? frontID ?? "the frontmost app"
                        feedback = "Posted to \(name) — check it."
                    case .refusedNoAccessibility:
                        feedback = "Retry failed — Accessibility permission is off."
                    case .clipboardUnavailable:
                        feedback = "Retry failed — the clipboard was unavailable."
                    case .pasteFailed:
                        feedback = "Retry failed — the paste keystroke could not be sent."
                    }
                }
            }
            Divider()
        }

        // Slice B undo: REMOVED (2026-10-06) — the OS owns undo; History's
        // Undo AI edit + Copy is the single raw-recovery path.
        Button("Show onboarding…") {
            onboarding.show()
        }
        Button("Settings…") {
            if let existing = NSApp.windows.first(where: { $0.title == "Settings" }) {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SettingsWindowID.id)
            }
        }
        Divider()
        Button("Quit Oto") {
            NSApplication.shared.terminate(nil)
        }
    }
}
