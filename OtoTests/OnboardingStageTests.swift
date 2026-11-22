//
//  OnboardingStageTests.swift
//  OtoTests
//
//  The onboarding path is a step machine with a fixed order and one set of
//  layout numbers. These tests pin the parts that would fail silently: the
//  chapters the footer counts, the order Continue walks them in, and the
//  page mark the finish flight leaves from.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Oto

@MainActor
struct OnboardingStepTests {
    /// Isolated defaults: a unit test must never write the developer's real
    /// resume point (the stage persists on every move).
    private func makeStage() -> OnboardingStage {
        OnboardingStage(
            defaults: UserDefaults(suiteName: "app.Oto.tests.stage-\(UUID().uuidString)")!
        )
    }

    @Test func chaptersAreTheStepsBetweenWelcomeAndHandoff() {
        #expect(OnboardingStage.Step.chapters == [.how, .catcher, .intelligence, .dictionary, .handsFree])
        #expect(OnboardingStage.Step.allCases.first == .welcome)
        #expect(OnboardingStage.Step.allCases.last == .handoff)
        for step in OnboardingStage.Step.chapters {
            #expect(step.isChapter)
        }
        #expect(OnboardingStage.Step.welcome.isChapter == false)
        #expect(OnboardingStage.Step.handoff.isChapter == false)
    }

    @Test func advanceMovesThroughTheChaptersInOrder() {
        let stage = self.makeStage()
        let order: [OnboardingStage.Step] = OnboardingStage.Step.chapters
        for step in order {
            stage.advance(to: step)
            #expect(stage.step == step)
            #expect(stage.movingForward)
        }
        stage.advance(to: .welcome)
        #expect(stage.movingForward == false)
    }

    @Test func resetReturnsToWelcome() {
        let stage = self.makeStage()
        stage.advance(to: .handsFree)
        stage.markInFlight = true
        stage.reset()
        #expect(stage.step == .welcome)
        #expect(stage.movingForward)
        #expect(stage.markInFlight == false)
    }

    // MARK: - Resume

    @Test func aNewStageResumesWhereTheLastOneStopped() {
        let defaults = UserDefaults(suiteName: "app.Oto.tests.resume-\(UUID().uuidString)")!
        let first = OnboardingStage(defaults: defaults)
        first.advance(to: .dictionary)

        // A relaunch: fresh object, same storage.
        let second = OnboardingStage(defaults: defaults)
        #expect(second.step == .welcome)
        second.restore()
        #expect(second.step == .dictionary)
    }

    /// The middle chapters were renamed in place (shortcut → intelligence,
    /// permissions → dictionary, try it → hands-free) so a resume point
    /// written by an older build still lands in the middle of the walk
    /// instead of on Welcome.
    @Test func middleRawValuesSurviveTheRename() {
        #expect(OnboardingStage.Step(rawValue: 3) == .intelligence)
        #expect(OnboardingStage.Step(rawValue: 4) == .dictionary)
        #expect(OnboardingStage.Step(rawValue: 5) == .handsFree)
        #expect(OnboardingStage.Step.chapters.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    @Test func resumeRestoresTheChapter() {
        let defaults = UserDefaults(suiteName: "app.Oto.tests.resume-how-\(UUID().uuidString)")!
        OnboardingStore.saveProgress(step: OnboardingStage.Step.how.rawValue, defaults: defaults)
        let stage = OnboardingStage(defaults: defaults)
        stage.restore()
        #expect(stage.step == .how)
    }

    @Test func resetClearsTheResumePoint() {
        let defaults = UserDefaults(suiteName: "app.Oto.tests.resume-clear-\(UUID().uuidString)")!
        let stage = OnboardingStage(defaults: defaults)
        stage.advance(to: .handsFree)
        stage.reset()
        #expect(OnboardingStore.progress(defaults: defaults) == nil)
        let relaunched = OnboardingStage(defaults: defaults)
        relaunched.restore()
        #expect(relaunched.step == .welcome)
    }

    @Test func handoffAndUnknownStepsClampOnRestore() {
        let defaults = UserDefaults(suiteName: "app.Oto.tests.resume-clamp-\(UUID().uuidString)")!
        OnboardingStore.saveProgress(step: OnboardingStage.Step.handoff.rawValue, defaults: defaults)
        let handoff = OnboardingStage(defaults: defaults)
        handoff.restore()
        #expect(handoff.step == .handsFree)

        OnboardingStore.saveProgress(step: 99, defaults: defaults)
        let unknown = OnboardingStage(defaults: defaults)
        unknown.restore()
        #expect(unknown.step == .welcome)
    }
}

@MainActor
struct OnboardingChapterLayoutTests {
    /// The mark the finish flight leaves from has to sit where the page
    /// draws it: top left, inside the copy's leading margin, before the
    /// words begin.
    @Test func thePageMarkSitsInTheTopLeftCorner() {
        let size = CGSize(width: 868, height: 608)
        let metrics = OnboardingChapterLayout.metrics(in: size)
        let rect = OnboardingChapterLayout.markRect(in: size)
        #expect(metrics.compact == false)
        #expect(abs(rect.midX - (metrics.leading + metrics.markBox / 2)) < 0.01)
        #expect(abs(rect.midY - (metrics.vertical + metrics.markBox / 2)) < 0.01)
        #expect(rect.minX >= metrics.leading - 0.01)
        #expect(rect.maxY <= metrics.vertical + metrics.markBox + 0.01)
        #expect(rect.midX < size.width / 2)
        #expect(rect.midY < size.height / 2)
    }

    @Test func thePageMarkKeepsTheMarksOwnAspect() {
        guard let mark = OtoMarkSource.cropped, mark.size.height > 0 else { return }
        let rect = OnboardingChapterLayout.markRect(in: CGSize(width: 868, height: 608))
        let aspect = mark.size.width / mark.size.height
        #expect(abs(rect.width / rect.height - aspect) < 0.01)
    }

    @Test func aCompactWindowMovesTheMarkWithTheMargins() {
        let size = CGSize(width: 700, height: 500)
        let metrics = OnboardingChapterLayout.metrics(in: size)
        let rect = OnboardingChapterLayout.markRect(in: size)
        #expect(metrics.compact)
        #expect(abs(rect.midX - (metrics.leading + metrics.markBox / 2)) < 0.01)
        #expect(abs(rect.midY - (metrics.vertical + metrics.markBox / 2)) < 0.01)
        #expect(rect.maxX < size.width / 2)
    }
}
