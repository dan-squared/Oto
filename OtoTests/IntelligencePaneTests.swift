//
//  IntelligencePaneTests.swift
//  OtoTests
//
//  Phase 10: the Auto Cleanup footnote must not promise raw-word recovery
//  while History is off. Pure copy mapping — no hardware, no panes.
//

import Foundation
import Testing
@testable import Oto

struct IntelligencePaneTests {
    @Test func footingPromisesRecoveryOnlyWhenHistoryKeepsRaw() {
        #expect(cleanupFooting(historyEnabled: true)
            == "Applies to every dictation. Your original words are never lost — Undo AI edit in History.")
        #expect(cleanupFooting(historyEnabled: false)
            == "Applies to every dictation. Your original words are only kept while History is on — turn it on in History to keep originals.")
    }
}
