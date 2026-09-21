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
    private struct Record: Codable, Equatable, Sendable {
        var name: String
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
}
