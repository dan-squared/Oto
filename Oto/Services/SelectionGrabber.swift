//
//  SelectionGrabber.swift
//  Oto
//
//  E2: reads the user's current selection in the frontmost app via a
//  synthesized Cmd+C. Snapshot → post copy → bounded read → unconditional
//  restore: the grab is read-only by contract (the replace path snapshots
//  again). Every refusal is fail-closed with the clipboard restored;
//  selection content is never logged.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Grab seam: nil means "no selection to transform" (untrusted, no frontmost
/// app, Oto itself frontmost, secure/no field, empty selection, copy failed).
/// Callers treat nil as abort-silently (menu/status note, never the pill).
protocol SelectionGrabbing: Sendable {
    func grabSelection() async -> String?
}

/// Live grab over the shared insertion edge (same trust/clipboard/focus
/// vocabulary as `RealTextInsertion`, minus posting).
@MainActor
final class LiveSelectionGrabber: SelectionGrabbing {
    private let events: InsertionEvents
    private let timings: InsertionTimings
    private let pasteboard: NSPasteboard
    private let focusCheck: any FocusChecking
    private let log = Logger(subsystem: "app.Oto", category: "selection")

    init(
        events: InsertionEvents = .live,
        timings: InsertionTimings = InsertionTimings(),
        pasteboard: NSPasteboard = .general,
        focusCheck: any FocusChecking = LiveFocusCheck()
    ) {
        self.events = events
        self.timings = timings
        self.pasteboard = pasteboard
        self.focusCheck = focusCheck
    }

    func grabSelection() async -> String? {
        guard events.isTrusted() else {
            log.info("grab refused: accessibility untrusted")
            return nil
        }
        guard let pid = events.frontmostPID(), !events.otoFrontmost() else {
            log.info("grab refused: no frontmost app or Oto itself frontmost")
            return nil
        }
        switch await focusCheck.editableFocus(for: pid) {
        case .editable, .unknown:
            break
        case .noField:
            log.info("grab refused: no editable focus, clipboard untouched")
            return nil
        case .secureField:
            log.info("grab refused: secure password field, clipboard untouched")
            return nil
        }
        let saved = PasteboardSnapshot.capture(pasteboard)
        defer { PasteboardSnapshot.restore(saved, to: pasteboard) }
        let before = pasteboard.changeCount
        guard await events.postCopy() else {
            log.info("grab failed: no copy keystroke created")
            return nil
        }
        guard await Self.pollForSelection(
            pasteboard: pasteboard, after: before,
            budget: timings.verifyBudget, poll: timings.verifyPoll, sleep: events.sleep
        ) else {
            log.info("grab empty: clipboard unchanged (no selection)")
            return nil
        }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Bounded read: the app must visibly write the clipboard (change count
    /// moves AND a non-empty string lands) or there is no selection. Pure
    /// reader loop (same shape as the insertion write-verify).
    private nonisolated static func pollForSelection(
        pasteboard: NSPasteboard, after changeCount: Int,
        budget: UInt64, poll: UInt64, sleep: (UInt64) async -> Void
    ) async -> Bool {
        func read() -> Bool {
            pasteboard.changeCount != changeCount
                && !(pasteboard.string(forType: .string) ?? "").isEmpty
        }
        if read() { return true }
        let start = Date()
        while Date().timeIntervalSince(start) * 1_000_000_000 < Double(budget) {
            await sleep(poll)
            if read() { return true }
        }
        return read()
    }
}

/// Scripted fake: returns the scripted selection (or nil), records calls.
/// Clipboard untouched by construction.
final class FakeSelectionGrabber: SelectionGrabbing, @unchecked Sendable {
    nonisolated(unsafe) var selection: String?
    private let lock = NSLock()
    nonisolated(unsafe) private var grabCount = 0

    var grabs: Int { lock.withLock { grabCount } }

    nonisolated func grabSelection() async -> String? {
        lock.withLock { grabCount += 1 }
        return selection
    }
}
