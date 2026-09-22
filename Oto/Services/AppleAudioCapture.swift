//
//  AppleAudioCapture.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
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
struct RebuildDebouncePolicy: Sendable {
    /// Minimum quiet between rebuilds. Starting value from the 2026-09-21
    /// Jabra trace (bring-up flurry inside one second); the device matrix
    /// tunes it, never guesses (plan/bt-sco-flap.md).
    var quietNanoseconds: UInt64 = 1_500_000_000

    nonisolated func shouldRebuildNow(now: Date, lastRebuild: Date?) -> Bool {
        guard let lastRebuild else { return true }
        return now.timeIntervalSince(lastRebuild) * 1_000_000_000 >= Double(quietNanoseconds)
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
    private var lastRebuild: Date?
    private var pendingRebuild: Task<Void, Never>?
    /// Voice-presence signal (silent-skip workstream): peak absolute
    /// sample seen since `start`. Lock-guarded `nonisolated(unsafe)` like
    /// the relay — the tap closure runs on the realtime thread and must
    /// not touch actor state (installTap comment below).
    private let peakLock = NSLock()
    private nonisolated(unsafe) var sessionPeak: Float = 0

    init(
        bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        debounce: RebuildDebouncePolicy = RebuildDebouncePolicy()
    ) {
        self.bufferHandler = bufferHandler
        self.debounce = debounce
    }

    func start() async throws {
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
        peakLock.withLock { sessionPeak }
    }

    /// Realtime-safe peak note (tap thread only touches the lock + Float).
    /// Stride-4 scan of every channel: ~1k samples per 4096-frame buffer,
    /// microseconds — no conversion, no allocation, no logging.
    nonisolated func noteBufferPeak(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        var peak: Float = 0
        for ch in 0..<channelCount {
            var f = 0
            while f < frames {
                peak = max(peak, abs(channels[ch][f]))
                f += 4
            }
        }
        guard peak > 0 else { return }
        peakLock.lock()
        sessionPeak = max(sessionPeak, peak)
        peakLock.unlock()
    }

    nonisolated func resetSessionPeak() {
        peakLock.lock()
        sessionPeak = 0
        peakLock.unlock()
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
        if debounce.shouldRebuildNow(now: Date(), lastRebuild: lastRebuild) {
            pendingRebuild?.cancel()
            pendingRebuild = nil
            rebuildForDeviceChange()
        } else {
            // Inside the window: collapse into one scheduled rebuild after
            // quiet. A newer change re-arms the timer (never stacks).
            pendingRebuild?.cancel()
            let quiet = debounce.quietNanoseconds
            pendingRebuild = Task { [weak self] in
                try? await Task.sleep(nanoseconds: quiet)
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
        lastRebuild = Date()

        do {
            try restart()
            let format = engine.inputNode.outputFormat(forBus: 0)
            log.info("audio rebuilt after device change rate=\(Int(format.sampleRate), privacy: .public) ch=\(format.channelCount, privacy: .public)")
        } catch {
            // The new device won't start: tear down rather than look alive
            // while recording nothing.
            log.error("audio engine could not restart after device change")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
    }
}
