//
//  FlowBarAudioHelpers.swift
//  OtoTests
//
//  Shared synthetic audio for visualizer tests. Deterministic by
//  construction (pure sine, exact frame counts) — no mic, no device.
//

import AVFoundation
@testable import Oto

/// Mono Float32 sine at `sampleRate`, `frames` long.
func sineBuffer(
    frequency: Double = 440,
    amplitude: Float = 0.5,
    sampleRate: Double = 48_000,
    frames: Int = 4096
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: 1, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let channel = buffer.floatChannelData![0]
    for i in 0..<frames {
        channel[i] = amplitude * sin(Float(2 * .pi * frequency * Double(i) / sampleRate))
    }
    return buffer
}

func argmax(_ values: [Float]) -> Int {
    var best = 0
    for i in 1..<values.count where values[i] > values[best] { best = i }
    return best
}
