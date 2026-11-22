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
}
