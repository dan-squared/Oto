//
//  HistoryPage.swift
//  Oto
//
//  Phase 6A follow-up: pure pagination math for the history list. Page size
//  is a view constant (10); the storage bound lives in HistoryStore.
//  Everything here is value math — headless-tested, no UI, no isolation.
//

import Foundation

/// Newest-first paging over an already-sorted entry array. Pages are
/// 1-based; page 1 is the 10 newest. Out-of-range pages clamp — an
/// out-of-range page can never render an empty list while entries exist.
struct HistoryPage: Sendable {
    nonisolated static let pageSize = 10

    /// Number of pages for a total (0 → 0, 1–10 → 1, 11 → 2, 100 → 10).
    nonisolated static func pageCount(total: Int) -> Int {
        guard total > 0 else { return 0 }
        return (total + pageSize - 1) / pageSize
    }

    /// Keeps a held page valid as the list shrinks (delete/clear).
    nonisolated static func clampedPage(_ page: Int, total: Int) -> Int {
        let count = pageCount(total: total)
        guard count > 0 else { return 1 }
        return min(max(page, 1), count)
    }

    nonisolated static func slice<T: Sendable>(items: [T], page: Int) -> [T] {
        guard !items.isEmpty else { return [] }
        let current = clampedPage(page, total: items.count)
        let start = (current - 1) * pageSize
        let end = min(start + pageSize, items.count)
        guard start < end else { return [] }
        return Array(items[start..<end])
    }

    nonisolated enum PageSlot: Equatable, Sendable {
        case page(Int)
        case ellipsis
    }

    /// Compact window of page buttons (at most 5 numbered slots plus ellipses)
    /// so pagination never overflows the 580 pt Settings detail column.
    nonisolated static func visibleSlots(current: Int, totalPages: Int) -> [PageSlot] {
        guard totalPages > 0 else { return [] }
        if totalPages <= 5 {
            return (1...totalPages).map { .page($0) }
        }
        let clamped = min(max(current, 1), totalPages)
        var slots: [PageSlot] = [.page(1)]
        let windowStart = max(2, min(clamped - 1, totalPages - 3))
        let windowEnd = min(totalPages - 1, max(clamped + 1, 4))
        if windowStart > 2 {
            slots.append(.ellipsis)
        }
        for page in windowStart...windowEnd {
            slots.append(.page(page))
        }
        if windowEnd < totalPages - 1 {
            slots.append(.ellipsis)
        }
        slots.append(.page(totalPages))
        return slots
    }
}

/// Pure, case- and diacritic-insensitive multi-word AND filter over history
/// entries: every whitespace-separated token must match `finalText`, `rawText`,
/// the app's display name, or its bundle identifier.
enum HistoryFilter: Sendable {
    nonisolated static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let tokens = tokenized(query)
        guard !tokens.isEmpty else { return entries }
        var appNameCache: [String: String] = [:]
        return entries.filter { entry in
            matches(entry, tokens: tokens, appNameCache: &appNameCache)
        }
    }

    nonisolated static func matches(_ entry: HistoryEntry, query: String) -> Bool {
        let tokens = tokenized(query)
        guard !tokens.isEmpty else { return true }
        var appNameCache: [String: String] = [:]
        return matches(entry, tokens: tokens, appNameCache: &appNameCache)
    }

    private nonisolated static func tokenized(_ query: String) -> [Substring] {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
    }

    private nonisolated static func matches(
        _ entry: HistoryEntry,
        tokens: [Substring],
        appNameCache: inout [String: String]
    ) -> Bool {
        let nonEmptyBundleID = entry.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = (nonEmptyBundleID?.isEmpty == false) ? nonEmptyBundleID : nil
        return tokens.allSatisfy { token in
            if entry.finalText.localizedStandardContains(token) { return true }
            if let raw = entry.rawText, raw.localizedStandardContains(token) { return true }
            guard let bundleID else { return false }
            if bundleID.localizedStandardContains(token) { return true }
            let displayName: String
            if let cached = appNameCache[bundleID] {
                displayName = cached
            } else {
                let resolved = AppNames.displayName(forBundleID: bundleID)
                appNameCache[bundleID] = resolved
                displayName = resolved
            }
            return displayName.localizedStandardContains(token)
        }
    }
}
