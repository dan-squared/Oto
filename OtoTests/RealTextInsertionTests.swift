//
//  RealTextInsertionTests.swift
//  OtoTests
//
//  Phase 4: the real service with scripted events and a scratch pasteboard.
//  Posting is always a no-op here — these tests prove gating, HID delivery
//  discipline, clipboard verify/restore behavior, and the retry path, never a
//  real keystroke. Every test cites the contract clause it guards (02 =
//  recording workflows, 11 = reliability matrix, §9 = the postToPid-revert
//  analysis); a test that cannot name its clause does not belong.
//

import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Oto

private func scratchBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("oto-insert-\(UUID().uuidString)"))
}

/// Scriptable focus verdicts (catcher void-case fix): no AX, no hardware.
struct StubFocusCheck: FocusChecking {
    let verdict: EditableFocus
    nonisolated func editableFocus(for pid: pid_t) async -> EditableFocus { verdict }
}

/// Test-only Sendable counter for the scripted `@Sendable` event hooks.
/// Swift 6 region isolation forbids mutating captured vars inside
/// concurrently-executing closures; the lock is the sharing proof, and the
/// main-actor test struct never touches the value off-domain.
final class HookCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func scriptedEvents(
    trusted: Bool = true,
    reactivate: @escaping @Sendable (pid_t) -> Bool = { _ in true },
    frontmostPID: @escaping @Sendable () -> pid_t? = { 99999 },
    otoFrontmost: @escaping @Sendable () -> Bool = { false },
    postedHID: @escaping @Sendable () -> Void = {}
) -> InsertionEvents {
    InsertionEvents(
        isTrusted: { trusted },
        reactivate: reactivate,
        currentModifiers: { [] },
        frontmostPID: frontmostPID,
        otoFrontmost: otoFrontmost,
        postPaste: { postedHID(); return true },
        postUndo: { postedHID(); return true },
        sleep: { _ in }
    )
}

private func fastTimings(restore: UInt64 = 5_000_000) -> InsertionTimings {
    InsertionTimings(
        prePasteDelay: 0, verifyBudget: 10_000_000, verifyPoll: 1_000_000,
        restoreDelay: restore, modifierTimeout: 0, modifierPoll: 0,
        reactivateSettle: 0, keyStep: 0
    )
}

private func anyTarget() -> TargetApplication {
    TargetApplication(bundleIdentifier: "com.example.App", processIdentifier: 99999, windowIdentifier: nil)
}

private func pidlessTarget() -> TargetApplication {
    TargetApplication(bundleIdentifier: "com.example.App", processIdentifier: nil, windowIdentifier: nil)
}

@MainActor
struct RealTextInsertionTests {
    // 02 recovery table, AX-denied row: recovery is an explicit Copy action,
    // never an auto-overwrite. changeCount equality proves ZERO writes (not
    // just equal strings); neither post route may fire and focus must never
    // even be read on a refusal.
    @Test func untrustedRefusalLeavesClipboardUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let reactivates = HookCount()
        let focusReads = HookCount()
        var events = scriptedEvents(trusted: false, postedHID: { hid.bump() })
        let baseReactivate = events.reactivate
        events.reactivate = { reactivates.bump(); return baseReactivate($0) }
        let baseFront = events.frontmostPID
        events.frontmostPID = { focusReads.bump(); return baseFront() }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("hello", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Accessibility"))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "mine")
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
        #expect(hid.count == 0)
        #expect(reactivates.count == 0)
        #expect(focusReads.count == 0)
    }

