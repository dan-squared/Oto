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

/// Manual clipboard writes (catcher Copy, history Copy, snippet Copy
/// expansion). Copy is an explicit command, so it writes straight through —
/// the "Replace clipboard contents?" confirm was removed 2026-10-31 by
/// request. Oto's insertion path never uses this: it snapshots and restores
/// with receipts (below), so a dictation can still leave the prior clipboard
/// intact. Pure over an injected board, so tests use scratch boards and
/// never touch `.general`.
enum ClipboardWrite {
    nonisolated static func text(_ text: String, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// Legacy name for the polish tests' injectable board (the manual clean-up
/// sheet that coined it is gone; the primitive is `ClipboardWrite`).
nonisolated func placePolishedOnClipboard(_ text: String, board: NSPasteboard = .general) {
    ClipboardWrite.text(text, to: board)
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
