//
//  LocalPersistence.swift
//  Oto
//
//  Phase 6A: one versioned-file service for all growing text data
//  (dictionary, snippets, history). Small scalars stay in UserDefaults;
//  everything else lives here. Never audio, partials, clipboard snapshots,
//  or target-app contents — the API takes Codable values, so unpersistable
//  types cannot enter by construction.
//
//  Isolation split (Swift 6, default MainActor isolation): `LocalPersistence`
//  owns both file I/O and Codable encoding/decoding off `@MainActor`.
//  `VersionedFile` is `nonisolated`, and store models (`HistoryEntry`,
//  `DictionaryRule`, `Snippet`) are `nonisolated` value types so JSON work
//  never blocks the UI thread.
//

import Foundation
import os

/// Version envelope. Bare arrays are never persisted: an unknown
/// schemaVersion triggers backup + empty instead of a decoding crash.
nonisolated struct VersionedFile<T: Codable>: Codable {
    var schemaVersion: Int
    var items: [T]
}

extension VersionedFile: Sendable where T: Sendable {}

/// Outcome of reading a versioned store file. Distinguishes a clean missing
/// file (`ENOENT`) from a real I/O read failure so transient errors never
/// silently wipe persisted data on the next save.
nonisolated enum StoreLoadOutcome<T: Sendable>: Sendable {
    case loaded([T])
    case missing
    case readError
}

