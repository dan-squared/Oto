//
//  RebuildDebounceTests.swift
//  OtoTests
//
//  bt-sco-flap.md: config-change flurries (Bluetooth SCO bring-up) must
//  coalesce into one rebuild per quiet window — tearing down on every
//  flutter multiplies silence gaps. Pure decision function, deterministic.
//

import AVFoundation
import Foundation
import Testing
@testable import Oto

struct RebuildDebounceTests {
    private let policy = RebuildDebouncePolicy(quietNanoseconds: 1_500_000_000)

    @Test func firstChangeRebuildsImmediately() {
        #expect(policy.shouldRebuildNow(now: Date(), lastRebuild: nil))
    }

    @Test func flurryInsideWindowDefers() {
        let last = Date()
        let now = last.addingTimeInterval(0.2)
        #expect(!policy.shouldRebuildNow(now: now, lastRebuild: last))
    }

    @Test func settledLinkRebuildsAgain() {
        let last = Date()
        let now = last.addingTimeInterval(5.0)
        #expect(policy.shouldRebuildNow(now: now, lastRebuild: last))
    }

    @Test func settledWindowRebuilds() {
        // Asserted CLEAR of the 1.5s line, not on it: Date doubles near
        // current timestamps carry ~120ns of rounding slop, so an exact
        // boundary assertion would be a coin flip across runs.
        let last = Date()
        let now = last.addingTimeInterval(1.6)
        #expect(policy.shouldRebuildNow(now: now, lastRebuild: last))
    }

    @Test func degenerateFormatRefusesTap() {
        // installTap-crash.md: a formatless node (device gone) must throw
        // before installTap is ever called — the throw is catchable, the
        // NSException on mismatch is not.
        let badRate = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)
        let badChannels = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 0)
        let good = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        // AVAudioFormat init is failable: a 0-rate/0-channel descriptor
        // may itself refuse to construct — nil counts as unusable.
        #expect((badRate.map(AppleAudioCapture.tapFormatUsable) ?? false) == false)
        #expect((badChannels.map(AppleAudioCapture.tapFormatUsable) ?? false) == false)
        #expect(AppleAudioCapture.tapFormatUsable(good))
    }

    @Test func tighterWindowFlapsLess() {
        let strict = RebuildDebouncePolicy(quietNanoseconds: 5_000_000_000)
        let last = Date()
        #expect(!strict.shouldRebuildNow(now: last.addingTimeInterval(2.0), lastRebuild: last))
        #expect(strict.shouldRebuildNow(now: last.addingTimeInterval(6.0), lastRebuild: last))
    }

    // MARK: - Session peak (silent-skip voice signal)

    private func pcmBuffer(frames: Int = 4096, fill: Float = 0) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        ), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        memset(channel, 0, frames * MemoryLayout<Float>.size)
        if fill != 0 {
            for f in 0..<frames { channel[f] = fill }
        }
        return buffer
    }

    @Test func silenceNotesZeroPeak() async {
        // Digital silence contributes nothing — a voice-less session
        // reads back 0.
        guard let silent = pcmBuffer() else {
            Issue.record("could not build a test buffer")
            return
        }
        let capture = await MainActor.run { AppleAudioCapture() }
        capture.noteBufferPeak(silent)
        #expect(await capture.sessionPeakAmplitude() == 0)
    }

    @Test func toneNotesPeakAndHoldsMax() async {
        // Peak holds the session max across buffers (stride-4 scan hits
        // a constant fill exactly).
        guard let loud = pcmBuffer(fill: 0.5), let quiet = pcmBuffer(fill: 0.2) else {
            Issue.record("could not build test buffers")
            return
        }
        let capture = await MainActor.run { AppleAudioCapture() }
        capture.noteBufferPeak(loud)
        #expect(await capture.sessionPeakAmplitude() == 0.5)
        capture.noteBufferPeak(quiet)
        #expect(await capture.sessionPeakAmplitude() == 0.5)
    }

    @Test func peakResetsForNewSession() async {
        guard let loud = pcmBuffer(fill: 0.5) else {
            Issue.record("could not build a test buffer")
            return
        }
        let capture = await MainActor.run { AppleAudioCapture() }
        capture.noteBufferPeak(loud)
        #expect(await capture.sessionPeakAmplitude() == 0.5)
        capture.resetSessionPeak()
        #expect(await capture.sessionPeakAmplitude() == 0)
    }
}
