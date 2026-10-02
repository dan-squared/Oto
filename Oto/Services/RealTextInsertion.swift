//
//  RealTextInsertion.swift
//  Oto
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Paste timings. Yap-tuned starting values against the same app classes
/// (Chromium async clipboard readers); the device matrix tunes from data,
/// never from guesses.
struct InsertionTimings: Equatable, Sendable {
    /// Clipboard write → Cmd-V breather for the pasteboard server round-trip.
    /// Kept small: the write-verify poll below is the real guard, this only
    /// avoids hammering the server in a tight loop.
    var prePasteDelay: UInt64 = 30_000_000
    /// Budget for the write-verify poll: insertion fails closed rather than
    /// post ahead of an invisible write (how stale content gets pasted).
    var verifyBudget: UInt64 = 300_000_000
    var verifyPoll: UInt64 = 5_000_000
    /// Transcript linger before the old clipboard is restored. Short enough
    /// to shrink the double-paste window, long enough for async readers.
    var restoreDelay: UInt64 = 100_000_000
    /// Cap for the held-modifier drain (our default trigger IS a modifier).
    var modifierTimeout: UInt64 = 600_000_000
    var modifierPoll: UInt64 = 15_000_000
    /// Target reactivation settle before the keystroke.
    var reactivateSettle: UInt64 = 120_000_000
    /// Gap between the four Cmd-V sub-events.
    var keyStep: UInt64 = 10_000_000
}

/// The live edge, injected so tests script every gate without hardware.
/// Production uses `.live`; tests use fakes + a scratch pasteboard.
struct InsertionEvents: Sendable {
    var isTrusted: @Sendable () -> Bool
    var reactivate: @Sendable (pid_t) -> Bool
    var currentModifiers: @Sendable () -> NSEvent.ModifierFlags
    /// Advisory focus read, used ONCE pre-post as a race guard (no retries,
    /// no activation loop — those failed as policy, not timing). Never gates
    /// the common path on its own; see `insert()`.
    var frontmostPID: @Sendable () -> pid_t?
    /// Whether Oto itself owns focus (menu/Settings open). Disambiguates the
    /// fail-closed reasons: "close Oto UI + Retry" vs "switch back + Retry".
    var otoFrontmost: @Sendable () -> Bool
    /// THE delivery route: full 4-event Cmd-V into the HID tap (where hardware
    /// events enter — the device-proven path). Addressed `postToPid` delivery
    /// was tried and reverted: it drives no paste in any tested app (§9).
    /// Returns false when no event could be created (nil source/event) so
    /// callers fail closed instead of claiming a post that never existed.
    var postPaste: @Sendable () async -> Bool
    /// Undo route for `replaceLast`: full 4-event Cmd-Z through the same tap.
    /// Same fail-closed contract as `postPaste`. The caller guarantees the
    /// strict window (seconds after its own paste, zero intervening input).
    var postUndo: @Sendable () async -> Bool
    var sleep: @Sendable (UInt64) async -> Void

    static var live: InsertionEvents {
        InsertionEvents(
            isTrusted: { AXIsProcessTrusted() },
            reactivate: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                guard !app.isActive else { return true }
                return app.activate()
            },
            currentModifiers: { NSEvent.modifierFlags },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            otoFrontmost: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == Bundle.main.bundleIdentifier
            },
            postPaste: { await Self.postFullCommandV() },
            postUndo: { await Self.postFullCommandV(key: CGKeyCode(kVK_ANSI_Z)) },
            sleep: { try? await Task.sleep(nanoseconds: $0) }
        )
    }

    /// Full Command-letter as four events (Command down, key down/up,
    /// Command up) on a private source. V by default; Z powers the guarded
    /// undo step of `replaceLast`. A lone letter with `.maskCommand` works
    /// natively, but Chromium rebuilds modifier state from the raw stream and needs a
    /// genuine Command keyDown or the paste silently does nothing. The HID
    /// tap is where hardware events enter, so Chromium reads the sequence
    /// as genuine typing. Pattern follows Yap (MIT) as Oto-owned code.
    /// `NX_DEVICELCMDKEYMASK` — "left command physically down": Qt/Java apps
    /// read the device-dependent bits and ignore a bare command flag.
    static func postFullCommandV(key: CGKeyCode = CGKeyCode(kVK_ANSI_V), step: UInt64 = 10_000_000) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let commandFlags = CGEventFlags(
            rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008
        )
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = key
        var posted = true
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: key, keyDown: down
            ) else {
                posted = false
                return
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        post(commandKey, down: true, flags: commandFlags)
        try? await Task.sleep(nanoseconds: step)
        post(vKey, down: true, flags: commandFlags)
        try? await Task.sleep(nanoseconds: step)
        post(vKey, down: false, flags: commandFlags)
        try? await Task.sleep(nanoseconds: step)
        post(commandKey, down: false, flags: [])
        return posted
    }
}

