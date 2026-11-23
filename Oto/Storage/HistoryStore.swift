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
nonisolated struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
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
    nonisolated enum CodingKeys: String, CodingKey {
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
    nonisolated static let filename = "history.v1.json"
    nonisolated static let enabledKey = "app.Oto.historyEnabled"
    nonisolated static let maxEntries = 100
    nonisolated static let maxAgeDays = 30

    /// Newest-first, already trimmed. Empty until load() + first record().
    private(set) var entries: [HistoryEntry] = []
    /// Last write failed; the pane says the entry is in memory only.
    var saveFailed = false
    private let persistence: LocalPersistence
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "app.Oto", category: "history")
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false
    private var hasLocalMutations = false
    private var clearedBeforeLoad = false
    private var loadFailed = false
    private var saveGeneration: UInt64 = 0
    private var pendingSaveTask: Task<Void, Never>?

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
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task {
            let outcome = await VersionedStoreFile.loadOutcome(
                HistoryEntry.self,
                filename: Self.filename,
                via: self.persistence
            )
            self.hasLoaded = true
            switch outcome {
            case .readError:
                self.loadFailed = true
                self.saveFailed = true
                return
            case .missing:
                self.loadFailed = false
                if !self.hasLocalMutations {
                    self.entries = []
                }
            case .loaded(let diskEntries):
                self.loadFailed = false
                let needsPersist: Bool
                if !self.hasLocalMutations {
                    self.entries = diskEntries
                    let beforeTrim = self.entries.count
                    self.trim()
                    needsPersist = self.entries.count != beforeTrim
                } else if self.clearedBeforeLoad {
                    needsPersist = false
                } else {
                    let localIDs = Set(self.entries.map(\.id))
                    let merged = self.entries + diskEntries.filter { !localIDs.contains($0.id) }
                    self.entries = merged
                    self.trim()
                    needsPersist = !diskEntries.isEmpty
                }
                if needsPersist {
                    await self.persist()
                }
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
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
        if !hasLoaded {
            await load()
        } else {
            await waitForLoadIfNeeded()
        }
        guard enabled() else { return }
        let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        hasLocalMutations = true
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
        await waitForLoadIfNeeded()
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let raw = entries[index].rawText, !raw.isEmpty
        else { return }
        hasLocalMutations = true
        entries[index].finalText = raw
        entries[index].rawText = nil
        entries[index].wasCleaned = false
        await persist()
    }

    func remove(id: UUID) async {
        await waitForLoadIfNeeded()
        hasLocalMutations = true
        entries.removeAll { $0.id == id }
        await persist()
    }

    /// Clear All removes every stored transcript AND any backup files for
    /// history so user-requested deletion leaves nothing behind on disk.
    func clearAll() async {
        await waitForLoadIfNeeded()
        hasLocalMutations = true
        clearedBeforeLoad = true
        loadFailed = false
        entries = []
        await persist()
        await persistence.purgeBackups(matchingPrefix: "history.v1")
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    // MARK: - Private

    private func waitForLoadIfNeeded() async {
        if let loadTask {
            await loadTask.value
        }
    }

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
        if loadFailed {
            saveFailed = true
            return
        }
        saveGeneration &+= 1
        let generation = saveGeneration
        let snapshot = entries
        let previous = pendingSaveTask
        let task = Task {
            await previous?.value
            guard generation == self.saveGeneration else { return }
            do {
                try await VersionedStoreFile.save(snapshot, filename: Self.filename, via: self.persistence)
                if generation == self.saveGeneration {
                    self.saveFailed = false
                }
            } catch {
                if generation == self.saveGeneration {
                    self.saveFailed = true
                }
                self.log.error("history save failed")
            }
        }
        pendingSaveTask = task
        await task.value
    }
}
