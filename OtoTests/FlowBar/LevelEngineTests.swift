//
//  LevelEngineTests.swift
//  OtoTests
//
//  Slice 6B: the loudness path is honest — one broadband RMS value, no
//  spectrum. A louder tone always reads louder, frequency does not change
//  the level at equal RMS, silence is 0, short buffers are safe, and the
//  engine is deterministic. The feed box drops (never blocks) and stays
//  free when unarmed.
//

import AVFoundation
import Testing
@testable import Oto

@MainActor
struct LevelEngineTests {
    @Test func levelRisesWithAmplitude() {
        // RMS is amplitude-only: 3× louder tone, 3× the RMS, a strictly
        // higher display level. Loudness survives the whole chain.
        let engine = LevelEngine()
        let quiet = engine.level(convertedToAnalysis(sineBuffer(amplitude: 0.01)))
        let normal = engine.level(convertedToAnalysis(sineBuffer(amplitude: 0.05)))
        let loud = engine.level(convertedToAnalysis(sineBuffer(amplitude: 0.2)))
        #expect(quiet > 0)
        #expect(quiet < normal)
        #expect(normal < loud)
        #expect(loud <= 1)
    }

    @Test func frequencyDoesNotChangeTheLevel() {
        // The pill draws loudness, not spectrum: a 440 Hz and an 880 Hz
        // tone at the same amplitude must read the same level.
        let engine = LevelEngine()
        let low = engine.level(convertedToAnalysis(sineBuffer(frequency: 440, amplitude: 0.05)))
        let high = engine.level(convertedToAnalysis(sineBuffer(frequency: 880, amplitude: 0.05)))
        #expect(abs(low - high) < 0.02)
    }

    @Test func levelMatchesTheDBMapping() {
        // One source of truth: the engine's output equals
        // VisualizerMath.level(rms:). A 0.05 amplitude sine has RMS
        // 0.03536 (−29.0 dBFS); the window was re-centred on 2026-11-01
        // (−52…−22 dB, plan/pill-wave-sensitivity.md), so it maps to
        // ≈ 0.766. Expected value derived from the constants, never a
        // copied number, so a recalibration can't leave this stale.
        let engine = LevelEngine()
        let buffer = convertedToAnalysis(sineBuffer(amplitude: 0.05))
        let rms = rootMeanSquare(buffer)
        #expect(abs(engine.level(buffer) - VisualizerMath.level(rms: rms)) < 0.001)
        let expected = (20 * log10(rms) - VisualizerMath.levelFloorDB)
            / (VisualizerMath.levelCeilingDB - VisualizerMath.levelFloorDB)
        #expect(abs(engine.level(buffer) - expected) < 0.01)
    }

    @Test func silenceStaysSilent() {
        let engine = LevelEngine()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        #expect(engine.level(buffer) == 0)
    }

    @Test func engineIsDeterministic() {
        let engine = LevelEngine()
        let converted = convertedToAnalysis(sineBuffer())
        #expect(engine.level(converted) == engine.level(converted))
    }

    @Test func shortBuffersStaySafe() {
        let engine = LevelEngine()
        let tiny = engine.level(convertedToAnalysis(sineBuffer(frames: 64)))
        #expect(!tiny.isNaN)
        #expect(tiny >= 0)
        #expect(tiny <= 1)
        // An empty buffer is silence, never a crash.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        empty.frameLength = 0
        #expect(engine.level(empty) == 0)
    }

    @Test func boxIsFreeWhenUnarmed() {
        let box = LevelFeedBox()
        box.offer(sineBuffer())
        #expect(box.takeLatest() == nil)
    }

    @Test func boxKeepsLatestDropsRest() {
        let box = LevelFeedBox()
        box.setArmed(true)
        box.offer(sineBuffer(frequency: 440))
        box.offer(sineBuffer(frequency: 880))
        // Latest wins (drop-on-full by construction); both convert clean.
        #expect(box.takeLatest() != nil)
        #expect(box.takeLatest() == nil)
        #expect(box.failureCount() == 0)
        box.setArmed(false)
        box.offer(sineBuffer())
        #expect(box.takeLatest() == nil)
    }

    // MARK: - Helpers

    /// The engine consumes 16 kHz mono; convert the 48 kHz test tone
    /// through the real converter (same instance shape as production).
    private func convertedToAnalysis(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let converter = BufferConverter()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        return try! converter.convertBuffer(buffer, to: format)
    }

    private func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
