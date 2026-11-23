//
//  PasteboardOwnershipTests.swift
//  OtoTests
//
//  Phase 4: clipboard ownership without touching the real clipboard.
//  Every case uses a scratch pasteboard; `.general` never appears here.
//

import AppKit
import Foundation
import Testing
@testable import Oto

private func scratchBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("oto-test-\(UUID().uuidString)"))
}

struct PasteboardOwnershipTests {
    @Test func ownedWritePassesReceipt() {
        let board = scratchBoard()
        board.clearContents()
        board.setString("hello", forType: .string)
        board.setString("m1", forType: PasteboardReceipt.markerType)
        let receipt = PasteboardReceipt(marker: "m1", changeCount: board.changeCount)
        #expect(receipt.stillOwned(by: board))
    }

    @Test func userCopyInBetweenVoidsReceipt() {
        let board = scratchBoard()
        board.clearContents()
        board.setString("oto text", forType: .string)
        board.setString("m1", forType: PasteboardReceipt.markerType)
        let receipt = PasteboardReceipt(marker: "m1", changeCount: board.changeCount)
        // The person copies something during the restore window.
        board.clearContents()
        board.setString("their copy", forType: .string)
        #expect(!receipt.stillOwned(by: board))
    }

    @Test func foreignMarkerVoidsReceipt() {
        let board = scratchBoard()
        board.clearContents()
        board.setString("x", forType: .string)
        board.setString("other", forType: PasteboardReceipt.markerType)
        let receipt = PasteboardReceipt(marker: "m1", changeCount: board.changeCount)
        #expect(!receipt.stillOwned(by: board))
    }

    @Test func snapshotRoundTripsEveryType() {
        let board = scratchBoard()
        board.clearContents()
        board.setString("plain", forType: .string)
        board.setString("<b>rtf?</b>", forType: .html)
        let saved = PasteboardSnapshot.capture(board)
        #expect(!saved.isEmpty)
        board.clearContents()
        board.setString("overwrite", forType: .string)
        PasteboardSnapshot.restore(saved, to: board)
        #expect(board.string(forType: .string) == "plain")
        #expect(board.string(forType: .html) == "<b>rtf?</b>")
    }

    @Test func restoreOfEmptySnapshotClears() {
        let board = scratchBoard()
        board.clearContents()
        board.setString("stale", forType: .string)
        PasteboardSnapshot.restore([], to: board)
        #expect(board.string(forType: .string) == nil)
    }

    @Test func restoreTagsTransientType() {
        let board = scratchBoard()
        board.clearContents()
        board.setString("hello", forType: .string)
        let saved = PasteboardSnapshot.capture(board)
        board.clearContents()
        PasteboardSnapshot.restore(saved, to: board)
        #expect(board.string(forType: .string) == "hello")
        #expect(board.data(forType: PasteboardReceipt.transientType) == Data())
    }

    @Test func captureSkipsPromisedFileTypesAndEmptyItems() {
        let board = scratchBoard()
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("file:///tmp/x".utf8), forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        item.setData(Data("public.data".utf8), forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
        board.writeObjects([item])
        let saved = PasteboardSnapshot.capture(board)
        #expect(saved.isEmpty)
    }

    @Test func captureEnforcesTotalByteBudget() {
        let board = scratchBoard()
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(repeating: 0x41, count: 64), forType: .string)
        item.setData(Data(repeating: 0x42, count: 1024), forType: .tiff)
        board.writeObjects([item])
        let saved = PasteboardSnapshot.capture(board, maxTotalBytes: 256)
        #expect(saved.count == 1)
        #expect(saved[0][.string] != nil)
        #expect(saved[0][.tiff] == nil)
    }

    @Test func shouldPreserveFlavorSkipsSystemTranslatedWhenAuthoritativePresent() {
        let translated = PasteboardSnapshot.systemTranslatedFlag
        #expect(PasteboardSnapshot.shouldPreserveFlavor(flags: [], hasAuthoritativeFlavor: true))
        #expect(!PasteboardSnapshot.shouldPreserveFlavor(flags: translated, hasAuthoritativeFlavor: true))
        #expect(PasteboardSnapshot.shouldPreserveFlavor(flags: translated, hasAuthoritativeFlavor: false))
    }
}

struct InsertionDecisionTests {
    @Test func untrustedRefuses() {
        #expect(InsertionDecision.next(isTrusted: false) == .refuseUntrusted)
    }

    @Test func postingBlockedRefuses() {
        // Accessibility granted, synthetic posting still denied: distinct
        // cause, distinct words, never a claimed insert.
        #expect(InsertionDecision.next(isTrusted: true, postingAuthorized: false)
            == .refusePostingBlocked)
        #expect(InsertionDecision.next(isTrusted: false, postingAuthorized: false)
            == .refuseUntrusted)
    }

    @Test func clearPathProceeds() {
        #expect(InsertionDecision.next(isTrusted: true) == .proceed)
    }

    @Test func restoreGuardNeedsBoth() {
        #expect(InsertionDecision.shouldRestore(
            wroteChangeCount: 7, wroteMarker: "m",
            currentChangeCount: 7, currentMarker: "m"))
        #expect(!InsertionDecision.shouldRestore(
            wroteChangeCount: 7, wroteMarker: "m",
            currentChangeCount: 8, currentMarker: "m"))
        #expect(!InsertionDecision.shouldRestore(
            wroteChangeCount: 7, wroteMarker: "m",
            currentChangeCount: 7, currentMarker: "other"))
        #expect(!InsertionDecision.shouldRestore(
            wroteChangeCount: 7, wroteMarker: "m",
            currentChangeCount: 7, currentMarker: nil))
    }
}

struct ClipboardWriteTests {
    private func scratchBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("oto-write-\(UUID().uuidString)"))
    }

    @Test func writesTextToAnEmptyBoard() {
        let board = scratchBoard()
        ClipboardWrite.text("oto words", to: board)
        #expect(board.string(forType: .string) == "oto words")
    }

    @Test func replacesForeignContentWithoutAsking() {
        // Copy is an explicit command: the old "Replace clipboard contents?"
        // confirm is gone (2026-10-31), so a foreign board is overwritten.
        let board = scratchBoard()
        ClipboardWrite.text("hunter2", to: board)
        ClipboardWrite.text("oto words", to: board)
        #expect(board.string(forType: .string) == "oto words")
    }

    @Test func legacyPolishWriterUsesTheSamePrimitive() {
        let board = scratchBoard()
        placePolishedOnClipboard("cleaned text", board: board)
        #expect(board.string(forType: .string) == "cleaned text")
    }
}