    // Secure FIELD row (replaces the old global secure-input refusal, which
    // Hex device-proved unnecessary — the OS delivers synthetic paste
    // while secure input is held): a focused password field refuses with
    // the transcript kept for explicit manual paste. Automation never
    // fills passwords by itself. Same untouched proof as every refusal.
    @Test func secureFieldRefusesLeavingClipboardUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(postedHID: { hid.bump() }),
            timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .secureField)
        )
        let result = await service.insert("secret words", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("password"))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "mine")
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
        #expect(hid.count == 0)
    }

    // §9: nil pid means capture found no frontmost app (locked screen, login
    // window) — nowhere safe to paste. Fail closed before any side effect.
    @Test func pidlessTargetFailsClosedUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let reactivates = HookCount()
        var events = scriptedEvents(postedHID: { hid.bump() })
        let base = events.reactivate
        events.reactivate = { reactivates.bump(); return base($0) }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: pidlessTarget())
        guard case .recoverableFailure = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(board.changeCount == before)
        #expect(hid.count == 0)
        #expect(reactivates.count == 0)
    }

    // §9 sandbox-valid proxy: `reactivate == false` is the sandboxed norm
    // after a switch — posting anyway would land in the WRONG app (02: never
    // substitute the frontmost app). Fail closed, clipboard pristine, and the
    // reason must point at the Retry escape hatch.
    @Test func refusedActivationFailsClosedUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(
                reactivate: { _ in false },
                postedHID: { hid.bump() }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Retry"))
        #expect(reason.contains("no longer in front"))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "mine")
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
        #expect(hid.count == 0)
    }

    // §11: the same fail-closed branches must name the Oto-frontmost case
    // explicitly (close Oto UI + Retry) instead of the generic switch text.
    // Two tests because both branches route through the helper independently.
    @Test func otoFrontmostNamesItselfOnReactivateRefusal() async {
        let board = scratchBoard()
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(
                reactivate: { _ in false },
                otoFrontmost: { true },
                postedHID: { hid.bump() }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Oto itself"))
        #expect(hid.count == 0)
    }

    @Test func otoFrontmostNamesItselfOnFocusRace() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(
                frontmostPID: { 11111 },
                otoFrontmost: { true },
                postedHID: { hid.bump() }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Oto itself"))
        #expect(hid.count == 0)
        #expect(board.string(forType: .string) == "mine")
    }

    // Happy path (§9 gates all green): exactly one HID post, clipboard marked
    // for the guarded restore. The HID route is the device-proven one.
    @Test func proceedPostsHIDWhenActiveAndFrontmost() async {
        let board = scratchBoard()
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(postedHID: { hid.bump() }),
            timings: fastTimings(restore: 300_000_000), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        #expect(result == .inserted)
        #expect(hid.count == 1)
        #expect(board.string(forType: .string) == "dictated")
        #expect(board.string(forType: PasteboardReceipt.markerType) != nil)
    }

    // §9 mid-settle race guard: focus leaves between the reactivate gate and
    // the post. No retries (refusals are policy, not timing) — restore
    // SYNCHRONOUSLY (no Task delay: assert immediately) and fail closed
    // rather than paste into the new frontmost app.
    @Test func focusRaceRestoresSynchronously() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(
                frontmostPID: { 11111 },
                postedHID: { hid.bump() }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("lost focus"))
        #expect(hid.count == 0)
        #expect(board.string(forType: .string) == "mine")
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
    }

    // The write-verify poll is the guard against posting ahead of an
    // invisible write (how stale content gets pasted). Pure-reader tests:
    // logic proven here, live pasteboard read wired in `insert`.
    @Test func clipboardPollPassesImmediatelyWhenVisible() async {
        var sleeps = 0
        let ok = await RealTextInsertion.pollForMatch(
            budget: 0, poll: 1_000_000,
            sleep: { _ in sleeps += 1 },
            read: { true }
        )
        #expect(ok)
        #expect(sleeps == 0)
    }

    @Test func clipboardPollWaitsForLateVisibility() async {
        var reads = 0
        var sleeps = 0
        let ok = await RealTextInsertion.pollForMatch(
            budget: 100_000_000, poll: 1_000_000,
            sleep: { _ in sleeps += 1 },
            read: { reads += 1; return reads >= 3 }
        )
        #expect(ok)
        #expect(sleeps >= 1)
    }

    @Test func clipboardPollFailsClosedWhenNeverVisible() async {
        var sleeps = 0
        let ok = await RealTextInsertion.pollForMatch(
            budget: 3_000_000, poll: 1_000_000,
            sleep: {
                sleeps += 1
                try? await Task.sleep(nanoseconds: $0)
            },
            read: { false }
        )
        #expect(!ok)
        #expect(sleeps <= 5)
    }

    // §9 retry contract: the USER is the check (switched back manually), so
    // policy gates are deliberately skipped — proven here by refusing every
    // gate (untrusted, dead activation, wrong focus) and still posting.
    // Clipboard discipline + restore are kept, not skipped.
    @Test func retryPostsWithoutFocusGates() async {
        // Retry skips FOCUS gates (the user is the check) but never trust:
        // without it the HID tap drops injected events silently.
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(
                trusted: true,
                reactivate: { _ in false },
                frontmostPID: { 11111 },
                postedHID: { hid.bump() }
            ),
            timings: fastTimings(restore: 300_000_000), pasteboard: board
        )
        let posted = await service.retryPostToFrontmost("kept words")
        #expect(posted)
        #expect(hid.count == 1)
        #expect(board.string(forType: .string) == "kept words")
        #expect(board.string(forType: PasteboardReceipt.markerType) != nil)
    }

    @Test func retryRefusesWithoutTrust() async {
        // Untrusted retry reports failure (never a phantom post): the
        // keystroke could not exist, so clipboard stays byte-identical.
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(trusted: false, postedHID: { hid.bump() }),
            timings: fastTimings(), pasteboard: board
        )
        #expect(await service.retryPostToFrontmost("kept words") == false)
        #expect(hid.count == 0)
        #expect(board.changeCount == before)
    }

    @Test func postCreationFailureFailsClosed() async {
        // Nil event source / uncreatable keystroke: the post reports
        // false, insertion fails closed with the clipboard restored —
        // never `.inserted` for a post that never existed.
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        var events = scriptedEvents()
        events.postPaste = { false }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .editable)
        )
        let result = await service.insert("unpostable", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("could not be posted"))
        #expect(board.string(forType: .string) == "mine")
    }

    @Test func prePostRegateRefusesRevokedTrust() async {
        // Trust revoked between the entry gate and the post (sudo prompt,
        // permission yank mid-session): the pre-post re-gate fails closed
        // with the clipboard restored, never a phantom `.inserted`. The
        // first trust read (entry) passes; all later reads refuse.
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let trustReads = HookCount()
        var events = scriptedEvents(postedHID: { hid.bump() })
        events.isTrusted = {
            trustReads.bump()
            return trustReads.count <= 1
        }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .editable)
        )
        let result = await service.insert("revoked", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Accessibility"))
        #expect(hid.count == 0)
        #expect(board.string(forType: .string) == "mine")
    }

    // 11 clipboard-restoration acceptance: the transcript lingers only until
    // the guarded restore returns the prior clipboard, marker included.
    @Test func restoreReturnsPriorClipboardWhenUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let service = RealTextInsertion(
            events: scriptedEvents(), timings: fastTimings(), pasteboard: board
        )
        _ = await service.insert("dictated", into: anyTarget())
        // Restore runs on a bounded Task; poll briefly (test-only wait).
        var restored = false
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            if board.string(forType: .string) == "mine" { restored = true; break }
        }
        #expect(restored)
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
    }

    // 01 §5 ownership rule: a user copy landing inside our restore window
    // wins — we leave their clipboard alone, transcript stays recoverable.
    @Test func userCopyInWindowSurvivesRestore() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let service = RealTextInsertion(
            events: scriptedEvents(), timings: fastTimings(), pasteboard: board
        )
        _ = await service.insert("dictated", into: anyTarget())
        // The person copies before our restore lands: theirs must survive.
        board.clearContents()
        board.setString("theirs", forType: .string)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(board.string(forType: .string) == "theirs")
    }

    // MARK: - Void-paste divert (catcher fix)

    @Test func focusRoleMapping() {
        // Text roles proceed; everything present-but-not-editable diverts;
        // a missing role is unknown (legacy path), never a guess.
        // A focused element owned by another app is unknown too — the
        // frontmostPID race guard owns that failure, not this layer.
        #expect(EditableFocus.classify(role: "AXTextField") == .editable)
        #expect(EditableFocus.classify(role: "AXTextArea") == .editable)
        #expect(EditableFocus.classify(role: "AXButton") == .noField)
        #expect(EditableFocus.classify(role: "AXStaticText") == .noField)
        #expect(EditableFocus.classify(role: "AXWebArea") == .noField)
        #expect(EditableFocus.classify(role: nil) == .unknown)
        #expect(EditableFocus.classify(role: "AXTextField", pidMatches: false) == .unknown)
        #expect(EditableFocus.classify(role: "AXButton", pidMatches: false) == .unknown)
        // Secure subrole (wire string pinned literally): a password field
        // refuses even though the role is text. Any other subrole — or
        // none — leaves the role verdict untouched.
        #expect(EditableFocus.classify(role: "AXTextField", subrole: "AXSecureTextField") == .secureField)
        #expect(EditableFocus.classify(role: "AXTextArea", subrole: "AXSecureTextField") == .secureField)
        #expect(EditableFocus.classify(role: "AXTextField", subrole: "AXUsernameField") == .editable)
        #expect(EditableFocus.classify(role: "AXTextField") == .editable)
        #expect(EditableFocus.classify(role: "AXButton", subrole: "AXSecureTextField") == .noField)
        #expect(LiveFocusCheck.timeoutNanoseconds == 700_000_000)
        #expect(LiveFocusCheck.maxAttempts == 3)
    }

    @Test func focusErrorMapping() {
        // No-value on the focus read IS the void case (nothing focused);
        // every other AX error is ambiguity (legacy proceed).
        #expect(EditableFocus.verdictForFocusError(.noValue) == .noField)
        #expect(EditableFocus.verdictForFocusError(.failure) == .unknown)
        #expect(EditableFocus.verdictForFocusError(.invalidUIElement) == .unknown)
        #expect(EditableFocus.verdictForFocusError(.apiDisabled) == .unknown)
        #expect(EditableFocus.verdictForFocusError(.cannotComplete) == .unknown)
    }

    @Test func terminalFallbackMapping() {
        // Terminal emulators consume keystrokes by definition: a focused
        // but unmapped role proceeds (never diverts). True void (nil
        // role) still diverts; non-terminals are untouched.
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "com.github.wez.wezterm", "dev.warp.Warp"] {
            #expect(TerminalEmulators.isTerminal(bundleID: id))
            #expect(TerminalEmulators.proceeds(role: "AXUnknown", bundleID: id))
            #expect(TerminalEmulators.proceeds(role: "AXGroup", bundleID: id))
            #expect(!TerminalEmulators.proceeds(role: nil, bundleID: id))
        }
        #expect(!TerminalEmulators.isTerminal(bundleID: "com.apple.Finder"))
        #expect(!TerminalEmulators.isTerminal(bundleID: nil))
        #expect(!TerminalEmulators.proceeds(role: "AXUnknown", bundleID: "com.apple.Finder"))
        // Text roles never reach the fallback (the caller consults it
        // only on .noField), so presence alone answers true here.
        #expect(TerminalEmulators.proceeds(role: "AXTextArea", bundleID: "com.apple.Terminal"))
    }

    @Test func terminalVoidProceeds() {
        // Emulators publish focus transiently: a persistent void in a
        // terminal is uninformative, so it proceeds (race guard and
        // clipboard restore still apply; secure password fields refuse
        // via .secureField). Everywhere else — and
        // dead pids — void still diverts.
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "com.github.wez.wezterm", "dev.warp.Warp"] {
            #expect(TerminalEmulators.proceedsVoid(bundleID: id))
        }
        #expect(!TerminalEmulators.proceedsVoid(bundleID: "com.apple.Finder"))
        #expect(!TerminalEmulators.proceedsVoid(bundleID: nil))
    }

    @Test func terminalFallbackNeverOverridesSecureField() {
        // The fallback only converts .noField: a password field refuses
        // even inside a terminal emulator, and non-terminals pass every
        // verdict through untouched.
        for id in ["com.apple.Terminal", "com.mitchellh.ghostty", "org.alacritty"] {
            #expect(TerminalEmulators.fallback(
                verdict: .secureField, role: "AXTextField", bundleID: id
            ) == .secureField)
            #expect(TerminalEmulators.fallback(
                verdict: .noField, role: "AXGroup", bundleID: id
            ) == .unknown)
            #expect(TerminalEmulators.fallback(
                verdict: .editable, role: "AXTextArea", bundleID: id
            ) == .editable)
        }
        #expect(TerminalEmulators.fallback(
            verdict: .noField, role: "AXGroup", bundleID: "com.apple.Finder"
        ) == .noField)
    }

    @Test func noEditableFocusDivertsPreClipboard() async {
        // Finder/desktop shape: focus with nowhere to paste diverts before
        // the clipboard is touched and posts nothing — recovery owns it.
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(postedHID: { hid.bump() }),
            timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .noField)
        )
        #expect(await service.insert("void words", into: anyTarget()) == .noEditableField)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "mine")
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
        #expect(hid.count == 0)
    }

    @Test func unknownFocusTakesLegacyPath() async {
        // AX error/timeout must never regress insertion: unknown proceeds
        // through the full legacy path (write → verify → post).
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let service = RealTextInsertion(
            events: scriptedEvents(postedHID: { hid.bump() }),
            timings: fastTimings(restore: 0), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .unknown)
        )
        #expect(await service.insert("legacy words", into: anyTarget()) == .inserted)
        #expect(hid.count == 1)
    }

    // MARK: - replaceLast (swap/undo flows): same fail-closed contract as
    // insert, with the undo step first. Reasons name the replacement; the
    // clipboard is untouched on every refusal.

    @Test func replaceUntrustedRefusesUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let undo = HookCount()
        var events = scriptedEvents(trusted: false, postedHID: { hid.bump() })
        events.postUndo = { undo.bump(); return true }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board
        )
        let result = await service.replaceLast("new words", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Nothing was changed"))
        #expect(board.changeCount == before)
        #expect(undo.count == 0)
        #expect(hid.count == 0)
    }

    @Test func replaceSecureFieldRefusesUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        let undo = HookCount()
        var events = scriptedEvents(postedHID: { hid.bump() })
        events.postUndo = { undo.bump(); return true }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .secureField)
        )
        let result = await service.replaceLast("secret words", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("password"))
        #expect(board.changeCount == before)
        #expect(undo.count == 0)
        #expect(hid.count == 0)
    }

    @Test func replaceHappyPathUndoesThenPastes() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let undo = HookCount()
        var events = scriptedEvents(postedHID: { hid.bump() })
        events.postUndo = { undo.bump(); return true }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(restore: 0), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .editable)
        )
        #expect(await service.replaceLast("new words", into: anyTarget()) == .inserted)
        #expect(undo.count == 1)
        #expect(hid.count == 1)
        #expect(board.string(forType: .string) == "new words")
        #expect(board.string(forType: PasteboardReceipt.markerType) != nil)
    }

    @Test func replaceUndoFailureChangesNothing() async {
        // Undo keystroke could not be created: the original stands, the
        // clipboard is untouched, and no paste is attempted.
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        let hid = HookCount()
        var events = scriptedEvents(postedHID: { hid.bump() })
        events.postUndo = { false }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .editable)
        )
        let result = await service.replaceLast("new words", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Nothing was changed"))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "mine")
        #expect(hid.count == 0)
    }

    @Test func replaceFocusRaceRestoresSynchronously() async {
        // Focus was never on the target (locked screen, fast switcher):
        // undo fires first (gates passed), then the pre-post race guard
        // refuses and the clipboard is restored on the spot — the
        // replacement never lands in the wrong app. Deterministic: the
        // frontmost PID is a constant mismatch (existing race-test pattern).
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let hid = HookCount()
        let undo = HookCount()
        var events = scriptedEvents(
            frontmostPID: { 11111 },
            postedHID: { hid.bump() }
        )
        events.postUndo = { undo.bump(); return true }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board,
            focusCheck: StubFocusCheck(verdict: .editable)
        )
        let result = await service.replaceLast("new words", into: anyTarget())
        guard case .recoverableFailure = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(undo.count == 1)
        #expect(hid.count == 0)
        #expect(board.string(forType: .string) == "mine")
    }
}
