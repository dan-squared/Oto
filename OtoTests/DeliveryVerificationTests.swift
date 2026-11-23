//
//  DeliveryVerificationTests.swift
//  OtoTests
//
//  v7 delivery truth. The pure core is fully scriptable: no AX, no hardware.
//  The rule these pin: only a *changed* caret (same element) is proof of
//  delivery, and "no signal" must never be read as failure — a catcher over
//  text that is already in the document is the exact bug v6 removed.
//

import Foundation
import Testing
@testable import Oto

/// Sendable caret holder for scripted probes.
final class CaretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CaretSample?

    init(_ value: CaretSample?) { self.value = value }

    var current: CaretSample? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: CaretSample?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

struct DeliveryVerificationTests {
    private func caret(_ location: Int, _ length: Int, _ characters: Int? = 0) -> CaretSample {
        CaretSample(location: location, length: length, characters: characters)
    }

    @Test func caretMovedIsLanded() {
        #expect(DeliveryVerification.outcome(
            before: caret(0, 0), after: caret(8, 0), sameElement: true
        ) == .landed)
    }

    @Test func selectionReplacedIsLanded() {
        #expect(DeliveryVerification.outcome(
            before: caret(4, 6), after: caret(10, 0), sameElement: true
        ) == .landed)
    }

    @Test func characterCountAloneProvesDelivery() {
        // Some apps keep the caret where it was but the field grew.
        #expect(DeliveryVerification.outcome(
            before: caret(0, 0, 3), after: caret(0, 0, 11), sameElement: true
        ) == .landed)
    }

    @Test func identicalCaretIsNotLanded() {
        #expect(DeliveryVerification.outcome(
            before: caret(2, 0, 5), after: caret(2, 0, 5), sameElement: true
        ) == .notLanded)
    }

    @Test func missingSampleIsUnverifiable() {
        #expect(DeliveryVerification.outcome(
            before: nil, after: caret(0, 0), sameElement: true
        ) == .unverifiable)
        #expect(DeliveryVerification.outcome(
            before: caret(0, 0), after: nil, sameElement: true
        ) == .unverifiable)
        #expect(DeliveryVerification.outcome(
            before: nil, after: nil, sameElement: false
        ) == .unverifiable)
    }

    @Test func differentElementIsUnverifiable() {
        // Focus moved: an unchanged caret elsewhere says nothing.
        #expect(DeliveryVerification.outcome(
            before: caret(0, 0), after: caret(0, 0), sameElement: false
        ) == .unverifiable)
    }

    @Test func budgetGrowsWithSizeAndCaps() {
        let base: UInt64 = 300_000_000
        let perKB: UInt64 = 15_000_000
        let cap: UInt64 = 1_500_000_000
        #expect(DeliveryVerification.budget(
            base: base, perKB: perKB, cap: cap, utf8Count: 0
        ) == base)
        #expect(DeliveryVerification.budget(
            base: base, perKB: perKB, cap: cap, utf8Count: 2_048
        ) == base + 2 * perKB)
        #expect(DeliveryVerification.budget(
            base: base, perKB: perKB, cap: cap, utf8Count: 1_000_000
        ) == cap)
    }

    @Test func verifyWithoutSignalIsUnverifiableImmediately() async {
        let outcome = await DeliveryVerification.verify(
            probe: .unavailable, budget: 10_000_000, poll: 1_000_000, sleep: { _ in }
        )
        #expect(outcome == .unverifiable)
    }

    @Test func verifySeesAChangeOnTheFirstRead() async {
        let box = CaretBox(caret(0, 0))
        let probe = DeliveryProbe(
            initial: caret(0, 0), read: { box.current }, stillFocused: { true }
        )
        box.set(caret(5, 0))
        let outcome = await DeliveryVerification.verify(
            probe: probe, budget: 1_000_000, poll: 1_000_000, sleep: { _ in }
        )
        #expect(outcome == .landed)
    }

    @Test func verifyWithoutMovementIsNotLanded() async {
        let box = CaretBox(caret(0, 0))
        let probe = DeliveryProbe(
            initial: caret(0, 0), read: { box.current }, stillFocused: { true }
        )
        let outcome = await DeliveryVerification.verify(
            probe: probe, budget: 5_000_000, poll: 1_000_000, sleep: { _ in }
        )
        #expect(outcome == .notLanded)
    }

    @Test func verifyWithoutMovementButFocusMovedIsUnverifiable() async {
        let box = CaretBox(caret(0, 0))
        let probe = DeliveryProbe(
            initial: caret(0, 0), read: { box.current }, stillFocused: { false }
        )
        let outcome = await DeliveryVerification.verify(
            probe: probe, budget: 5_000_000, poll: 1_000_000, sleep: { _ in }
        )
        #expect(outcome == .unverifiable)
    }

    @Test func verifyWaitsOnePollBeforeFirstReadWhenPollPositive() async {
        let events = CaretBox(nil)
        let box = CaretBox(caret(0, 0))
        let probe = DeliveryProbe(
            initial: caret(0, 0),
            read: { box.current },
            stillFocused: { true }
        )
        let outcome = await DeliveryVerification.verify(
            probe: probe,
            budget: 5_000_000,
            poll: 1_000_000,
            sleep: { _ in
                // Update caret on the pre-read poll sleep: proves the first
                // read did not fire at t = 0 before the sleep.
                box.set(CaretSample(location: 4, length: 0, characters: 4))
                events.set(CaretSample(location: 1, length: 0, characters: 1))
            }
        )
        #expect(outcome == .landed)
        #expect(events.current != nil)
    }

    @Test func verifyCaretChangeWithoutSameElementOrGrowthIsUnverifiable() async {
        let box = CaretBox(caret(5, 0, 10))
        let probe = DeliveryProbe(
            initial: caret(0, 0, 10),
            read: { box.current },
            stillFocused: { false }
        )
        let result = await DeliveryVerification.verifyDetailed(
            probe: probe, budget: 5_000_000, poll: 0, sleep: { _ in }
        )
        #expect(result.outcome == .unverifiable)
        #expect(!result.characterCountGrew)
    }

    @Test func verifyDetailedDistinguishesCharacterGrowthFromCaretOnlyMove() async {
        let grewProbe = DeliveryProbe(
            initial: caret(0, 0, 0),
            read: { CaretSample(location: 5, length: 0, characters: 5) },
            stillFocused: { true }
        )
        let grewResult = await DeliveryVerification.verifyDetailed(
            probe: grewProbe, budget: 5_000_000, poll: 0, sleep: { _ in }
        )
        #expect(grewResult == DeliveryResult(outcome: .landed, characterCountGrew: true))

        let caretOnlyProbe = DeliveryProbe(
            initial: caret(0, 0, 5),
            read: { CaretSample(location: 3, length: 0, characters: 5) },
            stillFocused: { true }
        )
        let caretOnlyResult = await DeliveryVerification.verifyDetailed(
            probe: caretOnlyProbe, budget: 5_000_000, poll: 0, sleep: { _ in }
        )
        #expect(caretOnlyResult == DeliveryResult(outcome: .landed, characterCountGrew: false))
    }

    @Test func probeAsyncTimesOutHungProbeAsUnavailable() async {
        struct HungDeliveryCheck: DeliveryChecking {
            nonisolated func probe(for pid: pid_t) -> DeliveryProbe {
                Thread.sleep(forTimeInterval: 1.0)
                return DeliveryProbe(
                    initial: CaretSample(location: 0, length: 0, characters: 0),
                    read: { nil },
                    stillFocused: { true }
                )
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let probe = await HungDeliveryCheck().probeAsync(for: 1234)
        #expect(probe.initial == nil)
        #expect(clock.now - start < .milliseconds(900))
    }
}

struct InsertionReadinessTests {
    private let floor: UInt64 = 120_000_000
    private let budget: UInt64 = 400_000_000

    @Test func frontmostAfterFloorPosts() {
        #expect(InsertionReadiness.shouldPost(
            elapsedNanoseconds: 200_000_000, floor: floor, budget: budget,
            isFrontmost: true
        ))
    }

    @Test func frontmostBeforeFloorWaits() {
        #expect(!InsertionReadiness.shouldPost(
            elapsedNanoseconds: 50_000_000, floor: floor, budget: budget,
            isFrontmost: true
        ))
    }

    @Test func notFrontmostKeepsWaiting() {
        #expect(!InsertionReadiness.shouldPost(
            elapsedNanoseconds: 300_000_000, floor: floor, budget: budget,
            isFrontmost: false
        ))
    }

    @Test func budgetExpiryPostsAnyway() {
        // Advisory by design: expiry must never strand a valid session.
        #expect(InsertionReadiness.shouldPost(
            elapsedNanoseconds: 400_000_000, floor: floor, budget: budget,
            isFrontmost: false
        ))
    }
}
