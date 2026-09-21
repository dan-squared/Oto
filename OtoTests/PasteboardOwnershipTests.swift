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
}

struct InsertionDecisionTests {
    @Test func untrustedBeatsSecureInput() {
        #expect(InsertionDecision.next(isTrusted: false, secureInput: true, holder: "Safari")
            == .refuseUntrusted)
    }

    @Test func secureInputRefusesWithHolder() {
        #expect(InsertionDecision.next(isTrusted: true, secureInput: true, holder: "Terminal")
            == .refuseSecureInput(holder: "Terminal"))
    }

    @Test func clearPathProceeds() {
        #expect(InsertionDecision.next(isTrusted: true, secureInput: false, holder: nil)
            == .proceed)
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
