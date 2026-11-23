//
//  PermissionModalTests.swift
//  OtoTests
//
//  Mic-denied mini modal: deep-link strings pinned (a renamed pane anchor
//  fails here before users land on the wrong Settings page), grant-action
//  branching tested without touching TCC, and prewarm builds headless.
//

import AppKit
import Foundation
import QuartzCore
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

    @Test func copyMatchesWhatTheSystemWillDo() {
        // Before the first answer macOS shows its own dialog, so the card
        // asks. After a denial the system never asks again, so the card
        // sends the person to the pane that owns the switch.
        let undetermined = PermissionCardCopy.forStatus(.notDetermined)
        #expect(undetermined.title == "Microphone Permission Required")
        #expect(undetermined.action == "Allow Microphone")
        let denied = PermissionCardCopy.forStatus(.denied)
        #expect(denied.title == "Microphone Access Is Off")
        #expect(denied.action == "Open Settings")
    }

    @Test func configureRewordsAndRefits() {
        let card = PermissionCardView(onGrant: nil)
        card.configure(PermissionCardCopy.forStatus(.denied))
        #expect(card.titleText() == "Microphone Access Is Off")
        #expect(!card.titleClipped())
        #expect(card.contentWidth() <= PermissionCardView.maxWidth)
    }

    @Test func geometryAndTimeoutPinned() {
        #expect(PermissionCardView.maxWidth == 460)
        #expect(PermissionModalController.visibleDuration == 5.0)
    }

    @Test func widthFitsTheWords() {
        // 12.5pt title + 18pt icon + button, string-measured, fitted and
        // clamped: the full words render (no truncation) inside the 460 ceiling.
        let card = PermissionCardView(onGrant: nil)
        #expect(card.titleText() == "Microphone Permission Required")
        #expect(!card.titleClipped())
        #expect(card.contentWidth() <= PermissionCardView.maxWidth)
        #expect(card.contentWidth() > 300)
    }

    @Test func titleIsVerticallyCentered() {
        // No icon since 2026-11-01: the title alone must sit on the capsule's
        // midline, and the button must share it.
        let card = PermissionCardView(onGrant: nil)
        #expect(abs(card.titleMidY() - PermissionCardView.height / 2) < 0.5)
    }

    @Test func bothSurfacesAreCapsules() {
        // The card is the pill expanded: outer radius is half its height,
        // and the action inside is its own pill (30 → 15). No concentric
        // offset survives — a capsule inside a capsule is the point.
        #expect(PermissionCardView.cardRadius == PermissionCardView.height / 2)
        #expect(PermissionCardView.buttonRadius == PermissionCardView.buttonHeight / 2)
        #expect(PermissionCardView.height <= 48)
    }

    @Test func actionIsConcentricWithTheCapsule() {
        // Concentric, Apple's own rule for a shape inside a capsule: the
        // inner radius is the outer minus the inset, and the button is inset
        // by exactly that much on every side.
        #expect(PermissionCardView.cardRadius - PermissionCardView.inset
            == PermissionCardView.buttonRadius)
        #expect(PermissionCardView.height - PermissionCardView.buttonHeight
            == PermissionCardView.inset * 2)
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

    @Test func morphUsesMaskRevealWithoutMutatingAnchorPointAndHonorsReduceMotion() {
        // Smooth mask-reveal morph: animates the CAShapeLayer mask path rather
        // than scaling NSGlassEffectView, never mutates layer.anchorPoint, and
        // settles immediately when Reduce Motion is enabled.
        let card = PermissionCardView(onGrant: nil)
        let originalAnchor = card.layer?.anchorPoint
        let pill = NSRect(x: 100, y: 100, width: VisualizerMath.dictationWidth, height: VisualizerMath.pillHeight)
        let target = NSRect(x: 0, y: 100, width: card.contentWidth(), height: PermissionCardView.height)

        card.morph(from: pill, card: target, position: .top, reduceMotion: false)
        #expect(card.layer?.anchorPoint == originalAnchor)
        #expect(card.hasActiveMorphAnimation())

        card.morph(from: pill, card: target, position: .bottom, reduceMotion: true)
        #expect(card.layer?.anchorPoint == originalAnchor)
        #expect(!card.hasActiveMorphAnimation())

        // Verify pure transform helper still pins top-center / bottom-center.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 44)
        let topT = PermissionCardView.morphTransform(
            bounds: bounds, anchorPoint: .zero, position: .top, sx: 0.25, sy: 0.5
        )
        let topCenterX = topT.m11 * bounds.midX + topT.m41
        let topCenterY = topT.m22 * bounds.maxY + topT.m42
        #expect(abs(topCenterX - bounds.midX) < 0.001)
        #expect(abs(topCenterY - bounds.maxY) < 0.001)

        let bottomT = PermissionCardView.morphTransform(
            bounds: bounds, anchorPoint: .zero, position: .bottom, sx: 0.25, sy: 0.5
        )
        let bottomCenterX = bottomT.m11 * bounds.midX + bottomT.m41
        let bottomCenterY = bottomT.m22 * bounds.minY + bottomT.m42
        #expect(abs(bottomCenterX - bounds.midX) < 0.001)
        #expect(abs(bottomCenterY - bounds.minY) < 0.001)
    }
}
