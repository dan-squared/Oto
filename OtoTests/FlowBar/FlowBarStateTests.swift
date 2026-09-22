//
//  FlowBarStateTests.swift
//  OtoTests
//
//  Slice 6B/6C1: the projection + routing contracts. Every DictationState
//  maps to exactly one pill case; recovery-owned failures NEVER reach the
//  pill (modal/auto-copy own them); success carries no text (no "Done",
//  no "insert", no checkmark — insertion is the confirmation).
//

import CoreGraphics
import Foundation
import Testing
@testable import Oto

@MainActor
struct FlowBarStateTests {
    private func context(
        interaction: InteractionMode = .holdToTalk,
        targetScreen: CGDirectDisplayID? = nil
    ) -> SessionContext {
        SessionContext(
            id: UUID(),
            startedAt: ContinuousClock().now,
            target: TargetApplication(bundleIdentifier: "com.example.App", processIdentifier: 42),
            targetScreen: targetScreen,
            interaction: interaction
        )
    }

    @Test func idleProjectsHidden() {
        let projection = FlowBarProjection.project(.idle, recoveryAvailable: false)
        #expect(projection.state == .hidden)
        #expect(projection.sessionID == nil)
        #expect(projection.message == nil)
    }

    @Test func activeStatesProjectOneToOne() {
        let ctx = context()
        #expect(FlowBarProjection.project(.starting(ctx), recoveryAvailable: false).state == .preparing)
        #expect(FlowBarProjection.project(.recording(ctx), recoveryAvailable: false).state == .recording)
        #expect(FlowBarProjection.project(.finalizing(ctx), recoveryAvailable: false).state == .finalizing)
        #expect(FlowBarProjection.project(.inserting(ctx), recoveryAvailable: false).state == .inserting)
        #expect(FlowBarProjection.project(.completed(ctx), recoveryAvailable: false).state == .successFlash)
        #expect(FlowBarProjection.project(.cancelled(ctx), recoveryAvailable: false).state == .cancelledFlash)
    }

    @Test func sessionIDPassesThroughForIntents() {
        let ctx = context()
        #expect(FlowBarProjection.project(.recording(ctx), recoveryAvailable: false).sessionID == ctx.id)
        #expect(FlowBarProjection.project(.completed(ctx), recoveryAvailable: false).sessionID == ctx.id)
    }

    @Test func handsFreeMarksRecordingOnly() {
        let handsFree = context(interaction: .handsFree)
        let talk = context(interaction: .holdToTalk)
        #expect(FlowBarProjection.project(.recording(handsFree), recoveryAvailable: false).handsFreeCaption)
        #expect(!FlowBarProjection.project(.recording(talk), recoveryAvailable: false).handsFreeCaption)
        #expect(!FlowBarProjection.project(.starting(handsFree), recoveryAvailable: false).handsFreeCaption)
    }

    @Test func successCarriesNoText() {
        // Insertion is the confirmation. Any wording here reopens the
        // "did it insert?" debate by test — so the test forbids text.
        let projection = FlowBarProjection.project(.completed(context()), recoveryAvailable: false)
        #expect(projection.message == nil)
        #expect(!projection.showsSettingsLink)
    }

    @Test func recoveryFailuresNeverReachThePill() {
        let ctx = context()
        for failure: DictationFailure in [.targetGone, .insertionFailed("nope")] {
            let projection = FlowBarProjection.project(.failed(ctx, failure), recoveryAvailable: true)
            #expect(projection.state == .hidden, "failure \(failure) must route to modal/auto-copy, not the pill")
        }
    }

    @Test func terminalFailuresHoldWithHonestCopy() {
        let ctx = context()
        let mic = FlowBarProjection.project(.failed(ctx, .microphoneDenied), recoveryAvailable: false)
        #expect(mic.state == .failure)
        #expect(mic.message?.contains("Microphone") == true)
        #expect(mic.showsSettingsLink)

        let prep = FlowBarProjection.project(
            .failed(ctx, .speechPreparation("assets missing")), recoveryAvailable: false
        )
        #expect(prep.state == .failure)
        #expect(prep.showsSettingsLink)

        let audio = FlowBarProjection.project(
            .failed(ctx, .audioCapture("boom")), recoveryAvailable: false
        )
        #expect(audio.state == .failure)
        #expect(!audio.showsSettingsLink)

        let silent = FlowBarProjection.project(.failed(ctx, .noAudioCaptured), recoveryAvailable: false)
        #expect(silent.state == .failure)
        #expect(silent.message?.contains("microphone") == true)
    }

    @Test func nilContextFailureStillProjects() {
        // .failed(nil,_) is legal (never force-unwrap, §5E).
        let projection = FlowBarProjection.project(.failed(nil, .microphoneDenied), recoveryAvailable: false)
        #expect(projection.state == .failure)
        #expect(projection.sessionID == nil)
    }

    // MARK: - RecoveryRouter

    @Test func routerSendsRecoveryFailuresToModalOrAutoCopy() {
        let ctx = context()
        let modal = RecoveryRouter.route(
            .failed(ctx, .targetGone), recoveryText: "kept words", modalEnabled: true
        )
        #expect(modal == .catcher(sessionKey: ctx.id.uuidString, text: "kept words"))
        let auto = RecoveryRouter.route(
            .failed(ctx, .insertionFailed("x")), recoveryText: "kept words", modalEnabled: false
        )
        #expect(auto == .autoCopy(sessionKey: ctx.id.uuidString, text: "kept words"))
    }

    @Test func routerStaysSilentOtherwise() {
        let ctx = context()
        #expect(RecoveryRouter.route(.recording(ctx), recoveryText: "x", modalEnabled: true) == nil)
        #expect(RecoveryRouter.route(.completed(ctx), recoveryText: "x", modalEnabled: true) == nil)
        #expect(RecoveryRouter.route(.failed(ctx, .microphoneDenied), recoveryText: "x", modalEnabled: true) == nil)
        // No kept text, no surface — even for recovery-owned failures.
        #expect(RecoveryRouter.route(.failed(ctx, .targetGone), recoveryText: nil, modalEnabled: true) == nil)
        #expect(RecoveryRouter.route(.failed(ctx, .targetGone), recoveryText: "", modalEnabled: false) == nil)
    }

    @Test func routerKeysNilContextStably() {
        // Nil-context failures still fire exactly once per transition: the
        // controller compares consecutive keys, so the key must be stable.
        let first = RecoveryRouter.route(.failed(nil, .targetGone), recoveryText: "x", modalEnabled: true)
        let second = RecoveryRouter.route(.failed(nil, .targetGone), recoveryText: "x", modalEnabled: true)
        #expect(first == second)
        #expect(first?.sessionKey == "nil-context")
    }
}
