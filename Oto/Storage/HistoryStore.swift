//
//  HistoryStore.swift
//  Oto
//
//  Phase 6A: opt-in local recall. Final text + timestamp (+ bundle ID for
//  display) only. Never audio, partials, clipboard snapshots, target-app
//  contents, or prompt traces — record() takes a String, so richer types
//  cannot enter by construction. Off by default.
//

import Foundation
import os

/// One remembered dictation. CodingKeys are pinned by test: adding a key is
/// a privacy decision, not a refactor. `rawText` (E1) holds what was said
/// when Auto Cleanup rewrote it; nil for verbatim entries and all pre-rework
/// rows (old JSON decodes with nils — same data class as `finalText`, same
/// bounds/caps/retention/deletion, never audio/partials/clipboard).
struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    nonisolated static let maxTextLength = 5000

    let id: UUID
    var finalText: String
    var createdAt: Date
    var bundleIdentifier: String?
    var rawText: String?
    var wasCleaned: Bool = false

    nonisolated init(
        id: UUID = UUID(),
        finalText: String,
        createdAt: Date = Date(),
        bundleIdentifier: String? = nil,
        rawText: String? = nil,
        wasCleaned: Bool = false
    ) {
        self.id = id
        self.finalText = finalText
        self.createdAt = createdAt
        self.bundleIdentifier = bundleIdentifier
        self.rawText = rawText
        self.wasCleaned = wasCleaned
    }

    /// Tolerant decode: pre-rework rows lack `rawText`/`wasCleaned` — they
    /// read as nil/false (Undo stays hidden for them) instead of failing.
    /// New rows always carry both keys when set (nil `rawText` still omits
    /// its key per `JSONEncoder` optional rules — pinned by test).
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        finalText = try container.decode(String.self, forKey: .finalText)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        wasCleaned = try container.decodeIfPresent(Bool.self, forKey: .wasCleaned) ?? false
    }
}

extension HistoryEntry {
    enum CodingKeys: String, CodingKey {
        case id
        case finalText
        case createdAt
        case bundleIdentifier
        case rawText
        case wasCleaned
    }
}

@Observable @MainActor
final class HistoryStore {
    static let filename = "history.v1.json"
    nonisolated static let enabledKey = "app.Oto.historyEnabled"
    nonisolated static let maxEntries = 100
    nonisolated static let maxAgeDays = 30

    /// Newest-first, already trimmed. Empty until load() + first record().
    private(set) var entries: [HistoryEntry] = []
    private let persistence: LocalPersistence
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "app.Oto", category: "history")

    init(persistence: LocalPersistence, defaults: UserDefaults = .standard) {
        self.persistence = persistence
        self.defaults = defaults
    }

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    private func enabled() -> Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    func load() async {
        entries = await VersionedStoreFile.load(HistoryEntry.self, filename: Self.filename, via: persistence)
        trim()
    }

    /// Records one final transcript. No-op when history is off or text is
    /// blank. Bounds enforced synchronously on every write: 30-day age,
    /// newest-100 cap (createdAt desc, id tie-break), 5000-char text cap
    /// (both texts). When Auto Cleanup rewrote the dictation, `rawText`
    /// carries what was said and `wasCleaned` marks the row Undo-able.
    func record(
        finalText: String,
        rawText: String? = nil,
        wasCleaned: Bool = false,
        bundleID: String?,
        at date: Date = Date()
    ) async {
        guard enabled() else { return }
        let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(HistoryEntry(
            finalText: String(clean.prefix(HistoryEntry.maxTextLength)),
            createdAt: date,
            bundleIdentifier: bundleID,
            rawText: raw.flatMap { String($0.prefix(HistoryEntry.maxTextLength)) },
            wasCleaned: wasCleaned && !(raw?.isEmpty ?? true)
        ))
        trim()
        await persist()
    }

    /// Undo AI edit (E1): restores the raw wording on a cleaned entry,
    /// then clears the raw (a second Undo is a no-op — the entry is now
    /// verbatim). No-op for verbatim entries and unknown IDs.
    func undoCleanup(id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let raw = entries[index].rawText, !raw.isEmpty
        else { return }
        entries[index].finalText = raw
        entries[index].rawText = nil
        entries[index].wasCleaned = false
        await persist()
    }

    func remove(id: UUID) async {
        entries.removeAll { $0.id == id }
        await persist()
    }

    /// Clear All names exactly what it deletes (history file content only).
    func clearAll() async {
        entries = []
        await persist()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    // MARK: - Private

    private func trim() {
        let cutoff = Date().addingTimeInterval(TimeInterval(-Self.maxAgeDays * 24 * 3600))
        entries = Array(entries
            .filter { $0.createdAt > cutoff }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(Self.maxEntries))
    }

    private func persist() async {
        do {
            try await VersionedStoreFile.save(entries, filename: Self.filename, via: persistence)
        } catch {
            log.error("history save failed")
        }
    }
}