/// Pure gate ordering: trust → paste. Unit-tested without hardware; the
/// live edge is proven by the device matrix only. Secure input is
/// deliberately NOT a gate: the OS delivers synthetic paste while it is
/// held (Hex posts unconditionally and lands; password managers fill
/// under it daily), so refusing on the global flag only strands sessions
/// whose target is nowhere near the holder. Secure password FIELDS still
/// refuse one layer down, via the focus check's `.secureField` verdict
/// (subrole-gated, pre-clipboard, transcript kept).
enum InsertionDecision: Equatable, Sendable {
    // Explicit: compared in decision tests from any domain (Swift 6).
    nonisolated static func == (lhs: InsertionDecision, rhs: InsertionDecision) -> Bool {
        switch (lhs, rhs) {
        case (.proceed, .proceed), (.refuseUntrusted, .refuseUntrusted):
            return true
        default:
            return false
        }
    }

    case proceed
    case refuseUntrusted

    nonisolated static func next(isTrusted: Bool) -> InsertionDecision {
        if !isTrusted { return .refuseUntrusted }
        return .proceed
    }

    nonisolated static func shouldRestore(
        wroteChangeCount: Int, wroteMarker: String,
        currentChangeCount: Int, currentMarker: String?
    ) -> Bool {
        currentChangeCount == wroteChangeCount && currentMarker == wroteMarker
    }
}

/// Real insertion (Phase 4). Gated clipboard + HID Cmd-V with guarded
/// restore; every failure keeps the transcript recoverable and the clipboard
/// untouched. No System Events route (no Automation permission, per plan);
/// no AX value-set writing (whole-value replace risk); no addressed
/// `postToPid` delivery (tried §9, drives no paste anywhere). The terminal
/// `.inserted` means "posted", never "proven" — delivery is unverifiable.
@MainActor
final class RealTextInsertion: TextInserting {
    private let events: InsertionEvents
    private let timings: InsertionTimings
    private let pasteboard: NSPasteboard
    /// Void-paste guard (catcher fix): read-only editable-focus check,
    /// injected so tests script verdicts without AX. Defaults live.
    private let focusCheck: any FocusChecking
    /// Insertion trail: gates, reactivate attempts, restores. Pids and bundle
    /// IDs only — transcript text is never logged.
    private let log = Logger(subsystem: "app.Oto", category: "insertion")

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

    func insert(_ text: String, into target: TargetApplication) async -> InsertionResult {
        // Same gates, same tail, same words as always — now shared so
        // replaceLast cannot drift from the proven policy. Covered by the
        // unchanged 02 recovery table.
        switch await readyPID(into: target, context: .insert) {
        case .refused(let result):
            return result
        case .ready(let pid):
            let saved = PasteboardSnapshot.capture(pasteboard)
            let receipt = placeOnClipboard(text)
            return await postPlacedText(text, pid: pid, saved: saved, receipt: receipt, context: .insert)
        }
    }

    /// Guarded undo-last-paste + insert replacement (swap/undo flows). Gates,
    /// tail, and restore discipline are the shared `insert` machinery; only
    /// the undo step and the failure words are new. The undo is
    /// unverifiable by nature — the caller owns the strict window (seconds
    /// after its own paste, zero intervening input) that makes the undo top
    /// near-certainly ours.
    func replaceLast(_ text: String, into target: TargetApplication) async -> InsertionResult {
        switch await readyPID(into: target, context: .replace) {
        case .refused(let result):
            return result
        case .ready(let pid):
            guard await events.postUndo() else {
                log.error("replace: no undo keystroke created, clipboard untouched")
                return .recoverableFailure(reason:
                    "The replacement could not be applied. Nothing was changed — the original text stands."
                )
            }
            await events.sleep(timings.reactivateSettle)
            let saved = PasteboardSnapshot.capture(pasteboard)
            let receipt = placeOnClipboard(text)
            return await postPlacedText(text, pid: pid, saved: saved, receipt: receipt, context: .replace)
        }
    }
    /// Post context: identical posting policy, but failure words must be
    /// honest about what already happened. A failed insert pasted nothing;
    /// a failed replace may already have undone the original.
    private enum PostContext {
        case insert
        case replace
    }

    /// Outcome of the shared pre-post gates.
    private enum PostReady {
        case ready(pid: pid_t)
        case refused(InsertionResult)
    }

