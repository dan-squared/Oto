//
//  OnboardingStage.swift
//  Oto
//
//  Where the onboarding window is in the path from Welcome to the menu bar.
//  Ported from Firstlight: the header — the mark and the word — is the one
//  thing that never moves. Welcome holds one thing in the centre; after it
//  come the chapters, which share one frame: words on the left, the thing
//  itself on the right, and a footer whose one button keeps its place while
//  only its label changes.
//

import Combine
import SwiftUI

@MainActor
final class OnboardingStage: ObservableObject {
    enum Step: Int, Equatable, Comparable, CaseIterable {
        /// The intro and the one button: the state the window opens in.
        case welcome
        /// Shown, not asked: what Oto does, one row at a time.
        case how
        /// Shown: the catcher, given the room to be understood.
        case catcher
        /// Asked: the hold key. The recorder applies immediately.
        case shortcut
        /// Asked: the three permissions dictation needs.
        case permissions
        /// Shown, and asked only if the language is not ready: offline speech.
        case speech
        /// Shown: a field to try it in.
        case tryIt
        /// The mark leaves the header for the menu bar; the window goes.
        case handoff

        /// The chapters, in order: what the dashes in the footer count.
        static let chapters: [Step] = [.how, .catcher, .shortcut, .permissions, .speech, .tryIt]

        var isChapter: Bool { Self.chapters.contains(self) }

        /// A chapter that shows has rows to step through; one that asks has none.
        var rows: Int {
            switch self {
            case .how: 2
            default: 0
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let shared = OnboardingStage()

    /// Content replaced inside a frame that stays — the title on Welcome, the
    /// recorder and the permission rows: the current content fades where it
    /// stands, with a little blur, and the next comes up over it from a few
    /// points below, so the two overlap and nothing reads as a screen going by.
    static let forward: AnyTransition = .asymmetric(
        insertion: .offset(y: 8).combined(with: .opacity).combined(with: .blur),
        removal: .opacity.combined(with: .blur)
    )
    static let backward: AnyTransition = .asymmetric(
        insertion: .offset(y: -8).combined(with: .opacity).combined(with: .blur),
        removal: .opacity.combined(with: .blur)
    )
    /// How far a chapter drifts as it gives way. A hint of direction, not a
    /// page going by.
    static let chapterDrift: CGFloat = 12
    /// The frame changing chapter: the leaving copy fades where it stands and
    /// the arriving one comes up over it from a few points to the side.
    static let turningForward: AnyTransition = .asymmetric(
        insertion: .offset(x: chapterDrift).combined(with: .opacity),
        removal: .offset(x: -chapterDrift).combined(with: .opacity)
    )
    static let turningBackward: AnyTransition = .asymmetric(
        insertion: .offset(x: -chapterDrift).combined(with: .opacity),
        removal: .offset(x: chapterDrift).combined(with: .opacity)
    )
    /// The right side of a chapter, replaced rather than turned: the new thing
    /// comes up a few points from below — from above on the way back — over
    /// the old one fading in place.
    static let replacingForward: AnyTransition = .asymmetric(
        insertion: .offset(y: 8).combined(with: .opacity),
        removal: .opacity
    )
    static let replacingBackward: AnyTransition = .asymmetric(
        insertion: .offset(y: -8).combined(with: .opacity),
        removal: .opacity
    )
    static let stepDuration = 0.34
    static let stepAnimation: Animation = .spring(duration: stepDuration, bounce: 0)

    @Published var step: Step = .welcome
    /// Which row of a showing chapter is open. Continue walks the rows before
    /// it leaves the chapter, so nobody has to find them to see them.
    @Published private(set) var row = 0
    /// How far the open row's dwell has run, 0 to 1. The rows keep the clock;
    /// the progress dashes draw it.
    @Published var dwell: CGFloat = 0
    /// Which way the last move went, for the transition of what it brought in.
    @Published private(set) var movingForward = true
    /// The header mark has left for the menu bar: the window draws neither it
    /// nor the word, since the flying copy is the only one there is.
    @Published var markInFlight = false

    var isWelcome: Bool { self.step == .welcome }

    /// What changes inside a chapter's own frame, which rises and falls.
    var transition: AnyTransition { self.movingForward ? Self.forward : Self.backward }

    /// What a chapter shows on its right, replaced where it stands.
    var replacing: AnyTransition { self.movingForward ? Self.replacingForward : Self.replacingBackward }

    /// The chapters as a whole: they arrive the way one chapter gives way to
    /// the next, and at the end they simply go.
    static func chapters(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : self.turningForward,
            removal: .opacity.animation(.easeOut(duration: 0.18))
        )
    }

    /// A step that has just come in has arrived once its spring is done.
    static func arrival() async { try? await Task.sleep(for: .seconds(self.stepDuration)) }

    /// The frame itself changing chapter, which dissolves with a drift — or,
    /// where the system asks for less motion, gives way without travelling.
    func turn(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return self.movingForward ? Self.turningForward : Self.turningBackward
    }

    func advance(to step: Step, row: Int = 0) {
        guard self.step != step else { return }
        // Set apart from the step, and first: a transition is read when the
        // view is inserted, so the direction has to be there already.
        self.movingForward = step > self.step
        // The dwell goes back to nought in the same move as the row, so the
        // dash keeps its length through the change and fills on from there.
        withAnimation(Self.stepAnimation) {
            self.step = step
            self.row = min(max(row, 0), max(step.rows - 1, 0))
            self.dwell = 0
        }
    }

    func open(row: Int) {
        guard row != self.row, row >= 0, row < self.step.rows else { return }
        withAnimation(Self.stepAnimation) {
            self.row = row
            self.dwell = 0
        }
    }

    func reset() {
        self.step = .welcome
        self.row = 0
        self.dwell = 0
        self.movingForward = true
        self.markInFlight = false
    }
}

/// A fade that also softens: the arrival vocabulary Firstlight's steps use
/// for content replaced inside a frame that stays.
struct BlurTransitionModifier: AnimatableModifier {
    init(radius: Double = 0) { self.animatableData = radius }

    var animatableData: Double

    func body(content: Content) -> some View {
        content.blur(radius: self.animatableData)
    }
}

extension AnyTransition {
    static var blur: AnyTransition {
        AnyTransition.modifier(active: BlurTransitionModifier(radius: 2.0), identity: .init())
    }
}
