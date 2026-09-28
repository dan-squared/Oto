//
//  SpeechService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Narrow speech seam: finals only. Real implementation (SpeechAnalyzer +
/// SpeechTranscriber) lands in Phase 2; partials are display-only and never
/// reach this boundary (02 §Apple Speech workflow).
protocol SpeechServing: Sendable {
    func prepare() async throws
    func finish() async throws -> String
    func cancel() async
}

/// Scriptable fake for Phase 1 coordinator tests. The preparation gate lets
/// tests hold the session in `starting` to prove release-during-preparation
/// means "finish when ready", not cancel (02 hold-to-talk rule 4).
actor FakeSpeechService: SpeechServing {
    struct PreparationError: Error, Sendable {}
    struct FinalizationError: Error, Sendable {}

    /// Text returned by `finish()`.
    var finalText: String
    /// When set, `prepare()` throws this after the gate opens.
    var prepareError: (any Error)?
    /// When set, `finish()` throws this.
    var finishError: (any Error)?

    private(set) var prepareCalls = 0
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0

    /// When false, `prepare()` suspends until `openPrepareGate()`.
    private var prepareGateOpen: Bool
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    /// When false, `finish()` suspends until `openFinishGate()` (audit:
    /// proves cancel-wins over in-flight finalize, the exact window the
    /// terminal-state reorder protects).
    private var finishGateOpen: Bool
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        finalText: String = "",
        prepareError: (any Error)? = nil,
        finishError: (any Error)? = nil,
        prepareGateOpen: Bool = true,
        finishGateOpen: Bool = true
    ) {
        self.finalText = finalText
        self.prepareError = prepareError
        self.finishError = finishError
        self.prepareGateOpen = prepareGateOpen
        self.finishGateOpen = finishGateOpen
    }

    func prepare() async throws {
        prepareCalls += 1
        if !prepareGateOpen {
            await withCheckedContinuation { continuation in
                prepareWaiters.append(continuation)
            }
        }
        if let prepareError {
            throw prepareError
        }
    }

    func finish() async throws -> String {
        finishCalls += 1
        if !finishGateOpen {
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
            }
        }
        if let finishError {
            throw finishError
        }
        return finalText
    }

    func cancel() async {
        cancelCalls += 1
    }

    func closePrepareGate() {
        prepareGateOpen = false
    }

    func openPrepareGate() {
        prepareGateOpen = true
        let waiters = prepareWaiters
        prepareWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func openFinishGate() {
        finishGateOpen = true
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
