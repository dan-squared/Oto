//
//  CleanSlate.swift
//  Oto
//
//  Dev clean slate: the `-OtoCleanSlate` launch argument wipes ALL
//  Oto-associated data and runs clean — the UserDefaults domain (shortcuts,
//  transforms, cleanup/intelligence, history toggle, dock, modal, onboarding
//  flags) plus the Application Support `Oto/` directory (dictionary,
//  snippets, history, backups). Explicit opt-in only (launch argument):
//  never automatic, never a corruption response (corrupt files move aside,
//  they are never deleted). Runs FIRST in OtoApp.init — before the sandbox
//  migration (which would otherwise copy cleared data back) and store loads
//  — so the launch proceeds exactly like a first install.
//

import Foundation
import os

/// Where Oto data lives (single source for the wipe + this doc):
/// - prefs: `~/Library/Preferences/app.Oto.plist` (every `app.Oto.*` key)
/// - files: `~/Library/Application Support/Oto/` (`history.v1.json`,
///   dictionary/snippet stores, `Backups/`)
/// - NOT wiped: Login Item registration (system-level, re-asserted by the
///   app), TCC permissions (system-owned), the clipboard.
enum CleanSlate {
    nonisolated static let launchArgument = "-OtoCleanSlate"
    nonisolated static let bundleDomain = "app.Oto"

    private nonisolated static let log = Logger(subsystem: "app.Oto", category: "cleanslate")

    /// Pure arg check (unit-tested).
    nonisolated static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    /// Wipes the domain + support dir. Best-effort per store (failures log
    /// and continue — a half-wipe still beats stale state). Returns true
    /// when invoked (so callers can skip follow-up migrations), regardless
    /// of per-store outcomes.
    @discardableResult
    nonisolated static func wipeIfRequested(
        arguments: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard,
        supportDir: URL? = nil
    ) -> Bool {
        guard isRequested(arguments: arguments) else { return false }
        wipe(defaults: defaults, supportDir: supportDir)
        return true
    }

    /// Unconditional wipe (wipeIfRequested's worker — tests call this with
    /// an ephemeral suite + temp dir, never production state).
    nonisolated static func wipe(
        defaults: UserDefaults = .standard,
        domain: String = bundleDomain,
        supportDir: URL? = nil
    ) {
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        let dir: URL?
        if let supportDir {
            dir = supportDir
        } else {
            dir = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false
            ).appendingPathComponent(LocalPersistence.appDirectoryName, isDirectory: true)
        }
        if let dir {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                // Missing dir is the common clean case — log only real
                // failures (removeItem throws the same for both; check).
                if FileManager.default.fileExists(atPath: dir.path) {
                    Self.log.error("clean slate: support dir removal failed")
                }
            }
        }
        Self.log.info("clean slate: wiped domain \(bundleDomain, privacy: .public)")
    }
}
