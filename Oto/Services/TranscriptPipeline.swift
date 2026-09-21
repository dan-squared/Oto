//
//  TranscriptPipeline.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Post-transcript processing seam. Phase 1 is trim + empty-check only;
/// deterministic dictionary/cleanup rules slot in here in Phase 6 without
/// touching the coordinator. The target is passed through now so the
/// signature already matches the Phase 6 contract (02 finish rules).
struct TranscriptPipeline: Sendable {
    /// Pure trim (Swift 6: `nonisolated` for the background coordinator).
    nonisolated func process(_ raw: String, for target: TargetApplication) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
