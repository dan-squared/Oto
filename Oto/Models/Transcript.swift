//
//  Transcript.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Finalized transcript text. Only finals (never partials) may be inserted,
/// saved, or preserved for recovery (02 §Apple Speech workflow).
/// Plain value: equality is `nonisolated` for the background coordinator
/// (Swift 6, default MainActor isolation).
struct Transcript: Equatable, Sendable {
    /// Raw finalized text from the speech service.
    let text: String

    nonisolated static func == (lhs: Transcript, rhs: Transcript) -> Bool {
        lhs.text == rhs.text
    }

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
    /// Focus without an editable field (Finder, desktop, viewer): nowhere
    /// to paste. Diverts to recovery pre-clipboard — nothing posted,
    /// clipboard untouched. The coordinator maps this to `.noTextField`.
    case noEditableField
}
