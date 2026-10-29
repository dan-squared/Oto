//
//  OnboardingStageTests.swift
//  OtoTests
//
//  The onboarding path is a step machine with a fixed order, one clock and
//  one set of layout numbers. These tests pin the parts that would fail
//  silently: the chapters the footer counts, the rows Continue walks, and
//  the welcome choreography finishing before the clock stops.
//

import CoreGraphics
import Testing
@testable import Oto

@MainActor
struct OnboardingStepTests {
    @Test func chaptersAreTheStepsBetweenWelcomeAndHandoff() {
        #expect(OnboardingStage.Step.chapters == [.how, .catcher, .shortcut, .permissions, .tryIt])
        #expect(OnboardingStage.Step.allCases.first == .welcome)
        #expect(OnboardingStage.Step.allCases.last == .handoff)
        for step in OnboardingStage.Step.chapters {
            #expect(step.isChapter)
        }
        #expect(OnboardingStage.Step.welcome.isChapter == false)
        #expect(OnboardingStage.Step.handoff.isChapter == false)
    }

    @Test func onlyTheShowingChapterWalksRows() {
        #expect(OnboardingStage.Step.how.rows == 2)
        for step in OnboardingStage.Step.allCases where step != .how {
            #expect(step.rows == 0)
        }
    }

    @Test func advanceResetsTheRowAndTheDwell() {
        let stage = OnboardingStage()
        stage.advance(to: .how, row: 2)
        stage.dwell = 0.7
        stage.advance(to: .shortcut)
        #expect(stage.step == .shortcut)
        #expect(stage.row == 0)
        #expect(stage.dwell == 0)
        #expect(stage.movingForward)
    }

    @Test func advanceClampsTheRowToTheStep() {
        let stage = OnboardingStage()
        stage.advance(to: .how, row: 99)
        #expect(stage.row == OnboardingStage.Step.how.rows - 1)
        stage.advance(to: .permissions, row: 2)
        #expect(stage.row == 0)
    }

    @Test func goingBackIsNotForward() {
        let stage = OnboardingStage()
        stage.advance(to: .permissions)
        stage.advance(to: .shortcut)
        #expect(stage.movingForward == false)
    }

    @Test func openOnlyOpensRowsThatExist() {
        let stage = OnboardingStage()
        stage.advance(to: .how)
        stage.open(row: 1)
        #expect(stage.row == 1)
        stage.open(row: 9)
        #expect(stage.row == 1)
        stage.advance(to: .permissions)
        stage.open(row: 1)
        #expect(stage.row == 0)
    }

    @Test func resetReturnsToWelcome() {
        let stage = OnboardingStage()
        stage.advance(to: .tryIt)
        stage.markInFlight = true
        stage.reset()
        #expect(stage.step == .welcome)
        #expect(stage.row == 0)
        #expect(stage.dwell == 0)
        #expect(stage.movingForward)
        #expect(stage.markInFlight == false)
    }
}

@MainActor
struct IntroTimingTests {
    @Test func shaderTimeNeverRunsBackwards() {
        var previous = -1.0
        for index in 0 ... 2000 {
            let real = IntroTiming.realDuration * Double(index) / 2000
            let shader = IntroTiming.shaderTime(atReal: real)
            #expect(shader >= previous - 1e-9)
            previous = shader
        }
    }

    @Test func shaderTimeSpansTheAuthoredTimeline() {
        #expect(IntroTiming.shaderTime(atReal: 0) == 0)
        #expect(IntroTiming.shaderTime(atReal: -1) == 0)
        #expect(IntroTiming.shaderTime(atReal: IntroTiming.realDuration) == IntroTiming.duration)
        #expect(IntroTiming.shaderTime(atReal: IntroTiming.realDuration * 2) == IntroTiming.duration)
    }

    @Test func theWindowTakesOverBeforeTheEnd() {
        #expect(IntroTiming.realHandoff > 0)
        #expect(IntroTiming.realHandoff < IntroTiming.realDuration)
        #expect(IntroTiming.shaderTime(atReal: IntroTiming.realHandoff) >= IntroTiming.handoff)
        #expect(IntroTiming.logoSettled < IntroTiming.duration)
    }

