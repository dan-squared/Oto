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
///
/// Concurrency (Swift 6, default MainActor isolation): the lock is the
/// isolation. Shared mutable state is `nonisolated(unsafe)` — manually
/// synchronized memory, every access under `lock` — and the methods are
/// plain checked `nonisolated`. See the accepted ordering race noted on
/// `attach` (audit N1). `NSLock` itself is Sendable (`NS_SWIFT_SENDABLE`
/// in the 27 SDK).
final class AudioBufferRelay: @unchecked Sendable {
    /// ~4096 frames each; 125 is roughly 10 seconds at the tuned 48 kHz.
    /// A ceiling in case the transcriber never becomes ready, so we never
    /// grow without bound. Halved with bufferSize 2048→4096 to preserve
    /// exact time-equivalence (plan/buffer-size.md).
    nonisolated static let maximumPending = 125

    /// Past this many dropped buffers the transcript is untrustworthy;
    /// `AppleSpeechService.finish()` throws instead of returning it.
    /// 25 ≈ 2.1 s of lost audio at 48 kHz (halved with bufferSize;
    /// exact value provisional pending device measurement).
    nonisolated static let maximumDroppedBeforeFailure = 25

    private let lock = NSLock()
    private nonisolated(unsafe) var pending: [AVAudioPCMBuffer] = []
    private nonisolated(unsafe) var sink: ((AVAudioPCMBuffer) -> Void)?
    private nonisolated(unsafe) var droppedCount = 0
    /// Buffers handed to the sink since `attach` (one session's proof of
    /// mic life; reset per attach, read at finish).
    private nonisolated(unsafe) var deliveredCount = 0

    nonisolated func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let sink {
            deliveredCount += 1
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

    nonisolated func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let buffered = pending
        pending.removeAll()
        deliveredCount = 0
        self.sink = sink
        lock.unlock()

        // Accepted race (audit N1): a buffer arriving between the sink
        // assignment above and this flush loop delivers AHEAD of older
        // buffered audio. Microsecond window at session start, quality-only
        // (slightly shuffled first words); sequencing the flush would cost
        // realtime blocking. Revisit with device evidence, not theory.
        for buffer in buffered {
            lock.lock()
            deliveredCount += 1
            lock.unlock()
            sink(buffer)
        }
    }

    nonisolated func reset() {
        lock.lock()
        sink = nil
        pending.removeAll()
        droppedCount = 0
        lock.unlock()
    }

    nonisolated func deliveredBufferCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredCount
    }

    nonisolated func droppedBufferCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }
}
