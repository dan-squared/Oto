//
//  DictionaryStore.swift
//  Oto
//
//  Phase 6A: personal dictionary. Deterministic literal replacements applied
//  inside TranscriptPipeline (pure function, target-scoped). Exact
//  person-authored values only — no model-generated replacements, no ambient
//  snippet expansion, no cloud.
//

import Foundation
import os

/// One replacement rule. `bundleID == nil` means global; otherwise the rule
/// fires only for that exact app (case-sensitive — bundle IDs are
/// case-sensitive reverse-DNS; lowercasing would silently never fire).
struct DictionaryRule: Sendable, Hashable, Codable, Identifiable {
    nonisolated static let maxSpokenLength = 80
    nonisolated static let maxReplacementLength = 200
    nonisolated static let maxRules = 500
    nonisolated static let maxPreviewLength = 1000

    let id: UUID
    var spoken: String
    var replacement: String
    var bundleID: String?
    var isEnabled: Bool

    nonisolated init(
        id: UUID = UUID(),
        spoken: String,
        replacement: String,
        bundleID: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
        self.bundleID = bundleID
        self.isEnabled = isEnabled
    }

    /// Scope key for duplicate detection. Spoken folds case (matching is
    /// case-insensitive); bundle IDs never fold.
    nonisolated func duplicateKey() -> String {
        "\(Self.normalizeSpoken(spoken).lowercased())\u{1F}\(bundleID ?? "*global*")"
    }

    /// Trim, collapse interior whitespace, NFC. The transcript is used as-is
    /// (renormalizing it would invalidate NSRange splicing), so rules store
    /// NFC and matching documents the residual NFD-miss edge.
    nonisolated static func normalizeSpoken(_ raw: String) -> String {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.precomposedStringWithCanonicalMapping
    }
}

/// Named validation failures with product copy (09 §3.5: feedback before the
/// person thinks a rule was saved).
enum DictionaryValidationError: Error, Equatable, Sendable {
    case emptySpoken
    case emptyReplacement
    case spokenTooLong
    case replacementTooLong
    case emptyBundleID
    case duplicate(spoken: String, scope: String)
    case storeFull
    case notFound

    nonisolated var errorDescription: String {
        switch self {
        case .emptySpoken:
            return "Enter what you say — the spoken form can't be empty."
        case .emptyReplacement:
            return "Enter the replacement text."
        case .spokenTooLong:
            return "Spoken form is too long (max \(DictionaryRule.maxSpokenLength) characters)."
        case .replacementTooLong:
            return "Replacement is too long (max \(DictionaryRule.maxReplacementLength) characters)."
        case .emptyBundleID:
            return "App scope is empty — pick Global or enter the app's bundle ID."
        case .duplicate(let spoken, let scope):
            return "‘\(spoken)’ already exists (\(scope)). Edit the existing rule instead of adding a copy."
        case .storeFull:
            return "Dictionary holds \(DictionaryRule.maxRules) rules. Delete or merge a rule before adding another."
        case .notFound:
            return "This rule was deleted."
        }
    }
}

/// Report for one import file: one bad row never discards the good rows.
struct DictionaryImportReport: Equatable, Sendable {
    var imported: Int
    var skippedDuplicates: Int
    var rejected: [(row: Int, reason: String)]

    nonisolated static func == (lhs: DictionaryImportReport, rhs: DictionaryImportReport) -> Bool {
        lhs.imported == rhs.imported
            && lhs.skippedDuplicates == rhs.skippedDuplicates
            && lhs.rejected.map(\.row) == rhs.rejected.map(\.row)
    }
}

private struct DictionaryImportFile: Codable {
    var schemaVersion: Int
    var rules: [DictionaryRule]
}

// MARK: - Pure application (no store, no isolation, no shared state)

