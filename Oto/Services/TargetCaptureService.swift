//
//  TargetCaptureService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Narrow target-capture seam. The target is captured once at session start,
/// before any Oto UI appears, and never re-resolved at insertion time
/// (02 §Session context). Real implementation (NSWorkspace + liveness
/// check) lands in Phase 4.
protocol TargetCapturing: Sendable {
    /// Capture the current target. Called once per session, synchronously
    /// at begin time — hence `nonisolated`: the background coordinator
    /// calls it from a synchronous context (Swift 6). Implementations must
    /// be synchronous and side-effect free beyond the read.
    nonisolated func capture() -> TargetApplication
    /// Whether a previously captured target is still alive. Checked at
    /// finalization; a dead target keeps the transcript in recovery and
    /// never falls back to the new frontmost app. Async by contract:
    /// liveness may involve I/O, and the coordinator already awaits it —
    /// which also keeps actor-backed fakes (Swift 6) natural.
    func isAlive(_ target: TargetApplication) async -> Bool
}

/// Scriptable fake for Phase 1 coordinator tests. Capture is start-pinned
/// by construction (`capture()` always returns `stubTarget`), so a
/// mid-session switch cannot redirect insertion — the same structural
/// guarantee the real service gives by capturing once (audit S1).
actor FakeTargetCapture: TargetCapturing {
    /// The target returned by `capture()` — i.e. what was frontmost at start.
    let stubTarget: TargetApplication
    /// When false, `isAlive` reports the captured target as dead.
    var capturedTargetAlive = true

    init(stubTarget: TargetApplication) {
        self.stubTarget = stubTarget
    }

    nonisolated func capture() -> TargetApplication {
        stubTarget
    }

    func isAlive(_ target: TargetApplication) async -> Bool {
        // Identity, not whole-struct equality: aliveness is about the pid
        // (and this avoids the @MainActor-inferred Equatable conformance,
        // unusable from actor isolation under Swift 6).
        guard target.processIdentifier == stubTarget.processIdentifier else { return true }
        return capturedTargetAlive
    }

    func setCapturedTargetAlive(_ alive: Bool) {
        capturedTargetAlive = alive
    }
}
