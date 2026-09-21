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
    var secureInputEnabled: @Sendable () -> Bool
    var secureHolderName: @Sendable () -> String?
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
    var postPaste: @Sendable () async -> Void
    var sleep: @Sendable (UInt64) async -> Void

    static var live: InsertionEvents {
        InsertionEvents(
            isTrusted: { AXIsProcessTrusted() },
            secureInputEnabled: { SecureInput.isEnabled },
            secureHolderName: { SecureInput.holderName() },
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
            sleep: { try? await Task.sleep(nanoseconds: $0) }
        )
    }

    /// Full Cmd-V as four events (Command down, V down, V up, Command up) on
    /// a private source. A lone V with `.maskCommand` works natively, but
    /// Chromium rebuilds modifier state from the raw stream and needs a
    /// genuine Command keyDown or the paste silently does nothing. The HID
    /// tap is where hardware events enter, so Chromium reads the sequence
    /// as genuine typing. Pattern follows Yap (MIT) as Oto-owned code.
    /// `NX_DEVICELCMDKEYMASK` — "left command physically down": Qt/Java apps
    /// read the device-dependent bits and ignore a bare command flag.
    static func postFullCommandV(step: UInt64 = 10_000_000) async {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let commandFlags = CGEventFlags(
            rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008
        )
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: key, keyDown: down
            ) else { return }
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
    }
}

/// Pure gate ordering: trust → secure input → paste. Unit-tested without
/// hardware; the live edge is proven by the device matrix only.
enum InsertionDecision: Equatable, Sendable {
    case proceed
    case refuseUntrusted
    case refuseSecureInput(holder: String?)

    static func next(isTrusted: Bool, secureInput: Bool, holder: String?) -> InsertionDecision {
        if !isTrusted { return .refuseUntrusted }
        if secureInput { return .refuseSecureInput(holder: holder) }
        return .proceed
    }

    static func shouldRestore(
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
    /// Insertion trail: gates, reactivate attempts, restores. Pids and bundle
    /// IDs only — transcript text is never logged.
    private let log = Logger(subsystem: "app.Oto", category: "insertion")

    init(
        events: InsertionEvents = .live,
        timings: InsertionTimings = InsertionTimings(),
        pasteboard: NSPasteboard = .general
    ) {
        self.events = events
        self.timings = timings
        self.pasteboard = pasteboard
    }

    func insert(_ text: String, into target: TargetApplication) async -> InsertionResult {
        switch InsertionDecision.next(
            isTrusted: events.isTrusted(),
            secureInput: events.secureInputEnabled(),
            holder: events.secureHolderName()
        ) {
        case .refuseUntrusted:
            // Clipboard untouched by design (02 recovery: Copy is an explicit
            // user action, not an auto-overwrite). The transcript survives in
            // the coordinator's recoveryTranscript + the menu copy action.
            log.info("refused: accessibility untrusted, clipboard untouched")
            return .recoverableFailure(reason:
                "Accessibility permission is required to insert text. Nothing was pasted — the transcript is kept for recovery."
            )
        case .refuseSecureInput(let holder):
            // Same discipline: a global secure-input holder (any app, e.g. a
            // background sudo prompt) must not cost the person their clipboard.
            log.info("refused: secure input held by \(holder ?? "?", privacy: .public), clipboard untouched")
            let who = holder.map { " (held by \($0))" } ?? ""
            return .recoverableFailure(reason:
                "Secure input is enabled\(who). Synthetic keystrokes are blocked — nothing was pasted, the transcript is kept for recovery."
            )
        case .proceed:
            break
        }

        // No pid means capture found no frontmost app (screen locked, login
        // window): there is nowhere safe to paste. Fail closed, untouched.
        guard let pid = target.processIdentifier else {
            log.error("refused: no pid on target, clipboard untouched")
            return .recoverableFailure(reason:
                "No target app was captured. Nothing was pasted — the transcript is kept for recovery."
            )
        }

        // Sandbox-valid proxy, not a courtesy: `reactivate` answers true when
        // the target is already frontmost (or activation succeeded, the
        // non-sandboxed future). A `false` here is the sandboxed norm after an
        // app switch — posting anyway would land in the WRONG app (02 forbids
        // substituting the frontmost app), so fail closed with recovery. The
        // menu retry button is the escape hatch.
        let accepted = events.reactivate(pid)
        log.info("reactivate: target \(pid, privacy: .public) activate=\(accepted, privacy: .public)")
        guard accepted else {
            return .recoverableFailure(reason: focusFailureReason(switchedReason:
                "The target app is no longer in front. Nothing was pasted — switch back and use Retry paste, or copy the kept transcript."
            ))
        }
        await events.sleep(timings.reactivateSettle)

        // Insurance: a held modifier leaking into Cmd-V mistypes (our own
        // default trigger is a held modifier; the release precedes us, but
        // some apps track modifiers from the raw stream themselves).
        await waitForModifiersToClear()

        let saved = PasteboardSnapshot.capture(pasteboard)
        let receipt = placeOnClipboard(text)
        await events.sleep(timings.prePasteDelay)

        // Never post ahead of an invisible write: that is how stale content
        // gets pasted. Fail closed on timeout, clipboard restored on the spot.
        guard await waitForClipboard(text: text, marker: receipt.marker) else {
            log.error("verify: clipboard write never visible, failing closed")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            return .recoverableFailure(reason:
                "The clipboard was unavailable. Nothing was pasted — the transcript is kept for recovery."
            )
        }

        // Single-read race guard: someone took focus during the settle above.
        // No retries (refusals are policy, not timing) — restore synchronously
        // and fail closed rather than paste into the new frontmost app.
        guard events.frontmostPID() == pid else {
            log.error("race: focus left target \(pid, privacy: .public) pre-post, failing closed")
            PasteboardSnapshot.restore(saved, to: pasteboard)
            return .recoverableFailure(reason: focusFailureReason(switchedReason:
                "The target app lost focus just before pasting. Nothing was pasted — the transcript is kept for recovery."
            ))
        }

        await events.postPaste()
        log.info("posted HID Cmd-V to frontmost (delivery unverified) for target \(pid, privacy: .public)")
        scheduleRestore(saved: saved, receipt: receipt)
        return .inserted
    }

    /// User-driven recovery post (production menu until the Flow Bar). Gates are
    /// DELIBERATELY absent: the person switched back to the target app
    /// themselves and pressed the button — they are the check. Clipboard
    /// discipline + write-verify + guarded restore are kept; only the
    /// trust/focus policy gates are skipped. Returns true when the keystroke
    /// was posted (delivery itself remains unverified, as always).
    func retryPostToFrontmost(_ text: String) async -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        log.info("retry: posting to frontmost \(front?.bundleIdentifier ?? "?", privacy: .public) (\(front?.processIdentifier ?? -1, privacy: .public))")
        let saved = PasteboardSnapshot.capture(pasteboard)
        let receipt = placeOnClipboard(text)
        await events.sleep(timings.prePasteDelay)
        guard await waitForClipboard(text: text, marker: receipt.marker) else {
            PasteboardSnapshot.restore(saved, to: pasteboard)
            return false
        }
        await events.postPaste()
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
