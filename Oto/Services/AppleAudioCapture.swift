//
//  AppleAudioCapture.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
import Synchronization
import os

/// Real `AudioCaptureServing` over `AVAudioEngine`. Graph lessons adopted
/// from the Yap reference (`AudioCaptureService.swift`, MIT) as Oto-owned
/// code — each one guards a real crash/failure class:
///
/// - Fresh engine per start: a reused engine keeps the last device's format,
///   so `installTap` can receive a mismatched format and throw an
///   uncatchable Objective-C exception. A fresh engine always reads the
///   current device's format.
/// - Degenerate-format guard: mid-switch the node can briefly report 0 Hz /
///   0 channels; installing a tap then throws. Fail fast instead.
/// - Drop-and-rebuild engine on stop: stopping halts rendering but leaves
///   the HAL unit instantiated, holding BT headsets in low-quality
///   call mode. A fresh engine releases the device.
/// - Config-change rebuild with re-entrancy guard; teardown (not a
///   half-running graph) when the new device won't start.
///
/// Tap the input's hardware format; never assume a sample rate. The tap
/// callback only forwards to the injected handler (the relay) — no UI,
/// no logging, no conversion on the realtime thread.
/// Coalesces input-device config flurries (notably Bluetooth SCO link
/// bring-up, which renegotiates in bursts) into at most one rebuild per
/// quiet window. Pure decision function — exhaustively unit-tested; the
/// actor owns timestamps and pending work.
nonisolated struct RebuildDebouncePolicy: Sendable {
    /// Minimum quiet between rebuilds (300 ms trailing coalesce so Bluetooth
    /// or USB config bursts settle without dropping 1.5 s of speech).
    var quietNanoseconds: UInt64 = 300_000_000

    func shouldRebuildNow(now: Date, lastRebuild: Date?) -> Bool {
        guard let lastRebuild else { return true }
        return now.timeIntervalSince(lastRebuild) * 1_000_000_000 >= Double(quietNanoseconds)
    }

    func shouldRebuildNow(
        now: ContinuousClock.Instant,
        lastRebuild: ContinuousClock.Instant?
    ) -> Bool {
        guard let lastRebuild else { return true }
        return lastRebuild.duration(to: now) >= .nanoseconds(Int64(quietNanoseconds))
    }
}

