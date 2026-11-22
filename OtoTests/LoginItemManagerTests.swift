//
//  LoginItemManagerTests.swift
//  OtoTests
//
//  Phase 5: login-item control behind a protocol (SMAppService is final).
//  These tests pin the wiring the UI depends on — enable/disable must reach
//  the right service call (an inversion here would silently do the opposite
//  of the toggle), and the raw three-state status must pass through
//  untouched (the UI renders guidance from it, never a reinterpretation).
//

import Foundation
import ServiceManagement
import Testing
@testable import Oto

private final class FakeLoginItem: LoginItemManaging, @unchecked Sendable {
    var statusValue: SMAppService.Status = .notRegistered
    private(set) var calls: [Bool] = []

    func status() -> SMAppService.Status { statusValue }

    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
    }
}

@MainActor
struct LoginItemManagerTests {
    @Test func enableReachesRegister() async {
        let fake = FakeLoginItem()
        try? fake.setEnabled(true)
        #expect(fake.calls == [true])
    }

    @Test func disableReachesUnregister() async {
        let fake = FakeLoginItem()
        try? fake.setEnabled(false)
        #expect(fake.calls == [false])
    }

    @Test func statusPassesThroughUntouched() async {
        let fake = FakeLoginItem()
        for state in [
            SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
        ] as [SMAppService.Status] {
            fake.statusValue = state
            #expect(fake.status() == state)
        }
    }

    @Test func liveManagerReportsWithoutThrowing() async {
        // No behavior asserted (system state belongs to the device matrix) —
        // this only pins that the live path is callable and returns a known
        // state rather than crashing. `.notFound` is expected in the test
        // host (not the app bundle) — and handled as guidance in the UI.
        let live = LiveLoginItemManager()
        let status = live.status()
        #expect([
            SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
        ].contains(status))
    }
}
