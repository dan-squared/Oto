//
//  TranscriptPipeline.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation
import Synchronization

/// Output from `TranscriptPipeline.processDetailed(_:for:)`.
nonisolated struct ProcessedTranscript: Equatable, Sendable {
    let text: String
    let matchedSnippet: Bool

    nonisolated static func == (lhs: ProcessedTranscript, rhs: ProcessedTranscript) -> Bool {
        lhs.text == rhs.text && lhs.matchedSnippet == rhs.matchedSnippet
    }
}

/// Post-transcript processing seam. Checks opt-in exact-utterance snippets first
/// (never inside longer sentences), then applies trim + deterministic dictionary
/// rules. Rules arrive as a value array (default empty = trim-only) and
/// pre-compile their regular expressions once at initialization so dictations
/// never recompile up to 500 regexes per utterance.
struct TranscriptPipeline: Sendable {
    private struct CompiledRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let replacement: String
        let bundleIDs: [String]
        let appScoped: Bool
        let order: String
    }

    private final class LinkDetectorCache: @unchecked Sendable {
        private let detector = Mutex<NSDataDetector?>(
            try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        )

        nonisolated func ranges(in text: String, fullRange: NSRange) -> [NSRange] {
            detector.withLock { det in
                det?.matches(in: text, options: [], range: fullRange).map(\.range) ?? []
            }
        }
    }

    private nonisolated static let pathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(~|\\.{1,2})?/[\\p{L}\\p{N}._\\-+%@:,/]+"
    )
    private nonisolated static let linkDetector = LinkDetectorCache()
    private nonisolated static let trailingSentencePunctuation = CharacterSet(
        charactersIn: ".!?,;:…。！？、；："
    )

    let dictionaryRules: [DictionaryRule]
    let snippets: [Snippet]
    private let compiledRules: [CompiledRule]

    /// Value init: `nonisolated` so the background coordinator can rebuild
    /// the pipeline on rule/snippet updates without a MainActor hop (Swift 6).
    nonisolated init(dictionaryRules: [DictionaryRule] = [], snippets: [Snippet] = []) {
        self.dictionaryRules = dictionaryRules
        self.snippets = snippets
        self.compiledRules = dictionaryRules.compactMap { rule in
            guard rule.isEnabled else { return nil }
            let spoken = DictionaryRule.normalizeSpoken(rule.spoken)
            guard !spoken.isEmpty else { return nil }
            let pattern = "(?<![\\p{L}\\p{N}_])"
                + NSRegularExpression.escapedPattern(for: spoken)
                + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .useUnicodeWordBoundaries]
            ) else { return nil }
            return CompiledRule(
                regex: regex,
                replacement: rule.replacement,
                bundleIDs: rule.bundleIDs,
                appScoped: !rule.bundleIDs.isEmpty,
                order: rule.id.uuidString
            )
        }
    }

    /// Normalizes a trigger phrase or spoken utterance for exact-utterance matching:
    /// trims whitespace/newlines, strips trailing sentence punctuation (ASCII &
    /// common Unicode/CJK), folds typographic apostrophes, collapses internal
    /// whitespace runs, and lowercases.
    nonisolated static func normalizeTriggerPhrase(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.unicodeScalars.last, trailingSentencePunctuation.contains(last) {
            value.unicodeScalars.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.localizedLowercase
    }

    /// Pure opt-in exact-utterance snippet expansion + trim + dictionary
    /// (Swift 6: `nonisolated` for the background coordinator).
    nonisolated func processDetailed(_ raw: String, for target: TargetApplication) -> ProcessedTranscript {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProcessedTranscript(text: "", matchedSnippet: false)
        }

        let normalizedUtterance = Self.normalizeTriggerPhrase(trimmed)
        if !normalizedUtterance.isEmpty {
            let matchingSnippets = snippets.filter { snippet in
                guard snippet.voiceTriggerEnabled else { return false }
                if !snippet.bundleIDs.isEmpty {
                    guard let targetID = target.bundleIdentifier,
                          DictionaryRule.scopeMatches(snippet.bundleIDs, target: targetID)
                    else { return false }
                }
                return Self.normalizeTriggerPhrase(snippet.name) == normalizedUtterance
            }
            if let matched = matchingSnippets.min(by: { lhs, rhs in
                let lhsScoped = !lhs.bundleIDs.isEmpty
                let rhsScoped = !rhs.bundleIDs.isEmpty
                if lhsScoped != rhsScoped { return lhsScoped }
                return lhs.id.uuidString < rhs.id.uuidString
            }) {
                return ProcessedTranscript(text: matched.expansion, matchedSnippet: true)
            }
        }

        let text = applyDictionary(to: trimmed, for: target)
        return ProcessedTranscript(text: text, matchedSnippet: false)
    }

    /// Pure trim + snippet/dictionary convenience returning just the final text.
    nonisolated func process(_ raw: String, for target: TargetApplication) -> String {
        processDetailed(raw, for: target).text
    }

    private nonisolated func applyDictionary(to trimmed: String, for target: TargetApplication) -> String {
        guard !compiledRules.isEmpty else { return trimmed }

        let active = compiledRules.filter { rule in
            guard !rule.bundleIDs.isEmpty else { return true }
            guard let targetID = target.bundleIdentifier else { return false }
            return DictionaryRule.scopeMatches(rule.bundleIDs, target: targetID)
        }
        guard !active.isEmpty else { return trimmed }

        let nsText = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var protected: [NSRange] = []
        if trimmed.contains(":") || trimmed.contains("@") || trimmed.contains(".") {
            protected += Self.linkDetector.ranges(in: trimmed, fullRange: fullRange)
        }
        if trimmed.contains("/"), let pathRegex = Self.pathRegex {
            protected += pathRegex.matches(in: trimmed, options: [], range: fullRange).map(\.range)
        }

        struct Candidate {
            let range: NSRange
            let replacement: String
            let appScoped: Bool
            let length: Int
            let order: String
        }
        var candidates: [Candidate] = []
        for rule in active {
            for match in rule.regex.matches(in: trimmed, options: [], range: fullRange) {
                let intersects = protected.contains { NSIntersectionRange($0, match.range).length > 0 }
                guard !intersects else { continue }
                candidates.append(Candidate(
                    range: match.range,
                    replacement: rule.replacement,
                    appScoped: rule.appScoped,
                    length: match.range.length,
                    order: rule.order
                ))
            }
        }
        guard !candidates.isEmpty else { return trimmed }

        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.length != $1.length { return $0.length > $1.length }
            if $0.appScoped != $1.appScoped { return $0.appScoped }
            return $0.order < $1.order
        }
        var accepted: [Candidate] = []
        var cursor = 0
        for candidate in candidates {
            guard candidate.range.location >= cursor else { continue }
            accepted.append(candidate)
            cursor = candidate.range.location + candidate.range.length
        }

        let result = NSMutableString(string: trimmed)
        for candidate in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: candidate.range, with: candidate.replacement)
        }
        return result as String
    }
}
