//
//  FocusRetryTests.swift
//  OtoTests
//
//  Bounded patience: transient noValue re-reads (async AX trees) instead of
//  diverting on first sight; persistent voids still divert; non-transient
//  verdicts never re-read. Deterministic via the injected reader — no AX,
//  no hardware.
//

import ApplicationServices
import Foundation
import Testing
@testable import Oto

@MainActor
struct FocusRetryTests {
    /// Scripted reader: returns the queued verdicts, counts calls.
    private final class Script: @unchecked Sendable {
        var queue: [(verdict: EditableFocus, axError: AXError?)]
        var calls = 0
        init(_ queue: [(EditableFocus, AXError?)]) { self.queue = queue }
        func read(_ pid: pid_t) -> (verdict: EditableFocus, axError: AXError?) {
            calls += 1
            return queue.count > 1 ? queue.removeFirst() : queue.first!
        }
    }

    @Test func transientVoidThenEditableProceeds() async {
        let script = Script([(.noField, .noValue), (.editable, nil)])
        let check = LiveFocusCheck(reader: { script.read($0) })
        let verdict = await check.editableFocus(for: 1234)
        #expect(verdict == .editable)
        #expect(script.calls == 2)
    }

    @Test func persistentVoidDivertsAfterMaxAttempts() async {
        let script = Script([(.noField, .noValue)])
        let check = LiveFocusCheck(reader: { script.read($0) })
        let verdict = await check.editableFocus(for: 1234)
        #expect(verdict == .noField)
        #expect(script.calls == LiveFocusCheck.maxAttempts)
    }

    @Test func definitiveNoFieldNeverReReads() async {
        // A present-but-not-editable role carries no error: final on sight.
        let script = Script([(.noField, nil)])
        let check = LiveFocusCheck(reader: { script.read($0) })
        let verdict = await check.editableFocus(for: 1234)
        #expect(verdict == .noField)
        #expect(script.calls == 1)
    }

    @Test func unknownNeverReReads() async {
        let script = Script([(.unknown, .failure)])
        let check = LiveFocusCheck(reader: { script.read($0) })
        let verdict = await check.editableFocus(for: 1234)
        #expect(verdict == .unknown)
        #expect(script.calls == 1)
    }

    @Test func editableFirstSightNeverReReads() async {
        let script = Script([(.editable, nil)])
        let check = LiveFocusCheck(reader: { script.read($0) })
        let verdict = await check.editableFocus(for: 1234)
        #expect(verdict == .editable)
        #expect(script.calls == 1)
    }
}
