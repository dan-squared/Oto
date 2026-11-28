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

    @Test func visibleSlotsKeepTenPagesCompact() {
        #expect(HistoryPage.visibleSlots(current: 1, totalPages: 3) == [.page(1), .page(2), .page(3)])
        #expect(
            HistoryPage.visibleSlots(current: 1, totalPages: 10)
                == [.page(1), .page(2), .page(3), .page(4), .ellipsis, .page(10)]
        )
        #expect(
            HistoryPage.visibleSlots(current: 5, totalPages: 10)
                == [.page(1), .ellipsis, .page(4), .page(5), .page(6), .ellipsis, .page(10)]
        )
        #expect(
            HistoryPage.visibleSlots(current: 10, totalPages: 10)
                == [.page(1), .ellipsis, .page(7), .page(8), .page(9), .page(10)]
        )
    }

    // MARK: - HistoryFilter

    private func makeEntry(
        finalText: String,
        rawText: String? = nil,
        wasCleaned: Bool = false,
        bundleID: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            finalText: finalText,
            bundleIdentifier: bundleID,
            rawText: rawText,
            wasCleaned: wasCleaned
        )
    }

    @Test func filterEmptyOrWhitespaceReturnsAllEntries() {
        let entries = [
            makeEntry(finalText: "First dictation", bundleID: "com.apple.Notes"),
            makeEntry(finalText: "Second dictation", bundleID: nil),
        ]
        #expect(HistoryFilter.filter(entries, query: "") == entries)
        #expect(HistoryFilter.filter(entries, query: "   \t\n  ") == entries)
        #expect(HistoryFilter.matches(entries[0], query: ""))
        #expect(HistoryFilter.matches(entries[1], query: "   "))
    }

    @Test func filterSingleWordCaseAndDiacriticInsensitiveInFinalText() {
        let cafe = makeEntry(finalText: "Meet me at the café at noon")
        let other = makeEntry(finalText: "Buy milk on the way home")
        let entries = [cafe, other]

        #expect(HistoryFilter.filter(entries, query: "CAFE") == [cafe])
        #expect(HistoryFilter.filter(entries, query: "café") == [cafe])
        #expect(HistoryFilter.filter(entries, query: "noon") == [cafe])
        #expect(HistoryFilter.matches(cafe, query: "CaFe"))
        #expect(!HistoryFilter.matches(other, query: "cafe"))
    }

    @Test func filterMultiWordAndSemanticsAcrossTextAndAppName() {
        let mailInvoice = makeEntry(finalText: "Send the invoice tomorrow", bundleID: "com.apple.mail")
        let notesInvoice = makeEntry(finalText: "Send the invoice tomorrow", bundleID: "com.apple.Notes")
        let mailLunch = makeEntry(finalText: "Lunch plans for Friday", bundleID: "com.apple.mail")
        let entries = [mailInvoice, notesInvoice, mailLunch]

        // Words in any order across finalText and app name must all match.
        #expect(HistoryFilter.filter(entries, query: "mail invoice") == [mailInvoice])
        #expect(HistoryFilter.filter(entries, query: "tomorrow mail") == [mailInvoice])
        #expect(HistoryFilter.filter(entries, query: "tomorrow invoice") == [mailInvoice, notesInvoice])
        #expect(HistoryFilter.filter(entries, query: "mail friday") == [mailLunch])
    }

    @Test func filterMatchesRawTextForCleanedEntries() {
        let cleaned = makeEntry(
            finalText: "Let's schedule the meeting.",
            rawText: "um let us pencil in the meeting",
            wasCleaned: true,
            bundleID: "com.apple.Notes"
        )
        let plain = makeEntry(finalText: "No markers needed", rawText: nil, bundleID: "com.apple.Notes")

        #expect(HistoryFilter.filter([cleaned, plain], query: "pencil") == [cleaned])
        #expect(HistoryFilter.filter([cleaned, plain], query: "schedule") == [cleaned])
        #expect(HistoryFilter.matches(cleaned, query: "pencil meeting"))
    }

    @Test func filterMatchesAppDisplayNameAndBundleIdentifier() {
        let mail = makeEntry(finalText: "Draft reply", bundleID: "com.apple.mail")
        let finder = makeEntry(finalText: "Rename folder", bundleID: "com.apple.finder")
        let custom = makeEntry(finalText: "Custom note", bundleID: "com.example.CustomEditor")
        let unknown = makeEntry(finalText: "Plain note", bundleID: nil)
        let entries = [mail, finder, custom, unknown]

        #expect(HistoryFilter.filter(entries, query: "Mail") == [mail])
        #expect(HistoryFilter.filter(entries, query: "com.apple.mail") == [mail])
        #expect(HistoryFilter.filter(entries, query: "Finder") == [finder])
        #expect(HistoryFilter.filter(entries, query: "CustomEditor") == [custom])
        // nil or empty bundleIdentifier should not fabricate "Unknown app" as a search target.
        let emptyBundle = makeEntry(finalText: "Another note", bundleID: "   ")
        #expect(HistoryFilter.filter([unknown, emptyBundle], query: "Unknown").isEmpty)
    }

    @Test func filterNonMatchingQueryReturnsEmpty() {
        let entries = [
            makeEntry(finalText: "Quick brown fox", rawText: "quick brown fox", bundleID: "com.apple.TextEdit"),
        ]
        #expect(HistoryFilter.filter(entries, query: "zebra").isEmpty)
        #expect(HistoryFilter.filter(entries, query: "fox zebra").isEmpty)
        #expect(!HistoryFilter.matches(entries[0], query: "zebra"))
    }
}
