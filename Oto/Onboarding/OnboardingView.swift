//
//  OnboardingView.swift
//  Oto
//
//  The arrival. Ported from Firstlight: both hosts render the same light —
//  the transparent carrier carries it across the desktop, the native window
//  continues it into the original mark in the centre and reveals the word
//  beside it. That pair is Welcome; it becomes the header only when the step
//  leaves Welcome, so the rise is the way into the first chapter.
//
//  Owns no services: the flow owns dispatch and the shared SettingsUIState.
//

import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var playback: IntroPlayback
    @ObservedObject var flow: OnboardingFlow
    let nativeSurface: Bool

    var body: some View {
        GeometryReader { proxy in
            let panel = self.nativeSurface ? CGRect(origin: .zero, size: proxy.size) : self.playback.panelRect
            let elapsed = self.playback.renderTime(nativeSurface: self.nativeSurface)
            // Derived from the panel, not measured: both hosts must agree on
            // the optical root from the very first frame, before Welcome exists.
            let frame = WelcomeLayout.frame(at: elapsed, in: panel.size)
            let slot = frame.markRect
            // Once the light has become the mark, a plain image of the asset
            // takes over in the same rect; the shader then holds a static,
            // markless frame and stops redrawing.
            let handover = self.nativeSurface ? WelcomeTiming.markImageProgress(at: elapsed) : 0
            let shaderElapsed = handover >= 1 ? WelcomeTiming.markImageVisibleAt : elapsed
            let offPane = slot.offsetBy(dx: 0, dy: -panel.height - slot.height)
            ZStack {
                if self.playback.shaderFailure == nil {
                    MetalOnboardingShaderView(
                        elapsed: Float(shaderElapsed), inset: 0, nativeSurface: self.nativeSurface,
                        variant: self.playback.variant,
                        rayLogoRect: self.stage.markInFlight || handover >= 1 ? offPane : slot,
                        targetSize: panel.size,
                        targetOffset: CGPoint(
                            x: panel.midX - proxy.size.width / 2,
                            y: panel.midY - proxy.size.height / 2
                        ),
                        onFailure: self.playback.fail,
                        onPresented: self.nativeSurface ? { self.playback.onNativeFramePresented?($0) } : nil
                    ).accessibilityHidden(true)
                } else {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }

                if self.nativeSurface {
                    self.welcome(size: panel.size, handover: handover)
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
        }
        .fontDesign(.rounded)
        // A native window: the stage follows the system appearance, and the
        // shader inverts with it (light on a dark field, ink on paper).
        .ignoresSafeArea()
        .task { self.flow.load() }
        .onDisappear { self.flow.disarm() }
        // A grant made in System Settings is only visible once the person
        // comes back; the chapter must not stay on the old status.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.flow.uiState.refreshPermissions()
        }
        // The tap that closes the rise: felt as the pair lands in the header,
        // a little before its spring is over.
        .onChange(of: self.pairRisen) { _, risen in
            guard risen, !self.reduceMotion, self.nativeSurface else { return }
            Task {
                try? await Task.sleep(for: .seconds(OnboardingStage.stepDuration * 0.8))
                OtoHaptics.introRiseLanded()
            }
        }
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var stage = OnboardingStage.shared

    /// Reduce Motion keeps a pill in each place: they change by fading, and
    /// nothing crosses the window.
    private var steps: some View {
        OnboardingChaptersView(flow: self.flow)
            .environment(\.onboardingPillTravels, !self.reduceMotion)
    }

    /// The pair is the header after Welcome, always.
    private var pairRisen: Bool { !self.stage.isWelcome }

    private func welcome(size: CGSize, handover: Double) -> some View {
        let time = self.playback.elapsed
        let compact = size.height < 538 || size.width < 748
        let titleAlpha = WelcomeTiming.titleOpacity(at: time)
        let titleIn = WelcomeTiming.spring(time, after: WelcomeTiming.titleStart)
        let subtitleAlpha = WelcomeTiming.subtitleOpacity(at: time)
        let subtitleIn = WelcomeTiming.spring(time, after: WelcomeTiming.subtitleStart)
        let buttonIn = WelcomeTiming.spring(time, after: WelcomeTiming.buttonStart)
        let buttonAlpha = WelcomeTiming.buttonOpacity(at: time)
        let enabled = time >= WelcomeTiming.interactiveAt
        let spacing: CGFloat = compact ? 8 : 10
        let lineHeight: CGFloat = compact ? 18 : 20
        let risen = self.pairRisen
        // The pair settles just far enough up that it and its line are centred
        // together; the line rides with it, one group, one gap.
        let lift = WelcomeLayout.lift(for: lineHeight)
        let contentTop = WelcomeLayout.contentTop(
            in: size,
            lift: lift * CGFloat(WelcomeTiming.settleProgress(at: time))
        )

        return ZStack {
            // One view for the whole life of the pair: hero of Welcome, then
            // the header of every step. Leaving Welcome moves it on the step's
            // own spring, together with the pill.
            WelcomePair(
                time: time, size: size, lift: lift, rise: risen ? 1 : 0,
                markOpacity: self.stage.markInFlight ? 0 : handover,
                nameHidden: self.stage.markInFlight
            )
            .id(self.reduceMotion && risen)
            .transition(.opacity)
            .animation(OnboardingStage.stepAnimation, value: risen)
            .animation(.easeOut(duration: 0.2), value: self.stage.markInFlight)
            .accessibilityHidden(true)

            if self.stage.isWelcome {
                // The line starts while the pair is still settling: the centre
                // is never empty.
                VStack(spacing: spacing) {
                    Text("Hold a key, speak anywhere, release — your words land where you type.")
                        .font(.system(size: compact ? 14 : 15))
                        .foregroundStyle(OnboardingTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: 420)
                        .opacity(subtitleAlpha)
                        .blur(radius: (1 - subtitleAlpha) * 6)
                        .offset(y: (1 - subtitleIn) * 10)
                        .accessibilityHidden(subtitleAlpha < 1)
                }
                .padding(.top, contentTop)
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(titleAlpha)
                .accessibilityHidden(titleAlpha < 1)
                // Nothing of the welcome carries into the first chapter but
                // the header, so it leaves the way a chapter does: sideways.
                .transition(self.reduceMotion ? .opacity : OnboardingStage.turningForward)

                VStack {
                    Spacer(minLength: 0)
                    OnboardingContinueButton(
                        title: self.flow.buttonTitle,
                        isEnabled: enabled,
                        action: { self.flow.next() }
                    )
                    .frame(width: min(352, size.width - 64))
                    .opacity(buttonAlpha)
                    .blur(radius: (1 - buttonAlpha) * 5)
                    .offset(y: (1 - buttonIn) * 24)
                    .allowsHitTesting(enabled)
                    .disabled(!enabled)
                    .accessibilityHidden(!enabled)
                    .padding(.bottom, compact ? 24 : 36)
                }
                .frame(width: size.width, height: size.height)
            } else {
                // A step owns the centre and the bottom, under the same header.
                self.steps
                    .frame(width: size.width, height: size.height)
                    .transition(OnboardingStage.chapters(reduceMotion: self.reduceMotion))
            }
        }
        // The one pill, drawn here and nowhere else. A step only keeps a place
        // for it, so when Welcome gives way to the first chapter the pill
        // crosses to the footer on the step's own spring, and its label morphs
        // on the way, instead of one pill leaving and another arriving.
        .overlayPreferenceValue(OnboardingContinueSlotKey.self) { slot in
            GeometryReader { proxy in
                if let slot {
                    let place = proxy[slot.bounds]
                    OnboardingContinuePill(spec: slot.spec)
                        .position(x: place.midX, y: place.midY)
                        .opacity(buttonAlpha)
                        .blur(radius: (1 - buttonAlpha) * 5)
                        .allowsHitTesting(enabled)
                        .disabled(!enabled)
                        .accessibilityHidden(!enabled)
                }
            }
        }
        .foregroundStyle(OnboardingTheme.ink)
        .animation(OnboardingStage.stepAnimation, value: self.stage.isWelcome)
    }
}

/// The mark and the word on one set of numbers. The clock reveals the name
/// and settles the pair; `lift` and `rise` are state, animated by whoever
/// changes them.
private struct WelcomePair: View, Animatable {
    var time: Double
    var size: CGSize
    var lift: CGFloat
    var rise: CGFloat
    var markOpacity: Double
    var nameHidden: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(self.lift, self.rise) }
        set {
            self.lift = newValue.first
            self.rise = newValue.second
        }
    }

    var body: some View {
        let frame = WelcomeLayout.frame(at: self.time, in: self.size, lift: self.lift, rise: self.rise)
        let slot = frame.markRect
        ZStack {
            // The plain image of the asset, in the rect the shader's mark had.
            if self.markOpacity > 0, let mark = OtoMarkSource.cropped {
                // The asset is white bars; as a template it takes the stage's
                // ink, so it reads on a dark field and on paper alike.
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: slot.width, height: slot.height)
                    .position(x: slot.midX, y: slot.midY)
                    .opacity(self.markOpacity)
                    .transaction { $0.animation = nil }
            }
            // The word slides out from behind the mark through a soft
            // transparent edge at the mark's side, last letters first.
            ZStack {
                Text(WelcomeLayout.name)
                    .font(.system(size: frame.nameFontSize, weight: .medium))
                    .tracking(WelcomeLayout.nameTracking * frame.nameFontSize / WelcomeLayout.nameFontSize)
                    .fixedSize()
                    .position(x: frame.nameCenter.x + frame.nameSlide, y: frame.nameCenter.y)
            }
            .frame(width: self.size.width, height: self.size.height)
            .mask {
                let windowWidth = max(0, self.size.width - frame.nameWindowLeft)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: min(1, frame.nameFront / max(windowWidth, 1))),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: windowWidth, height: self.size.height)
                .position(x: frame.nameWindowLeft + windowWidth / 2, y: self.size.height / 2)
            }
            .opacity(self.nameHidden ? 0 : frame.nameOpacity)
        }
        .frame(width: self.size.width, height: self.size.height)
    }
}
