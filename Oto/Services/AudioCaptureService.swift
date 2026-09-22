//
//  AudioCaptureService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import Foundation

/// Narrow audio-capture seam. Real implementation (AVAudioEngine) lands in
/// Phase 2; the coordinator only ever talks to this protocol.
protocol AudioCaptureServing: Sendable {
    func start() async throws
    func stop() async
    func cancel() async
    /// Peak absolute sample seen since `start` (0 = digital silence).
    /// Silent-skip workstream: lets the coordinator complete voice-less
    /// sessions without transcription (the loader never exists).
    /// Realtime-safe on the real service (lock-guarded, never touches
    /// actor state); scriptable on the fake.
    func sessionPeakAmplitude() async -> Float
}

/// Scriptable fake for Phase 1 coordinator tests. No audio hardware used.
actor FakeAudioCapture: AudioCaptureServing {
    struct CaptureError: Error, Sendable {}

    /// When set, `start()` throws this instead of succeeding.
    var startError: (any Error)?

    /// Scriptable voice presence for the silent-skip gate. Loud by
    /// default so every existing test keeps the full transcription path;
    /// silent tests set ~0.
    var stubPeak: Float = 1.0

    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0

    init(startError: (any Error)? = nil, stubPeak: Float = 1.0) {
        self.startError = startError
        self.stubPeak = stubPeak
    }

    func start() async throws {
        startCalls += 1
        if let startError {
            throw startError
        }
    }

    func stop() async {
        stopCalls += 1
    }

    func cancel() async {
        cancelCalls += 1
    }

    func sessionPeakAmplitude() async -> Float { stubPeak }
}
