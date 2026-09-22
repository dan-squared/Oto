//
//  SpectrumEngineTests.swift
//  OtoTests
//
//  Slice 6B: the FFT path is honest — a synthetic 440 Hz sine lands in the
//  440 Hz band, silence lands nowhere, and the engine is deterministic.
//  The feed box drops (never blocks) and stays free when unarmed.
//

import AVFoundation
import Testing
@testable import Oto

@MainActor
struct SpectrumEngineTests {
    @Test func sineLandsInItsBand() {
        // 440 Hz @ 16 kHz analysis: band 3 (318–505 Hz). Hann + demean
        // keep leakage small; the peak must still own the spectrum.
        let engine = SpectrumEngine()
        let converted = convertedToAnalysis(sineBuffer())
        let levels = engine.process(converted)
        #expect(levels.count == 10)
        #expect(argmax(levels) == 3)
        #expect(levels[3] > 0.5)
    }

    @Test func silenceStaysSilent() {
        let engine = SpectrumEngine()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let levels = engine.process(buffer)
        #expect(levels.allSatisfy { $0 == 0 })
    }

    @Test func engineIsDeterministic() {
        let engine = SpectrumEngine()
        let converted = convertedToAnalysis(sineBuffer())
        #expect(engine.process(converted) == engine.process(converted))
    }

    @Test func shortBuffersZeroPadWithoutCrashing() {
        let engine = SpectrumEngine()
        let tiny = sineBuffer(frames: 64)
        let levels = engine.process(tiny)
        #expect(levels.count == 10)
        #expect(levels.allSatisfy { !$0.isNaN })
    }

    @Test func boxIsFreeWhenUnarmed() {
        let box = SpectrumFeedBox()
        box.offer(sineBuffer())
        #expect(box.takeLatest() == nil)
    }

    @Test func boxKeepsLatestDropsRest() {
        let box = SpectrumFeedBox()
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
}
