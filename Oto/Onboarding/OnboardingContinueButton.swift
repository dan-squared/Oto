//
//  OnboardingContinueButton.swift
//  Oto
//
//  One action and one default shortcut. Ported from Firstlight's travelling
//  pill: Welcome's button and the footer's are one object, so it crosses from
//  one place to the other on the step's own spring while only its label
//  changes. Oto's pill is the app's own inversion — white on the dark stage,
//  ink for the label — rather than Firstlight's violet.
//

import SwiftUI

/// One button from Welcome to the end; later steps only give it another title
/// and another place.
struct OnboardingContinueButton: View {
    var title: String
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        if self.travels {
            // Inside the onboarding window the pill is drawn once, above the
            // steps, and this only keeps its place and says what it is now.
            OnboardingContinuePill(spec: self, placeholder: true)
                .anchorPreference(key: OnboardingContinueSlotKey.self, value: .bounds) {
                    OnboardingContinueSlot(spec: self, bounds: $0)
                }
        } else {
            OnboardingContinuePill(spec: self)
        }
    }

    @Environment(\.onboardingPillTravels) private var travels
}

/// Where the pill stands now, and what it says there.
struct OnboardingContinueSlot {
    let spec: OnboardingContinueButton
    let bounds: Anchor<CGRect>
}

struct OnboardingContinueSlotKey: PreferenceKey {
    static var defaultValue: OnboardingContinueSlot?

    /// One pill: a page still on its way out does not outvote the one coming in.
    static func reduce(value: inout OnboardingContinueSlot?, nextValue: () -> OnboardingContinueSlot?) {
        value = nextValue() ?? value
    }
}

private struct OnboardingPillTravelsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the onboarding window, which draws the pill itself. Anywhere
    /// else the button draws where it is put.
    var onboardingPillTravels: Bool {
        get { self[OnboardingPillTravelsKey.self] }
        set { self[OnboardingPillTravelsKey.self] = newValue }
    }
}

/// Crisp tactile spring button style for the onboarding continue pill.
private struct OnboardingPillButtonStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !self.reduceMotion ? 0.97 : 1.0)
            .animation(
                self.reduceMotion ? nil : .spring(duration: 0.20, bounce: 0.0),
                value: configuration.isPressed
            )
    }
}

/// The pill itself, or with `placeholder` only the room it takes.
struct OnboardingContinuePill: View {
    let spec: OnboardingContinueButton
    var placeholder = false

    /// Smooth, critically damped spring for capsule width/position morphs
    /// when the title changes (e.g. "Continue" → "Enable Accessibility" →
    /// "Allow Microphone" → "Finish").
    static let morphSpring: Animation = .spring(duration: 0.34, bounce: 0.0)

    var body: some View {
        if self.placeholder {
            self.label.hidden().accessibilityHidden(true)
        } else {
            self.button
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var lit: Bool { self.hovering && self.spec.isEnabled }

    private var button: some View {
        Button(action: self.press) {
            self.label
                .background(
                    LinearGradient(
                        colors: self.lit
                            ? [OnboardingTheme.pill.opacity(0.90), OnboardingTheme.pill.opacity(0.82)]
                            : [OnboardingTheme.pill, OnboardingTheme.pill.opacity(0.94)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [OnboardingTheme.pill.opacity(0.95), OnboardingTheme.pill.opacity(0.45)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.38), radius: 12, y: 6)
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                .animation(self.reduceMotion ? nil : Self.morphSpring, value: self.spec.title)
        }
        .buttonStyle(OnboardingPillButtonStyle(reduceMotion: self.reduceMotion))
        .focused(self.$focused)
        .overlay {
            if self.focused {
                Capsule().stroke(OnboardingTheme.pillLabel.opacity(0.85), lineWidth: 2).padding(-4)
            }
        }
        .opacity(self.spec.isEnabled ? 1 : 0.6)
        .disabled(!self.spec.isEnabled)
        .onHover { self.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: self.lit)
        .animation(self.reduceMotion ? nil : Self.morphSpring, value: self.spec.title)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(self.spec.title)
        .accessibilityHint("Press Enter to continue.")
    }

    private var label: some View {
        HStack(spacing: 10) {
            OnboardingMorphLabel(self.spec.title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(OnboardingTheme.pillLabel)
        .padding(.horizontal, 20)
        .frame(height: 36)
        .fixedSize()
        .contentShape(Capsule())
    }

    private func press() {
        guard self.spec.isEnabled else { return }
        self.spec.action()
    }
}

/// The pill's label. A change of wording crossfades cleanly inside the
/// spring-morphing capsule without jumping or clipping.
struct OnboardingMorphLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(self.text)
            .contentTransition(.opacity)
            .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.20), value: self.text)
    }
}
