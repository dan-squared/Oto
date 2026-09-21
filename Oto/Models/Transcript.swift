//
//  Transcript.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Finalized transcript text. Only finals (never partials) may be inserted,
/// saved, or preserved for recovery (02 §Apple Speech workflow).
struct Transcript: Equatable, Sendable {
    /// Raw finalized text from the speech service.
    let text: String

    /// Trimmed text. Empty (including whitespace-only) transcripts complete
    /// the session without insertion (02 session timeline).
    var cleaned: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { cleaned.isEmpty }
}

/// Insertion outcome. Success is never claimed from merely sending a paste
/// event — only the insertion boundary decides (START_HERE_PRODUCT.md).
enum InsertionResult: Equatable, Sendable {
    case inserted
    case recoverableFailure(reason: String)
}
