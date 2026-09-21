//
//  AudioBufferRelay.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation

/// Capture starts instantly but analyzer preparation takes a moment, so
/// buffers captured before a sink attaches are held and flushed on attach —
/// otherwise the first words are lost (capture-first ordering, 02).
///
/// Receives on the realtime audio thread: lock-protected, no await, no UI,
/// no allocation beyond the bounded queue. Technique follows the Yap
/// reference (`AudioBufferRelay.swift`, MIT) with one required improvement
/// (07 §4.2): drops are COUNTED, and the session fails past a threshold
/// rather than silently producing a corrupted transcript.
final class AudioBufferRelay: @unchecked Sendable {
    /// ~2048 frames each; 250 is roughly 10 seconds. A ceiling in case the
    /// transcriber never becomes ready, so we never grow without bound.
    static let maximumPending = 250

    /// Past this many dropped buffers the transcript is untrustworthy;
    /// `AppleSpeechService.finish()` throws instead of returning it.
    /// Exact value is provisional pending device measurement.
    static let maximumDroppedBeforeFailure = 50

    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var droppedCount = 0

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let sink {
            lock.unlock()
            sink(buffer)
            return
        }
        if pending.count < Self.maximumPending {
            pending.append(buffer)
        } else {
            // Drop oldest (stale audio), count it. Never grow, never block.
            pending.removeFirst()
            pending.append(buffer)
            droppedCount += 1
        }
        lock.unlock()
    }

    func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let buffered = pending
        pending.removeAll()
        self.sink = sink
        lock.unlock()

        for buffer in buffered {
            sink(buffer)
        }
    }

    func reset() {
        lock.lock()
        sink = nil
        pending.removeAll()
        droppedCount = 0
        lock.unlock()
    }

    func droppedBufferCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }
}
