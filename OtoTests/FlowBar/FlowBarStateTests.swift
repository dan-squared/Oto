//
//  FlowBarStateTests.swift
//  OtoTests
//
//  Slice 6B/6C1 (+v7): the projection + routing contracts. Every
//  DictationState maps to exactly one pill case; NO failure reaches the
//  pill (v7 — errors ruin it; modal/auto-copy own recovery failures,
//  concise menu status owns the rest); completion renders no pixels at
//  all (v6 — insertion is the confirmation, the loader just melts out).
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
    }

    @Test func activeStatesProjectOneToOne() {
        let ctx = context()
        #expect(FlowBarProjection.project(.starting(ctx), recoveryAvailable: false).state == .preparing)
        #expect(FlowBarProjection.project(.recording(ctx), recoveryAvailable: false).state == .recording)
        #expect(FlowBarProjection.project(.finalizing(ctx), recoveryAvailable: false).state == .finalizing)
        #expect(FlowBarProjection.project(.inserting(ctx), recoveryAvailable: false).state == .inserting)
        // v6: completion renders no pixels — the loader melts straight out.
        #expect(FlowBarProjection.project(.completed(ctx), recoveryAvailable: false).state == .hidden)
        #expect(FlowBarProjection.project(.cancelled(ctx), recoveryAvailable: false).state == .hidden)
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

    @Test func completionCarriesNoPixels() {
        // Insertion is the confirmation (v6: not even a flash — the loader
        // melts straight out). The projection carries no copy at all.
        let done = FlowBarProjection.project(.completed(context()), recoveryAvailable: false)
        #expect(done.state == .hidden)
        let cancelled = FlowBarProjection.project(.cancelled(context()), recoveryAvailable: false)
        #expect(cancelled.state == .hidden)
    }

    @Test func noFailureReachesThePill() {
        // v7: error copy ruins the pill — EVERY failure projects hidden.
        // Recovery failures route to modal/auto-copy; the rest are concise
        // menu status (`lastSessionSummary`). Session identity still passes
        // through for routing.
        let ctx = context()
        for failure: DictationFailure in [
            .targetGone, .insertionFailed("nope"), .noTextField, .microphoneDenied,
            .speechPreparation("assets missing"), .audioCapture("boom"),
            .noAudioCaptured,
        ] {
            let projection = FlowBarProjection.project(.failed(ctx, failure), recoveryAvailable: true)
            #expect(projection.state == .hidden, "failure \(failure) must never reach the pill")
            #expect(projection.sessionID == ctx.id)
        }
    }

    @Test func nilContextFailureStillProjects() {
        // .failed(nil,_) is legal (never force-unwrap, §5E) — hidden, nil id.
        let projection = FlowBarProjection.project(.failed(nil, .microphoneDenied), recoveryAvailable: false)
        #expect(projection.state == .hidden)
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
        // Void-case divert: no focused field routes exactly like the other
        // recovery failures — modal when enabled, auto-copy when not.
        let voidModal = RecoveryRouter.route(
            .failed(ctx, .noTextField), recoveryText: "void words", modalEnabled: true
        )
        #expect(voidModal == .catcher(sessionKey: ctx.id.uuidString, text: "void words"))
        let voidAuto = RecoveryRouter.route(
            .failed(ctx, .noTextField), recoveryText: "void words", modalEnabled: false
        )
        #expect(voidAuto == .autoCopy(sessionKey: ctx.id.uuidString, text: "void words"))
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