/// File owner & off-main Codable serializer. Actor-isolated: concurrent writes
/// serialize instead of interleaving partial files.
actor LocalPersistence {
    static let schemaVersion = 1
    static let appDirectoryName = "Oto"
    static let backupDirectoryName = "Backups"
    static let maxBackupsPerFile = 3

    private static let log = Logger(subsystem: "app.Oto", category: "persistence")

    /// Nil in production (resolves Application Support); injected in tests
    /// so no test touches the real container.
    private let overrideDirectory: URL?

    init(directory: URL? = nil) {
        self.overrideDirectory = directory
    }

    nonisolated static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    nonisolated func url(for filename: String) throws -> URL {
        let dir: URL
        if let overrideDirectory {
            dir = overrideDirectory
        } else {
            dir = try Self.defaultDirectory()
        }
        return dir.appendingPathComponent(filename, isDirectory: false)
    }

    /// Raw bytes, or `nil` when the file does not exist (`ENOENT`).
    /// Real I/O read errors throw so callers never treat them as an empty store.
    func read(filename: String) throws -> Data? {
        try ensureDirectory()
        let fileURL = try url(for: filename)
        do {
            return try Data(contentsOf: fileURL)
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        {
            return nil
        }
    }

    /// All-or-nothing on disk (`.atomic`); encoder runs before this call so
    /// a serialization failure never leaves a partial file. Written JSON files
    /// are restricted to owner-only (`0600`), and history is excluded from
    /// Time Machine backups.
    func write(_ data: Data, filename: String) throws {
        try ensureDirectory()
        let fileURL = try url(for: filename)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        if filename == HistoryStore.filename {
            excludeFromBackup(fileURL)
        }
    }

    func delete(filename: String) throws {
        let fileURL = try url(for: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Decodes a versioned store file off `@MainActor`. Distinguishes missing
    /// files from I/O errors, and backs up corrupt or unknown-schema files.
    func loadVersioned<T: Codable & Sendable>(_ type: T.Type, filename: String) -> StoreLoadOutcome<T> {
        let data: Data?
        do {
            data = try read(filename: filename)
        } catch {
            Self.log.error("persistence read failed \(filename, privacy: .public)")
            return .readError
        }
        guard let data else { return .missing }
        do {
            // Symmetric with `save`: dates are ISO-8601 strings. A default
            // decoder expects reference-date Doubles and would mark every
            // file this app writes as corrupt on the next launch.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(VersionedFile<T>.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion else {
                moveAside(filename: filename, reason: "schema")
                return .loaded([])
            }
            return .loaded(envelope.items)
        } catch {
            moveAside(filename: filename, reason: "corrupt")
            return .loaded([])
        }
    }

    /// Encodes and atomically writes a versioned store file off `@MainActor`.
    func saveVersioned<T: Codable & Sendable>(_ items: [T], filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(VersionedFile<T>(
            schemaVersion: Self.schemaVersion, items: items
        ))
        try write(data, filename: filename)
    }

    /// Moves the unreadable file aside (counts only in logs — file
    /// contents are never logged) and prunes old backups to the newest 3.
    /// The caller then starts empty: user data is never silently deleted.
    func moveAside(filename: String, reason: String) {
        do {
            let fileURL = try url(for: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let manager = FileManager.default
            let backups = fileURL.deletingLastPathComponent()
                .appendingPathComponent(Self.backupDirectoryName, isDirectory: true)
            try manager.createDirectory(
                at: backups,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.path)
            excludeFromBackup(backups)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let suffix = String(UUID().uuidString.prefix(8))
            let base = fileURL.deletingPathExtension().lastPathComponent
            let backupName = "\(base).\(reason)-\(stamp)-\(suffix).json"
            let destination = backups.appendingPathComponent(backupName)
            try manager.moveItem(at: fileURL, to: destination)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let kept = try manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(base) }
                .sorted { $0.path > $1.path }
            for stale in kept.dropFirst(Self.maxBackupsPerFile) {
                try? manager.removeItem(at: stale)
            }
            Self.log.error("persistence backup (\(reason, privacy: .public)) for \(filename, privacy: .public)")
        } catch {
            Self.log.error("persistence backup failed \(filename, privacy: .public)")
        }
    }

    /// Removes all backup files in `Backups/` matching `base` (e.g.,
    /// `"history.v1"` removes `history.v1.*.json`). Used by `HistoryStore.clearAll()`
    /// so user-requested deletion leaves no residual transcript backups behind.
    func purgeBackups(matchingPrefix base: String) {
        do {
            let dir = try url(for: "probe").deletingLastPathComponent()
            let backups = dir.appendingPathComponent(Self.backupDirectoryName, isDirectory: true)
            let manager = FileManager.default
            guard manager.fileExists(atPath: backups.path) else { return }
            let entries = try manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent.hasPrefix(base) {
                try? manager.removeItem(at: entry)
            }
        } catch {
            Self.log.error("persistence backup purge failed for \(base, privacy: .public)")
        }
    }

    // MARK: - Private

    private func ensureDirectory() throws {
        let dir = try url(for: "probe").deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    /// One-shot sandbox→unsandboxed migration (audit F7): Container-scoped
    /// stores stay behind otherwise (dictionary/history silently restart
    /// empty). Copies `*.json` from the dead Container dir ONLY when the
    /// new home has no JSON stores yet — never merges, never overwrites,
    /// never runs twice (second run sees migrated JSON). Non-JSON entries
    /// like `Crashes/` or `.DS_Store` do not block migration.
    nonisolated static func migrateSandboxedStoreIfNeeded(
        fileManager: FileManager = .default,
        home: URL? = nil,
        containerHome: URL? = nil
    ) {
        let fm = fileManager
        let homeDir = home
            ?? (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent(appDirectoryName, isDirectory: true) }
        let oldDir = containerHome ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/app.Oto/Data/Library/Application Support/\(appDirectoryName)", isDirectory: true)
        guard let homeDir, let old = try? fm.contentsOfDirectory(
            at: oldDir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }), !old.isEmpty else { return }
        let current = (try? fm.contentsOfDirectory(at: homeDir, includingPropertiesForKeys: nil)) ?? []
        guard !current.contains(where: { $0.pathExtension == "json" }) else { return }
        try? fm.createDirectory(
            at: homeDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homeDir.path)
        for file in old {
            let destination = homeDir.appendingPathComponent(file.lastPathComponent)
            try? fm.copyItem(at: file, to: destination)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
}

/// Versioned-store facade preserving the static API while delegating JSON
/// encoding/decoding and file I/O off `@MainActor` inside `LocalPersistence`.
enum VersionedStoreFile {
    /// Load or empty. Unknown schema or corrupt JSON moves the file to
    /// Backups/ and returns empty — never throws user data away, never
    /// crashes dictation-adjacent flows.
    nonisolated static func load<T: Codable & Sendable>(
        _ type: T.Type,
        filename: String,
        via persistence: LocalPersistence
    ) async -> [T] {
        switch await loadOutcome(type, filename: filename, via: persistence) {
        case .loaded(let items):
            return items
        case .missing, .readError:
            return []
        }
    }

    nonisolated static func loadOutcome<T: Codable & Sendable>(
        _ type: T.Type,
        filename: String,
        via persistence: LocalPersistence
    ) async -> StoreLoadOutcome<T> {
        await persistence.loadVersioned(type, filename: filename)
    }

    nonisolated static func save<T: Codable & Sendable>(
        _ items: [T],
        filename: String,
        via persistence: LocalPersistence
    ) async throws {
        try await persistence.saveVersioned(items, filename: filename)
    }
}
