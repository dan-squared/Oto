//
//  OnboardingHandoffTests.swift
//  OtoTests
//
//  The mark's landing is pure geometry around one measured box: the status
//  button. These pin the centre (the part the user sees fail when it is a
//  constant), the icon-sized height, and the fallback's place in the bar.
//  The live window lookup itself is exercised by the probe, not here.
//

import AppKit
import CoreGraphics
import Testing
@testable import Oto

@MainActor
struct OnboardingHandoffTests {
    /// The mark's cropped ink, as measured from the app icon.
    private let aspect: CGFloat = 583.0 / 491.0
    /// The real status button on this Mac's 38 pt menu bar.
    private let button = CGRect(x: 1366, y: 1079, width: 32, height: 29)

    @Test func landingIsCentredOnTheStatusButton() {
        let target = OnboardingHandoff.landingRect(centredIn: button, aspect: aspect)
        #expect(abs(target.midX - button.midX) < 0.0001)
        #expect(abs(target.midY - button.midY) < 0.0001)
        #expect(button.contains(target))
    }

    @Test func landingIsTheIconsHeightAndTheMarksAspect() {
        let target = OnboardingHandoff.landingRect(centredIn: button, aspect: aspect)
        // 47% of the 29 pt button: the SF waveform's ink is 13.5 pt.
        #expect(abs(target.height - 13.63) < 0.01)
        #expect(abs(target.width / target.height - aspect) < 0.001)
        #expect(target.width > 15.5 && target.width < 17)
    }

    @Test func landingKeepsIconSizeOnOtherBarHeights() {
        let short = CGRect(x: 0, y: 0, width: 32, height: 22)
        let tall = CGRect(x: 0, y: 0, width: 32, height: 40)
        #expect(OnboardingHandoff.landingRect(centredIn: short, aspect: aspect).height == 13)
        #expect(OnboardingHandoff.landingRect(centredIn: tall, aspect: aspect).height == 16)
    }

    @Test func fallbackSitsCentredInTheMenuBar() throws {
        let screen = try #require(NSScreen.main)
        let target = OnboardingHandoff.menuBarTarget(on: screen)
        let barHeight = max(
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top
        )
        #expect(screen.frame.contains(target))
        #expect(abs(target.midY - (screen.frame.maxY - barHeight / 2)) < 0.001)
        #expect(target.maxX <= screen.frame.maxX - 18)
    }
}
