//
//  RealTextInsertion.swift
//  Oto
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Hidden A/B seam for keystroke-shape experiments (8b Slice 3): three
/// UserDefaults keys with today-value defaults. Read once at composition
/// (app launch) — the matrix flips values via `defaults write` + relaunch,
/// zero rebuilds. No UI, deliberately: winners graduate to real defaults,
/// losers die with data. Defaults byte-identical to today — the seam
/// itself changes nothing (pinned by test).
struct InsertionExperiment: Sendable, Equatable {
    /// Synthetic event source: private-state (today) vs system-default
    /// (null source, the Hex shape).
    var useDefaultEventSource: Bool
    /// Gap between the Cmd-V sub-events, ns (today 10M; 0 = Hex shape:
    /// back-to-back posts).
    var keyStepNs: UInt64
    /// Transcript linger before clipboard restore, ns (today 100M;
    /// Hex uses 500M for slow readers).
    var restoreDelayNs: UInt64

    nonisolated static let sourceKey = "app.Oto.xpEventSource"
    nonisolated static let keyStepKey = "app.Oto.xpKeyStepNs"
    nonisolated static let restoreDelayKey = "app.Oto.xpRestoreDelayNs"

    nonisolated static func current(defaults: UserDefaults = .standard) -> InsertionExperiment {
        let source = defaults.string(forKey: sourceKey) ?? "private"
        let keyStep = defaults.object(forKey: keyStepKey) as? UInt64
        let restore = defaults.object(forKey: restoreDelayKey) as? UInt64
        return InsertionExperiment(
            useDefaultEventSource: source == "default",
            keyStepNs: keyStep ?? InsertionTimings().keyStep,
            restoreDelayNs: restore ?? InsertionTimings().restoreDelay
        )
    }
}

/// Synthetic keystroke event source. Private-state is today's HID path;
/// system-default (null source) is the Hex shape under test.
enum SyntheticEventSource: Sendable {
    case privateState
    case systemDefault
}

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
    /// Transcript linger before the old clipboard is restored for unverifiable
    /// async readers (Chromium/Electron/web editors). 500 ms matches Hex's
    /// battle-tested window so slow pasteboard readers never paste stale data.
    /// Native apps whose `AXNumberOfCharacters` grows still restore immediately.
    var restoreDelay: UInt64 = 500_000_000
    /// Cap for the held-modifier drain (our default trigger IS a modifier).
    var modifierTimeout: UInt64 = 600_000_000
    var modifierPoll: UInt64 = 15_000_000
    /// Target reactivation settle before the keystroke. Serves as the FLOOR
    /// of the readiness wait (see `readyBudget`), not as a blind sleep.
    var reactivateSettle: UInt64 = 120_000_000
    /// Readiness wait ceiling: keep checking "is the target frontmost" up to
    /// here, then post anyway. Advisory only — the pre-post frontmost guard
    /// owns refusal, so expiry must never strand a session.
    var readyBudget: UInt64 = 400_000_000
    var readyPoll: UInt64 = 15_000_000
    /// Post-paste delivery verification: base budget, growth per KB of text
    /// (bigger pastes render slower), hard ceiling, poll interval.
    var deliveryBudget: UInt64 = 300_000_000
    var deliveryPerKB: UInt64 = 15_000_000
    var deliveryBudgetCap: UInt64 = 1_500_000_000
    var deliveryPoll: UInt64 = 15_000_000
    /// Gap between the four Cmd-V sub-events.
    var keyStep: UInt64 = 10_000_000
}

