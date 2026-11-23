//
//  AudioBufferRelay.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
import Synchronization

/// Capture starts instantly but analyzer preparation takes a moment, so
/// buffers captured before a sink attaches are held and flushed on attach —
/// otherwise the first words are lost (capture-first ordering, 02).
///
/// Receives on the realtime audio thread: `Synchronization.Mutex`-protected,
/// no await, no UI, bounded queue. During `attach(_:)`, `isFlushing` keeps any
/// concurrently arriving live buffers queued in `pending` until the drain loop
/// empties them in strict FIFO order — live buffers can never overtake
/// pre-attach audio, and the realtime thread never blocks on flush.
nonisolated final class AudioBufferRelay: Sendable {
    /// ~4096 frames each; 125 is roughly 10 seconds at the tuned 48 kHz.
    /// A ceiling in case the transcriber never becomes ready, so we never
    /// grow without bound. Halved with bufferSize 2048→4096 to preserve
    /// exact time-equivalence (plan/buffer-size.md).
    static let maximumPending = 125

    /// Past this many dropped buffers the transcript is untrustworthy;
    /// `AppleSpeechService.finish()` throws instead of returning it.
    /// 25 ≈ 2.1 s of lost audio at 48 kHz (halved with bufferSize;
    /// exact value provisional pending device measurement).
    static let maximumDroppedBeforeFailure = 25

    private struct SinkBox: @unchecked Sendable {
        let call: (AVAudioPCMBuffer) -> Void
    }

    private struct BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private struct State {
        var pending: [BufferBox] = []
        var sink: SinkBox?
        var isFlushing = false
        var generation: UInt64 = 0
        var droppedCount = 0
        /// Buffers handed to the sink since `attach` (one session's proof of
        /// mic life; reset on `attach` and `reset`, read at finish).
        var deliveredCount = 0
    }

    private let state = Mutex(State())

    init() {}

    func receive(_ buffer: AVAudioPCMBuffer) {
        let boxed = BufferBox(buffer: buffer)
        let directSink: SinkBox? = state.withLock { s in
            if let sink = s.sink, !s.isFlushing {
                s.deliveredCount += 1
                return sink
            }
            if s.pending.count < Self.maximumPending {
                s.pending.append(boxed)
            } else {
                // Drop oldest (stale audio), count it. Never grow, never block.
                s.pending.removeFirst()
                s.pending.append(boxed)
                s.droppedCount += 1
            }
            return nil
        }
        directSink?.call(boxed.buffer)
    }

    func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        let sinkBox = SinkBox(call: sink)
        let myGeneration: UInt64 = state.withLock { s in
            s.generation &+= 1
            s.deliveredCount = 0
            s.sink = sinkBox
            s.isFlushing = true
            return s.generation
        }

        // Drain pending buffers in strict FIFO order while `isFlushing` keeps
        // any concurrent realtime `receive(_:)` calls queued behind them.
        while true {
            let batch: [BufferBox] = state.withLock { s in
                guard s.generation == myGeneration, s.sink != nil else {
                    return []
                }
                if s.pending.isEmpty {
                    s.isFlushing = false
                    return []
                }
                let next = s.pending
                s.pending.removeAll(keepingCapacity: true)
                s.deliveredCount += next.count
                return next
            }
            if batch.isEmpty { break }
            for item in batch {
                sinkBox.call(item.buffer)
            }
        }
    }

    func reset() {
        state.withLock { s in
            s.generation &+= 1
            s.sink = nil
            s.isFlushing = false
            s.pending.removeAll()
            s.droppedCount = 0
            s.deliveredCount = 0
        }
    }

    func deliveredBufferCount() -> Int {
        state.withLock { $0.deliveredCount }
    }

    func droppedBufferCount() -> Int {
        state.withLock { $0.droppedCount }
    }
}
