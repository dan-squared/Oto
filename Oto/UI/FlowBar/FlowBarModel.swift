//
//  FlowBarModel.swift
//  Oto
//
//  Slice 6B: the pill's @MainActor observable. Holds the polled projection,
//  the smoothed display sample, and transient notices. Smoothing lives here
//  (analyzer publishes raw band levels; the model shapes them with
//  attack/release) so frozen motion, silence, and notices all funnel
//  through one @MainActor owner. Intents go to the coordinator only.
//

import Foundation

/// Established shape (@Observable @MainActor, HistoryStore precedent).
@Observable @MainActor
final class FlowBarModel {
    private(set) var projection = FlowBarProjection(
        state: .hidden, sessionID: nil, handsFreeCaption: false,
        message: nil, showsSettingsLink: false, recoveryAvailable: false
    )
    private(set) var sample = BarSample.silence
    /// Transient pill copy (auto-copy confirmation). Overrides content and
    /// widens the pill while set; the controller clears it on deadline.
    private(set) var notice: String?
    /// Set by the controller from the Reduce Motion indicator each poll.
    /// Frozen: levels ignored (bars hold), tick held (chase/spinner still).
    var motionFrozen = false

    private var smoothed = [Float](repeating: 0, count: VisualizerMath.barCount)
    private let coordinator: DictationCoordinator

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Poll inputs (controller only)

    func update(projection: FlowBarProjection) {
        self.projection = projection
    }

    /// Raw analyzer band levels → smoothed display sample. Frozen motion
    /// ignores input (the pill holds its last shape, statically).
    func applyLevels(_ levels: [Float], tick: UInt64) {
        guard !motionFrozen else { return }
        for i in 0..<VisualizerMath.barCount {
            let target = i < levels.count ? levels[i] : 0
            smoothed[i] = VisualizerMath.smoothStep(current: smoothed[i], target: target)
        }
        sample = BarSample(
            values: smoothed.map(VisualizerMath.displayValue),
            tick: tick
        )
    }

    /// Post-stop guarantee: reads are silent. Instant zero (the pill is
    /// already leaving bars for dots/flash — decay would lag the state).
    func publishSilence() {
        smoothed = [Float](repeating: 0, count: VisualizerMath.barCount)
        sample = .silence
    }

    func showNotice(_ message: String) {
        notice = message
    }

    func clearNotice() {
        notice = nil
    }

    // MARK: - Intents (view buttons → coordinator, session-checked there)

    func stop() async {
        guard let id = projection.sessionID else { return }
        await coordinator.finish(id)
    }

    func cancel() async {
        guard let id = projection.sessionID else { return }
        await coordinator.cancel(id)
    }
}
