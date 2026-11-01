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

/// Realtime-safe latest-slot for the analyzer. Drop-on-full by
/// construction (overwrite, never grow, never block). Unarmed (before
/// `start`, after `stop`) `offer` returns immediately — zero cost outside
/// recording. Conversion happens here on the audio thread: allocation per
/// buffer at ~12 buffers/s is precedent-proven (AudioFeedBox does the
/// same under its lock).
final class LevelFeedBox: @unchecked Sendable {
    nonisolated static let analysisSampleRate: Double = 16_000

    private let lock = NSLock()
    private nonisolated(unsafe) var armed = false
    private nonisolated(unsafe) var latest: AVAudioPCMBuffer?
    private nonisolated(unsafe) var offerFailures = 0
    private let converter = BufferConverter()
    private nonisolated(unsafe) var format: AVAudioFormat?

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.analysisSampleRate,
            channels: 1, interleaved: false
        )
    }

    nonisolated func setArmed(_ armed: Bool) {
        lock.lock()
        self.armed = armed
        if !armed { latest = nil }
        lock.unlock()
    }

    nonisolated func offer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard armed, let format else {
            lock.unlock()
            return
        }
        let converted: AVAudioPCMBuffer?
        do {
            converted = try converter.convertBuffer(buffer, to: format)
        } catch {
            offerFailures += 1
            converted = nil
        }
        if converted != nil { latest = converted }
        lock.unlock()
    }

    /// Consume-once: the analyzer drains at ~60 Hz; anything not taken is
    /// stale by definition.
    nonisolated func takeLatest() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let buffer = latest
        latest = nil
        return buffer
    }

    nonisolated func failureCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return offerFailures
    }
}

/// Whole converted buffer → RMS → display level 0…1. No FFT, no bands:
/// loudness is the only quantity the wave needs. Confined to the analyzer
/// actor (single-threaded by actor serialization); @unchecked Sendable
/// names exactly that confinement.
final class LevelEngine: @unchecked Sendable {
    nonisolated init() {}

    /// RMS over the entire converted buffer (≈85 ms at 16 kHz). The buffer
    /// cadence is the latency floor; a shorter window would not beat it.
    /// Digital silence maps to 0, never NaN.
    nonisolated func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            return 0
        }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        return VisualizerMath.level(rms: rms)
    }
}

/// Owns the analyzer loop. `start` arms the box + spawns the ~60 Hz drain
/// (16 ms: vsync-grade loudness for the display-link render path);
/// `stop` cancels, awaits termination, disarms, and publishes silence —
/// post-stop reads are silent, guaranteed (tested). Zero changes to the
/// tap/relay/debounce/speech paths.
actor AudioLevelAnalyzer {
    private let engine = LevelEngine()
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
            guard let buffer = box.takeLatest() else { continue }
            tick += 1
            let level = engine.level(buffer)
            await model.ingestLevel(level, tick: tick)
        }
    }
}
