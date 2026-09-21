//
//  SpeechAssetPreparer.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation
import Speech
import os

/// Explicit offline-speech preparation for Settings use. This is the ONLY caller of `downloadAndInstall()`
/// in the codebase — enforce with the `downloadAndInstall` grep gate.
/// The shortcut/dictation path (`AppleSpeechService.prepare()`) inspects
/// readiness only and never downloads.
struct SpeechAssetPreparer: Sendable {
    private let log = Logger(subsystem: "app.Oto", category: "assets")
    private let permissions = PermissionsManager()

    /// Readiness inspection for the Settings status row. Mirrors the
    /// inspection half of `AppleSpeechService.prepare()` (same mapper, same
    /// order) without building a session and WITHOUT prompting: the mic
    /// check reads current permission only — a status row must never
    /// trigger a system prompt. No download (grep gate holds). The live
    /// Apple calls make this device-verified; the mapping itself is
    /// unit-tested via `SpeechReadinessMapper`.
    func status(locale: Locale = .current) async -> (resolved: Locale?, readiness: SpeechReadiness) {
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = SpeechLocaleMatching.bestMatch(for: locale, in: supported) else {
            return (nil, .unsupportedLocale)
        }
        let probe = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let installed = await SpeechTranscriber.installedLocales
        let assetStatus = await AssetInventory.status(forModules: [probe])
        let readiness = SpeechReadinessMapper.map(
            microphoneGranted: permissions.microphoneStatus() == .granted,
            resolvedLocale: resolved,
            installedLocales: installed,
            assetStatus: assetStatus
        )
        return (resolved, readiness)
    }

    /// Prepare the system locale. Returns a human-readable summary for the
    /// Settings prepare row.
    func prepareDefault() async -> String {
        await prepare(locale: .current)
    }

    func prepare(locale: Locale) async -> String {
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = SpeechLocaleMatching.bestMatch(for: locale, in: supported) else {
            return "Unsupported language — unavailable offline."
        }
        let tag = resolved.identifier(.bcp47)

        let probe = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let installed = Set((await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) })
        if installed.contains(tag) {
            let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
            if !reserved.contains(tag) {
                do { _ = try await AssetInventory.reserve(locale: resolved) } catch {
                    log.error("reserve failed after installed check")
                    return "Installed but could not be reserved: \(error.localizedDescription)"
                }
            }
            log.info("already prepared")
            return "Already prepared (\(tag))."
        }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
            _ = try await AssetInventory.reserve(locale: resolved)
            log.info("prepared language assets")
            return "Prepared (\(tag))."
        } catch {
            log.error("preparation failed")
            return "Preparation failed: \(error.localizedDescription)"
        }
    }
}
