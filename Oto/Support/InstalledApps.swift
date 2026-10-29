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
struct InstalledApp: Sendable, Hashable, Identifiable {
    let bundleID: String
    let name: String
    /// Absolute bundle path, used for the app's icon. Empty for a legacy
    /// bundle ID that is no longer installed.
    let path: String

    var id: String { bundleID }
}

@MainActor
enum InstalledApps {
    /// Cached scan. Lazy: Settings only pays for it the first time a scope
    /// picker opens, never at launch.
    static let all: [InstalledApp] = scan()

    /// Human name for a bundle ID, or nil when this Mac has no such app.
    static func name(forBundleID bundleID: String) -> String? {
        all.first { $0.bundleID == bundleID }?.name
    }

    /// One line for a row: names, not IDs. Unknown IDs fall back to
    /// themselves so a stale scope stays visible and removable.
    static func names(for bundleIDs: [String]) -> String {
        bundleIDs
            .map { name(forBundleID: $0) ?? $0 }
            .joined(separator: ", ")
    }

    private static func scan() -> [InstalledApp] {
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

        // Running apps cover anything launched outside the folders above. The
        // activation policy is the line: `.regular` apps own a Dock tile and
        // windows; agents, daemons and widgets do not, and naming one as a
        // scope would only confuse the list.
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  let url = app.bundleURL,
                  let bundle = Bundle(url: url),
                  isUserFacingApp(bundle, path: url.path),
                  seen.insert(bundleID).inserted
            else { continue }
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                path: url.path
            ))
        }

        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apps only: no background agents, daemons, widgets, or app extensions.
    /// Those carry the same icon and a plausible name, which is exactly why
    /// they must never reach the picker.
    private static func isUserFacingApp(_ bundle: Bundle, path: String) -> Bool {
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

    private static func flag(_ info: [String: Any], _ key: String) -> Bool {
        if let value = info[key] as? Bool { return value }
        if let value = info[key] as? NSNumber { return value.boolValue }
        if let value = info[key] as? String {
            return value == "1" || value.lowercased() == "true" || value.lowercased() == "yes"
        }
        return false
    }
}