/// The live edge, injected so tests script every gate without hardware.
/// Production uses `.live`; tests use fakes + a scratch pasteboard.
struct InsertionEvents: Sendable {
    var isTrusted: @Sendable () -> Bool
    /// Whether the OS will deliver a synthetic keystroke at all
    /// (`CGPreflightPostEventAccess`). Distinct from Accessibility: a grant
    /// can read AX while posting stays blocked, and a dropped post used to
    /// be reported as success. Defaulted for tests and fakes that script the
    /// other gates.
    var postingAuthorized: @Sendable () -> Bool = { true }
    var reactivate: @Sendable (pid_t) -> Bool
    var currentModifiers: @Sendable () -> NSEvent.ModifierFlags
    /// Advisory focus read, used ONCE pre-post as a race guard (no retries,
    /// no activation loop — those failed as policy, not timing). Never gates
    /// the common path on its own; see `insert()`.
    var frontmostPID: @Sendable () -> pid_t?
    /// Bundle ID of the currently frontmost app (used by `retryPostToFrontmost`
    /// to check caret-opacity without bypassing injected test seams).
    var frontmostBundleID: @Sendable () -> String? = { nil }
    /// Whether Oto itself owns focus (menu/Settings open). Disambiguates the
    /// fail-closed reasons: "close Oto UI + Retry" vs "switch back + Retry".
    var otoFrontmost: @Sendable () -> Bool
    /// THE delivery route: full 4-event Cmd-V into the HID tap (where hardware
    /// events enter — the device-proven path). Addressed `postToPid` delivery
    /// was tried and reverted: it drives no paste in any tested app (§9).
    /// Returns false when no event could be created (nil source/event) so
    /// callers fail closed instead of claiming a post that never existed.
    var postPaste: @Sendable () async -> Bool
    /// Selection-grab route for `SelectionGrabber`: full 4-event Cmd-C
    /// through the same tap. Same fail-closed contract as `postPaste`.
    var postCopy: @Sendable () async -> Bool
    /// Undo route for `replaceLast`: full 4-event Cmd-Z through the same tap.
    /// Same fail-closed contract as `postPaste`. The caller guarantees the
    /// strict window (seconds after its own paste, zero intervening input).
    var postUndo: @Sendable () async -> Bool
    /// Optional Unicode burst typing route (borrowed from Hex): used when a
    /// target app dynamically matches Chromium 155–156 (whose pasteboard
    /// observer races synthetic Cmd-V) so dictation still lands without
    /// hardcoding browser bundle IDs. Nil on scripted test fakes unless wired.
    var typeText: (@Sendable (String) async -> Bool)? = nil
    /// Resolves whether `pid` requires direct Unicode typing instead of
    /// clipboard paste (default false in scripted tests; `.live` inspects the
    /// running bundle's embedded Chromium framework dynamically).
    var prefersDirectTyping: @Sendable (pid_t) -> Bool = { _ in false }
    /// Character immediately before the focused field's insertion point, for
    /// Hex-style Smart Spacing. Default nil in scripted tests; `.live` reads
    /// via `SmartSpacing.charBeforeCaret(pid:)` when `SmartSpacing.isEnabled()`.
    var charBeforeCaret: @Sendable (pid_t) -> Character? = { _ in nil }
    var sleep: @Sendable (UInt64) async -> Void

