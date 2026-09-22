//
//  PermissionModalTests.swift
//  OtoTests
//
//  Mic-denied mini modal: deep-link strings pinned (a renamed pane anchor
//  fails here before users land on the wrong Settings page), grant-action
//  branching tested without touching TCC, and prewarm builds headless.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct PermissionModalTests {
    @Test func deepLinkTargetsMicrophoneFirst() {
        let urls = MicSettingsLink.candidates().map(\.absoluteString)
        #expect(urls.count == 3)
        #expect(urls[0] == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(urls[1] == "x-apple.systempreferences:com.apple.preference.security?Privacy")
        #expect(urls[2] == "x-apple.systempreferences:")
    }

    @Test func grantActionBranchesWithoutTCC() {
        #expect(PermissionModalController.action(for: .notDetermined) == .systemPrompt)
        #expect(PermissionModalController.action(for: .denied) == .openSettings)
        #expect(PermissionModalController.action(for: .granted) == .openSettings)
    }

    @Test func geometryAndTimeoutPinned() {
        #expect(PermissionCardView.maxWidth == 415)
        #expect(PermissionModalController.visibleDuration == 5.0)
    }

    @Test func widthFitsTheWords() {
        // 12.5pt title + 18pt icon + button, fitted and clamped: the full
        // words render (no truncation) inside the 415 ceiling.
        let card = PermissionCardView(onGrant: nil)
        #expect(card.titleText() == "Microphone Permission Required")
        #expect(!card.titleClipped())
        #expect(card.contentWidth() <= PermissionCardView.maxWidth)
        #expect(card.contentWidth() > 300)
    }

    @Test func buttonRadiusFollowsAppleConcentricFormula() {
        // Inner = outer − gap: 18pt card minus the 12pt uniform inset.
        #expect(PermissionCardView.buttonRadius == 6)
    }

    @Test func grantOpensMicrophoneLinkWhenDenied() {
        // Denied (or granted — both route to Settings): the first attempted
        // URL must be the Microphone pane; opener is injected, nothing launches.
        // Skipped when undetermined: that path prompts TCC for real.
        guard PermissionsManager().microphoneStatus() != .notDetermined else { return }
        let modal = PermissionModalController()
        var attempted: [String] = []
        modal.grant(opener: { url in
            attempted.append(url.absoluteString)
            return true
        })
        #expect(attempted.first == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @Test func prewarmBuildsWithoutShowing() {
        // Catcher precedent: construction moves to launch; show() only
        // positions + orders.
        let modal = PermissionModalController()
        #expect(!modal.hasPanel)
        modal.prewarm()
        #expect(modal.hasPanel)
        #expect(!modal.isVisible)
        modal.prewarm()
        #expect(modal.hasPanel)
        modal.hide()
    }
}
