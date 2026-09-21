//
//  HistoryStoreTests.swift
//  OtoTests
//
//  Phase 6A: off-by-default, bounded retention, delete semantics, and the
//  privacy guarantee (entry keys pinned — audio/partials/clipboard can never
//  be stored because the API takes a String).
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct HistoryStoreTests {
    private func makeStore() -> (HistoryStore, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        let store = HistoryStore(persistence: LocalPersistence(directory: dir), defaults: defaults)
        return (store, defaults)
    }

    @Test func offByDefaultAndNoOp() async {
        let (store, _) = makeStore()
        await store.load()
        #expect(store.entries.isEmpty)
        await store.record(finalText: "hello", bundleID: "com.a.App")
        #expect(store.entries.isEmpty)
    }

    @Test func recordsFinalTextOnly() async {
        let (store, _) = makeStore()
        store.setEnabled(true)
        await store.record(finalText: "  hello world  ", bundleID: "com.a.App")
        #expect(store.entries.count == 1)
        #expect(store.entries[0].finalText == "hello world")
        #expect(store.entries[0].bundleIdentifier == "com.a.App")
        // Blank text never records, even when enabled.
        await store.record(finalText: "   ", bundleID: nil)
        #expect(store.entries.count == 1)
    }

    @Test func boundsEnforcedOnWrite() async {
        let (store, _) = makeStore()
        store.setEnabled(true)
        let now = Date()
        for index in 0..<250 {
            await store.record(
                finalText: "entry \(index)",
                bundleID: nil,
                at: now.addingTimeInterval(TimeInterval(index))
            )
        }
        #expect(store.entries.count == HistoryStore.maxEntries)
        // Newest first: the last written entry is on top.
        #expect(store.entries[0].finalText == "entry 249")
    }

    @Test func oldEntriesEvicted() async {
        let (store, _) = makeStore()
        store.setEnabled(true)
        let ancient = Date().addingTimeInterval(TimeInterval(-31 * 24 * 3600))
        await store.record(finalText: "old", bundleID: nil, at: ancient)
        await store.record(finalText: "new", bundleID: nil)
        #expect(store.entries.count == 1)
        #expect(store.entries[0].finalText == "new")
    }

    @Test func longTextTruncated() async {
        let (store, _) = makeStore()
        store.setEnabled(true)
        await store.record(finalText: String(repeating: "x", count: 6000), bundleID: nil)
        #expect(store.entries[0].finalText.count == HistoryEntry.maxTextLength)
    }

    @Test func deleteAndClearAll() async {
        let (store, _) = makeStore()
        store.setEnabled(true)
        await store.record(finalText: "one", bundleID: nil)
        await store.record(finalText: "two", bundleID: nil)
        await store.remove(id: store.entries[0].id)
        #expect(store.entries.count == 1)
        await store.clearAll()
        #expect(store.entries.isEmpty)
    }

    @Test func entryKeysPinned() throws {
        // Adding a stored key is a privacy decision. This test fails the
        // moment a new key appears — audio/partials/clipboard keys can never
        // slip in silently.
        let entry = HistoryEntry(finalText: "hi", bundleIdentifier: "com.a.App")
        let encoded = try JSONEncoder().encode(entry)
        let keys = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(Set(keys.keys) == ["id", "finalText", "createdAt", "bundleIdentifier"])
    }

    @Test func concurrentRecordsStayConsistent() async {
        let (store, _) = makeStore()
        store.setEnabled(true)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    await store.record(finalText: "entry \(index)", bundleID: nil)
                }
            }
        }
        // Actor serialization: all 20 land, newest-first, valid file.
        #expect(store.entries.count == 20)
        let texts = Set(store.entries.map(\.finalText))
        #expect(texts.count == 20)
    }
}
