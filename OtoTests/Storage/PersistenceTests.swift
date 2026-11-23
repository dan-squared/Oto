//
//  PersistenceTests.swift
//  OtoTests
//
//  Phase 6A: bytes-level files (round-trip, missing, delete, atomicity)
//  plus the versioned envelope (schema-mismatch/corrupt backup + empty).
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct PersistenceTests {
    nonisolated private struct Record: Codable, Equatable, Sendable {
        var name: String
    }

    /// The stores carry `Date` fields (history timestamps). The envelope
    /// must round-trip them: `save` writes ISO-8601, so `load` must read it.
    nonisolated private struct DatedRecord: Codable, Equatable, Sendable {
        var name: String
        var createdAt: Date
    }

    private func makePersistence() -> LocalPersistence {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return LocalPersistence(directory: dir)
    }

    @Test func envelopeRoundTrip() async throws {
        let persistence = makePersistence()
        let loaded0: [Record] = await VersionedStoreFile.load(Record.self, filename: "t.v1.json", via: persistence)
        #expect(loaded0.isEmpty)
        try await VersionedStoreFile.save([Record(name: "a"), Record(name: "b")], filename: "t.v1.json", via: persistence)
        let loaded: [Record] = await VersionedStoreFile.load(Record.self, filename: "t.v1.json", via: persistence)
        #expect(loaded == [Record(name: "a"), Record(name: "b")])
    }

    @Test func datedEnvelopeRoundTrips() async throws {
        // Regression: save encoded dates as ISO-8601 while load used the
        // default (reference-date Double) strategy, so the app moved its own
        // history file to Backups as "corrupt" on the next launch.
        let persistence = makePersistence()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try await VersionedStoreFile.save(
            [DatedRecord(name: "a", createdAt: date)],
            filename: "t.v1.json",
            via: persistence
        )
        let loaded: [DatedRecord] = await VersionedStoreFile.load(DatedRecord.self, filename: "t.v1.json", via: persistence)
        #expect(loaded.count == 1)
        #expect(abs(loaded.first!.createdAt.timeIntervalSince(date)) < 1)
        // And it was not moved aside.
        let backups = try persistence.url(for: "t.v1.json")
            .deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        #expect(contents.isEmpty)
    }

    @Test func deleteRemovesFile() async throws {
        let persistence = makePersistence()
        try await VersionedStoreFile.save([Record(name: "a")], filename: "t.v1.json", via: persistence)
        try await persistence.delete(filename: "t.v1.json")
        let loaded: [Record] = await VersionedStoreFile.load(Record.self, filename: "t.v1.json", via: persistence)
        #expect(loaded.isEmpty)
        // Deleting a missing file is not an error.
        try await persistence.delete(filename: "t.v1.json")
    }

    @Test func corruptFileBackedUpAndEmptied() async throws {
        let persistence = makePersistence()
        try await VersionedStoreFile.save([Record(name: "a")], filename: "t.v1.json", via: persistence)
        let url = try persistence.url(for: "t.v1.json")
        try Data("{{not json".utf8).write(to: url, options: .atomic)
        let loaded: [Record] = await VersionedStoreFile.load(Record.self, filename: "t.v1.json", via: persistence)
        #expect(loaded.isEmpty)
        // Original preserved under Backups/, never silently deleted.
        let backups = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil
        )
        #expect(contents.count == 1)
        #expect(contents[0].lastPathComponent.contains("corrupt"))
    }

    @Test func schemaMismatchBackedUpAndEmptied() async throws {
        let persistence = makePersistence()
        try await VersionedStoreFile.save([Record(name: "a")], filename: "t.v1.json", via: persistence)
        let url = try persistence.url(for: "t.v1.json")
        struct Future: Codable { var schemaVersion: Int; var items: [Record] }
        let future = try JSONEncoder().encode(Future(schemaVersion: 99, items: [Record(name: "a")]))
        try future.write(to: url, options: .atomic)
        let loaded: [Record] = await VersionedStoreFile.load(Record.self, filename: "t.v1.json", via: persistence)
        #expect(loaded.isEmpty)
        let backups = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil
        )
        #expect(contents.count == 1)
        #expect(contents[0].lastPathComponent.contains("schema"))
    }

    @Test func concurrentSavesStayValid() async throws {
        let persistence = makePersistence()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    try? await VersionedStoreFile.save([Record(name: "n\(index)")], filename: "t.v1.json", via: persistence)
                }
            }
        }
        // Exactly one writer won; the file is valid either way.
        let loaded: [Record] = await VersionedStoreFile.load(Record.self, filename: "t.v1.json", via: persistence)
        #expect(loaded.count == 1)
    }

    @Test func sandboxedStoreMigratesOnce() throws {
        // Audit F7: Container-scoped JSON moves over only into an empty
        // home (never merge/overwrite); second run and non-empty homes
        // are no-ops.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldDir = tmp.appendingPathComponent("old", isDirectory: true)
        let newDir = tmp.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "rules".write(to: oldDir.appendingPathComponent("dictionary.v1.json"), atomically: true, encoding: .utf8)
        LocalPersistence.migrateSandboxedStoreIfNeeded(home: newDir, containerHome: oldDir)
        #expect(fm.fileExists(atPath: newDir.appendingPathComponent("dictionary.v1.json").path))
        try "changed".write(to: oldDir.appendingPathComponent("dictionary.v1.json"), atomically: true, encoding: .utf8)
        LocalPersistence.migrateSandboxedStoreIfNeeded(home: newDir, containerHome: oldDir)
        let kept = try String(contentsOf: newDir.appendingPathComponent("dictionary.v1.json"), encoding: .utf8)
        #expect(kept == "rules")
        try fm.removeItem(at: tmp)
    }

    @Test func migrationIgnoresNonJsonEntriesLikeCrashesAndDSStore() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldDir = tmp.appendingPathComponent("old", isDirectory: true)
        let newDir = tmp.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir.appendingPathComponent("Crashes", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: newDir.appendingPathComponent(".DS_Store"))
        try "rules".write(to: oldDir.appendingPathComponent("dictionary.v1.json"), atomically: true, encoding: .utf8)

        LocalPersistence.migrateSandboxedStoreIfNeeded(home: newDir, containerHome: oldDir)
        #expect(fm.fileExists(atPath: newDir.appendingPathComponent("dictionary.v1.json").path))
        try fm.removeItem(at: tmp)
    }

    @Test func permissionsAndBackupExclusionAreApplied() async throws {
        let persistence = makePersistence()
        try await VersionedStoreFile.save([Record(name: "secret")], filename: HistoryStore.filename, via: persistence)
        let fileURL = try persistence.url(for: HistoryStore.filename)
        let dirURL = fileURL.deletingLastPathComponent()

        let dirPerms = try FileManager.default.attributesOfItem(atPath: dirURL.path)[.posixPermissions] as? Int
        let filePerms = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
        #expect(filePerms == 0o600)

        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func rapidBackupsSanitizeColonsAndDoNotCollide() async throws {
        let persistence = makePersistence()
        let url = try persistence.url(for: HistoryStore.filename)
        for index in 0..<2 {
            try await persistence.write(Data("bad \(index)".utf8), filename: HistoryStore.filename)
            await persistence.moveAside(filename: HistoryStore.filename, reason: "corrupt")
        }
        let backups = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let backupValues = try backups.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(backupValues.isExcludedFromBackup == true)
        let contents = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(contents.count == 2)
        for file in contents {
            #expect(!file.lastPathComponent.contains(":"))
        }
        await persistence.purgeBackups(matchingPrefix: "history.v1")
        let remaining = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(remaining.isEmpty)
    }

    @Test func readDistinguishesMissingFromRealIOError() async throws {
        let persistence = makePersistence()
        let missing = try await persistence.read(filename: "does-not-exist.v1.json")
        #expect(missing == nil)

        // A directory at the target filename triggers a real read error (EISDIR),
        // not a clean missing file.
        let fileURL = try persistence.url(for: "broken.v1.json")
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let outcome = await VersionedStoreFile.loadOutcome(Record.self, filename: "broken.v1.json", via: persistence)
        if case .readError = outcome {
            // expected
        } else {
            Issue.record("expected .readError for unreadable file path")
        }
    }
}
