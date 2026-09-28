//
//  FlowBarModel.swift
//  Oto
//
//  Slice 6B: the pill's @MainActor observable. Holds the polled projection,
//  the smoothed display sample, and transient notices. Smoothing lives here
//  (analyzer publishes raw band levels; the model shapes them with
//  attack/release) so frozen motion, silence, and notices all funnel
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
    private(set) var sample = BarSample.silence
    /// Set by the controller from the Reduce Motion indicator each poll.
    /// Frozen: levels ignored (bars hold statically), animations off.
    var motionFrozen = false

    private var smoothed = [Float](repeating: 0, count: VisualizerMath.barCount)

    init() {}

    // MARK: - Poll inputs (controller only)

    func update(projection: FlowBarProjection) {
        self.projection = projection
    }

    /// Raw analyzer band levels → smoothed display sample. Frozen motion
    /// ignores input (the pill holds its last shape, statically).
    /// Per-band smoothing first (voice character), then neighbor coupling
    /// (bars move as one wave), then the floor-lift display mapping.
    func applyLevels(_ levels: [Float], tick: UInt64) {
        guard !motionFrozen else { return }
        for i in 0..<VisualizerMath.barCount {
            let target = i < levels.count ? levels[i] : 0
            smoothed[i] = VisualizerMath.smoothStep(current: smoothed[i], target: target)
        }
        sample = BarSample(
            values: VisualizerMath.couple(smoothed).map(VisualizerMath.displayValue),
            tick: tick
        )
    }

    /// Post-stop guarantee: reads are silent. Instant zero (the pill is
    /// already leaving bars for dots/flash — decay would lag the state).
    func publishSilence() {
        smoothed = [Float](repeating: 0, count: VisualizerMath.barCount)
        sample = .silence
    }
}
