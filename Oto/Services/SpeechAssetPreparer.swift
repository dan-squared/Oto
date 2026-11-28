//
//  SpeechAssetPreparer.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation
import Network
import Speech
import os

/// Snapshot of the current network path for speech asset downloads.
nonisolated enum NetworkPathCondition: Equatable, Sendable {
    case online
    case constrained
    case offline
}

/// Outcome of explicit offline-speech asset preparation.
nonisolated enum PrepareOutcome: Equatable, Sendable {
    case prepared(String)
    case alreadyPrepared(String)
    case cancelled
    case failed(String)

    var summary: String {
        switch self {
        case .prepared(let tag):
            "Prepared (\(tag))."
        case .alreadyPrepared(let tag):
            "Already prepared (\(tag))."
        case .cancelled:
            "Preparation cancelled."
        case .failed(let message):
            message
        }
    }
}

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
    func status(locale: Locale = SpeechLocalePreference.effectiveLocale()) async -> (resolved: Locale?, readiness: SpeechReadiness) {
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

    /// Prepare the effective dictation locale (selected preference or system).
    /// Returns a human-readable summary for the Settings prepare row.
    func prepareDefault(
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async -> String {
        await prepare(locale: SpeechLocalePreference.effectiveLocale(), onProgress: onProgress)
    }

    /// Prepare the effective dictation locale and return a typed outcome so
    /// callers can distinguish user cancellation from failure.
    func prepareDefaultWithOutcome(
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async -> PrepareOutcome {
        await prepareWithOutcome(locale: SpeechLocalePreference.effectiveLocale(), onProgress: onProgress)
    }

    /// Read-only inspection of Apple Speech's supported and currently installed
    /// locales for the Settings language picker. Never downloads.
    func availableLocales() async -> (supported: [Locale], installed: [Locale]) {
        guard SpeechTranscriber.isAvailable else {
            return ([], [])
        }
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        return (supported: supported, installed: installed)
    }

    func prepare(
        locale: Locale,
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async -> String {
        await prepareWithOutcome(locale: locale, onProgress: onProgress).summary
    }

    func prepareWithOutcome(
        locale: Locale,
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async -> PrepareOutcome {
        guard SpeechTranscriber.isAvailable else {
            return .failed("Unsupported language — unavailable offline.")
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = SpeechLocaleMatching.bestMatch(for: locale, in: supported) else {
            return .failed("Unsupported language — unavailable offline.")
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
                return .failed("Installed but could not be reserved: \(error.localizedDescription)")
            }
            log.info("already prepared")
            return .alreadyPrepared(tag)
        }

        do {
            try Task.checkCancellation()
            if await currentNetworkCondition() == .offline {
                return .failed("No internet connection — connect to download this language.")
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                var observations: [NSKeyValueObservation] = []
                if let onProgress {
                    let reportProgress: @Sendable (Progress) -> Void = { progress in
                        guard !progress.isCancelled else { return }
                        if progress.isIndeterminate || progress.fractionCompleted <= 0 {
                            onProgress(nil)
                        } else {
                            onProgress(min(1, max(0, progress.fractionCompleted)))
                        }
                    }
                    observations.append(
                        request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                            reportProgress(progress)
                        }
                    )
                    observations.append(
                        request.progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
                            reportProgress(progress)
                        }
                    )
                }
                defer { observations.forEach { $0.invalidate() } }

                try await withTaskCancellationHandler {
                    try await request.downloadAndInstall()
                } onCancel: {
                    request.progress.cancel()
                }
            }
            try Task.checkCancellation()
            try await reserveLocale(resolved)
            log.info("prepared language assets")
            return .prepared(tag)
        } catch is CancellationError {
            return .cancelled
        } catch {
            let nsError = error as NSError
            if Task.isCancelled
                || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            {
                return .cancelled
            }
            log.error("preparation failed")
            return .failed("Preparation failed: \(error.localizedDescription)")
        }
    }

    /// One-shot inspection of the active network path so Settings can explain
    /// offline or Low Data Mode stalls honestly. Falls back to `.online` after
    /// 500 ms so it can never block or falsely refuse a download.
    func currentNetworkCondition() async -> NetworkPathCondition {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "app.Oto.network-path-probe")
            let settled = OSAllocatedUnfairLock(initialState: false)

            @Sendable func finish(_ condition: NetworkPathCondition) {
                let shouldResume = settled.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                monitor.cancel()
                continuation.resume(returning: condition)
            }

            monitor.pathUpdateHandler = { path in
                if path.status != .satisfied {
                    finish(.offline)
                } else if path.isConstrained {
                    finish(.constrained)
                } else {
                    finish(.online)
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                finish(.online)
            }
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
