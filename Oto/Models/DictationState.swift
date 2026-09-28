//
//  DictationState.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import CoreGraphics
import Foundation

/// Which user gesture owns the session. Both modes share one coordinator
/// and one finalization/insertion pipeline (Docs/OTO_REBUILD_PLAN/02).
/// Plain value semantics: equality is `nonisolated` so the background
/// coordinator actor can use it without a MainActor hop (Swift 6, default
/// MainActor isolation).
enum InteractionMode: Equatable, Sendable, Codable {
    case holdToTalk
    case handsFree

    nonisolated static func == (lhs: InteractionMode, rhs: InteractionMode) -> Bool {
        switch (lhs, rhs) {
        case (.holdToTalk, .holdToTalk):
            return true
        case (.handsFree, .handsFree):
            return true
        default:
            return false
        }
    }
}

/// The application that was frontmost when dictation began. Captured once
/// at session start; never re-resolved at insertion time.
struct TargetApplication: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let windowIdentifier: String?
    /// Display the focused window was on (Phase 4, best-effort). Consumed by
    /// the Flow Bar in Phase 6; nil means unknown, never a blocker.
    let displayID: CGDirectDisplayID?

    /// Plain snapshot construction: `nonisolated` so background capture
    /// (Swift 6) can build targets without a MainActor hop.
    nonisolated init(
        bundleIdentifier: String? = nil,
        processIdentifier: pid_t? = nil,
        windowIdentifier: String? = nil,
        displayID: CGDirectDisplayID? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.displayID = displayID
    }

    // Explicit: the fake compares pid identity from actor isolation
    // (Swift 6, default MainActor isolation).
    nonisolated static func == (lhs: TargetApplication, rhs: TargetApplication) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.processIdentifier == rhs.processIdentifier
            && lhs.windowIdentifier == rhs.windowIdentifier
            && lhs.displayID == rhs.displayID
    }
}

/// Immutable for the lifetime of a recording (02 §Session context).
struct SessionContext: Equatable, Sendable {
    // Explicit: compared (and constructed) across domains — coordinator,
    // tests, and `@Sendable` predicates that inherit no isolation (Swift 6).
    nonisolated static func == (lhs: SessionContext, rhs: SessionContext) -> Bool {
        lhs.id == rhs.id
            && lhs.startedAt == rhs.startedAt
            && lhs.target == rhs.target
            && lhs.targetScreen == rhs.targetScreen
            && lhs.interaction == rhs.interaction
    }

    let id: UUID
    let startedAt: ContinuousClock.Instant
    let target: TargetApplication
    let targetScreen: CGDirectDisplayID?
    let interaction: InteractionMode
}

/// Terminal or recoverable failure. Only finals, never partials, lead here.
enum DictationFailure: Equatable, Sendable {
    // Explicit: compared across domains (Swift 6; see SessionContext).
    nonisolated static func == (lhs: DictationFailure, rhs: DictationFailure) -> Bool {
        switch (lhs, rhs) {
        case (.audioCapture(let a), .audioCapture(let b)):
            return a == b
        case (.speechPreparation(let a), .speechPreparation(let b)):
            return a == b
        case (.microphoneDenied, .microphoneDenied),
             (.targetGone, .targetGone),
             (.noTextField, .noTextField),
             (.noAudioCaptured, .noAudioCaptured):
            return true
        case (.insertionFailed(let a), .insertionFailed(let b)):
            return a == b
        default:
            return false
        }
    }

    case audioCapture(String)
    case speechPreparation(String)
    case microphoneDenied
    case targetGone
    case insertionFailed(String)
    /// Focus without an editable field at finalize time (Finder, desktop,
    /// viewer): nowhere to paste. Kept transcript + catcher, never void.
    case noTextField
    /// Zero buffers reached the feeder all session (dead/zombie mic).
    /// Fails loud instead of completing empty (bt-sco-flap.md).
    case noAudioCaptured
}

/// Coordinator-owned session state (Docs/START_HERE_PRODUCT.md canonical
/// enum; `starting` is 02's `preparing`). Only the coordinator mutates it.
enum DictationState: Equatable, Sendable {
    // Explicit: `@Sendable` predicates (e.g. test wait-helpers) inherit no
    // isolation, so the synthesized conformance is unusable there (Swift 6).
    nonisolated static func == (lhs: DictationState, rhs: DictationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.starting(let a), .starting(let b)):
            return a == b
        case (.recording(let a), .recording(let b)):
            return a == b
        case (.finalizing(let a), .finalizing(let b)):
            return a == b
        case (.inserting(let a), .inserting(let b)):
            return a == b
        case (.completed(let a), .completed(let b)):
            return a == b
        case (.cancelled(let a), .cancelled(let b)):
            return a == b
        case (.failed(let a, let af), .failed(let b, let bf)):
            return a == b && af == bf
        default:
            return false
        }
    }

    case idle
    case starting(SessionContext)
    case recording(SessionContext)
    case finalizing(SessionContext)
    case inserting(SessionContext)
    case completed(SessionContext)
    case cancelled(SessionContext)
    case failed(SessionContext?, DictationFailure)

    /// States from which a new session may begin. Pure switch, no state
    /// access: `nonisolated` for the background coordinator (Swift 6).
    nonisolated var isTerminal: Bool {
        switch self {
        case .idle, .completed, .cancelled, .failed:
            return true
        case .starting, .recording, .finalizing, .inserting:
            return false
        }
    }

    /// States from which `finish` may proceed (02 hold-to-talk rules 3–4).
    /// Pure switch: `nonisolated` (see `isTerminal`).
    nonisolated var canFinish: Bool {
        switch self {
        case .starting, .recording:
            return true
        case .idle, .finalizing, .inserting, .completed, .cancelled, .failed:
            return false
        }
    }

    /// Active (non-terminal, non-idle) states cancellable by the user.
    /// Pure switch: `nonisolated` (see `isTerminal`).
    nonisolated var canCancel: Bool {
        switch self {
        case .starting, .recording, .finalizing, .inserting:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }
}
