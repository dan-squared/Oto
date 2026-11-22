//
//  AudioBufferRelayTests.swift
//  OtoTests
//
//  Relay bound/flush/reset/drop-count tests. Buffers are allocated
//  headless (no microphone); delivery is synchronous and deterministic.
//

import AVFoundation
import Testing
@testable import Oto

struct AudioBufferRelayTests {
    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 2048
        )!
        buffer.frameLength = 2048
        return buffer
    }

    @Test func flushesBufferedAudioInOrderOnAttach() {
        let relay = AudioBufferRelay()
        let first = makeBuffer()
        let second = makeBuffer()
        let third = makeBuffer()
        relay.receive(first)
        relay.receive(second)
        relay.receive(third)

        var delivered: [AVAudioPCMBuffer] = []
        relay.attach { delivered.append($0) }

        #expect(delivered.count == 3)
        #expect(delivered[0] === first)
        #expect(delivered[1] === second)
        #expect(delivered[2] === third)
    }

    @Test func deliversDirectlyOnceAttached() {
        let relay = AudioBufferRelay()
        var delivered: [AVAudioPCMBuffer] = []
        relay.attach { delivered.append($0) }

        let buffer = makeBuffer()
        relay.receive(buffer)

        #expect(delivered.count == 1)
        #expect(delivered.first === buffer)
    }

    @Test func boundsPendingAudioAndCountsDrops() {
        let relay = AudioBufferRelay()
        for _ in 0..<(AudioBufferRelay.maximumPending + 20) {
            relay.receive(makeBuffer())
        }

        // Bounded: exactly capacity kept, overflow counted, never grown.
        #expect(relay.droppedBufferCount() == 20)

        var delivered: [AVAudioPCMBuffer] = []
        relay.attach { delivered.append($0) }
        #expect(delivered.count == AudioBufferRelay.maximumPending)
    }

    @Test func deliveredCountsSinkHandoffsPerAttachWindow() {
        let relay = AudioBufferRelay()
        var delivered: [AVAudioPCMBuffer] = []
        relay.attach { delivered.append($0) }
        relay.receive(makeBuffer())
        relay.receive(makeBuffer())
        relay.receive(makeBuffer())
        #expect(relay.deliveredBufferCount() == 3)
        // Re-attach opens a new window: the count resets, flushed audio counts.
        relay.receive(makeBuffer())
        relay.reset()
        relay.receive(makeBuffer())
        relay.receive(makeBuffer())
        var flushed: [AVAudioPCMBuffer] = []
        relay.attach { flushed.append($0) }
        #expect(flushed.count == 2)
        #expect(relay.deliveredBufferCount() == 2)
    }

    @Test func resetClearsSinkPendingAndDrops() {
        let relay = AudioBufferRelay()
        var delivered: [AVAudioPCMBuffer] = []
        relay.attach { delivered.append($0) }
        relay.receive(makeBuffer())
        #expect(delivered.count == 1)

        relay.reset()
        // Post-reset receives with no sink buffer (bounded) but are not
        // delivered anywhere.
        relay.receive(makeBuffer())
        #expect(delivered.count == 1)
        #expect(relay.droppedBufferCount() == 0)
    }
}
