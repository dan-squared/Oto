//
//  FlowBarState.swift
//  Oto
//
//  Slice 6B: payload-free projection from coordinator state to pill.
//  The enum carries NO level/partial/text payloads (02's recording has no
//  producer — `onPartial` is unwired in AppleSpeechService). Everything the
//  view needs beyond the case (hands-free marker, failure copy, session
//  identity for intents) rides the sibling `FlowBarProjection`, computed by
//  the pure `project()` below — headless-tested, no window needed.
//
//  Recovery routing (6C1) is a SEPARATE pure function (`RecoveryRouter`):
//  the pill deliberately shows nothing for targetGone/insertionFailed (the
//  catcher modal or auto-copy owns those) — doubling the surfaces would
//  fork recovery truth.
//

import Foundation

/// Pill cases. Display payloads live on `FlowBarProjection`, never here.
enum FlowBarState: Equatable, Sendable {
    // Explicit: compared from nonisolated contexts (tests, routers) —
    // the synthesized conformance inherits default MainActor isolation
    // (Swift 6) and is unusable there. DictationState.swift precedent.
    nonisolated static func == (lhs: FlowBarState, rhs: FlowBarState) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden), (.preparing, .preparing),
             (.recording, .recording), (.finalizing, .finalizing),
             (.inserting, .inserting):
            return true
        default:
            return false
        }
    }

    case hidden
    case preparing
    case recording
    case finalizing
    case inserting
}

/// Everything one poll snapshot needs: the case, intent identity, and
/// derived display facts. Pure value; `project()` is the only producer.
struct FlowBarProjection: Equatable, Sendable {
    // Explicit nonisolated equality (see FlowBarState above).
    nonisolated static func == (lhs: FlowBarProjection, rhs: FlowBarProjection) -> Bool {
        lhs.state == rhs.state
            && lhs.sessionID == rhs.sessionID
            && lhs.handsFreeCaption == rhs.handsFreeCaption
            && lhs.recoveryAvailable == rhs.recoveryAvailable
    }

    let state: FlowBarState
    /// Intent routing only (Stop/Cancel target this session). Never shown.
    let sessionID: UUID?
    /// Hands-free sessions get a ring marker, never a text caption (the
    /// pill carries no words outside the transient auto-copy notice).
    let handsFreeCaption: Bool
    let recoveryAvailable: Bool

    /// Pure DictationState → projection. `nonisolated`: the controller
    /// calls it on poll results without actor hops (Swift 6 pattern).
    nonisolated static func project(
        _ dictation: DictationState,
        recoveryAvailable: Bool
    ) -> FlowBarProjection {
        switch dictation {
        case .idle:
            return FlowBarProjection(
                state: .hidden, sessionID: nil, handsFreeCaption: false,
                recoveryAvailable: recoveryAvailable
            )
        case .starting(let context):
            return FlowBarProjection(
                state: .preparing, sessionID: context.id,
                handsFreeCaption: false, recoveryAvailable: recoveryAvailable
            )
        case .recording(let context):
            return FlowBarProjection(
                state: .recording, sessionID: context.id,
                handsFreeCaption: context.interaction == .handsFree,
                recoveryAvailable: recoveryAvailable
            )
        case .finalizing(let context):
            return FlowBarProjection(
                state: .finalizing, sessionID: context.id,
                handsFreeCaption: false, recoveryAvailable: recoveryAvailable
            )
        case .inserting(let context):
            return FlowBarProjection(
                state: .inserting, sessionID: context.id,
                handsFreeCaption: false, recoveryAvailable: recoveryAvailable
            )
        case .completed(let context):
            // v6: no end-state pixels. Insertion is the confirmation — the
            // loader melts straight out (controller vanish path).
            return FlowBarProjection(
                state: .hidden, sessionID: context.id,
                handsFreeCaption: false, recoveryAvailable: recoveryAvailable
            )
        case .cancelled(let context):
            // v6: cancel vanishes like success (no monument either).
            return FlowBarProjection(
                state: .hidden, sessionID: context.id,
                handsFreeCaption: false, recoveryAvailable: recoveryAvailable
            )
        case .failed(let context, _):
            // v7: NO failure reaches the pill — errors ruin the pill's
            // UI/UX. Recovery-owned failures route to the catcher modal or
            // auto-copy (6C1, unchanged); everything else is concise menu
            // status (`lastSessionSummary`, e.g. "failed: microphone
            // denied") with Settings one row below. The pill melts out.
            return FlowBarProjection(
                state: .hidden, sessionID: context?.id,
                handsFreeCaption: false,
                recoveryAvailable: recoveryAvailable
            )
        }
    }
}

/// Which recovery surface owns a failed session, if any. Pure routing so
/// the controller fires the modal/auto-copy exactly once per transition
/// (transition detection compares consecutive route keys).
enum RecoveryRoute: Equatable, Sendable {
    // Explicit nonisolated equality (see FlowBarState above).
    nonisolated static func == (lhs: RecoveryRoute, rhs: RecoveryRoute) -> Bool {
        switch (lhs, rhs) {
        case (.catcher(let a, let at), .catcher(let b, let bt)):
            return a == b && at == bt
        case (.autoCopy(let a, let at), .autoCopy(let b, let bt)):
            return a == b && at == bt
        default:
            return false
        }
    }

    case catcher(sessionKey: String, text: String)
    case autoCopy(sessionKey: String, text: String)

    nonisolated var sessionKey: String {
        switch self {
        case .catcher(let key, _), .autoCopy(let key, _): return key
        }
    }
}

enum RecoveryRouter {
    /// Nil for every state except targetGone/insertionFailed WITH kept
    /// text. `modalEnabled` is the `app.Oto.noTargetModal` setting.
    /// `recoveryText` is the coordinator's kept transcript (nil = none).
    nonisolated static func route(
        _ dictation: DictationState,
        recoveryText: String?,
        modalEnabled: Bool
    ) -> RecoveryRoute? {
        guard case .failed(let context, let failure) = dictation else { return nil }
        switch failure {
        case .targetGone, .insertionFailed:
            break
        default:
            return nil
        }
        guard let text = recoveryText, !text.isEmpty else { return nil }
        let key: String
        if let context {
            key = context.id.uuidString
        } else {
            // Session-identity-free failure: key on the failure so the
            // controller still fires exactly once per transition.
            key = "nil-context"
        }
        if modalEnabled {
            return .catcher(sessionKey: key, text: text)
        } else {
            return .autoCopy(sessionKey: key, text: text)
        }
    }
}
