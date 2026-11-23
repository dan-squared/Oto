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
nonisolated struct SpeechAssetPreparer: Sendable {
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
        let micGranted: Bool
        if case .granted = permissions.microphoneStatus() {
            micGranted = true
        } else {
            micGranted = false
        }
        guard SpeechTranscriber.isAvailable else {
            return (nil, micGranted ? .unsupportedLocale : .microphoneDenied)
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = SpeechLocaleMatching.bestMatch(for: locale, in: supported) else {
            return (nil, micGranted ? .unsupportedLocale : .microphoneDenied)
        }
        let probe = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let installed = await SpeechTranscriber.installedLocales
        let assetStatus = await AssetInventory.status(forModules: [probe])
        let readiness = SpeechReadinessMapper.map(
            microphoneGranted: micGranted,
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
        guard SpeechTranscriber.isAvailable else {
            return "Unsupported language — unavailable offline."
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = SpeechLocaleMatching.bestMatch(for: locale, in: supported) else {
            return "Unsupported language — unavailable offline."
        }
        let tag = resolved.identifier(.bcp47)

        let probe = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let installed = Set((await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) })
        if installed.contains(tag) {
            do {
                try await reserveLocale(resolved)
            } catch {
                log.error("reserve failed after installed check")
                return "Installed but could not be reserved: \(error.localizedDescription)"
            }
            log.info("already prepared")
            return "Already prepared (\(tag))."
        }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
            try await reserveLocale(resolved)
            log.info("prepared language assets")
            return "Prepared (\(tag))."
        } catch {
            log.error("preparation failed")
            return "Preparation failed: \(error.localizedDescription)"
        }
    }

    /// Reserves `locale` in `AssetInventory`, evicting excess previously
    /// reserved locales if `AssetInventory.maximumReservedLocales` is reached.
    private func reserveLocale(_ locale: Locale) async throws {
        let tag = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == tag }) {
            return
        }
        let maxReserved = AssetInventory.maximumReservedLocales
        if maxReserved > 0, reserved.count >= maxReserved {
            let excess = reserved.count - maxReserved + 1
            for candidate in reserved.prefix(excess) {
                _ = await AssetInventory.release(reservedLocale: candidate)
            }
        }
        _ = try await AssetInventory.reserve(locale: locale)
    }
}
