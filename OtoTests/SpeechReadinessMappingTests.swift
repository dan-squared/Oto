//
//  SpeechReadinessMappingTests.swift
//  OtoTests
//
//  Pure readiness-matrix tests: no hardware, no Apple assets.
//  Deterministic.
//

import Foundation
import Speech
import Testing
@testable import Oto

struct SpeechReadinessMappingTests {
    private static let locale = Locale(identifier: "en_US")

    @Test func microphoneDeniedWinsOverEverything() {
        #expect(
            SpeechReadinessMapper.map(
                microphoneGranted: false,
                resolvedLocale: Self.locale,
                installedLocales: [Self.locale],
                assetStatus: .installed
            ) == .microphoneDenied
        )
    }

    @Test func unresolvableLocaleIsUnsupported() {
        #expect(
            SpeechReadinessMapper.map(
                microphoneGranted: true,
                resolvedLocale: nil,
                installedLocales: [],
                assetStatus: .unsupported
            ) == .unsupportedLocale
        )
    }

    @Test func downloadingAssetsMeansPreparing() {
        #expect(
            SpeechReadinessMapper.map(
                microphoneGranted: true,
                resolvedLocale: Self.locale,
                installedLocales: [],
                assetStatus: .downloading
            ) == .assetsPreparing
        )
    }

    @Test func installedAndReady() {
        #expect(
            SpeechReadinessMapper.map(
                microphoneGranted: true,
                resolvedLocale: Self.locale,
                installedLocales: [Self.locale],
                assetStatus: .installed
            ) == .ready
        )
    }

    @Test func supportedButNotInstalledNeedsPreparation() {
        #expect(
            SpeechReadinessMapper.map(
                microphoneGranted: true,
                resolvedLocale: Self.locale,
                installedLocales: [],
                assetStatus: .supported
            ) == .assetsNotPrepared
        )
    }

    @Test func unsupportedStatusNeedsPreparation() {
        #expect(
            SpeechReadinessMapper.map(
                microphoneGranted: true,
                resolvedLocale: Self.locale,
                installedLocales: [],
                assetStatus: .unsupported
            ) == .assetsNotPrepared
        )
    }

    @Test func readinessErrorsCarryRecoveryMessages() {
        #expect(SpeechReadiness.microphoneDenied.errorDescription == "Microphone access is needed.")
        #expect(SpeechReadiness.unsupportedLocale.errorDescription == "This language is unavailable offline.")
        #expect(SpeechReadiness.assetsNotPrepared.errorDescription == "Prepare offline speech in Settings.")
        #expect(SpeechReadiness.assetsPreparing.errorDescription == "Speech assets are still preparing.")
    }
}