/// Deterministic single-pass application. Case-insensitive,
/// diacritic-sensitive, locale-independent; Unicode-aware word boundaries;
/// URL/email/path ranges vetoed; replacements never re-scanned (no cascade).
/// All matching state is function-local: NSRegularExpression/NSDataDetector
/// never cross a Sendable boundary.
nonisolated func applyDictionaryRules(
    _ rules: [DictionaryRule],
    to text: String,
    for target: TargetApplication
) -> String {
    let active = rules.filter(\.isEnabled).filter { rule in
        guard let scope = rule.bundleID else { return true }
        guard let targetID = target.bundleIdentifier else { return false }
        return scope == targetID
    }
    guard !active.isEmpty, !text.isEmpty else { return text }

    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)

    // Protected ranges: links (URLs, emails) + file paths (detector blind spot).
    var protected: [NSRange] = []
    if let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    ) {
        protected += detector.matches(in: text, options: [], range: fullRange).map(\.range)
    }
    if let pathRegex = try? NSRegularExpression(
        pattern: "(~|\\.{1,2})?/[\\p{L}\\p{N}._\\-+%@:,/]+"
    ) {
        protected += pathRegex.matches(in: text, options: [], range: fullRange).map(\.range)
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
        let spoken = DictionaryRule.normalizeSpoken(rule.spoken)
        guard !spoken.isEmpty else { continue }
        let pattern = "(?<![\\p{L}\\p{N}_])"
            + NSRegularExpression.escapedPattern(for: spoken)
            + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ) else { continue }
        for match in regex.matches(in: text, options: [], range: fullRange) {
            let intersects = protected.contains { NSIntersectionRange($0, match.range).length > 0 }
            guard !intersects else { continue }
            candidates.append(Candidate(
                range: match.range,
                replacement: rule.replacement,
                appScoped: rule.bundleID != nil,
                length: match.range.length,
                order: rule.id.uuidString
            ))
        }
    }
    guard !candidates.isEmpty else { return text }

    // Earliest start wins; longest match at same start; app-scoped beats
    // global at identical range; id breaks full ties deterministically.
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

    let result = NSMutableString(string: text)
    for candidate in accepted.sorted(by: { $0.range.location > $1.range.location }) {
        result.replaceCharacters(in: candidate.range, with: candidate.replacement)
    }
    return result as String
}

// MARK: - Store (MainActor owner for Settings; values cross to background)

/// UI-owned rule collection. Persistence and validation live here; the
/// background pipeline receives plain `[DictionaryRule]` values only.
@Observable @MainActor
final class DictionaryStore {
    static let filename = "dictionary.v1.json"

    private(set) var rules: [DictionaryRule] = []
    private let persistence: LocalPersistence
    private let log = Logger(subsystem: "app.Oto", category: "dictionary")

    init(persistence: LocalPersistence) {
        self.persistence = persistence
    }

    func load() async {
        rules = await VersionedStoreFile.load(DictionaryRule.self, filename: Self.filename, via: persistence)
    }

    private func persist() async {
        do {
            try await VersionedStoreFile.save(rules, filename: Self.filename, via: persistence)
        } catch {
            log.error("dictionary save failed")
        }
    }

