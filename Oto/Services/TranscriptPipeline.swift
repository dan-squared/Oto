//
//  TranscriptPipeline.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Post-transcript processing seam. Trim + deterministic dictionary rules;
/// snippet expansion is NEVER ambient (explicit user action only). Rules
/// arrive as a value array (default empty = trim-only) so this stays a pure
/// `nonisolated` function the background coordinator can call without a hop.
/// The target is passed through so app-scoped rules resolve (02 finish rules).
struct TranscriptPipeline: Sendable {
    let dictionaryRules: [DictionaryRule]

    /// Value init: `nonisolated` so the background coordinator can rebuild
    /// the pipeline on rule updates without a MainActor hop (Swift 6).
    nonisolated init(dictionaryRules: [DictionaryRule] = []) {
        self.dictionaryRules = dictionaryRules
    }

    /// Pure trim + dictionary (Swift 6: `nonisolated` for the background coordinator).
    nonisolated func process(_ raw: String, for target: TargetApplication) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return applyDictionaryRules(dictionaryRules, to: trimmed, for: target)
    }
}
