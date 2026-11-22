//
//  AppNames.swift
//  Oto
//
//  Phase 12: bundle ID → human name in exactly one place. Retry confirm,
//  menu feedback, and History rows all name the same app the same way:
//  a running app's localized name, falling back to the raw ID (never
//  "Unknown", never empty). Pure over NSWorkspace (headless-safe:
//  unknown IDs fall back without a window).
//

import AppKit
import Foundation

enum AppNames {
    /// Localized name of a running app, else the raw bundle ID, else
    /// "Unknown app" when there is nothing to show.
    nonisolated static func displayName(forBundleID bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "Unknown app" }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty
        {
            return name
        }
        return bundleID
    }

    /// Retry mismatch gate: confirm only when both sides are known and
    /// differ. Unknown on either side posts without interrogating (the
    /// person pressed Retry looking at their target — they are the check).
    nonisolated static func shouldConfirmRetry(frontmost: String?, expected: String?) -> Bool {
        guard let frontmost, !frontmost.isEmpty,
              let expected, !expected.isEmpty
        else { return false }
        return frontmost != expected
    }
}
