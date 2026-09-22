//
//  AudioSpectrumAnalyzer.swift
//  Oto
//
//  Slice 6B: the visualizer's ears. Fed ONLY by forking OtoApp's
//  bufferHandler (`relay.receive` + `box.offer`) — attaching to the relay
//  would DETACH speech (single sink, AudioBufferRelay.swift:72), so the
//  fork is the only low-risk feed. Own converter instance (never shares
//  the speech path's), vDSP bands off the main thread, ≤30 Hz immutable
//  publish. `stop()` guarantees silence after (tested).
//
//  Threading: the box is realtime-safe (lock-shaped, @unchecked Sendable,
//  mirrors AudioFeedBox); the engine is confined to the analyzer actor
//  (@unchecked Sendable by confinement, documented); the actor itself runs
//  on the generic pool — FFT never touches the MainActor.
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
final class SpectrumFeedBox: @unchecked Sendable {
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

    /// Consume-once: the analyzer drains at ≤30 Hz; anything not taken is
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

/// 512-point real FFT → 10 voice-weighted band levels. Confined to the
/// analyzer actor (single-threaded by actor serialization); @unchecked
/// Sendable names exactly that confinement. Owns its FFTSetup + scratch —
/// created once, destroyed in deinit (actors can't reliably destroy
/// isolated state in deinit, hence the separate class).
final class SpectrumEngine: @unchecked Sendable {
    nonisolated static let frameSize = 512
    nonisolated static let log2n: vDSP_Length = 9

    private nonisolated(unsafe) var setup: FFTSetup?
    private nonisolated(unsafe) var real: [Float]
    private nonisolated(unsafe) var imag: [Float]
    private nonisolated(unsafe) var mags: [Float]
    private nonisolated(unsafe) var scratch: [Float]
    private nonisolated(unsafe) var window: [Float]
    private nonisolated(unsafe) let edges: [Float]
    private nonisolated(unsafe) let binHz: Float

    nonisolated init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        real = [Float](repeating: 0, count: 256)
        imag = [Float](repeating: 0, count: 256)
        mags = [Float](repeating: 0, count: 256)
        scratch = [Float](repeating: 0, count: Self.frameSize)
        var hann = [Float](repeating: 0, count: Self.frameSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
        window = hann
        edges = VisualizerMath.bandEdges(count: VisualizerMath.barCount)
        binHz = Float(SpectrumFeedBox.analysisSampleRate) / Float(Self.frameSize)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// First 512 frames of channel 0 (zero-padded when short) → 10 levels
    /// 0…1. Deterministic: same buffer in, same levels out (tested with a
    /// synthetic sine). DC is removed before windowing so a DC offset
    /// never pegs band 0.
    nonisolated func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let setup else {
            return [Float](repeating: 0, count: VisualizerMath.barCount)
        }
        let n = Int(min(buffer.frameLength, UInt32(Self.frameSize)))
        if n > 0, let src = buffer.floatChannelData?[0] {
            for i in 0..<n { scratch[i] = src[i] }
        }
        if n < Self.frameSize {
            for i in n..<Self.frameSize { scratch[i] = 0 }
        }
        // Demean → window → real-FFT pack.
        var mean: Float = 0
        scratch.withUnsafeMutableBufferPointer { ptr in
            vDSP_meanv(ptr.baseAddress!, 1, &mean, vDSP_Length(Self.frameSize))
            var negMean = -mean
            vDSP_vsadd(ptr.baseAddress!, 1, &negMean, ptr.baseAddress!, 1, vDSP_Length(Self.frameSize))
            window.withUnsafeBufferPointer { win in
                vDSP_vmul(ptr.baseAddress!, 1, win.baseAddress!, 1, ptr.baseAddress!, 1, vDSP_Length(Self.frameSize))
            }
            for i in 0..<256 {
                real[i] = ptr[i * 2]
                imag[i] = ptr[i * 2 + 1]
            }
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvmags(&split, 1, mp.baseAddress!, 1, 256)
                    // zvmags yields power (|X|²); bandLevels takes
                    // magnitudes, so root once (vForce, one pass).
                    var count = Int32(256)
                    vvsqrtf(mp.baseAddress!, mp.baseAddress!, &count)
                }
            }
        }
        return VisualizerMath.bandLevels(magnitudes: mags, edges: edges, binHz: binHz)
    }
}

/// Owns the analyzer loop. `start` arms the box + spawns the ≤30 Hz drain;
/// `stop` cancels, awaits termination, disarms, and publishes silence —
/// post-stop reads are silent, guaranteed (tested). Zero changes to the
/// tap/relay/debounce/speech paths.
actor AudioSpectrumAnalyzer {
    private let engine = SpectrumEngine()
    private var task: Task<Void, Never>?
    private var box: SpectrumFeedBox?
    private var model: FlowBarModel?
    private var tick: UInt64 = 0

    func start(box: SpectrumFeedBox, model: FlowBarModel) {
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
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { break }
            guard let box, let model else { continue }
            guard let buffer = box.takeLatest() else { continue }
            tick += 1
            let levels = engine.process(buffer)
            await model.applyLevels(levels, tick: tick)
        }
    }
}
