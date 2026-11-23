//
//  AudioLevelAnalyzer.swift
//  Oto
//
//  Slice 6B: the visualizer's ears. Fed ONLY by forking OtoApp's
//  bufferHandler (`relay.receive` + `box.offer`) — attaching to the relay
//  would DETACH speech (single sink, AudioBufferRelay.swift:72), so the
//  fork is the only low-risk feed. Own converter instance (never shares
//  the speech path's), RMS off the main thread, ~60 Hz immutable publish.
//  `stop()` guarantees silence after (tested).
//
//  One broadband loudness value is the whole model: the pill's wave is a
//  single level shaped by a fixed envelope plus a staggered ripple, not a
//  per-band spectrum. See VisualizerMath.
//
//  Threading: the box is realtime-safe (lock-shaped, @unchecked Sendable,
//  mirrors AudioFeedBox); the engine is confined to the analyzer actor
//  (@unchecked Sendable by confinement, documented); the actor itself runs
//  on the generic pool — RMS never touches the MainActor.
//

import Accelerate
import AVFoundation
import Foundation
import Synchronization

/// Realtime-safe latest-slot for the analyzer. Drop-on-full by construction
/// (overwrite a single `Float?` RMS value, never allocate, never grow, never
/// block). Broadband RMS is sample-rate invariant, so `offer` computes it
/// directly from the incoming `AVAudioPCMBuffer` with zero allocations or
/// `AVAudioConverter` overhead. Unarmed (before `start`, after `stop`) `offer`
/// returns immediately — zero cost outside recording.
nonisolated final class LevelFeedBox: Sendable {
    static let analysisSampleRate: Double = 16_000

    private struct State {
        var armed = false
        var latestRMS: Float?
        var offerFailures = 0
    }

    private let state = Mutex(State())

    init() {}

    func setArmed(_ armed: Bool) {
        state.withLock { s in
            s.armed = armed
            if !armed { s.latestRMS = nil }
        }
    }

    func offer(_ buffer: AVAudioPCMBuffer) {
        guard state.withLock({ $0.armed }) else { return }
        let rms = LevelEngine.rms(buffer)
        state.withLock { s in
            guard s.armed else { return }
            s.latestRMS = rms
        }
    }

    /// Consume-once: the analyzer drains at ~60 Hz; anything not taken is
    /// stale by definition.
    func takeLatest() -> Float? {
        state.withLock { s in
            let rms = s.latestRMS
            s.latestRMS = nil
            return rms
        }
    }

    func failureCount() -> Int {
        state.withLock { $0.offerFailures }
    }
}

/// Whole buffer → broadband RMS → display level 0…1. No FFT, no bands, no
/// sample-rate conversion: loudness is sample-rate invariant and computed
/// directly from Float32 (`vDSP_rmsqv`), Int16, or Int32 in interleaved or
/// non-interleaved layouts with zero allocations.
nonisolated final class LevelEngine: Sendable {
    init() {}

    /// Broadband RMS over the entire buffer across all channels.
    /// Digital silence and empty/unrecognized buffers map to 0, never NaN.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return 0 }
        let isInterleaved = buffer.format.isInterleaved

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return 0 }
            if isInterleaved {
                var value: Float = 0
                vDSP_rmsqv(channels[0], 1, &value, vDSP_Length(frames * channelCount))
                return value.isFinite ? value : 0
            } else if channelCount == 1 {
                var value: Float = 0
                vDSP_rmsqv(channels[0], 1, &value, vDSP_Length(frames))
                return value.isFinite ? value : 0
            } else {
                var meanSquareSum: Float = 0
                for ch in 0..<channelCount {
                    var channelMeanSquare: Float = 0
                    vDSP_measqv(channels[ch], 1, &channelMeanSquare, vDSP_Length(frames))
                    if channelMeanSquare.isFinite {
                        meanSquareSum += channelMeanSquare
                    }
                }
                let combined = (meanSquareSum / Float(channelCount)).squareRoot()
                return combined.isFinite ? combined : 0
            }

        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return 0 }
            let scale = 1.0 / 32768.0
            var sumSquares: Double = 0
            let totalSamples = frames * channelCount
            if isInterleaved {
                let samples = channels[0]
                for i in 0..<totalSamples {
                    let s = Double(samples[i]) * scale
                    sumSquares += s * s
                }
            } else {
                for ch in 0..<channelCount {
                    let samples = channels[ch]
                    for f in 0..<frames {
                        let s = Double(samples[f]) * scale
                        sumSquares += s * s
                    }
                }
            }
            let value = Float((sumSquares / Double(totalSamples)).squareRoot())
            return value.isFinite ? value : 0

        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { return 0 }
            let scale = 1.0 / 2_147_483_648.0
            var sumSquares: Double = 0
            let totalSamples = frames * channelCount
            if isInterleaved {
                let samples = channels[0]
                for i in 0..<totalSamples {
                    let s = Double(samples[i]) * scale
                    sumSquares += s * s
                }
            } else {
                for ch in 0..<channelCount {
                    let samples = channels[ch]
                    for f in 0..<frames {
                        let s = Double(samples[f]) * scale
                        sumSquares += s * s
                    }
                }
            }
            let value = Float((sumSquares / Double(totalSamples)).squareRoot())
            return value.isFinite ? value : 0

        default:
            return 0
        }
    }

    /// RMS over the entire buffer → display level 0…1. Digital silence maps
    /// to 0, never NaN.
    func level(_ buffer: AVAudioPCMBuffer) -> Float {
        VisualizerMath.level(rms: Self.rms(buffer))
    }
}

/// Owns the analyzer loop. `start` arms the box + spawns the ~60 Hz drain
/// (16 ms: vsync-grade loudness for the display-link render path);
/// `stop` cancels, awaits termination, disarms, and publishes silence —
/// post-stop reads are silent, guaranteed (tested).
actor AudioLevelAnalyzer {
    private var task: Task<Void, Never>?
    private var box: LevelFeedBox?
    private var model: FlowBarModel?
    private var tick: UInt64 = 0

    func start(box: LevelFeedBox, model: FlowBarModel) {
        task?.cancel()
        self.box = box
        self.model = model
        tick = 0
        box.setArmed(true)
        task = Task { await self.drain() }
    }

    func stop() async {
        task?.cancel()
        if let task { _ = await task.value }
        task = nil
        box?.setArmed(false)
        await model?.publishSilence()
    }

    private func drain() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { break }
            guard let box, let model else { continue }
            guard let rms = box.takeLatest() else { continue }
            tick += 1
            let level = VisualizerMath.level(rms: rms)
            await model.ingestLevel(level, tick: tick)
        }
    }
}