actor AppleAudioCapture: AudioCaptureServing {
    struct EngineError: Error, Sendable {}

    private let bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let debounce: RebuildDebouncePolicy
    private let log = Logger(subsystem: "app.Oto", category: "audio")

    private var engine = AVAudioEngine()
    private var isRunning = false
    private var configObserver: NSObjectProtocol?
    private var handlingConfigChange = false
    private var lastRebuild: ContinuousClock.Instant?
    private var pendingRebuild: Task<Void, Never>?
    /// Voice-presence signal (silent-skip workstream): peak absolute
    /// sample seen since `start`. Guarded by `Synchronization.Mutex` so the
    /// realtime tap thread never touches actor state.
    private let sessionPeak = Mutex<Float>(0)

    init(
        bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        debounce: RebuildDebouncePolicy = RebuildDebouncePolicy()
    ) {
        self.bufferHandler = bufferHandler
        self.debounce = debounce
    }

    func start() async throws {
        lastRebuild = nil
        resetSessionPeak()
        try restart()
        isRunning = true
    }

    func stop() async {
        teardown()
    }

    func cancel() async {
        teardown()
    }

    func sessionPeakAmplitude() async -> Float {
        sessionPeak.withLock { $0 }
    }

    /// Realtime-safe peak note (tap thread only touches the `Mutex` + Float).
    /// Stride-4 scan of every channel: ~1k samples per 4096-frame buffer,
    /// microseconds — no conversion, no allocation, no logging. Supports
    /// Float32, Int16, and Int32 in both interleaved and non-interleaved
    /// layouts; unrecognized PCM formats fail open (`1.0`) so valid speech is
    /// never silently skipped.
    nonisolated func noteBufferPeak(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let isInterleaved = buffer.format.isInterleaved
        var peak: Float = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else {
                peak = 1.0
                break
            }
            if isInterleaved {
                let samples = channels[0]
                var f = 0
                while f < frames {
                    let base = f * channelCount
                    for ch in 0..<channelCount {
                        let v = abs(samples[base + ch])
                        if v > peak { peak = v }
                    }
                    f += 4
                }
            } else {
                for ch in 0..<channelCount {
                    let samples = channels[ch]
                    var f = 0
                    while f < frames {
                        let v = abs(samples[f])
                        if v > peak { peak = v }
                        f += 4
                    }
                }
            }

        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else {
                peak = 1.0
                break
            }
            if isInterleaved {
                let samples = channels[0]
                var f = 0
                while f < frames {
                    let base = f * channelCount
                    for ch in 0..<channelCount {
                        // Float-first: abs(Int16.min) overflows; normalized to 0..1.
                        let v = abs(Float(samples[base + ch])) / 32768.0
                        if v > peak { peak = v }
                    }
                    f += 4
                }
            } else {
                for ch in 0..<channelCount {
                    let samples = channels[ch]
                    var f = 0
                    while f < frames {
                        let v = abs(Float(samples[f])) / 32768.0
                        if v > peak { peak = v }
                        f += 4
                    }
                }
            }

        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else {
                peak = 1.0
                break
            }
            if isInterleaved {
                let samples = channels[0]
                var f = 0
                while f < frames {
                    let base = f * channelCount
                    for ch in 0..<channelCount {
                        let v = abs(Float(samples[base + ch])) / 2_147_483_648.0
                        if v > peak { peak = v }
                    }
                    f += 4
                }
            } else {
                for ch in 0..<channelCount {
                    let samples = channels[ch]
                    var f = 0
                    while f < frames {
                        let v = abs(Float(samples[f])) / 2_147_483_648.0
                        if v > peak { peak = v }
                        f += 4
                    }
                }
            }

        default:
            // Fail open for unrecognized PCM formats so valid speech is never
            // silently discarded by silent-skip.
            peak = 1.0
        }

        guard peak > 0 else { return }
        sessionPeak.withLock { $0 = max($0, peak) }
    }

    nonisolated func resetSessionPeak() {
        sessionPeak.withLock { $0 = 0 }
    }

    // MARK: - Private

    private func restart() throws {
        // A leftover observer would stack listeners that race to rebuild.
        removeConfigObserver()
        engine.stop()
        engine = AVAudioEngine()

        try installTap()
        addConfigObserver()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Never leave observer or tap behind a non-running engine.
            removeConfigObserver()
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    private func teardown() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        lastRebuild = nil
        removeConfigObserver()
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        // Drop the engine so the input unit is deallocated and the
        // microphone device released; start() builds a fresh one.
        engine = AVAudioEngine()
    }

    /// Degenerate-node predicate: a formatless input (device gone) must
    /// throw before `installTap`, never reach it. Pure — unit-tested.
    nonisolated static func tapFormatUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func installTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)

        guard Self.tapFormatUsable(format) else {
            throw EngineError()
        }

        // Capture the handler (not self): the tap closure runs on the
        // realtime thread and must not touch actor state.
        // format: nil — the tap uses the node's LIVE format. Passing our
        // just-read format reintroduces the crash class that killed PID
        // 19574: on a flapping device the read is stale by install time
        // and installTap raises an uncatchable NSException on mismatch
        // (plan/installtap-crash.md). Nil has zero behavioral delta when
        // stable (it IS the hardware format); the downstream converter
        // adapts arbitrary input by design.
        // S5 (plan/s5-audiotap.md): throwing installAudioTap; the block
        // receives a Sendable read-only struct, bridged to an owned buffer
        // via the sanctioned init(copying:). One small copy per block; the
        // relay owns it from here, and the realtime thread never touches
        // it again.
        let handler = bufferHandler
        // bufferSize 4096 (plan/buffer-size.md): power-of-2 inside the
        // documented [100, 400] ms request range for the BT rate
        // (256 ms @16 kHz; 85 ms @48 kHz).
        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] readOnly, _ in
            let owned = AVAudioPCMBuffer(copying: readOnly)
            handler?(owned)
            // Voice-presence peak (silent-skip): realtime-safe, never
            // touches actor state — see noteBufferPeak.
            self?.noteBufferPeak(owned)
        }
    }

    private func addConfigObserver() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }
    }

    private func removeConfigObserver() {
        guard let configObserver else { return }
        NotificationCenter.default.removeObserver(configObserver)
        self.configObserver = nil
    }

    /// Default input reconfigured (device unplugged/switched): rebuild on a
    /// fresh engine so recording continues without inheriting the old
    /// device's format. Delivered on the main queue.
    ///
    /// Flurries (Bluetooth SCO bring-up renegotiates in bursts) coalesce:
    /// at most one rebuild per quiet window, scheduled after the link
    /// settles — tearing down on every flutter is how gaps multiply
    /// (plan/bt-sco-flap.md, device-proven 2026-09-21).
    private func handleConfigurationChange() {
        // Rebuilding can itself emit another change; never re-enter, and
        // ignore changes once stopped.
        guard isRunning, !handlingConfigChange else { return }
        if debounce.shouldRebuildNow(now: ContinuousClock.now, lastRebuild: lastRebuild) {
            pendingRebuild?.cancel()
            pendingRebuild = nil
            rebuildForDeviceChange()
        } else {
            // Inside the window: collapse into one scheduled rebuild after
            // quiet. A newer change re-arms the timer (never stacks).
            pendingRebuild?.cancel()
            let quiet = debounce.quietNanoseconds
            pendingRebuild = Task { [weak self] in
                try? await Task.sleep(for: .nanoseconds(Int64(quiet)))
                guard !Task.isCancelled else { return }
                await self?.rebuildForDeviceChange()
            }
        }
    }

    /// Single rebuild path for device changes (immediate and scheduled).
    /// Re-guards: a stop racing the timer must not resurrect the engine.
    private func rebuildForDeviceChange() {
        pendingRebuild = nil
        guard isRunning, !handlingConfigChange else { return }
        handlingConfigChange = true
        defer { handlingConfigChange = false }
        lastRebuild = ContinuousClock.now

        do {
            try restart()
            let format = engine.inputNode.outputFormat(forBus: 0)
            log.info("audio rebuilt after device change rate=\(Int(format.sampleRate), privacy: .public) ch=\(format.channelCount, privacy: .public)")
        } catch {
            // The new device won't start: tear down and drop the engine so the
            // HAL input unit is released cleanly.
            log.error("audio engine could not restart after device change")
            removeConfigObserver()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            isRunning = false
        }
    }
}
