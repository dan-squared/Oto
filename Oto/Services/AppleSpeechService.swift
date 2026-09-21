//
//  AppleSpeechService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
import Speech
import os

/// Runtime failures from the live speech path. `prepare()` throws
/// `SpeechReadiness` (never downloads); `finish()` may throw this.
enum SpeechSessionError: Error, Sendable {
    case excessiveAudioLoss(dropped: Int)
    case engineFailure(String)
}

extension SpeechSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .excessiveAudioLoss(let dropped):
            return "Too much audio was lost (\(dropped) buffers dropped)."
        case .engineFailure(let detail):
            return "Speech engine failed (\(detail))."
        }
    }
}

/// Realtime feeder: the ONLY object the audio thread touches. Converter +
/// continuation live behind one lock; session state stays on the actor.
/// `feed` drops (never blocks) when no session is configured.
final class AudioFeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private let converter = BufferConverter()

    func createStream() -> AsyncStream<AnalyzerInput> {
        lock.lock()
        defer { lock.unlock() }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        return stream
    }

    func configure(format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.format = format
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let continuation, let format else {
            lock.unlock()
            return
        }
        let converted: AVAudioPCMBuffer?
        do {
            converted = try converter.convertBuffer(buffer, to: format)
        } catch {
            converted = nil
        }
        lock.unlock()
        if let converted {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finishInput() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
        format = nil
    }
}

/// Real `SpeechServing` over `SpeechAnalyzer` + `SpeechTranscriber`
/// (fixed module choice per build, 07 §3.3 — not selectable, no fallback).
/// Short-lived analyzer per session, released at every terminal path
/// (07 §3.2). Session ordering follows 07 §4.3 tactics 5–9 and the
/// Yap-proven finish sequence; the download-during-dictation behavior is
/// deliberately NOT adopted (locked Oto rule).
actor AppleSpeechService: SpeechServing {
    /// Volatile (display-only) partials. Unwired in Phase 2 — the Flow Bar
    /// lands in Phase 6. Finals are the only path to insertion.
    var onPartial: (@Sendable (String) -> Void)?

    private let locale: Locale
    private let relay: AudioBufferRelay
    private let permissions: PermissionsManager
    private let feedBox = AudioFeedBox()
    private let log = Logger(subsystem: "app.Oto", category: "speech")

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var finalizedText = ""

    init(
        locale: Locale = .current,
        relay: AudioBufferRelay,
        permissions: PermissionsManager = PermissionsManager()
    ) {
        self.locale = locale
        self.relay = relay
        self.permissions = permissions
    }

    /// Resolve locale → verify assets → build session. Inspects readiness
    /// ONLY: anything but ready throws a specific `SpeechReadiness` with a
    /// recovery message. This method never downloads.
    func prepare() async throws {
        // 1. Microphone first (most actionable recovery).
        guard await permissions.ensureMicrophone() else {
            throw SpeechReadiness.microphoneDenied
        }

        // 2. Resolve the system locale against what Apple supports.
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = SpeechLocaleMatching.bestMatch(for: locale, in: supported) else {
            throw SpeechReadiness.unsupportedLocale
        }

        // 3. Readiness inspection — probe module for the status call.
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let installed = await SpeechTranscriber.installedLocales
        let status = await AssetInventory.status(forModules: [transcriber])
        let readiness = SpeechReadinessMapper.map(
            microphoneGranted: true,
            resolvedLocale: resolved,
            installedLocales: installed,
            assetStatus: status
        )
        guard readiness == .ready else { throw readiness }

        // 4. Build the single-analyzer session.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechSessionError.engineFailure("no compatible audio format")
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            throw SpeechSessionError.engineFailure(error.localizedDescription)
        }

        let stream = feedBox.createStream()
        feedBox.configure(format: format)
        self.transcriber = transcriber
        self.analyzer = analyzer
        finalizedText = ""

        resultTask = Task { [weak self] in
            await self?.consumeResults()
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            teardown()
            throw SpeechSessionError.engineFailure(error.localizedDescription)
        }

        // Attach AFTER the stream exists: pre-attach audio buffered in the
        // relay flushes here in order (capture-first, no lost first words).
        let feedBox = self.feedBox
        relay.attach { buffer in feedBox.feed(buffer) }
        log.info("speech prepared")
    }

    /// Close input → drain once → finalize through end of input → collect
    /// finals → release. Then the drop counter decides: past threshold the
    /// transcript is untrustworthy and this throws instead of returning it.
    func finish() async throws -> String {
        feedBox.finishInput()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Non-fatal by itself (Yap-proven): finals collected so far
            // still count; teardown proceeds below.
            log.error("finalize failed, keeping collected finals")
        }
        resultTask?.cancel()
        resultTask = nil

        let text = finalizedText
        let dropped = relay.droppedBufferCount()
        teardown()

        if dropped > AudioBufferRelay.maximumDroppedBeforeFailure {
            throw SpeechSessionError.excessiveAudioLoss(dropped: dropped)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Serialized teardown: stop delivery, end analysis now, release refs.
    /// Never runs concurrently with finalization (coordinator guarantees
    /// finish/cancel mutual exclusion).
    func cancel() async {
        feedBox.finishInput()
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        resultTask = nil
        teardown()
        log.info("speech cancelled")
    }

    // MARK: - Private

    private func consumeResults() async {
        guard let transcriber else { return }
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalizedText += text
                    onPartial?(finalizedText)
                } else {
                    onPartial?(finalizedText + text)
                }
            }
        } catch {
            // Stream ended or task cancelled — teardown owns the outcome.
        }
    }

    private func teardown() {
        relay.reset()
        transcriber = nil
        analyzer = nil
        finalizedText = ""
    }
}
