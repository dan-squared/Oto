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
    /// at begin time.
    func capture() -> TargetApplication
    /// Whether a previously captured target is still alive. Checked at
    /// finalization; a dead target keeps the transcript in recovery and
    /// never falls back to the new frontmost app.
    func isAlive(_ target: TargetApplication) -> Bool
}

/// Scriptable fake for Phase 1 coordinator tests. `frontmost` may be mutated
/// mid-session to simulate app switching; the coordinator must still insert
/// into `stubTarget` (the captured one), never the new frontmost.
actor FakeTargetCapture: TargetCapturing {
    /// The target returned by `capture()` — i.e. what was frontmost at start.
    var stubTarget: TargetApplication
    /// Simulates the live frontmost app. Mutating this mid-session must not
    /// affect where the transcript goes.
    var frontmost: TargetApplication
    /// When false, `isAlive` reports the captured target as dead.
    var capturedTargetAlive = true

    private(set) var captureCalls = 0

    init(stubTarget: TargetApplication) {
        self.stubTarget = stubTarget
        self.frontmost = stubTarget
    }

    func capture() -> TargetApplication {
        captureCalls += 1
        return stubTarget
    }

    func isAlive(_ target: TargetApplication) -> Bool {
        target == stubTarget ? capturedTargetAlive : true
    }

    func setFrontmost(_ target: TargetApplication) {
        frontmost = target
    }

    func setCapturedTargetAlive(_ alive: Bool) {
        capturedTargetAlive = alive
    }
}
