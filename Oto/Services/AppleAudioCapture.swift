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
actor AppleAudioCapture: AudioCaptureServing {
    struct EngineError: Error, Sendable {}

    private let bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let log = Logger(subsystem: "app.Oto", category: "audio")

    private var engine = AVAudioEngine()
    private var isRunning = false
    private var configObserver: NSObjectProtocol?
    private var handlingConfigChange = false

    init(bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) {
        self.bufferHandler = bufferHandler
    }

    func start() async throws {
        try restart()
        isRunning = true
    }

    func stop() async {
        teardown()
    }

    func cancel() async {
        teardown()
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

    private func installTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError()
        }

        // Capture the handler (not self): the tap closure runs on the
        // realtime thread and must not touch actor state.
        let handler = bufferHandler
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            handler?(buffer)
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
    private func handleConfigurationChange() {
        // Rebuilding can itself emit another change; never re-enter, and
        // ignore changes once stopped.
        guard isRunning, !handlingConfigChange else { return }
        handlingConfigChange = true
        defer { handlingConfigChange = false }

        do {
            try restart()
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