    /// Shared pre-post gates (trust → pid → reactivate → settle → modifiers
    /// → focus). Identical policy for insert and replace; only the failure
    /// words differ per context. Clipboard untouched on every refusal.
    private func readyPID(into target: TargetApplication, context: PostContext) async -> PostReady {
        switch InsertionDecision.next(isTrusted: events.isTrusted()) {
        case .refuseUntrusted:
            switch context {
            case .insert:
                log.info("refused: accessibility untrusted, clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "Accessibility permission is required to insert text. Nothing was pasted — the transcript is kept for recovery."
                ))
            case .replace:
                log.info("replace refused: accessibility untrusted, clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "Accessibility permission is required to replace text. Nothing was changed — the original text stands."
                ))
            }
        case .proceed:
            break
        }

        guard let pid = target.processIdentifier else {
            switch context {
            case .insert:
                log.error("refused: no pid on target, clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "No target app was captured. Nothing was pasted — the transcript is kept for recovery."
                ))
            case .replace:
                log.error("replace refused: no pid on target, clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "No target app was captured. Nothing was changed — the original text stands."
                ))
            }
        }

        let accepted = events.reactivate(pid)
        log.info("reactivate: target \(pid, privacy: .public) activate=\(accepted, privacy: .public)")
        guard accepted else {
            switch context {
            case .insert:
                return .refused(.recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app is no longer in front. Nothing was pasted — switch back and use Retry paste, or copy the kept transcript."
                )))
            case .replace:
                return .refused(.recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app is no longer in front. Nothing was changed — the original text stands."
                )))
            }
        }
        await events.sleep(timings.reactivateSettle)
        await waitForModifiersToClear()

        switch await focusCheck.editableFocus(for: pid) {
        case .editable, .unknown:
            break
        case .noField:
            log.info("diverted: no editable focus in target \(pid, privacy: .public), clipboard untouched")
            return .refused(.noEditableField)
        case .secureField:
            switch context {
            case .insert:
                log.info("refused: secure password field in target \(pid, privacy: .public), clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "The focused field is a secure password field. Nothing was pasted — the transcript is kept; copy and paste it manually if you intend it there."
                ))
            case .replace:
                log.info("replace refused: secure password field in target \(pid, privacy: .public), clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "The focused field is a secure password field. Nothing was changed — the original text stands."
                ))
            }
        }
        return .ready(pid: pid)
    }

    /// Shared post tail: pre-paste breather → write-verify → single-read
    /// race guard → trust re-gate → post → guarded restore. `insert()` takes
    /// the identical path it always did (same order, same words); only the
    /// failure copy differs per context.
    private func postPlacedText(
        _ text: String, pid: pid_t,
        saved: [[NSPasteboard.PasteboardType: Data]],
        receipt: PasteboardReceipt, context: PostContext
    ) async -> InsertionResult {
        await events.sleep(timings.prePasteDelay)

        guard await waitForClipboard(text: text, marker: receipt.marker) else {
            log.error("verify: clipboard write never visible, failing closed")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            switch context {
            case .insert:
                return .recoverableFailure(reason:
                    "The clipboard was unavailable. Nothing was pasted — the transcript is kept for recovery."
                )
            case .replace:
                return .recoverableFailure(reason:
                    "The clipboard was unavailable. The replacement was not pasted — the original text stands."
                )
            }
        }

        guard events.frontmostPID() == pid else {
            log.error("race: focus left target \(pid, privacy: .public) pre-post, failing closed")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            switch context {
            case .insert:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. Nothing was pasted — the transcript is kept for recovery."
                ))
            case .replace:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. The replacement was not pasted — the original text stands."
                ))
            }
        }

        guard events.isTrusted() else {
            log.info("refused: accessibility revoked pre-post, clipboard restored")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            switch context {
            case .insert:
                return .recoverableFailure(reason:
                    "Accessibility permission is required to insert text. Nothing was pasted — the transcript is kept for recovery."
                )
            case .replace:
                return .recoverableFailure(reason:
                    "Accessibility permission is required to replace text. The replacement was not pasted — the original text stands."
                )
            }
        }

        guard await events.postPaste() else {
            log.error("post: no keystroke created, failing closed")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            switch context {
            case .insert:
                return .recoverableFailure(reason:
                    "The keystroke could not be posted. Nothing was pasted — the transcript is kept for recovery."
                )
            case .replace:
                return .recoverableFailure(reason:
                    "The keystroke could not be posted. The replacement was not pasted — the original text stands."
                )
            }
        }
        log.info("posted HID Cmd-V to frontmost (delivery unverified) for target \(pid, privacy: .public)")
        scheduleRestore(saved: saved, receipt: receipt)
        return .inserted
    }

    /// User-driven recovery post (production menu until the Flow Bar). FOCUS
    /// gates are deliberately absent: the person switched back to the target
    /// app themselves and pressed the button — they are the check. Trust
    /// is NOT waivable (a physical precondition for posting, not a policy
    /// judgment): without it the keystroke never exists while the caller
    /// reports success. Clipboard discipline + write-verify + guarded
    /// restore are kept. Returns true when the keystroke was posted
    /// (delivery itself remains unverified, as always).
    func retryPostToFrontmost(_ text: String) async -> Bool {
        guard events.isTrusted() else {
            log.info("retry: refused, accessibility untrusted")
            return false
        }
        let front = NSWorkspace.shared.frontmostApplication
        log.info("retry: posting to frontmost \(front?.bundleIdentifier ?? "?", privacy: .public) (\(front?.processIdentifier ?? -1, privacy: .public))")
        let saved = PasteboardSnapshot.capture(pasteboard)
        let receipt = placeOnClipboard(text)
        await events.sleep(timings.prePasteDelay)
        guard await waitForClipboard(text: text, marker: receipt.marker) else {
            PasteboardSnapshot.restore(saved, to: pasteboard)
            return false
        }
        guard await events.postPaste() else {
            log.info("retry: no keystroke created")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            return false
        }
        log.info("retry: posted HID Cmd-V (delivery unverified)")
        scheduleRestore(saved: saved, receipt: receipt)
        return true
    }

    // MARK: - Private

    /// Writes text + session marker; the returned receipt proves ownership.
    /// The change count is read AFTER all writes (each write bumps it).
    private func placeOnClipboard(_ text: String) -> PasteboardReceipt {
        let marker = UUID().uuidString
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(marker, forType: PasteboardReceipt.markerType)
        return PasteboardReceipt(marker: marker, changeCount: pasteboard.changeCount)
    }

    /// Bounded write-verify: the post must never run ahead of an invisible
    /// clipboard write (that pastes stale content). The loop body is a pure
    /// reader so tests script immediate/late/never visibility; production
    /// reads the live pasteboard.
    private func waitForClipboard(text: String, marker: String) async -> Bool {
        let pasteboard = pasteboard
        return await Self.pollForMatch(
            budget: timings.verifyBudget,
            poll: timings.verifyPoll,
            sleep: events.sleep,
            read: {
                pasteboard.string(forType: .string) == text
                    && pasteboard.string(forType: PasteboardReceipt.markerType) == marker
            }
        )
    }

    /// Names the fix the person can apply: Oto-frontmost (close menu/Settings,
    /// then Retry) vs a genuine switch (switch back, then Retry). Gate logic
    /// is untouched — this only words the failure.
    private func focusFailureReason(switchedReason: String) -> String {
        guard events.otoFrontmost() else { return switchedReason }
        return "Oto itself is in front (menu or Settings open). Close it, switch back to the target app, and use Retry paste — the transcript is kept."
    }

    static func pollForMatch(        budget: UInt64,
        poll: UInt64,
        sleep: (UInt64) async -> Void,
        read: () -> Bool
    ) async -> Bool {
        if read() { return true }
        let start = Date()
        while Date().timeIntervalSince(start) * 1_000_000_000 < Double(budget) {
            await sleep(poll)
            if read() { return true }
        }
        return read()
    }

    private func waitForModifiersToClear() async {        let watched: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        let start = Date()
        while Date().timeIntervalSince(start) * 1_000_000_000 < Double(timings.modifierTimeout) {
            if events.currentModifiers().intersection(watched).isEmpty { return }
            await events.sleep(timings.modifierPoll)
        }
        // Budget exhausted with modifiers still held: Sticky Keys users
        // legitimately hold modifiers here, so failing closed would strand
        // valid sessions — proceed and log loudly instead. The mistype
        // hazard above stands; this line is its device-matrix witness.
        log.error("modifiers: still held after timeout, posting anyway")
    }

    /// One bounded Task per insertion (not per event): restores the previous
    /// clipboard only if nobody touched it since — a user copy in between
    /// wins, and our text stays available for manual paste.
    private func scheduleRestore(
        saved: [[NSPasteboard.PasteboardType: Data]],
        receipt: PasteboardReceipt
    ) {
        let pasteboard = pasteboard
        let delay = timings.restoreDelay
        let sleep = events.sleep
        Task {
            await sleep(delay)
            guard InsertionDecision.shouldRestore(
                wroteChangeCount: receipt.changeCount,
                wroteMarker: receipt.marker,
                currentChangeCount: pasteboard.changeCount,
                currentMarker: pasteboard.string(forType: PasteboardReceipt.markerType)
            ) else { return }
            PasteboardSnapshot.restore(saved, to: pasteboard)
        }
    }
}
