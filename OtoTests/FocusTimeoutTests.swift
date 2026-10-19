//
//  FocusTimeoutTests.swift
//  OtoTests
//
//  The read contract, not the policy: one read, its verdict passes through
//  untouched, and a hung AX call becomes `.unknown` (proceed) inside the
//  budget instead of hanging dictation. The policy tables live in
//  FocusPolicyTests; the reader is injected here so no AX is touched.
//

import ApplicationServices
import Foundation
import Testing
@testable import Oto

@MainActor
struct FocusTimeoutTests {
    /// Scripted reader: returns the queued reads, counts calls.
    private final class Script: @unchecked Sendable {
        var queue: [FocusRead]
        var calls = 0
        init(_ queue: [FocusRead]) { self.queue = queue }
        func read(_ pid: pid_t) -> FocusRead {
            calls += 1
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }

    @Test func readerVerdictPassesThroughUnchanged() async {
        let script = Script([FocusRead(verdict: .editable, role: "AXTextArea", source: .systemWide)])
        let check = LiveFocusCheck(reader: { script.read($0) })
        #expect(await check.editableFocus(for: 1234) == .editable)
        #expect(script.calls == 1)
    }

    @Test func secureFieldPassesThroughUnchanged() async {
        let script = Script([
            FocusRead(verdict: .secureField, role: "AXTextField", source: .app),
        ])
        let check = LiveFocusCheck(reader: { script.read($0) })
        #expect(await check.editableFocus(for: 1234) == .secureField)
        #expect(script.calls == 1)
    }

    @Test func oneReadNoPatience() async {
        // v6 removed the retry loop: with silence no longer diverting, a
        // second read could only reach the same decision later.
        let script = Script([
            FocusRead(verdict: .noField, axError: .noValue, source: .systemWide),
        ])
        let check = LiveFocusCheck(reader: { script.read($0) })
        #expect(await check.editableFocus(for: 1234) == .noField)
        #expect(script.calls == 1)
    }

    @Test func hungReadTimesOutAsUnknown() async {
        // A blocking AX call cannot be cancelled, so the budget is a race:
        // past it the verdict is `.unknown`, which proceeds exactly as the
        // product did before the gate existed.
        let check = LiveFocusCheck(reader: { _ in
            Thread.sleep(forTimeInterval: 1.5)
            return FocusRead(verdict: .editable, source: .systemWide)
        })
        let began = ContinuousClock.now
        #expect(await check.editableFocus(for: 1234) == .unknown)
        #expect(ContinuousClock.now - began < Duration.seconds(1.4))
    }
}
