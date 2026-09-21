//
//  BufferConverterTests.swift
//  OtoTests
//
//  Converter tests with headless-allocated buffers (no microphone).
//  Deterministic.
//

import AVFoundation
import Testing
@testable import Oto

struct BufferConverterTests {
    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    @Test func sameFormatPassesThroughUnchanged() throws {
        let converter = BufferConverter()
        let buffer = makeBuffer(sampleRate: 48_000, channels: 1, frames: 1024)
        let out = try converter.convertBuffer(buffer, to: buffer.format)
        #expect(out === buffer)
    }

    @Test func convertsAcrossSampleRates() throws {
        let converter = BufferConverter()
        let input = makeBuffer(sampleRate: 48_000, channels: 1, frames: 2048)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let out = try converter.convertBuffer(input, to: target)
        #expect(out.format == target)
        // 2048 @ 48kHz ≈ 683 frames @ 16kHz; allow converter rounding.
        #expect(out.frameLength > 0)
        #expect(abs(Int(out.frameLength) - 683) <= 2)
    }
}