    static var live: InsertionEvents {
        InsertionEvents(
            isTrusted: { AXIsProcessTrusted() },
            postingAuthorized: { CGPreflightPostEventAccess() },
            reactivate: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                guard !app.isActive else { return true }
                return app.activate()
            },
            currentModifiers: {
                Self.modifierFlags(from: CGEventSource.flagsState(.combinedSessionState))
            },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            otoFrontmost: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == Bundle.main.bundleIdentifier
            },
            postPaste: { await Self.postFullCommandV(key: PasteKeycodeResolver.keyCode(for: "v")) },
            postCopy: { await Self.postFullCommandV(key: PasteKeycodeResolver.keyCode(for: "c")) },
            postUndo: { await Self.postFullCommandV(key: PasteKeycodeResolver.keyCode(for: "z")) },
            typeText: { text in DirectTextTyping.postBurst(text) },
            prefersDirectTyping: { pid in ChromiumRaceDetector.shouldTypeInsteadOfPaste(pid: pid) },
            charBeforeCaret: { pid in
                guard SmartSpacing.isEnabled() else { return nil }
                return SmartSpacing.charBeforeCaret(pid: pid)
            },
            sleep: { try? await Task.sleep(nanoseconds: $0) }
        )
    }

    /// Converts live WindowServer modifier state (`CGEventSource.flagsState`)
    /// into `NSEvent.ModifierFlags` so held-modifier draining sees real
    /// hardware state even when Oto is not the active app.
    nonisolated static func modifierFlags(from cgFlags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskCommand) { result.insert(.command) }
        if cgFlags.contains(.maskShift) { result.insert(.shift) }
        if cgFlags.contains(.maskAlternate) { result.insert(.option) }
        if cgFlags.contains(.maskControl) { result.insert(.control) }
        if cgFlags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }

    /// Full Command-letter as four events (Command `.flagsChanged` down, key
    /// down/up, Command `.flagsChanged` up) on a private source. V by default;
    /// Z powers the guarded undo step of `replaceLast`. A lone letter with
    /// `.maskCommand` works natively, but Chromium rebuilds modifier state from
    /// the raw stream and needs genuine Command flag transitions or the paste
    /// silently does nothing. If cancelled mid-sequence after Command down, any
    /// remaining letter press is skipped and Command up is still posted so
    /// Command can never stick.
    /// Every event carries the Oto synthetic marker (`kCGEventSourceUserData`)
    /// so device trails and the HID tap distinguish Oto keystrokes from hardware.
    nonisolated static let syntheticMarker: Int64 = 0x4F54_4F // "OTO"
    static func postFullCommandV(
        key: CGKeyCode = CGKeyCode(kVK_ANSI_V),
        step: UInt64 = 10_000_000,
        source: SyntheticEventSource = .privateState
    ) async -> Bool {
        let eventSource: CGEventSource?
        switch source {
        case .privateState:
            guard let created = CGEventSource(stateID: .privateState) else { return false }
            eventSource = created
        case .systemDefault:
            eventSource = nil
        }
        eventSource?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let commandFlags = CGEventFlags(
            rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008
        )
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = key

        func postModifier(flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(
                keyboardEventSource: eventSource, virtualKey: commandKey, keyDown: false
            ) else {
                return false
            }
            event.type = .flagsChanged
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
            return true
        }

        func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(
                keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: down
            ) else {
                return false
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
            return true
        }

        guard postModifier(flags: commandFlags) else { return false }
        var posted = true
        var keyPressed = false
        do {
            if step > 0 { try await Task.sleep(nanoseconds: step) }
            try Task.checkCancellation()
            if postKey(vKey, down: true, flags: commandFlags) {
                keyPressed = true
            } else {
                posted = false
            }
            if step > 0 { try await Task.sleep(nanoseconds: step) }
            if !postKey(vKey, down: false, flags: commandFlags) { posted = false }
            keyPressed = false
            if step > 0 { try await Task.sleep(nanoseconds: step) }
        } catch {
            if keyPressed {
                _ = postKey(vKey, down: false, flags: commandFlags)
            }
            _ = postModifier(flags: [])
            return false
        }
        if !postModifier(flags: []) { posted = false }
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
        case (.proceed, .proceed),
            (.refuseUntrusted, .refuseUntrusted),
            (.refusePostingBlocked, .refusePostingBlocked):
            return true
        default:
            return false
        }
    }

    case proceed
    case refuseUntrusted
    /// Accessibility may be granted while the WindowServer still refuses to
    /// deliver synthetic events. Posting then is a silent no-op, so it is
    /// refused here instead of reported as an insert.
    case refusePostingBlocked

    nonisolated static func next(
        isTrusted: Bool, postingAuthorized: Bool = true
    ) -> InsertionDecision {
        if !isTrusted { return .refuseUntrusted }
        if !postingAuthorized { return .refusePostingBlocked }
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
    /// Post-paste delivery check (v7): proves the caret moved where the app
    /// publishes the required text attributes; `.unverifiable` elsewhere.
    private let deliveryCheck: any DeliveryChecking
    /// Insertion trail: gates, reactivate attempts, restores. Pids and bundle
    /// IDs only — transcript text is never logged.
    private let log = Logger(subsystem: "app.Oto", category: "insertion")

    init(
        events: InsertionEvents = .live,
        timings: InsertionTimings = InsertionTimings(),
        pasteboard: NSPasteboard = .general,
        focusCheck: any FocusChecking = LiveFocusCheck(),
        deliveryCheck: any DeliveryChecking = LiveDeliveryCheck()
    ) {
        self.events = events
        self.timings = timings
        self.pasteboard = pasteboard
        self.focusCheck = focusCheck
        self.deliveryCheck = deliveryCheck
    }

    /// Minimum restore floor (50 ms) when delivery reported `.landed` via caret
    /// movement alone without positive `AXNumberOfCharacters` growth.
    nonisolated static let caretOnlyRestoreFloorNs: UInt64 = 50_000_000

    func insert(_ text: String, into target: TargetApplication) async -> InsertionResult {
        // Same gates, same tail, same words as always — now shared so
        // replaceLast cannot drift from the proven policy. Covered by the
        // unchanged 02 recovery table.
        switch await readyPID(into: target, context: .insert) {
        case .refused(let result):
            return result
        case .ready(let pid):
            let formatted = SmartSpacing.apply(
                to: text,
                characterBeforeCaret: events.charBeforeCaret(pid)
            )
            if let direct = await postDirectIfPreferred(formatted, pid: pid, context: .insert) {
                return direct
            }
            let saved = PasteboardSnapshot.capture(pasteboard)
            let receipt = placeOnClipboard(formatted)
            return await postPlacedText(
                formatted, pid: pid, saved: saved, receipt: receipt, context: .insert,
                caretOpaque: CaretOpaqueApps.isOpaque(target.bundleIdentifier)
            )
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
            PasteKeycodeResolver.warmLayoutCacheOnMainThread()
            guard await events.postUndo() else {
                log.error("replace: no undo keystroke created, clipboard untouched")
                return .recoverableFailure(reason:
                    "The replacement could not be applied. Nothing was changed — the original text stands."
                )
            }
            await events.sleep(timings.reactivateSettle)
            if let direct = await postDirectIfPreferred(text, pid: pid, context: .replace) {
                return direct
            }
            let saved = PasteboardSnapshot.capture(pasteboard)
            let receipt = placeOnClipboard(text)
            return await postPlacedText(
                text, pid: pid, saved: saved, receipt: receipt, context: .replace,
                caretOpaque: CaretOpaqueApps.isOpaque(target.bundleIdentifier)
            )
        }
    }
    /// Plain selection replacement (E2 transforms): the caller's selection
    /// is still selected, so a guarded paste overwrites exactly it. Gates,
    /// tail, and restore discipline are the shared `insert` machinery; only
    /// the failure words are selection-honest. No undo step (unlike
    /// `replaceLast`) — native Cmd+Z in the target app is the undo path.
    func replaceSelection(_ text: String, into target: TargetApplication) async -> InsertionResult {
        switch await readyPID(into: target, context: .replaceSelection) {
        case .refused(let result):
            return result
        case .ready(let pid):
            if let direct = await postDirectIfPreferred(text, pid: pid, context: .replaceSelection) {
                return direct
            }
            let saved = PasteboardSnapshot.capture(pasteboard)
            let receipt = placeOnClipboard(text)
            return await postPlacedText(
                text, pid: pid, saved: saved, receipt: receipt, context: .replaceSelection,
                caretOpaque: CaretOpaqueApps.isOpaque(target.bundleIdentifier)
            )
        }
    }

    /// Direct Unicode burst typing path (borrowed from Hex): bypasses clipboard
    /// paste for targets dynamically detected as Chromium 155–156 (where
    /// synthetic Cmd+V races Chromium's pasteboard change notification).
    /// Runs the same frontmost + trust + posting-authorized guards as clipboard
    /// paste, never touches the clipboard.
    private func postDirectIfPreferred(
        _ text: String,
        pid: pid_t,
        context: PostContext
    ) async -> InsertionResult? {
        guard events.prefersDirectTyping(pid), let typeText = events.typeText else {
            return nil
        }
        guard events.frontmostPID() == pid else {
            log.error("race: focus left target \(pid, privacy: .public) pre-type, failing closed")
            switch context {
            case .insert:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. Nothing was pasted — the transcript is kept for recovery."
                ))
            case .replace:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. The previous paste may have been undone — switch back and press ⌘⇧Z, or use Retry paste."
                ))
            case .replaceSelection:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. The replacement was not pasted — your text stands as it was."
                ))
            }
        }
        guard events.isTrusted() else {
            return .recoverableFailure(reason:
                "Accessibility permission is required to insert text. Nothing was pasted — the transcript is kept for recovery."
            )
        }
        guard events.postingAuthorized() else {
            return .recoverableFailure(reason: postingBlockedReason(context, undoAlreadyRan: context == .replace))
        }
        guard await typeText(text) else {
            log.error("direct-type: failed to create unicode keystrokes for target \(pid, privacy: .public)")
            return .recoverableFailure(reason:
                "The keystroke could not be posted. Nothing was pasted — the transcript is kept for recovery."
            )
        }
        log.info("posted direct Unicode burst for target \(pid, privacy: .public) chars=\(text.count, privacy: .public)")
        return .inserted
    }
    /// Post context: identical posting policy, but failure words must be
    /// honest about what already happened. A failed insert pasted nothing;
    /// a failed replace may already have undone the original.
    private enum PostContext {
        case insert
        case replace
        case replaceSelection
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
        switch InsertionDecision.next(
            isTrusted: events.isTrusted(),
            postingAuthorized: events.postingAuthorized()
        ) {
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
            case .replaceSelection:
                log.info("replaceSelection refused: accessibility untrusted, clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "Accessibility permission is required to replace the selection. Nothing was changed — your text stands as it was."
                ))
            }
        case .refusePostingBlocked:
            log.info("refused: synthetic posting blocked, clipboard untouched")
            return .refused(.recoverableFailure(reason: postingBlockedReason(context)))
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
            case .replaceSelection:
                log.error("replaceSelection refused: no pid on target, clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "No target app was captured. Nothing was changed — your text stands as it was."
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
            case .replaceSelection:
                return .refused(.recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app is no longer in front. Nothing was changed — your text stands as it was."
                )))
            }
        }
        await waitForReadiness(pid: pid)
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
            case .replaceSelection:
                log.info("replaceSelection refused: secure password field in target \(pid, privacy: .public), clipboard untouched")
                return .refused(.recoverableFailure(reason:
                    "The focused field is a secure password field. Nothing was changed — your text stands as it was."
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
        receipt: PasteboardReceipt, context: PostContext,
        caretOpaque: Bool
    ) async -> InsertionResult {
        await events.sleep(timings.prePasteDelay)

        guard await waitForClipboard(text: text, marker: receipt.marker) else {
            log.error("verify: clipboard write never visible, failing closed")
            restoreIfStillOwned(saved: saved, receipt: receipt)
            switch context {
            case .insert:
                return .recoverableFailure(reason:
                    "The clipboard was unavailable. Nothing was pasted — the transcript is kept for recovery."
                )
            case .replace:
                return .recoverableFailure(reason:
                    "The clipboard was unavailable. The previous paste may have been undone — press ⌘⇧Z to restore it, or use Retry paste."
                )
            case .replaceSelection:
                return .recoverableFailure(reason:
                    "The clipboard was unavailable. The replacement was not pasted — your text stands as it was."
                )
            }
        }

        guard events.frontmostPID() == pid else {
            log.error("race: focus left target \(pid, privacy: .public) pre-post, failing closed")
            restoreIfStillOwned(saved: saved, receipt: receipt)
            switch context {
            case .insert:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. Nothing was pasted — the transcript is kept for recovery."
                ))
            case .replace:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. The previous paste may have been undone — switch back and press ⌘⇧Z, or use Retry paste."
                ))
            case .replaceSelection:
                return .recoverableFailure(reason: focusFailureReason(switchedReason:
                    "The target app lost focus just before pasting. The replacement was not pasted — your text stands as it was."
                ))
            }
        }

        guard events.isTrusted() else {
            log.info("refused: accessibility revoked pre-post, clipboard restored")
            restoreIfStillOwned(saved: saved, receipt: receipt)
            switch context {
            case .insert:
                return .recoverableFailure(reason:
                    "Accessibility permission is required to insert text. Nothing was pasted — the transcript is kept for recovery."
                )
            case .replace:
                return .recoverableFailure(reason:
                    "Accessibility permission is required to replace text. The previous paste may have been undone — press ⌘⇧Z to restore it, or use Retry paste."
                )
            case .replaceSelection:
                return .recoverableFailure(reason:
                    "Accessibility permission is required to replace the selection. The replacement was not pasted — your text stands as it was."
                )
            }
        }

        // The OS's own answer to "will this post reach the tap". Checked
        // here as well as pre-flight: a grant can be revoked mid-session,
        // and a dropped post must never be reported as an insert.
        guard events.postingAuthorized() else {
            log.info("refused: synthetic posting blocked pre-post, clipboard restored")
            restoreIfStillOwned(saved: saved, receipt: receipt)
            return .recoverableFailure(reason: postingBlockedReason(context, undoAlreadyRan: context == .replace))
        }

        // Capture the caret BEFORE posting (off MainActor with a hard timeout):
        // the probe re-reads this same element afterwards, so a change cannot
        // be another field's caret. A caret-opaque terminal/IDE is skipped
        // outright so stale samples never manufacture a false failure.
        let probe: DeliveryProbe = caretOpaque
            ? .unavailable
            : await deliveryCheck.probeAsync(for: pid)

        PasteKeycodeResolver.warmLayoutCacheOnMainThread()
        guard await events.postPaste() else {
            log.error("post: no keystroke created, failing closed")
            restoreIfStillOwned(saved: saved, receipt: receipt)
            switch context {
            case .insert:
                return .recoverableFailure(reason:
                    "The keystroke could not be posted. Nothing was pasted — the transcript is kept for recovery."
                )
            case .replace:
                return .recoverableFailure(reason:
                    "The keystroke could not be posted. The previous paste may have been undone — press ⌘⇧Z to restore it, or use Retry paste."
                )
            case .replaceSelection:
                return .recoverableFailure(reason:
                    "The keystroke could not be posted. The replacement was not pasted — your text stands as it was."
                )
            }
        }
        log.info("posted HID Cmd-V for target \(pid, privacy: .public)")

        let budget = DeliveryVerification.budget(
            base: timings.deliveryBudget,
            perKB: timings.deliveryPerKB,
            cap: timings.deliveryBudgetCap,
            utf8Count: text.utf8.count
        )
        let (delivery, elapsedMs) = await verifyDelivery(probe, budget: budget)
        log.info("delivery=\(String(describing: delivery.outcome), privacy: .public) grew=\(delivery.characterCountGrew, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms chars=\(text.count, privacy: .public) caretOpaque=\(caretOpaque, privacy: .public)")

        // Restore follows the evidence: positive character-count growth proves
        // the app already consumed the paste (restore immediately); caret-only
        // movement keeps a short 50ms restore floor so async readers finish;
        // anything else keeps the configured grace.
        if delivery.outcome == .landed {
            if delivery.characterCountGrew {
                restoreNow(saved: saved, receipt: receipt)
            } else {
                scheduleRestore(
                    saved: saved,
                    receipt: receipt,
                    delay: min(timings.restoreDelay, Self.caretOnlyRestoreFloorNs)
                )
            }
        } else {
            scheduleRestore(saved: saved, receipt: receipt)
        }

        // Only positive proof of "nothing moved" fails the session. An
        // unverifiable app (web editor) keeps the pre-v7 behaviour, because
        // a catcher over text that is already in the document is the exact
        // failure v6 removed.
        if delivery.outcome == .notLanded {
            return .recoverableFailure(reason: notDeliveredReason(context))
        }
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
    /// Retry outcome, per cause — the menu names the failure instead of
    /// bundling causes (Phase 12: honesty over brevity).
    enum RetryOutcome: Equatable, Sendable {
        case posted
        case refusedNoAccessibility
        case refusedPostingBlocked
        case refusedOtoFrontmost
        case clipboardUnavailable
        case pasteFailed
        /// The post was delivered but the caret proved nothing moved.
        case notDelivered

        nonisolated static func == (lhs: RetryOutcome, rhs: RetryOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.posted, .posted), (.refusedNoAccessibility, .refusedNoAccessibility),
                 (.refusedPostingBlocked, .refusedPostingBlocked),
                 (.refusedOtoFrontmost, .refusedOtoFrontmost),
                 (.clipboardUnavailable, .clipboardUnavailable), (.pasteFailed, .pasteFailed),
                 (.notDelivered, .notDelivered):
                return true
            default:
                return false
            }
        }
    }

    func retryPostToFrontmost(_ text: String) async -> RetryOutcome {
        guard events.isTrusted() else {
            log.info("retry: refused, accessibility untrusted")
            return .refusedNoAccessibility
        }
        guard events.postingAuthorized() else {
            log.info("retry: refused, synthetic posting blocked")
            return .refusedPostingBlocked
        }
        guard !events.otoFrontmost() else {
            log.info("retry: refused, Oto itself is frontmost")
            return .refusedOtoFrontmost
        }
        await waitForModifiersToClear()
        let frontPID = events.frontmostPID()
        let frontBundleID = events.frontmostBundleID()
        log.info("retry: posting to frontmost \(frontBundleID ?? "?", privacy: .public) (\(frontPID ?? -1, privacy: .public))")
        let saved = PasteboardSnapshot.capture(pasteboard)
        let receipt = placeOnClipboard(text)
        await events.sleep(timings.prePasteDelay)
        guard await waitForClipboard(text: text, marker: receipt.marker) else {
            restoreIfStillOwned(saved: saved, receipt: receipt)
            return .clipboardUnavailable
        }
        let caretOpaque = CaretOpaqueApps.isOpaque(frontBundleID)
        let probe: DeliveryProbe
        if caretOpaque {
            probe = .unavailable
        } else if let frontPID {
            probe = await deliveryCheck.probeAsync(for: frontPID)
        } else {
            probe = .unavailable
        }
        PasteKeycodeResolver.warmLayoutCacheOnMainThread()
        guard await events.postPaste() else {
            log.info("retry: no keystroke created")
            restoreIfStillOwned(saved: saved, receipt: receipt)
            return .pasteFailed
        }
        let budget = DeliveryVerification.budget(
            base: timings.deliveryBudget,
            perKB: timings.deliveryPerKB,
            cap: timings.deliveryBudgetCap,
            utf8Count: text.utf8.count
        )
        let (delivery, elapsedMs) = await verifyDelivery(probe, budget: budget)
        log.info("retry: delivery=\(String(describing: delivery.outcome), privacy: .public) grew=\(delivery.characterCountGrew, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms caretOpaque=\(caretOpaque, privacy: .public)")
        if delivery.outcome == .landed {
            if delivery.characterCountGrew {
                restoreNow(saved: saved, receipt: receipt)
            } else {
                scheduleRestore(
                    saved: saved,
                    receipt: receipt,
                    delay: min(timings.restoreDelay, Self.caretOnlyRestoreFloorNs)
                )
            }
        } else {
            scheduleRestore(saved: saved, receipt: receipt)
        }
        return delivery.outcome == .notLanded ? .notDelivered : .posted
    }

    // MARK: - Private

    /// Writes text + session marker + NSPasteboard.org transient/auto-generated
    /// tags atomically in a single item so clipboard managers ignore transient
    /// dictation traffic. The change count is read AFTER the write.
    private func placeOnClipboard(_ text: String) -> PasteboardReceipt {
        let marker = UUID().uuidString
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(marker, forType: PasteboardReceipt.markerType)
        item.setData(Data(), forType: PasteboardReceipt.transientType)
        item.setData(Data(), forType: PasteboardReceipt.autoGeneratedType)
        pasteboard.writeObjects([item])
        return PasteboardReceipt(marker: marker, changeCount: pasteboard.changeCount)
    }

    /// Guarded synchronous restore for early-failure paths: never clobbers a
    /// concurrent user copy that landed before the failure triggered.
    private func restoreIfStillOwned(
        saved: [[NSPasteboard.PasteboardType: Data]],
        receipt: PasteboardReceipt
    ) {
        guard receipt.stillOwned(by: pasteboard) else { return }
        PasteboardSnapshot.restore(saved, to: pasteboard)
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

    static func pollForMatch(
        budget: UInt64,
        poll: UInt64,
        sleep: (UInt64) async -> Void,
        read: () -> Bool
    ) async -> Bool {
        if read() { return true }
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(clamping: budget))
        while clock.now < deadline {
            await sleep(poll)
            if read() { return true }
        }
        return read()
    }

    private func waitForModifiersToClear() async {
        let watched: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(clamping: timings.modifierTimeout))
        while clock.now < deadline {
            if events.currentModifiers().intersection(watched).isEmpty { return }
            await events.sleep(timings.modifierPoll)
        }
        // Budget exhausted with modifiers still held: Sticky Keys users
        // legitimately hold modifiers here, so failing closed would strand
        // valid sessions — proceed and log loudly instead. The mistype
        // hazard above stands; this line is its device-matrix witness.
        log.error("modifiers: still held after timeout, posting anyway")
    }

    /// Readiness wait (v7): activation is a condition, not a duration.
    /// Advisory only — budget expiry still posts, and the pre-post frontmost
    /// guard owns refusal with its better message.
    private func waitForReadiness(pid: pid_t) async {
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            let elapsed = Self.nanoseconds(from: clock.now - started)
            let frontmost = events.frontmostPID() == pid
            if InsertionReadiness.shouldPost(
                elapsedNanoseconds: elapsed,
                floor: timings.reactivateSettle,
                budget: timings.readyBudget,
                isFrontmost: frontmost
            ) {
                log.info("ready pid=\(pid, privacy: .public) frontmost=\(frontmost, privacy: .public) elapsed=\(elapsed / 1_000_000, privacy: .public)ms post-auth=\(self.events.postingAuthorized(), privacy: .public)")
                return
            }
            await events.sleep(timings.readyPoll)
        }
    }

    /// Delivery poll off the main actor: AX reads into another process can
    /// block, and the failure path runs for the whole budget. Bounded by the
    /// budget, so it needs no cancellation.
    private func verifyDelivery(
        _ probe: DeliveryProbe, budget: UInt64
    ) async -> (DeliveryResult, Int) {
        let poll = timings.deliveryPoll
        let sleep = events.sleep
        let clock = ContinuousClock()
        let started = clock.now
        let result = await Task.detached(priority: .utility) {
            await DeliveryVerification.verifyDetailed(
                probe: probe, budget: budget, poll: poll, sleep: sleep
            )
        }.value
        let elapsedMs = Int(Self.nanoseconds(from: clock.now - started) / 1_000_000)
        return (result, elapsedMs)
    }

    private nonisolated static func nanoseconds(from duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let secNs = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if secNs.overflow { return UInt64.max }
        let subNs = UInt64(max(0, attoseconds) / 1_000_000_000)
        let total = secNs.partialValue.addingReportingOverflow(subNs)
        return total.overflow ? UInt64.max : total.partialValue
    }

    /// Refusal words for a blocked synthetic post. Names the permission the
    /// person can change; never claims the text went anywhere.
    private func postingBlockedReason(_ context: PostContext, undoAlreadyRan: Bool = false) -> String {
        switch context {
        case .insert:
            return "macOS is not delivering Oto's synthetic keystrokes, so nothing was pasted. The transcript is kept — check Accessibility for Oto in System Settings, then use Retry paste."
        case .replace:
            if undoAlreadyRan {
                return "macOS is not delivering Oto's synthetic keystrokes, so the replacement could not be pasted. The previous paste may have been undone — press ⌘⇧Z to restore it, or use Retry paste."
            }
            return "macOS is not delivering Oto's synthetic keystrokes, so the replacement was not applied. The text is kept — check Accessibility for Oto in System Settings, then use Retry paste."
        case .replaceSelection:
            return "macOS is not delivering Oto's synthetic keystrokes, so the replacement was not applied. Your text stands as it was — the transcript is kept."
        }
    }

    /// Failure words when the caret proved nothing moved. Explicitly says the
    /// text was not inserted twice: the paste was delivered but refused.
    private func notDeliveredReason(_ context: PostContext) -> String {
        switch context {
        case .insert:
            return "The text did not appear in the target app. It was posted once — the transcript is kept: copy it, or switch back and press Retry paste."
        case .replace:
            return "The replacement did not appear in the target app. The previous paste may have been undone — press ⌘⇧Z to restore it, copy the text, or press Retry paste."
        case .replaceSelection:
            return "The replacement did not appear in the target app. Your text stands as it was — copy the transcript, or press Retry paste."
        }
    }

    private func restoreNow(
        saved: [[NSPasteboard.PasteboardType: Data]], receipt: PasteboardReceipt
    ) {
        scheduleRestore(saved: saved, receipt: receipt, delay: 0)
    }

    /// One bounded Task per insertion (not per event): restores the previous
    /// clipboard only if nobody touched it since — a user copy in between
    /// wins, and our text stays available for manual paste. `delay` nil uses
    /// the configured grace; v7 passes 0 once delivery is proven.
    private func scheduleRestore(
        saved: [[NSPasteboard.PasteboardType: Data]],
        receipt: PasteboardReceipt,
        delay: UInt64? = nil
    ) {
        let pasteboard = pasteboard
        let delay = delay ?? timings.restoreDelay
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

/// Dynamic Chromium 155–156 clipboard-race detector (borrowed from Hex).
/// Chromium 155 and 156 on macOS can drop a synthetic Cmd+V that races its own
/// pasteboard change notification (upstream CL 8217390, fixed by CL 8503629 in
/// 157). Inspects `<bundle>/Contents/Frameworks/*Framework.framework/Versions/*`
/// dynamically so every Chromium browser (Chrome, Brave, Arc, Edge, Helium,
/// Dia, etc.) is covered without hardcoding browser bundle IDs.
enum ChromiumRaceDetector: Sendable {
    nonisolated static let affectedMajors: ClosedRange<Int> = 155...156

    nonisolated static func shouldTypeInsteadOfPaste(pid: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
            return false
        }
        return hasClipboardRace(bundleURL: bundleURL)
    }

    nonisolated static func hasClipboardRace(bundleURL: URL) -> Bool {
        let frameworksDir = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let frameworks = try? FileManager.default.contentsOfDirectory(
            at: frameworksDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for framework in frameworks where framework.lastPathComponent.hasSuffix("Framework.framework") {
            let versionsDir = framework.appendingPathComponent("Versions", isDirectory: true)
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: versionsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for version in versions {
                if let major = chromiumMajorVersion(version.lastPathComponent),
                   affectedMajors.contains(major)
                {
                    return true
                }
            }
        }
        return false
    }

    nonisolated static func chromiumMajorVersion(_ name: String) -> Int? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == 4 else { return nil }
        return nums[0]
    }
}

