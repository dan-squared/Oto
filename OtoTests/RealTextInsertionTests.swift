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
import Foundation
import Testing
@testable import Oto

private func scratchBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("oto-insert-\(UUID().uuidString)"))
}

private func scriptedEvents(
    trusted: Bool = true,
    secure: Bool = false,
    reactivate: @escaping @Sendable (pid_t) -> Bool = { _ in true },
    frontmostPID: @escaping @Sendable () -> pid_t? = { 99999 },
    otoFrontmost: @escaping @Sendable () -> Bool = { false },
    postedHID: @escaping @Sendable () -> Void = {}
) -> InsertionEvents {
    InsertionEvents(
        isTrusted: { trusted },
        secureInputEnabled: { secure },
        secureHolderName: { secure ? "TestHolder" : nil },
        reactivate: reactivate,
        currentModifiers: { [] },
        frontmostPID: frontmostPID,
        otoFrontmost: otoFrontmost,
        postPaste: { postedHID() },
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
        var hid = 0
        var reactivates = 0
        var focusReads = 0
        var events = scriptedEvents(trusted: false, postedHID: { hid += 1 })
        let baseReactivate = events.reactivate
        events.reactivate = { reactivates += 1; return baseReactivate($0) }
        let baseFront = events.frontmostPID
        events.frontmostPID = { focusReads += 1; return baseFront() }
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
        #expect(hid == 0)
        #expect(reactivates == 0)
        #expect(focusReads == 0)
    }

    // 02 recovery table, secure-input row: a global holder (any app) must not
    // cost the person their clipboard. Same untouched proof; the holder hint
    // must survive in the reason (it is the only place naming it).
    @Test func secureInputRefusalLeavesClipboardUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(secure: true, postedHID: { hid += 1 }),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("secret words", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("TestHolder"))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "mine")
        #expect(board.string(forType: PasteboardReceipt.markerType) == nil)
        #expect(hid == 0)
    }

    // §9: nil pid means capture found no frontmost app (locked screen, login
    // window) — nowhere safe to paste. Fail closed before any side effect.
    @Test func pidlessTargetFailsClosedUntouched() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        let before = board.changeCount
        var hid = 0
        var reactivates = 0
        var events = scriptedEvents(postedHID: { hid += 1 })
        let base = events.reactivate
        events.reactivate = { reactivates += 1; return base($0) }
        let service = RealTextInsertion(
            events: events, timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: pidlessTarget())
        guard case .recoverableFailure = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(board.changeCount == before)
        #expect(hid == 0)
        #expect(reactivates == 0)
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
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(
                reactivate: { _ in false },
                postedHID: { hid += 1 }
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
        #expect(hid == 0)
    }

    // §11: the same fail-closed branches must name the Oto-frontmost case
    // explicitly (close Oto UI + Retry) instead of the generic switch text.
    // Two tests because both branches route through the helper independently.
    @Test func otoFrontmostNamesItselfOnReactivateRefusal() async {
        let board = scratchBoard()
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(
                reactivate: { _ in false },
                otoFrontmost: { true },
                postedHID: { hid += 1 }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Oto itself"))
        #expect(hid == 0)
    }

    @Test func otoFrontmostNamesItselfOnFocusRace() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(
                frontmostPID: { 11111 },
                otoFrontmost: { true },
                postedHID: { hid += 1 }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("Oto itself"))
        #expect(hid == 0)
        #expect(board.string(forType: .string) == "mine")
    }

    // Happy path (§9 gates all green): exactly one HID post, clipboard marked
    // for the guarded restore. The HID route is the device-proven one.
    @Test func proceedPostsHIDWhenActiveAndFrontmost() async {
        let board = scratchBoard()
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(postedHID: { hid += 1 }),
            timings: fastTimings(restore: 300_000_000), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        #expect(result == .inserted)
        #expect(hid == 1)
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
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(
                frontmostPID: { 11111 },
                postedHID: { hid += 1 }
            ),
            timings: fastTimings(), pasteboard: board
        )
        let result = await service.insert("dictated", into: anyTarget())
        guard case .recoverableFailure(let reason) = result else {
            Issue.record("expected recoverableFailure, got \(result)")
            return
        }
        #expect(reason.contains("lost focus"))
        #expect(hid == 0)
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
    @Test func retryPostsWithoutPolicyGates() async {
        let board = scratchBoard()
        board.clearContents()
        board.setString("mine", forType: .string)
        var hid = 0
        let service = RealTextInsertion(
            events: scriptedEvents(
                trusted: false,
                reactivate: { _ in false },
                frontmostPID: { 11111 },
                postedHID: { hid += 1 }
            ),
            timings: fastTimings(restore: 300_000_000), pasteboard: board
        )
        let posted = await service.retryPostToFrontmost("kept words")
        #expect(posted)
        #expect(hid == 1)
        #expect(board.string(forType: .string) == "kept words")
        #expect(board.string(forType: PasteboardReceipt.markerType) != nil)
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
}
