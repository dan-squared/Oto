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
enum InteractionMode: Equatable, Sendable, Codable {
    case holdToTalk
    case handsFree
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

    init(
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
}

/// Immutable for the lifetime of a recording (02 §Session context).
struct SessionContext: Equatable, Sendable {
    let id: UUID
    let startedAt: ContinuousClock.Instant
    let target: TargetApplication
    let targetScreen: CGDirectDisplayID?
    let interaction: InteractionMode
}

/// Terminal or recoverable failure. Only finals, never partials, lead here.
enum DictationFailure: Equatable, Sendable {
    case audioCapture(String)
    case speechPreparation(String)
    case microphoneDenied
    case targetGone
    case insertionFailed(String)
}

/// Coordinator-owned session state (Docs/START_HERE_PRODUCT.md canonical
/// enum; `starting` is 02's `preparing`). Only the coordinator mutates it.
enum DictationState: Equatable, Sendable {
    case idle
    case starting(SessionContext)
    case recording(SessionContext)
    case finalizing(SessionContext)
    case inserting(SessionContext)
    case completed(SessionContext)
    case cancelled(SessionContext)
    case failed(SessionContext?, DictationFailure)

    /// States from which a new session may begin.
    var isTerminal: Bool {
        switch self {
        case .idle, .completed, .cancelled, .failed:
            return true
        case .starting, .recording, .finalizing, .inserting:
            return false
        }
    }

    /// States from which `finish` may proceed (02 hold-to-talk rules 3–4).
    var canFinish: Bool {
        switch self {
        case .starting, .recording:
            return true
        case .idle, .finalizing, .inserting, .completed, .cancelled, .failed:
            return false
        }
    }

    /// Active (non-terminal, non-idle) states cancellable by the user.
    var canCancel: Bool {
        switch self {
        case .starting, .recording, .finalizing, .inserting:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }
}
