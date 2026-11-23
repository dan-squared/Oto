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
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os
import Synchronization

/// Grab seam: nil means "no selection to transform" (untrusted, no frontmost
/// app, Oto itself frontmost, secure/no field, empty selection, copy failed).
/// Callers treat nil as abort-silently (menu/status note, never the pill).
protocol SelectionGrabbing: Sendable {
    func grabSelection() async -> String?
}

/// Outcome of the read-only Accessibility selection probe.
enum AXSelectionRead: Equatable, Sendable {
    /// AX returned a non-empty selected string (zero clipboard touch).
    case selected(String)
    /// AX authoritatively reported `""` (empty selection): do NOT fall back to
    /// `Cmd+C`, preventing editors like VS Code/Cursor/Zed from copying the
    /// entire current line.
    case empty
    /// AX could not answer (unsupported, noValue, timeout, opaque surface):
    /// caller may fall back to guarded `Cmd+C`.
    case unavailable
}

/// Live grab: read-only AX `kAXSelectedTextAttribute` first, falling back to
/// guarded `Cmd+C` only when AX cannot answer. Selection content is never logged.
@MainActor
final class LiveSelectionGrabber: SelectionGrabbing {
    nonisolated static let axTimeoutSeconds: Float = 0.25
    nonisolated static let axReadTimeoutNanoseconds: UInt64 = 250_000_000

    private let events: InsertionEvents
    private let timings: InsertionTimings
    private let pasteboard: NSPasteboard
    private let focusCheck: any FocusChecking
    private let axSelectionReader: @Sendable (pid_t) async -> AXSelectionRead
    private let log = Logger(subsystem: "app.Oto", category: "selection")

    init(
        events: InsertionEvents = .live,
        timings: InsertionTimings = InsertionTimings(),
        pasteboard: NSPasteboard = .general,
        focusCheck: any FocusChecking = LiveFocusCheck(),
        axSelectionReader: @escaping @Sendable (pid_t) async -> AXSelectionRead = {
            await LiveSelectionGrabber.readAXSelection(pid: $0)
        }
    ) {
        self.events = events
        self.timings = timings
        self.pasteboard = pasteboard
        self.focusCheck = focusCheck
        self.axSelectionReader = axSelectionReader
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

        // AX-first read: zero clipboard mutation, zero beep, and authoritative
        // empty detection (eliminates VS Code / Cursor / Zed whole-line copy).
        switch await axSelectionReader(pid) {
        case .selected(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return text
        case .empty:
            log.info("grab empty: AX reported empty selection, skipping Cmd+C")
            return nil
        case .unavailable:
            break
        }

        // Fallback: guarded Cmd+C. Check posting authorization, drain held
        // transform shortcut modifiers, and re-verify target focus before posting.
        guard events.postingAuthorized() else {
            log.info("grab refused: synthetic posting blocked")
            return nil
        }
        await waitForModifiersToClear()
        guard events.frontmostPID() == pid, !events.otoFrontmost() else {
            log.info("grab refused: focus left target \(pid, privacy: .public) before copy")
            return nil
        }

        PasteKeycodeResolver.warmLayoutCacheOnMainThread()
        let saved = PasteboardSnapshot.capture(pasteboard)
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
        let copiedChangeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        // Guarded restore: only restore if nobody else modified the clipboard
        // since the app's Cmd+C landed.
        if pasteboard.changeCount == copiedChangeCount {
            PasteboardSnapshot.restore(saved, to: pasteboard)
        }
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    private func waitForModifiersToClear() async {
        let watched: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(clamping: timings.modifierTimeout))
        while clock.now < deadline {
            if events.currentModifiers().intersection(watched).isEmpty { return }
            await events.sleep(timings.modifierPoll)
        }
    }

    /// Bounded read: the app must visibly write the clipboard (change count
    /// moves AND a non-empty string lands) or there is no selection. Uses a
    /// monotonic `ContinuousClock` deadline.
    private nonisolated static func pollForSelection(
        pasteboard: NSPasteboard, after changeCount: Int,
        budget: UInt64, poll: UInt64, sleep: (UInt64) async -> Void
    ) async -> Bool {
        func read() -> Bool {
            pasteboard.changeCount != changeCount
                && !(pasteboard.string(forType: .string) ?? "").isEmpty
        }
        if read() { return true }
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(clamping: budget))
        while clock.now < deadline {
            await sleep(poll)
            if read() { return true }
        }
        return read()
    }

    /// Off-main-thread read-only AX selection probe with hard timeout guard.
    private final class ClaimGate: Sendable {
        private let claimed = Mutex(false)
        nonisolated func claim() -> Bool {
            claimed.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
        }
    }

    nonisolated static func readAXSelection(pid: pid_t) async -> AXSelectionRead {
        await withCheckedContinuation { continuation in
            let gate = ClaimGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: Self.axReadTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                if gate.claim() {
                    continuation.resume(returning: .unavailable)
                }
            }
            DispatchQueue.global(qos: .utility).async {
                let result = Self.readAXSelectionSync(pid: pid)
                timeoutTask.cancel()
                if gate.claim() {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    nonisolated static func readAXSelectionSync(pid: pid_t) -> AXSelectionRead {
        guard AXIsProcessTrusted(), let element = focusedElement(pid: pid) else {
            return .unavailable
        }
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &raw
        )
        guard error == .success, let text = raw as? String else {
            return .unavailable
        }
        return text.isEmpty ? .empty : .selected(text)
    }

    private nonisolated static func focusedElement(pid: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeoutSeconds)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &raw
        ) == .success,
            let value = raw,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        {
            let element = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success, owner == pid {
                return element
            }
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeoutSeconds)
        raw = nil
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &raw
        ) == .success,
            let value = raw,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        return element
    }
}

/// Scripted fake: returns the scripted selection (or nil), records calls.
/// Clipboard untouched by construction; state protected by `Synchronization.Mutex`.
final class FakeSelectionGrabber: SelectionGrabbing, Sendable {
    private struct State: Sendable {
        var selection: String?
        var grabCount = 0
    }

    private let state = Mutex(State())

    nonisolated var selection: String? {
        get { state.withLock { $0.selection } }
        set { state.withLock { $0.selection = newValue } }
    }

    nonisolated var grabs: Int { state.withLock { $0.grabCount } }

    nonisolated func grabSelection() async -> String? {
        state.withLock {
            $0.grabCount += 1
            return $0.selection
        }
    }
}
