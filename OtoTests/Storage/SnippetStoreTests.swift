//
//  SnippetStoreTests.swift
//  OtoTests
//
//  Phase 6A: snippet CRUD, validation, preview truncation, and the
//  manual-only guarantee (no trigger key in v1 JSON, pipeline ignores
//  snippets by construction).
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct SnippetStoreTests {
    private func makeStore() -> SnippetStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SnippetStore(persistence: LocalPersistence(directory: dir))
    }

    @Test func crud() async {
        let store = makeStore()
        await store.load()
        #expect(store.snippets.isEmpty)
        let added = await store.add(name: "Addr", expansion: "1 Main St", bundleID: nil)
        guard case .success(let snippet) = added else {
            Issue.record("add must succeed"); return
        }
        #expect(store.snippets.count == 1)
        var edited = snippet
        edited.expansion = "2 Main St"
        let updated = await store.update(edited)
        guard case .success = updated else {
            Issue.record("update must succeed"); return
        }
        #expect(store.snippets[0].expansion == "2 Main St")
        await store.remove(id: snippet.id)
        #expect(store.snippets.isEmpty)
    }

    @Test func validation() async {
        let store = makeStore()
        if case .failure(let error) = await store.add(name: "  ", expansion: "x", bundleID: nil) {
            #expect(error == .emptyName)
        } else { Issue.record("expected emptyName") }
        if case .failure(let error) = await store.add(name: "n", expansion: "  ", bundleID: nil) {
            #expect(error == .emptyExpansion)
        } else { Issue.record("expected emptyExpansion") }
        _ = await store.add(name: "Addr", expansion: "x", bundleID: nil)
        if case .failure(let error) = await store.add(name: "addr", expansion: "y", bundleID: nil) {
            #expect(error == .duplicateName)
        } else { Issue.record("expected duplicateName (case-insensitive)") }
        if case .failure(let error) = await store.add(name: "n2", expansion: "x", bundleID: "  ") {
            #expect(error == .emptyBundleID)
        } else { Issue.record("expected emptyBundleID") }
    }

    @Test func previewTruncates() {
        let short = Snippet(name: "s", expansion: "hello")
        #expect(short.preview() == "hello")
        let long = Snippet(name: "l", expansion: String(repeating: "w ", count: 100))
        let preview = long.preview()
        #expect(preview.count <= Snippet.previewLength + 20)
        #expect(preview.hasSuffix("more)"))
    }

    @Test func v1SchemaHasNoTriggerKey() async throws {
        let store = makeStore()
        // Scoped snippet: all four v1 keys present, trigger absent by bytes.
        _ = await store.add(name: "Addr", expansion: "1 Main St", bundleID: "com.a.App")
        let encoded = try JSONEncoder().encode(store.snippets[0])
        let keys = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(Set(keys.keys) == ["id", "name", "expansion", "bundleID"])
        // Unscoped snippet: nil optionals use encodeIfPresent (key omitted,
        // still decodes to nil) — still no trigger key.
        _ = await store.add(name: "Sig", expansion: "bye", bundleID: nil)
        let encoded2 = try JSONEncoder().encode(store.snippets[1])
        let keys2 = try JSONSerialization.jsonObject(with: encoded2) as! [String: Any]
        #expect(Set(keys2.keys) == ["id", "name", "expansion"])
    }
}
