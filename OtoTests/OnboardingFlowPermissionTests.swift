//
//  OnboardingFlowPermissionTests.swift
//  OtoTests
//
//  The last chapter's Finish gate is a pure table: Accessibility first
//  (the global key and insertion need it), then the microphone. No TCC
//  prompts in tests — only the decision to ask is pinned here.
//

import Testing
@testable import Oto

@MainActor
struct OnboardingFlowPermissionTests {
    @Test func blockerFollowsProductOrder() {
        #expect(OnboardingFlow.blocker(axTrusted: false, mic: .granted) == .accessibility)
        #expect(OnboardingFlow.blocker(axTrusted: false, mic: nil) == .accessibility)
        #expect(OnboardingFlow.blocker(axTrusted: true, mic: nil) == .microphone)
        #expect(OnboardingFlow.blocker(axTrusted: true, mic: .notDetermined) == .microphone)
        #expect(OnboardingFlow.blocker(axTrusted: true, mic: .denied) == .microphone)
        #expect(OnboardingFlow.blocker(axTrusted: true, mic: .granted) == nil)
    }
}
