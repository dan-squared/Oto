//
//  IssueReporter.swift
//  Oto
//
//  No paid crash service. An uncaught exception writes a small local report
//  (version, reason, symbols) under Application Support/Oto/Crashes. It never
//  records transcripts, target-app contents, or user files. About links to
//  GitHub Issues and names the newest report so the person can choose to
//  attach it.
//

import Foundation
import os

nonisolated enum IssueReporter {
    private static let log = Logger(subsystem: "app.Oto", category: "issues")
    private static let maxReports = 10
    private nonisolated(unsafe) static var previousHandler: (@convention(c) (NSException) -> Void)?

    /// Install once, before any scene or probe work. Chains any prior
    /// handler and runs nonisolated so background-thread NSExceptions never
    /// trap on MainActor isolation checks before writing the report.
    static func install() {
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            IssueReporter.write(exception)
            IssueReporter.previousHandler?(exception)
        }
    }

    static var reportsDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Oto/Crashes", isDirectory: true)
    }

    /// Newest first — About uses this only to name the file, never its text.
    static var latestReportURL: URL? {
        guard let dir = reportsDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        return names
            .filter { $0.hasPrefix("Crash-") && $0.hasSuffix(".txt") }
            .sorted(by: >)
            .first
            .map { dir.appendingPathComponent($0) }
    }

    private static func write(_ exception: NSException) {
        guard let dir = reportsDirectory else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let safeStamp = stamp.replacingOccurrences(of: ":", with: "-")
        let text = [
            "Oto \(version) (\(build))",
            "Time: \(stamp)",
            "Exception: \(exception.name.rawValue)",
            "",
            exception.callStackSymbols.joined(separator: "\n"),
        ].joined(separator: "\n")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Crash-\(safeStamp).txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let existing = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.hasPrefix("Crash-") && $0.hasSuffix(".txt") }
                .sorted(by: >) ?? []
            for stale in existing.dropFirst(maxReports) {
                try? fm.removeItem(at: dir.appendingPathComponent(stale))
            }
            log.error("wrote crash report \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("could not write crash report")
        }
    }
}