/// Synthesized Unicode burst typing (borrowed from Hex): chunks text into
/// Quartz's 20-UTF-16-unit maximum without splitting surrogate pairs, and sends
/// Shift+Return for line breaks so chat composers insert newlines instead of
/// sending. Every event carries `InsertionEvents.syntheticMarker`.
enum DirectTextTyping: Sendable {
    nonisolated static let maxUTF16Units = 20

    nonisolated enum Stroke: Equatable, Sendable {
        case text([UInt16])
        case lineBreak
    }

    nonisolated static func strokes(for text: String) -> [Stroke] {
        var result: [Stroke] = []
        var units: [UInt16] = []
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()

        while let scalar = pending {
            pending = scalars.next()
            if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", pending == "\n" {
                    pending = scalars.next()
                }
                if !units.isEmpty {
                    result.append(.text(units))
                    units.removeAll(keepingCapacity: true)
                }
                result.append(.lineBreak)
                continue
            }
            let encoded = Array(scalar.utf16)
            if units.count + encoded.count > maxUTF16Units, !units.isEmpty {
                result.append(.text(units))
                units.removeAll(keepingCapacity: true)
            }
            units.append(contentsOf: encoded)
        }
        if !units.isEmpty {
            result.append(.text(units))
        }
        return result
    }

    nonisolated static func postBurst(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        var events: [CGEvent] = []
        for stroke in strokes(for: text) {
            switch stroke {
            case .text(let units):
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                        return false
                    }
                    ev.flags = []
                    units.withUnsafeBufferPointer { buf in
                        if let base = buf.baseAddress {
                            ev.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                        }
                    }
                    ev.setIntegerValueField(.eventSourceUserData, value: InsertionEvents.syntheticMarker)
                    events.append(ev)
                }
            case .lineBreak:
                let shiftKey = CGKeyCode(kVK_Shift)
                let returnKey = CGKeyCode(kVK_Return)
                guard let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false),
                      let retDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
                      let retUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false),
                      let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false)
                else { return false }
                shiftDown.type = .flagsChanged
                shiftDown.flags = .maskShift
                retDown.flags = .maskShift
                retUp.flags = .maskShift
                shiftUp.type = .flagsChanged
                shiftUp.flags = []
                for ev in [shiftDown, retDown, retUp, shiftUp] {
                    ev.setIntegerValueField(.eventSourceUserData, value: InsertionEvents.syntheticMarker)
                    events.append(ev)
                }
            }
        }
        for ev in events {
            ev.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Optional Smart Spacing (borrowed from Hex `with_smart_spacing` +
/// `char_before_caret`): inspects the single character immediately before the
/// focused element's insertion point via `AXSelectedTextRange` and
/// `AXStringForRange`, prepending a single leading space when dictating right
/// after a word, number, or sentence/closing punctuation mark.
enum SmartSpacing: Sendable {
    nonisolated static let defaultsKey = "app.Oto.smartSpacing"
    nonisolated static let axTimeoutSeconds: Float = 0.20

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    nonisolated static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    /// Pure spacing rule (ported from Hex `paste.rs:828-851`).
    nonisolated static func apply(to text: String, characterBeforeCaret previous: Character?) -> String {
        guard let previous, needsLeadingSpace(previous: previous, text: text) else {
            return text
        }
        return " " + text
    }

    nonisolated static func needsLeadingSpace(previous: Character, text: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isWhitespace || isClosingPunctuation(first) {
            return false
        }
        if previous.isLetter || previous.isNumber {
            return true
        }
        return leadingSpacePunctuation.contains(previous)
    }

    private nonisolated static let leadingSpacePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "”", "’", "»",
    ]

    private nonisolated static let closingPunctuation: Set<Character> = [
        ",", ".", "?", "!", ";", ":", ")", "]", "}",
    ]

    private nonisolated static func isClosingPunctuation(_ ch: Character) -> Bool {
        closingPunctuation.contains(ch)
    }

    /// Reads the single character immediately before the insertion point of
    /// `pid`'s focused text element (ported from Hex `accessibility.rs:514-529`).
    /// Returns `nil` for Oto's own process, secure password fields, non-zero
    /// selections, caret at index 0, or apps that do not expose `AXStringForRange`.
    nonisolated static func charBeforeCaret(pid: pid_t) -> Character? {
        guard pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted()
        else { return nil }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeoutSeconds)

        var focusedRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRaw
        ) == .success,
            let raw = focusedRaw,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }

        let focused = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, axTimeoutSeconds)

        // Never inspect secure password fields.
        for attr in [kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString] {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, attr, &val) == .success,
               (val as? String) == (kAXSecureTextFieldSubrole as String)
            {
                return nil
            }
        }

        var rangeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRaw
        ) == .success,
            let rangeVal = rangeRaw,
            CFGetTypeID(rangeVal) == AXValueGetTypeID()
        else { return nil }

        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeVal, to: AXValue.self), .cfRange, &selection),
              selection.length == 0,
              selection.location > 0
        else { return nil }

        let maxUnits = min(2, selection.location)
        for units in 1...maxUnits {
            var queryRange = CFRange(location: selection.location - units, length: units)
            guard let param = AXValueCreate(.cfRange, &queryRange) else { continue }
            var strRaw: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(
                focused,
                kAXStringForRangeParameterizedAttribute as CFString,
                param,
                &strRaw
            )
            if status == .success, let str = strRaw as? String, let last = str.last {
                return last
            }
        }
        return nil
    }
}
