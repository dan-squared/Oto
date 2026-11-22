//
//  PerfTraceTests.swift
//  OtoTests
//
//  P1 (plan/p1-perf-signposts.md): pure contracts of the measurement layer.
//  Signpost emission itself is NOT headless-testable (it needs Instruments /
//  a recording session) — so these tests pin what is pinnable: the phase
//  vocabulary (Instruments filter contract) and the ms() formatting contract.
//  Nothing here touches TCC, hardware, or the network.
//

import Foundation
import Testing
@testable import Oto

struct PerfTraceTests {
    @Test func allPhasesHaveDistinctRawValues() {
        let values = PerfTrace.Phase.allCases.map(\.rawValue)
        #expect(Set(values).count == values.count)
    }

    @Test func expectedPhaseCount() {
        // 8 spans: pressToReady, localeResolve, assetProbe, engineWarm,
        // finalizeAwait, cleanupRace, insert, cleanupFirstToken.
        // If you add a phase, update this count AND rerun the device matrix
        // (renaming invalidates recorded traces).
        #expect(PerfTrace.Phase.allCases.count == 8)
    }

    @Test func msZero() {
        #expect(PerfTrace.ms(.seconds(0)) == 0)
    }

    @Test func msOneSecondIs1000() {
        #expect(PerfTrace.ms(.seconds(1)) == 1000)
    }

    @Test func msFifteenHundred() {
        let d: Duration = .seconds(1) + .milliseconds(500)
        #expect(PerfTrace.ms(d) == 1500)
    }

    @Test func msTruncatesNeverRoundsUp() {
        // 1.9ms must read as 1, not 2 — the signpost carries the exact
        // duration for anyone who needs sub-ms precision.
        let d: Duration = .milliseconds(1) + .microseconds(900)
        #expect(PerfTrace.ms(d) == 1)
    }
}
