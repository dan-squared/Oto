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

/// The pill itself, or with `placeholder` only the room it takes.
struct OnboardingContinuePill: View {
    let spec: OnboardingContinueButton
    var placeholder = false

    var body: some View {
        if self.placeholder {
            self.label.hidden().accessibilityHidden(true)
        } else {
            self.button
                .id(self.spec.title)
        }
    }

    @FocusState private var focused: Bool
    @State private var hovering = false

    private var lit: Bool { self.hovering && self.spec.isEnabled }

    private var button: some View {
        Button(action: self.press) {
            self.label
                .background(
                    LinearGradient(
                        colors: self.lit
                            ? [Color(white: 0.90), Color(white: 0.82)]
                            : [Color(white: 1), Color(white: 0.94)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.95), .white.opacity(0.45)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.38), radius: 12, y: 6)
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .focused(self.$focused)
        .overlay {
            if self.focused {
                Capsule().stroke(.white.opacity(0.85), lineWidth: 2).padding(-4)
            }
        }
        .opacity(self.spec.isEnabled ? 1 : 0.6)
        .allowsHitTesting(self.spec.isEnabled)
        .onHover { self.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: self.lit)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(self.spec.title)
        .accessibilityHint("Press Enter to continue.")
    }

    private var label: some View {
        HStack(spacing: 10) {
            OnboardingMorphLabel(self.spec.title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.black)
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

/// The pill's label. A change of wording fades where it stands rather than
/// travelling up or down.
struct OnboardingMorphLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(self.text)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: self.text)
    }
}
