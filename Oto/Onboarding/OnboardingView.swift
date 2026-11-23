//
//  OnboardingView.swift
//  Oto
//
//  The page inside the one onboarding window: the brand hero on Welcome and
//  the chapters after it. There is no arrival animation — the window opens
//  on a plain page and the walk starts from its first line. The only motion
//  left is the chapter turn and the finish flight to the menu bar.
//
//  Owns no services: the flow owns dispatch and the shared SettingsUIState.
//

import AppKit
import SwiftUI

struct OnboardingView: View {
    let flow: OnboardingFlow

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                OnboardingTheme.ground
                if self.stage.isWelcome {
                    self.welcome(size: size)
                        .transition(self.reduceMotion ? .opacity : OnboardingStage.turningForward)
                } else {
                    // A step owns the page, from its first line to its footer.
                    self.steps
                        .frame(width: size.width, height: size.height)
                        .transition(OnboardingStage.chapters(reduceMotion: self.reduceMotion))
                }
            }
            .frame(width: size.width, height: size.height)
            // The one pill, drawn here and nowhere else while a chapter is on
            // screen. A step only keeps a place for it, so it stays in the
            // footer while only its label changes.
            .overlayPreferenceValue(OnboardingContinueSlotKey.self) { slot in
                GeometryReader { proxy in
                    if let slot {
                        let place = proxy[slot.bounds]
                        OnboardingContinuePill(spec: slot.spec)
                            .position(x: place.midX, y: place.midY)
                            .animation(
                                self.reduceMotion ? nil : OnboardingContinuePill.morphSpring,
                                value: slot.spec.title
                            )
                            .animation(
                                self.reduceMotion ? nil : OnboardingStage.stepAnimation,
                                value: self.stage.step
                            )
                    }
                }
            }
            .animation(OnboardingStage.stepAnimation, value: self.stage.isWelcome)
        }
        .fontDesign(.rounded)
        .ignoresSafeArea()
        // A restored walk can land on the last chapter before the window has
        // drawn a single frame; the grants are asked there too.
        .task {
            self.flow.load()
            self.flow.scheduleLastChapterPreparation()
        }
        .onChange(of: self.stage.step) { _, _ in
            self.flow.scheduleLastChapterPreparation()
        }
        .onDisappear { self.flow.disarm() }
        // A grant made in System Settings is only visible once the person
        // comes back; the chapter must not stay on the old status. The tap
        // heals here too — the last chapter never re-prompts.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.flow.uiState.refreshPermissions()
            self.flow.refreshPermissionGate()
            self.flow.dispatch.refreshAvailability()
            if self.flow.isLastChapter {
                self.flow.prepareDictation()
            }
        }
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var stage: OnboardingStage { .shared }

    /// Reduce Motion keeps a pill in each place: they change by fading, and
    /// nothing crosses the window.
    private var steps: some View {
        OnboardingChaptersView(flow: self.flow)
            .environment(\.onboardingPillTravels, !self.reduceMotion)
    }

    /// Welcome is the brand hero and one line, still: the mark and the word
    /// on one baseline, held a little above the middle, with the one pill at
    /// the foot of the page. Nothing is choreographed — the page is simply
    /// there when the window opens.
    private func welcome(size: CGSize) -> some View {
        let compact = size.height < 538 || size.width < 748
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                HStack(spacing: WelcomeHero.gap) {
                    if let mark = OtoMarkSource.cropped {
                        // The asset is white bars; as a template it takes the
                        // stage's ink, so it reads on a dark field and on
                        // paper alike.
                        Image(nsImage: mark)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: WelcomeHero.markSide, height: WelcomeHero.markSide)
                    }
                    Text(WelcomeHero.name)
                        .font(.system(size: WelcomeHero.nameFontSize, weight: .medium))
                        .tracking(WelcomeHero.nameTracking)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Oto")

                Text("Hold a key, speak anywhere, release — your words land where you type.")
                    .font(.system(size: compact ? 14 : 15))
                    .foregroundStyle(OnboardingTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: 420)
                    .padding(.top, WelcomeHero.lineSpacing)
            }
            .offset(y: -WelcomeHero.groupRaise)
            Spacer(minLength: 0)

            OnboardingContinueButton(
                title: self.flow.buttonTitle,
                action: { self.flow.next() }
            )
            .frame(width: min(352, size.width - 64))
            .padding(.bottom, compact ? 24 : 36)
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(OnboardingTheme.ink)
    }
}

/// The hero's own numbers. The wordmark and the mark sit on one baseline;
/// the pair is held a little above the middle so it and its line read as one
/// group.
private enum WelcomeHero {
    static let markSide: CGFloat = 72
    static let gap: CGFloat = 16
    static let name = "Oto"
    static let nameFontSize: CGFloat = 42
    static let nameTracking: CGFloat = -1.5
    /// Between the pair and the line under it.
    static let lineSpacing: CGFloat = 22
    /// How far the pair and its line sit above the middle.
    static let groupRaise: CGFloat = 24
}
