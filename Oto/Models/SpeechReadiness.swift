//
//  SpeechReadiness.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation
import Speech

/// Readiness of the Apple Speech path. Checked on every `prepare()`; the
/// shortcut path inspects readiness only and fails with a recovery message —
/// it NEVER downloads (START_HERE_PRODUCT.md). Download happens exclusively
/// via `SpeechAssetPreparer` (explicit Settings action).
enum SpeechReadiness: Error, Equatable, Sendable {
    case unsupportedLocale
    case assetsNotPrepared
    case assetsPreparing
    case microphoneDenied
    case ready

    // Explicit: the coordinator actor compares readiness without a
    // MainActor hop (Swift 6, default MainActor isolation).
    nonisolated static func == (lhs: SpeechReadiness, rhs: SpeechReadiness) -> Bool {
        switch (lhs, rhs) {
        case (.unsupportedLocale, .unsupportedLocale),
             (.assetsNotPrepared, .assetsNotPrepared),
             (.assetsPreparing, .assetsPreparing),
             (.microphoneDenied, .microphoneDenied),
             (.ready, .ready):
            return true
        default:
            return false
        }
    }
}

extension SpeechReadiness: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return "This language is unavailable offline."
        case .assetsNotPrepared:
            return "Prepare offline speech in Settings."
        case .assetsPreparing:
            return "Speech assets are still preparing."
        case .microphoneDenied:
            return "Microphone access is needed."
        case .ready:
            return nil
        }
    }
}

/// Pure readiness mapping — unit-tested without hardware or Apple assets.
enum SpeechReadinessMapper: Sendable {
    /// Order is deliberate: microphone first (most actionable), then locale,
    /// then asset state. Pure mapping: `nonisolated` for the background
    /// speech actor (Swift 6, default MainActor isolation).
    nonisolated static func map(
        microphoneGranted: Bool,
        resolvedLocale: Locale?,
        installedLocales: [Locale],
        assetStatus: AssetInventory.Status
    ) -> SpeechReadiness {
        guard microphoneGranted else { return .microphoneDenied }
        guard let resolved = resolvedLocale else { return .unsupportedLocale }
        let identifiers = Set(installedLocales.map { $0.identifier(.bcp47) })
        switch assetStatus {
        case .downloading:
            return .assetsPreparing
        case .installed where identifiers.contains(resolved.identifier(.bcp47)):
            return .ready
        case .installed, .supported, .unsupported:
            return .assetsNotPrepared
        @unknown default:
            return .assetsNotPrepared
        }
    }
}
