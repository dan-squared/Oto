//
//  CaretOpaqueApps.swift
//  Oto
//
//  v7 delivery proof needs a document-true insertion point: a caret range
//  that includes the caret and a character count that is fresh. Terminal
//  emulators draw their own text grid and publish neither. Ghostty 1.4.0,
//  for example, returns the *selection* range from
//  `accessibilitySelectedTextRange()` (SurfaceView_AppKit.swift:2374) and
//  reads `AXNumberOfCharacters` from a 500 ms screen cache (:245, :254,
//  :2395) — longer than Oto's 300 ms delivery budget. The sample therefore
//  never changes and v7 would report `.notLanded` over a paste the terminal
//  already took.
//
//  These apps are classified as caret-opaque: the post is still sent once,
//  but delivery is `.unverifiable` (the pre-v7 contract — assume it landed).
//  Exact bundle-ID matches only; every row needs evidence, never a guess.
//

import Foundation

enum CaretOpaqueApps {
    /// Terminal emulators and terminal hosts whose AX caret is not a
    /// document-true insertion point.
    nonisolated static let bundleIDs: Set<String> = [
        // Proven from the installed app and its source (see file header).
        "com.mitchellh.ghostty",
        // Apple's terminal: same text-grid class; probe before changing rows.
        "com.apple.terminal",
        // Rex is a multiplexer that hosts a terminal surface in its panes.
        // Installed on this Mac as "Rex Beta", bundle ID verified from
        // Contents/Info.plist (team AG92C3PT77).
        "com.superlogical.rex",
    ]

    /// Nil, empty and unknown bundle IDs stay verifiable: only a known
    /// terminal loses the post-paste proof.
    nonisolated static func isOpaque(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        return self.bundleIDs.contains(key)
    }
}
