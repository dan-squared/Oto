//
//  InstalledApps.swift
//  Oto
//
//  One index of the apps on this Mac, so Settings can offer names instead of
//  asking people to type reverse-DNS bundle IDs. Scanned once (lazily) from
//  the standard application folders, plus whatever is running right now —
//  an app launched from Downloads is still the app somebody means.
//

import AppKit
import Foundation

/// One app that can be chosen as a scope.
nonisolated struct InstalledApp: Sendable, Hashable, Identifiable {
    let bundleID: String
    let name: String
    /// Absolute bundle path, used for the app's icon. Empty for a legacy
    /// bundle ID that is no longer installed.
    let path: String

    var id: String { bundleID }
}

@MainActor
enum InstalledApps {
    /// Cached scan, populated asynchronously off `@MainActor` by `load()`.
    private(set) static var cached: [InstalledApp] = []
    private static var hasScanned = false
    private static var inFlightScan: Task<[InstalledApp], Never>?
    private static var iconCache: [String: NSImage] = [:]

    /// Async refreshable discovery: runs filesystem scanning off `@MainActor`
    /// so opening the scope picker never stalls the UI thread.
    static func load(forceRefresh: Bool = false) async -> [InstalledApp] {
        if hasScanned, !forceRefresh {
            return cached
        }
        if let existing = inFlightScan {
            return await existing.value
        }
        let running = runningRegularApps()
        let task = Task.detached(priority: .utility) {
            Self.scanFilesystem(runningApps: running)
        }
        inFlightScan = task
        let result = await task.value
        cached = result
        hasScanned = true
        inFlightScan = nil
        return result
    }

    /// Cached icon lookup by bundle path so scrolling `LazyVStack` never
    /// repeatedly queries LaunchServices icon services on redraws.
    static func icon(forPath path: String) -> NSImage {
        if let existing = iconCache[path] {
            return existing
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        if iconCache.count >= 256 {
            iconCache.removeAll(keepingCapacity: true)
        }
        iconCache[path] = image
        return image
    }

    /// Human name for a bundle ID, or nil when this Mac has no such app.
    /// O(1) via LaunchServices (`AppNames.displayName`) after checking the
    /// in-memory cache — never blocks `@MainActor` with a `/Applications` scan.
    static func name(forBundleID bundleID: String) -> String? {
        if let hit = cached.first(where: { $0.bundleID == bundleID }) {
            return hit.name
        }
        let resolved = AppNames.displayName(forBundleID: bundleID)
        return resolved == bundleID ? nil : resolved
    }

    /// One line for a row: names, not IDs. Unknown IDs fall back to
    /// themselves so a stale scope stays visible and removable.
    static func names(for bundleIDs: [String]) -> String {
        bundleIDs
            .map { name(forBundleID: $0) ?? $0 }
            .joined(separator: ", ")
    }

    private static func runningRegularApps() -> [InstalledApp] {
        var result: [InstalledApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  let url = app.bundleURL,
                  let bundle = Bundle(url: url),
                  isUserFacingApp(bundle, path: url.path)
            else { continue }
            result.append(InstalledApp(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                path: url.path
            ))
        }
        return result
    }

    nonisolated private static func scanFilesystem(runningApps: [InstalledApp]) -> [InstalledApp] {
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                guard let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty,
                      isUserFacingApp(bundle, path: path),
                      seen.insert(bundleID).inserted
                else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? (entry as NSString).deletingPathExtension
                apps.append(InstalledApp(bundleID: bundleID, name: name, path: path))
            }
        }

        // Running apps cover anything launched outside the folders above.
        for app in runningApps where seen.insert(app.bundleID).inserted {
            apps.append(app)
        }

        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apps only: no background agents, daemons, widgets, or app extensions.
    /// Those carry the same icon and a plausible name, which is exactly why
    /// they must never reach the picker.
    nonisolated private static func isUserFacingApp(_ bundle: Bundle, path: String) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        guard (info["CFBundlePackageType"] as? String) == "APPL" else { return false }
        // Extensions, widget providers and Quick Look plugins.
        if info["NSExtension"] != nil { return false }
        // Menu-bar-only and headless helpers.
        if flag(info, "LSUIElement") || flag(info, "LSBackgroundOnly") { return false }
        // Never offer a helper nested inside another app's bundle.
        if path.contains(".app/Contents/") { return false }
        return true
    }

    nonisolated private static func flag(_ info: [String: Any], _ key: String) -> Bool {
        if let value = info[key] as? Bool { return value }
        if let value = info[key] as? NSNumber { return value.boolValue }
        if let value = info[key] as? String {
            return value == "1" || value.lowercased() == "true" || value.lowercased() == "yes"
        }
        return false
    }
}
