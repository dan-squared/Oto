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
/// a privacy decision, not a refactor.
struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    nonisolated static let maxTextLength = 5000

    let id: UUID
    var finalText: String
    var createdAt: Date
    var bundleIdentifier: String?

    nonisolated init(
        id: UUID = UUID(),
        finalText: String,
        createdAt: Date = Date(),
        bundleIdentifier: String? = nil
    ) {
        self.id = id
        self.finalText = finalText
        self.createdAt = createdAt
        self.bundleIdentifier = bundleIdentifier
    }
}

@Observable @MainActor
final class HistoryStore {
    static let filename = "history.v1.json"
    nonisolated static let enabledKey = "app.Oto.historyEnabled"
    nonisolated static let maxEntries = 200
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
    /// newest-200 cap (createdAt desc, id tie-break), 5000-char text cap.
    func record(finalText: String, bundleID: String?, at date: Date = Date()) async {
        guard enabled() else { return }
        let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        entries.append(HistoryEntry(
            finalText: String(clean.prefix(HistoryEntry.maxTextLength)),
            createdAt: date,
            bundleIdentifier: bundleID
        ))
        trim()
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
