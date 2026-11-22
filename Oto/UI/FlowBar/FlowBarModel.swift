//
//  FlowBarModel.swift
//  Oto
//
//  Slice 6B: the pill's @MainActor observable. Holds the polled projection,
//  the analyzer's latest loudness target, and transient notices. Smoothing
//  lives here: the analyzer publishes a raw target at buffer cadence, the
//  display link moves a private smoothed value per frame so the wave is
//  frame-rate independent. Frozen motion, silence, and notices all funnel
//  through one @MainActor owner. Button-free: the model carries no intents
//  (stop/cancel/finish stay on the shortcut layer + coordinator).
//

import Foundation

/// Established shape (@Observable @MainActor, HistoryStore precedent).
@Observable @MainActor
final class FlowBarModel {
    private(set) var projection = FlowBarProjection(
        state: .hidden, sessionID: nil, handsFreeCaption: false,
        recoveryAvailable: false
    )
    /// Latest analyzer publish (target level + tick). Poll-path reads only.
    private(set) var sample = BarSample.silence
    /// Set by the controller from the Reduce Motion indicator each poll.
    /// Frozen: levels ignored (bars hold statically), animations off.
    var motionFrozen = false

    // Per-frame clock state: the display link touches these at 60/120 Hz,
    // so they are @ObservationIgnored — a notify per vsync would churn
    // SwiftUI observers for nothing.
    @ObservationIgnored private var targetLevel: Float = 0
    @ObservationIgnored private var smoothedLevel: Float = 0
    @ObservationIgnored private var lastAdvanceTime: Double?

    init() {}

    // MARK: - Poll inputs (controller only)

    func update(projection: FlowBarProjection) {
        self.projection = projection
    }

    /// Analyzer target (buffer cadence, ~12 Hz). Frozen motion ignores input
    /// (the pill holds its last shape, statically).
    func ingestLevel(_ level: Float, tick: UInt64) {
        guard !motionFrozen else { return }
        targetLevel = min(1, max(0, level))
        sample = BarSample(level: targetLevel, tick: tick)
    }

    /// One display frame: smooth toward the analyzer target on the FRAME
    /// clock and return the level the bars should draw. `dt` comes from
    /// display-link timestamps, clamped to 1/240…0.1 s; the first frame
    /// assumes 60 fps so it never jumps. Attack/release keepers live in
    /// VisualizerMath (~98 ms to 90 % rising, ~200 ms falling).
    func advance(to time: Double) -> Float {
        defer { lastAdvanceTime = time }
        guard !motionFrozen else { return smoothedLevel }
        let dt: Double
        if let last = lastAdvanceTime {
            dt = min(0.1, max(1.0 / 240, time - last))
        } else {
            dt = 1.0 / 60
        }
        smoothedLevel = VisualizerMath.smoothLevel(
            current: smoothedLevel, target: targetLevel, dt: dt
        )
        return smoothedLevel
    }

    /// Post-stop guarantee: reads are silent. Instant zero (the pill is
    /// already leaving bars for dots/flash — decay would lag the state).
    func publishSilence() {
        targetLevel = 0
        smoothedLevel = 0
        lastAdvanceTime = nil
        sample = .silence
    }
}
