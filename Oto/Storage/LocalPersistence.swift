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
//  Isolation split (Swift 6, default MainActor isolation): this actor moves
//  BYTES only. All Codable work happens in VersionedStoreFile (@MainActor),
//  because synthesized Codable conformances inherit MainActor isolation and
//  cannot cross into a background actor. The split is deliberate, not layered.
//

import Foundation
import os

/// Version envelope. Bare arrays are never persisted: an unknown
/// schemaVersion triggers backup + empty instead of a decoding crash.
struct VersionedFile<T: Codable>: Codable {
    var schemaVersion: Int
    var items: [T]
}

/// Bytes-only file owner. Actor-isolated: concurrent writes serialize
/// instead of interleaving partial files. Knows nothing about Codable.
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

    /// Raw bytes or nil (missing file is not an error).
    func read(filename: String) -> Data? {
        do {
            try ensureDirectory()
            let fileURL = try url(for: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        } catch {
            Self.log.error("persistence read failed \(filename, privacy: .public)")
            return nil
        }
    }

    /// All-or-nothing on disk (`.atomic`); encoder runs before this call so
    /// a serialization failure never leaves a partial file.
    func write(_ data: Data, filename: String) throws {
        try ensureDirectory()
        try data.write(to: url(for: filename), options: .atomic)
    }

    func delete(filename: String) throws {
        let fileURL = try url(for: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
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
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let base = fileURL.deletingPathExtension().lastPathComponent
            let backupName = "\(base).\(reason)-\(stamp).json"
            try manager.moveItem(at: fileURL, to: backups.appendingPathComponent(backupName))
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

    // MARK: - Private

    private func ensureDirectory() throws {
        let dir = try url(for: "probe").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Codable side of persistence. @MainActor by design (see file header):
/// every encode/decode of store models happens here, never in the actor.
@MainActor
enum VersionedStoreFile {
    /// Load or empty. Unknown schema or corrupt JSON moves the file to
    /// Backups/ and returns empty — never throws user data away, never
    /// crashes dictation-adjacent flows.
    static func load<T: Codable>(_ type: T.Type, filename: String, via persistence: LocalPersistence) async -> [T] {
        guard let data = await persistence.read(filename: filename) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(VersionedFile<T>.self, from: data)
            guard envelope.schemaVersion == LocalPersistence.schemaVersion else {
                await persistence.moveAside(filename: filename, reason: "schema")
                return []
            }
            return envelope.items
        } catch {
            await persistence.moveAside(filename: filename, reason: "corrupt")
            return []
        }
    }

    static func save<T: Codable>(_ items: [T], filename: String, via persistence: LocalPersistence) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(VersionedFile<T>(
            schemaVersion: LocalPersistence.schemaVersion, items: items
        ))
        try await persistence.write(data, filename: filename)
    }
}
