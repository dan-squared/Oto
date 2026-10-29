//
//  SettingsChrome.swift
//  Oto
//
//  The pane's master control lives in the window's top-right corner, the way
//  the reference puts it: a switch where the feature has a real on/off, an
//  add button where the pane's master action is "one more".
//
//  Why it cannot simply be a `.toolbar` inside the pane: panes are hosted by
//  `NSSplitViewItem` view controllers, which are separate SwiftUI roots, and
//  toolbar preferences do not cross that boundary. So the pane publishes its
//  accessory here and `SettingsRoot` — which owns the window's toolbar —
//  renders it. One accessory at a time; the root clears it when the pane
//  changes.
//

import SwiftUI

@MainActor
@Observable
final class SettingsChrome {
    enum Accessory {
        /// A real on/off for the pane's feature.
        case toggle(isOn: Bool, help: String, set: (Bool) -> Void)
        /// The pane's primary action, as a glass button.
        case action(symbol: String, help: String, run: () -> Void)

        /// The toolbar paints one shared glass plate behind an item, sized for
        /// a single 36 pt glyph. A switch is wider and shorter than that
        /// plate, so the plate reads as a stray frame around it (measured
        /// 2026-10-29: plate 37.5 × 35, switch 44.5 × 21.5). The switch opts
        /// out and sits bare on the titlebar; a lone glyph keeps its circle.
        var usesSharedBackground: Bool {
            switch self {
            case .toggle: false
            case .action: true
            }
        }
    }

    var accessory: Accessory?

    /// Called from a pane's appear/refresh path. The closure is captured from
    /// the live view state each time, so a switch always writes through the
    /// same path the pane's own controls do (confirmations included).
    func publish(_ accessory: Accessory?) {
        self.accessory = accessory
    }
}
