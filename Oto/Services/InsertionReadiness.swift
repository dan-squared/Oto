//
//  InsertionReadiness.swift
//  Oto
//
//  Activation is a condition, not a duration. v6 posted after a blind
//  `reactivateSettle` sleep; on a Space switch, a full-screen app or a cold
//  Electron start the target is not frontmost yet, and the only outcome was
//  "switch back and press Retry". The wait now watches the actual
//  precondition (frontmost pid) and stays ADVISORY: the budget expiring still
//  posts, because the pre-post frontmost guard owns the refusal with its
//  better message. A readiness wait must never strand a valid session.
//

import Foundation

enum InsertionReadiness {
    /// Pure decision (unit-tested).
    ///
    /// - frontmost and past the floor → post now
    /// - budget spent → post anyway (advisory only)
    /// - otherwise → keep waiting
    ///
    /// The floor exists because `NSRunningApplication.isActive` can turn true
    /// a few milliseconds before the window server routes key events.
    nonisolated static func shouldPost(
        elapsedNanoseconds: UInt64,
        floor: UInt64,
        budget: UInt64,
        isFrontmost: Bool
    ) -> Bool {
        if elapsedNanoseconds >= budget { return true }
        return isFrontmost && elapsedNanoseconds >= floor
    }
}