    @Test func theDesktopDarkensAndIsRestored() {
        #expect(IntroTiming.dimming(atReal: 0) == 0)
        #expect(IntroTiming.dimming(atReal: 1.1) > IntroTiming.dimmingPeak * 0.99)
        #expect(IntroTiming.dimming(atReal: 4.05) == 0)
        #expect(IntroTiming.dimming(atReal: 9) == 0)
    }

    @Test func everyWelcomeElementArrivesBeforeTheClockStops() {
        let end = IntroTiming.duration
        #expect(WelcomeTiming.markImageProgress(at: end) == 1)
        #expect(WelcomeTiming.nameProgress(at: end) == 1)
        #expect(WelcomeTiming.titleOpacity(at: end) == 1)
        #expect(WelcomeTiming.subtitleOpacity(at: end) == 1)
        #expect(WelcomeTiming.buttonOpacity(at: end) == 1)
        #expect(WelcomeTiming.settleProgress(at: end) == 1)
        #expect(WelcomeTiming.interactiveAt <= IntroTiming.duration)
    }

    @Test func theWelcomeArrivesInOrder() {
        #expect(WelcomeTiming.markImageVisibleAt < WelcomeTiming.nameStart)
        #expect(WelcomeTiming.nameVisibleAt < WelcomeTiming.titleStart)
        #expect(WelcomeTiming.titleStart < WelcomeTiming.buttonStart)
        #expect(WelcomeTiming.subtitleStart < WelcomeTiming.buttonStart)
        #expect(WelcomeTiming.buttonStart <= WelcomeTiming.interactiveAt)
    }

    @Test func theSpringStartsAtNothingAndComesToRest() {
        #expect(WelcomeTiming.spring(0, after: 0) == 0)
        #expect(WelcomeTiming.spring(0, after: 1) == 0)
        #expect(abs(WelcomeTiming.spring(3, after: 0) - 1) < 0.001)
    }
}

@MainActor
struct WelcomeLayoutTests {
    private let panel = CGSize(width: 868, height: 608)

    @Test func theMarkStartsCentred() {
        let frame = WelcomeLayout.frame(at: 0, in: self.panel)
        #expect(abs(frame.markRect.midX - self.panel.width / 2) < 0.01)
        #expect(abs(frame.markRect.midY - self.panel.height / 2) < 0.01)
        #expect(frame.markRect.width == OtoLogoTiming.side)
        #expect(frame.nameReveal == 0)
        #expect(frame.nameWindowLeft == frame.markRect.maxX)
    }

    @Test func theNameLeavesTheMarkWithoutMovingThePair() {
        let frame = WelcomeLayout.frame(at: IntroTiming.duration, in: self.panel)
        #expect(frame.nameReveal == 1)
        #expect(frame.nameSlide == 0)
        #expect(frame.nameCenter.x > frame.markRect.maxX)
        // The gap between the mark and the name's centre is half the name plus
        // the gap, so the pair's own width is recoverable without the view.
        let nameWidth = 2 * (frame.nameCenter.x - frame.markRect.maxX - WelcomeLayout.gap)
        let right = frame.nameCenter.x + nameWidth / 2
        #expect(abs((self.panel.width - right) - frame.markRect.minX) < 0.5)
    }

    @Test func thePairSettlesAboveTheMiddle() {
        let lift = WelcomeLayout.lift(for: 26)
        let frame = WelcomeLayout.frame(at: IntroTiming.duration, in: self.panel, lift: lift)
        #expect(abs(frame.markRect.midY - (self.panel.height / 2 - lift)) < 0.01)
        #expect(frame.markRect.midY < self.panel.height / 2)
    }

    @Test func theRiseShrinksThePairIntoTheHeader() {
        let header = WelcomeLayout.frame(at: IntroTiming.duration, in: self.panel, rise: 1)
        #expect(abs(header.markRect.width - WelcomeLayout.headerMarkSide) < 0.01)
        #expect(abs(header.markRect.midY - WelcomeLayout.headerCenterY) < 0.01)
        #expect(header.nameFontSize < WelcomeLayout.nameFontSize)
    }

    @Test func theLineSitsUnderThePair() {
        let below: CGFloat = 26
        let lift = WelcomeLayout.lift(for: below)
        #expect(lift > WelcomeLayout.groupRaise)
        let top = WelcomeLayout.contentTop(in: self.panel, lift: lift)
        let expected = self.panel.height / 2 - lift + OtoLogoTiming.side / 2 + WelcomeLayout.lineSpacing
        #expect(abs(top - expected) < 0.01)
    }
}
