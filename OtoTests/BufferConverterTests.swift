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

    // F1: a device switch mid-session changes the tap's input format. The
    // converter must rebuild (not reuse the stale input format), or every
    // post-switch buffer throws and is silently dropped.
    @Test func feedBoxCountsFailedConversions() {
        let box = AudioFeedBox()
        // 16-bit int like the analyzer's own format: AnalyzerInput TRAPS
        // on float buffers (SpeechFramework precondition), so the target
        // must be int16 — a float target would crash the runner, not fail
        // the test.
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        _ = box.createStream()
        box.configure(format: target)
        #expect(box.conversionFailureCount() == 0)
        // 48 kHz in, 16 kHz target, but zero frames: capacity computes to
        // zero and conversion throws deterministically (no hardware).
        let empty = makeBuffer(sampleRate: 48_000, channels: 1, frames: 2048)
        empty.frameLength = 0
        box.feed(empty)
        #expect(box.conversionFailureCount() == 1)
        let good = makeBuffer(sampleRate: 48_000, channels: 1, frames: 2048)
        box.feed(good)
        #expect(box.conversionFailureCount() == 1)
    }

    @Test func rebuildsWhenInputFormatChanges() throws {
        let converter = BufferConverter()
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let first = makeBuffer(sampleRate: 48_000, channels: 1, frames: 2048)
        let out1 = try converter.convertBuffer(first, to: target)
        #expect(out1.format == target)
        #expect(out1.frameLength > 0)
        // Device switched: 44.1 kHz hardware now, same analyzer target.
        let second = makeBuffer(sampleRate: 44_100, channels: 1, frames: 2048)
        let out2 = try converter.convertBuffer(second, to: target)
        #expect(out2.format == target)
        // 2048 @ 44.1kHz ≈ 743 frames @ 16kHz; allow converter rounding.
        #expect(out2.frameLength > 0)
        #expect(abs(Int(out2.frameLength) - 743) <= 3)
    }
}
