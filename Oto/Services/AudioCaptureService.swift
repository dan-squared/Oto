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
}

/// Scriptable fake for Phase 1 coordinator tests. No audio hardware used.
actor FakeAudioCapture: AudioCaptureServing {
    struct CaptureError: Error, Sendable {}

    /// When set, `start()` throws this instead of succeeding.
    var startError: (any Error)?

    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0

    init(startError: (any Error)? = nil) {
        self.startError = startError
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
}
