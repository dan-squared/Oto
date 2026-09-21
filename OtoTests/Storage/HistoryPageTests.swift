//
//  HistoryPageTests.swift
//  OtoTests
//
//  Phase 6A follow-up: pure pagination math — counts, slices, clamps.
//

import Foundation
import Testing
@testable import Oto

struct HistoryPageTests {
    @Test func pageCounts() {
        #expect(HistoryPage.pageCount(total: 0) == 0)
        #expect(HistoryPage.pageCount(total: 1) == 1)
        #expect(HistoryPage.pageCount(total: 10) == 1)
        #expect(HistoryPage.pageCount(total: 11) == 2)
        #expect(HistoryPage.pageCount(total: 100) == 10)
    }

    @Test func slicesAreNewestFirstTens() {
        let items = (0..<25).map { "entry \($0)" }
        #expect(HistoryPage.slice(items: items, page: 1) == Array(items[0..<10]))
        #expect(HistoryPage.slice(items: items, page: 3) == Array(items[20..<25]))
    }

    @Test func outOfRangePagesClamp() {
        let items = (0..<25).map { "entry \($0)" }
        // Page 0 and overflow land on first/last instead of empty.
        #expect(HistoryPage.slice(items: items, page: 0) == Array(items[0..<10]))
        #expect(HistoryPage.slice(items: items, page: 99) == Array(items[20..<25]))
        #expect(HistoryPage.slice(items: [String](), page: 1).isEmpty)
    }

    @Test func clampKeepsSelectionStable() {
        // Held page 3 of 25; deletion shrinks to 10 → page 1, never empty.
        #expect(HistoryPage.clampedPage(3, total: 25) == 3)
        #expect(HistoryPage.clampedPage(3, total: 10) == 1)
        #expect(HistoryPage.clampedPage(5, total: 0) == 1)
    }
}
