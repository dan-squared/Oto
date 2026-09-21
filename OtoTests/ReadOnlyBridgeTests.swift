//
//  ReadOnlyBridgeTests.swift
//  OtoTests
//
//  plan/s5-audiotap.md: the tap delivers Sendable read-only structs;
//  the relay chain eats owned AVAudioPCMBuffers. The sanctioned bridge
//  (init(copying:) both directions) must preserve audio bit-exactly —
//  proven here headless, no hardware, no tap.
//

import AVFoundation
import Foundation
import Testing
@testable import Oto

struct ReadOnlyBridgeTests {
    @Test func roundTripPreservesSamplesBitExactly() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        )!
        let frames: AVAudioFrameCount = 1024
        let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        original.frameLength = frames
        let channels = original.int16ChannelData!
        for i in 0 ..< Int(frames) {
            channels[0][i] = Int16(i % 997)
        }

        let readOnly = AVReadOnlyAudioPCMBuffer(copying: original)
        #expect(readOnly.frameLength == Int(frames))
        let owned = AVAudioPCMBuffer(copying: readOnly)
        #expect(owned.format == format)
        #expect(owned.frameLength == frames)

        let back = owned.int16ChannelData!
        for i in 0 ..< Int(frames) {
            #expect(back[0][i] == Int16(i % 997))
        }
    }

    @Test func bridgePreservesForeignFormats() {
        // The converter's future input: 48 kHz float survives the bridge
        // with its format intact (conversion still happens downstream).
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        original.frameLength = 512
        let owned = AVAudioPCMBuffer(copying: AVReadOnlyAudioPCMBuffer(copying: original))
        #expect(owned.format == format)
        #expect(owned.frameLength == 512)
    }
}
