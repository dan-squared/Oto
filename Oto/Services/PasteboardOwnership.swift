//
//  PasteboardOwnership.swift
//  Oto
//

import AppKit
import Foundation
import os

/// Pasteboard-file logger: restore failure must never be silent (a failed
/// write after clearContents leaves the clipboard empty — the one case
/// where the prior clipboard is unrecoverable by design).
nonisolated private let log = Logger(subsystem: "app.Oto", category: "pasteboard")

/// Clipboard ownership for insertion (01 §5, 15:121).
///
/// The safety property is ownership, not delay: Oto writes a unique marker,
/// records the change count, and restores the previous snapshot only if the
/// marker and count still match. If the person copied anything meanwhile, we
/// leave their clipboard alone and the transcript stays recoverable.
struct PasteboardReceipt: Equatable, Sendable {
    nonisolated static let markerType = NSPasteboard.PasteboardType("com.oto.session-marker")

    let marker: String
    let changeCount: Int

    nonisolated func stillOwned(by pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == changeCount
            && pasteboard.string(forType: Self.markerType) == marker
    }
}

/// Confirm-before-overwrite for MANUAL clipboard writes (menu recovery
/// Copy, catcher Copy, history Copy, snippet Copy expansion, polish sheet
/// Keep/Original): Oto's insertion path already snapshots + receipts, but
/// these surfaces used to clearContents() blind. Pure over an injected
/// board, so tests use scratch boards and never touch `.general`.
enum ClipboardOverwriteGuard {
    /// True iff the board holds user content Oto didn't place: non-empty
    /// string with no Oto marker. Empty boards and Oto's own placements
    /// write with zero friction. Marker presence ⟺ Oto was the last
    /// writer (any user copy clears all types including the marker).
    nonisolated static func shouldConfirm(board: NSPasteboard) -> Bool {
        guard let current = board.string(forType: .string), !current.isEmpty else { return false }
        return board.string(forType: PasteboardReceipt.markerType) == nil
    }

    /// Marks a manual Oto placement so the next manual write skips the
    /// confirm (Oto-to-Oto overwrites need no friction). The marker is an
    /// inert extra type: insertion receipts pair marker UUIDs they create
    /// themselves, so a manual marker can never read as owned there, and
    /// the next placement overwrites it.
    nonisolated static func markAsOto(_ board: NSPasteboard) {
        board.setString(UUID().uuidString, forType: PasteboardReceipt.markerType)
    }
}

/// Full-fidelity clipboard snapshot: every type of every item, in order.
/// Pattern follows the Yap reference (`PasteboardSnapshot`, MIT) as Oto-owned
/// code. Pure over an injected pasteboard, so tests use a scratch board and
/// never touch `.general`.
enum PasteboardSnapshot {
    nonisolated static func capture(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representation: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representation[type] = data
                }
            }
            return representation
        }
    }

    nonisolated static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = saved.map { representation -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representation {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            if !pasteboard.writeObjects(items) {
                log.error("clipboard restore failed after clearing — clipboard left empty")
            }
        }
    }
}
