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
    /// Terminal emulators, terminal hosts, and custom-rendered editors whose
    /// AX caret is not a document-true insertion point.
    nonisolated static let bundleIDs: Set<String> = [
        // Proven from the installed app and its source (see file header).
        "com.mitchellh.ghostty",
        // Apple's terminal: same text-grid class; probe before changing rows.
        "com.apple.terminal",
        // Rex is a multiplexer that hosts a terminal surface in its panes.
        // Installed on this Mac as "Rex Beta", bundle ID verified from
        // Contents/Info.plist (team AG92C3PT77).
        "com.superlogical.rex",
        // Terminal emulators & GPU/custom-surface editors that render text
        // grids without a fresh document-true AXSelectedTextRange / count.
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.zed.zed",
        "org.gnu.emacs",
    ]

    /// Bundle-ID prefixes for multi-product suites (JetBrains IDEs) whose
    /// custom editor surfaces do not publish a verifiable AX caret.
    nonisolated static let bundleIDPrefixes: [String] = [
        "com.jetbrains.",
    ]

    /// Nil, empty and unknown bundle IDs stay verifiable: only a known
    /// caret-opaque app loses the post-paste proof.
    nonisolated static func isOpaque(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        if self.bundleIDs.contains(key) { return true }
        return self.bundleIDPrefixes.contains { key.hasPrefix($0) }
    }
}
