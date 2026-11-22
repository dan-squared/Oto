//
//  AppNamesTests.swift
//  OtoTests
//
//  Phase 12: bundle ID → display name fallback + retry mismatch gate.
//  No window, no running apps harmed (unknown IDs exercise the fallback).
//

import AppKit
import Testing
@testable import Oto

@MainActor
struct AppNamesTests {
    @Test func unknownIDsFallBackToRawID() {
        #expect(AppNames.displayName(forBundleID: "com.example.NoSuchApp-xyz") == "com.example.NoSuchApp-xyz")
        #expect(AppNames.displayName(forBundleID: nil) == "Unknown app")
        #expect(AppNames.displayName(forBundleID: "") == "Unknown app")
    }

    @Test func realAppResolvesToLocalizedName() {
        // Finder always runs: its name is never the raw ID.
        let name = AppNames.displayName(forBundleID: "com.apple.finder")
        #expect(name != "com.apple.finder")
        #expect(!name.isEmpty)
    }

    @Test func mismatchGateNeedsBothSidesKnownAndDifferent() {
        #expect(AppNames.shouldConfirmRetry(frontmost: "com.apple.Mail", expected: "com.apple.Notes") == true)
        // Same app: no interrogation.
        #expect(AppNames.shouldConfirmRetry(frontmost: "com.apple.Mail", expected: "com.apple.Mail") == false)
        // Unknown on either side: the person pressed Retry looking at
        // their target — post without interrogating.
        #expect(AppNames.shouldConfirmRetry(frontmost: nil, expected: "com.apple.Mail") == false)
        #expect(AppNames.shouldConfirmRetry(frontmost: "com.apple.Mail", expected: nil) == false)
        #expect(AppNames.shouldConfirmRetry(frontmost: nil, expected: nil) == false)
        #expect(AppNames.shouldConfirmRetry(frontmost: "", expected: "com.apple.Mail") == false)
    }
}
