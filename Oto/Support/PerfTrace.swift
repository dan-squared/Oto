//
//  PerfTrace.swift
//  Oto
//
//  P1 (plan/p1-perf-signposts.md). The ONLY measurement layer on the
//  dictation hot path. Wraps os_signpost so call sites stay one-liners and
//  Instruments does the aggregation natively.
//
//  Hard rule (plan, risks section): NOTHING in the ship path may branch on
//  these values. Observation only — zero behavior change. Signpost macros
//  compile to near-nothing unless a recording is active.
//

import Foundation
import os

enum PerfTrace: Sendable {
    nonisolated static let log = OSLog(subsystem: "app.Oto", category: "perf")

    /// Fixed vocabulary — Instruments filters on these names. Renaming a case
    /// invalidates every recorded trace; treat the raw values as a contract.
    enum Phase: String, CaseIterable, Sendable {
        /// begin() → .recording. Contains ALL of speech.prepare() — the
        /// press-to-ready number users feel as "starting" in the pill.
        case pressToReady
        /// supportedLocales await + locale match (P3 attacks this).
        case localeResolve
        /// installedLocales + AssetInventory.status awaits.
        case assetProbe
        /// Analyzer build → prepareToAnalyze → start (P2 attacks this).
        case engineWarm
        /// The coordinator's await of speech.finish() — "Finalizing…".
        case finalizeAwait
        /// Auto Cleanup bounded race (≤3s) before insertion.
        case cleanupRace
        /// inserter.insert — clipboard + Cmd-V + restore.
        case insert
        /// First streamed chunk of a polish run (model latency).
        case cleanupFirstToken
    }

    nonisolated static func begin(_ phase: Phase) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Dictation", signpostID: id,
                    "%{public}s", phase.rawValue)
        return id
    }

    nonisolated static func end(_ phase: Phase, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: "Dictation", signpostID: id,
                    "%{public}s", phase.rawValue)
    }

    /// Integer milliseconds for the release log line. Truncates, never
    /// rounds up — a 1.9ms span reads as 1, and the signpost carries the
    /// exact duration for anyone who needs it.
    nonisolated static func ms(_ elapsed: Duration) -> Int {
        let comps = elapsed.components
        return Int(comps.seconds) * 1000
            + Int(comps.attoseconds / 1_000_000_000_000_000)
    }
}
