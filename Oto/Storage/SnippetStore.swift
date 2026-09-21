//
//  SnippetStore.swift
//  Oto
//
//  Phase 6A: repeated-text snippets. Manual insertion only (menu /
//  Scratchpad / Settings copy) — there are NO spoken-trigger fields in v1.
//  A phrase like "my email" is ordinary speech; ambient matching could expose
//  private text in the wrong place (09 §3.6). Triggers arrive only with a
//  follow-up exact-match gate + matrix.
//

import Foundation
import os

/// Named reusable text. Scope mirrors the dictionary (nil = global).
/// Deliberately no trigger/activation: manual-only v1.
struct Snippet: Sendable, Hashable, Codable, Identifiable {
    nonisolated static let maxNameLength = 60
    nonisolated static let maxExpansionLength = 2000
    nonisolated static let maxSnippets = 500
    nonisolated static let previewLength = 120

    let id: UUID
    var name: String
    var expansion: String
    var bundleID: String?

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        expansion: String,
        bundleID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.expansion = expansion
        self.bundleID = bundleID
    }

    /// List-row preview: first 120 chars, newlines flattened, "+N more".
    nonisolated func preview() -> String {
        let flat = expansion
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > Self.previewLength else { return flat }
        let head = String(flat.prefix(Self.previewLength)).trimmingCharacters(in: .whitespaces)
        return "\(head)… (+\(flat.count - Self.previewLength) more)"
    }
}

enum SnippetValidationError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case duplicateName
    case emptyExpansion
    case expansionTooLong
    case emptyBundleID
    case storeFull
    case notFound

    nonisolated var errorDescription: String {
        switch self {
        case .emptyName:
            return "Give the snippet a name."
        case .nameTooLong:
            return "Name is too long (max \(Snippet.maxNameLength) characters)."
        case .duplicateName:
            return "A snippet with that name already exists. Pick another name."
        case .emptyExpansion:
            return "Enter the text to insert."
        case .expansionTooLong:
            return "Expansion is too long (max \(Snippet.maxExpansionLength) characters)."
        case .emptyBundleID:
            return "App scope is empty — pick Global or enter the app's bundle ID."
        case .storeFull:
            return "Snippets hold \(Snippet.maxSnippets) entries. Delete one before adding another."
        case .notFound:
            return "This snippet was deleted."
        }
    }
}

@Observable @MainActor
final class SnippetStore {
    static let filename = "snippets.v1.json"

    private(set) var snippets: [Snippet] = []
    private let persistence: LocalPersistence
    private let log = Logger(subsystem: "app.Oto", category: "snippets")

    init(persistence: LocalPersistence) {
        self.persistence = persistence
    }

    func load() async {
        snippets = await VersionedStoreFile.load(Snippet.self, filename: Self.filename, via: persistence)
    }

    private func persist() async {
        do {
            try await VersionedStoreFile.save(snippets, filename: Self.filename, via: persistence)
        } catch {
            log.error("snippet save failed")
        }
    }

    @discardableResult
    func add(name: String, expansion: String, bundleID: String?) async -> Result<Snippet, SnippetValidationError> {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return .failure(.emptyName) }
        guard cleanName.count <= Snippet.maxNameLength else { return .failure(.nameTooLong) }
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyExpansion)
        }
        guard expansion.count <= Snippet.maxExpansionLength else { return .failure(.expansionTooLong) }
        let cleanScope: String?
        if let bundleID {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyBundleID) }
            cleanScope = trimmed
        } else {
            cleanScope = nil
        }
        guard snippets.count < Snippet.maxSnippets else { return .failure(.storeFull) }
        if snippets.contains(where: { $0.name.lowercased() == cleanName.lowercased() }) {
            return .failure(.duplicateName)
        }
        let snippet = Snippet(name: cleanName, expansion: expansion, bundleID: cleanScope)
        snippets.append(snippet)
        await persist()
        return .success(snippet)
    }

    func update(_ snippet: Snippet) async -> Result<Snippet, SnippetValidationError> {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else {
            return .failure(.notFound)
        }
        var fixed = snippet
        fixed.name = fixed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fixed.name.isEmpty else { return .failure(.emptyName) }
        guard fixed.name.count <= Snippet.maxNameLength else { return .failure(.nameTooLong) }
        guard !fixed.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyExpansion)
        }
        guard fixed.expansion.count <= Snippet.maxExpansionLength else { return .failure(.expansionTooLong) }
        if let scope = fixed.bundleID,
           scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptyBundleID)
        }
        if snippets.contains(where: { $0.id != fixed.id && $0.name.lowercased() == fixed.name.lowercased() }) {
            return .failure(.duplicateName)
        }
        snippets[index] = fixed
        await persist()
        return .success(fixed)
    }

    func remove(id: UUID) async {
        snippets.removeAll { $0.id == id }
        await persist()
    }
}