    /// Validates + inserts. Returns the saved rule or the blocking error.
    /// Cross-scope same-spoken is legal (app wins at apply time); the caller
    /// surfaces the precedence warning from `precedenceWarning(for:)`.
    @discardableResult
    func add(spoken: String, replacement: String, bundleID: String?, isEnabled: Bool = true) async -> Result<DictionaryRule, DictionaryValidationError> {
        let cleanSpoken = DictionaryRule.normalizeSpoken(spoken)
        guard !cleanSpoken.isEmpty else { return .failure(.emptySpoken) }
        guard cleanSpoken.count <= DictionaryRule.maxSpokenLength else { return .failure(.spokenTooLong) }
        let cleanReplacement = replacement.trimmingCharacters(in: CharacterSet.newlines)
        guard !cleanReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyReplacement)
        }
        guard cleanReplacement.count <= DictionaryRule.maxReplacementLength else {
            return .failure(.replacementTooLong)
        }
        let cleanScope: String?
        if let bundleID {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyBundleID) }
            cleanScope = trimmed
        } else {
            cleanScope = nil
        }
        guard rules.count < DictionaryRule.maxRules else { return .failure(.storeFull) }
        let candidate = DictionaryRule(
            spoken: cleanSpoken, replacement: cleanReplacement,
            bundleID: cleanScope, isEnabled: isEnabled
        )
        let key = candidate.duplicateKey()
        if rules.contains(where: { $0.duplicateKey() == key }) {
            return .failure(.duplicate(
                spoken: cleanSpoken,
                scope: cleanScope.map { "for \($0)" } ?? "globally"
            ))
        }
        rules.append(candidate)
        await persist()
        return .success(candidate)
    }

    func update(_ rule: DictionaryRule) async -> Result<DictionaryRule, DictionaryValidationError> {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return .failure(.notFound)
        }
        var fixed = rule
        fixed.spoken = DictionaryRule.normalizeSpoken(rule.spoken)
        guard !fixed.spoken.isEmpty else { return .failure(.emptySpoken) }
        guard fixed.spoken.count <= DictionaryRule.maxSpokenLength else { return .failure(.spokenTooLong) }
        guard !fixed.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyReplacement)
        }
        guard fixed.replacement.count <= DictionaryRule.maxReplacementLength else {
            return .failure(.replacementTooLong)
        }
        if let scope = fixed.bundleID, scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptyBundleID)
        }
        let key = fixed.duplicateKey()
        if rules.contains(where: { $0.id != fixed.id && $0.duplicateKey() == key }) {
            return .failure(.duplicate(
                spoken: fixed.spoken,
                scope: fixed.bundleID.map { "for \($0)" } ?? "globally"
            ))
        }
        rules[index] = fixed
        await persist()
        return .success(fixed)
    }

    func remove(id: UUID) async {
        rules.removeAll { $0.id == id }
        await persist()
    }

    func setEnabled(id: UUID, enabled: Bool) async {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        await persist()
    }

    /// Non-blocking notice when a same-spoken rule exists in another scope.
    func precedenceWarning(for rule: DictionaryRule) -> String? {
        let spokenKey = DictionaryRule.normalizeSpoken(rule.spoken).lowercased()
        let clash = rules.contains {
            $0.id != rule.id
                && DictionaryRule.normalizeSpoken($0.spoken).lowercased() == spokenKey
                && $0.bundleID != rule.bundleID
        }
        guard clash else { return nil }
        if let scope = rule.bundleID {
            return "‘\(rule.spoken)’ also has a global rule. The \(scope) rule wins there; the global rule still applies everywhere else."
        } else {
            return "‘\(rule.spoken)’ also has an app-scoped rule. That rule wins in its app; this global rule applies everywhere else."
        }
    }

    /// Honest preview: the SAME apply path with an explicit scope target.
    nonisolated func test(sample: String, scope: String?, rules snapshot: [DictionaryRule]) -> String {
        let probe = String(sample.prefix(DictionaryRule.maxPreviewLength))
        let target = TargetApplication(bundleIdentifier: scope)
        return applyDictionaryRules(snapshot, to: probe, for: target)
    }

    /// Import: validate every row first; write once. One bad row never
    /// discards the good rows or the existing store.
    func importData(_ data: Data) async -> DictionaryImportReport {
        var report = DictionaryImportReport(imported: 0, skippedDuplicates: 0, rejected: [])
        let file: DictionaryImportFile
        do {
            file = try JSONDecoder().decode(DictionaryImportFile.self, from: data)
        } catch {
            report.rejected.append((row: 0, reason: "Not an Oto dictionary file."))
            return report
        }
        guard file.schemaVersion == LocalPersistence.schemaVersion else {
            report.rejected.append((row: 0, reason: "Unsupported file version."))
            return report
        }
        var existingKeys = Set(rules.map { $0.duplicateKey() })
        var accepted: [DictionaryRule] = []
        for (offset, var rule) in file.rules.enumerated() {
            rule.spoken = DictionaryRule.normalizeSpoken(rule.spoken)
            let problems: String? = {
                if rule.spoken.isEmpty
                    || rule.spoken.count > DictionaryRule.maxSpokenLength { return "Bad spoken form." }
                if rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || rule.replacement.count > DictionaryRule.maxReplacementLength { return "Bad replacement." }
                if let scope = rule.bundleID,
                   scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Bad app scope." }
                return nil
            }()
            if let problems {
                report.rejected.append((row: offset + 1, reason: problems))
                continue
            }
            if existingKeys.contains(rule.duplicateKey()) {
                report.skippedDuplicates += 1
                continue
            }
            if rules.count + accepted.count >= DictionaryRule.maxRules {
                report.rejected.append((row: offset + 1, reason: "Dictionary is full (500 rules)."))
                continue
            }
            existingKeys.insert(rule.duplicateKey())
            accepted.append(rule)
        }
        if !accepted.isEmpty {
            rules += accepted
            await persist()
        }
        report.imported = accepted.count
        return report
    }

    /// Export payload (same schema the importer reads).
    func exportData(snapshot: [DictionaryRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(DictionaryImportFile(
            schemaVersion: LocalPersistence.schemaVersion, rules: snapshot
        ))
    }
}
