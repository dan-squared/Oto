//
//  PasteboardOwnership.swift
//  Oto
//

import AppKit
import Foundation

/// Clipboard ownership for insertion (01 §5, 15:121).
///
/// The safety property is ownership, not delay: Oto writes a unique marker,
/// records the change count, and restores the previous snapshot only if the
/// marker and count still match. If the person copied anything meanwhile, we
/// leave their clipboard alone and the transcript stays recoverable.
struct PasteboardReceipt: Equatable, Sendable {
    static let markerType = NSPasteboard.PasteboardType("com.oto.session-marker")

    let marker: String
    let changeCount: Int

    func stillOwned(by pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == changeCount
            && pasteboard.string(forType: Self.markerType) == marker
    }
}

/// Full-fidelity clipboard snapshot: every type of every item, in order.
/// Pattern follows the Yap reference (`PasteboardSnapshot`, MIT) as Oto-owned
/// code. Pure over an injected pasteboard, so tests use a scratch board and
/// never touch `.general`.
enum PasteboardSnapshot {
    static func capture(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
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

    static func restore(
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
            pasteboard.writeObjects(items)
        }
    }
}
