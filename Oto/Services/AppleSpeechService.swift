//
//  AppleSpeechService.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
import Speech
import Synchronization
import os

/// Runtime failures from the live speech path. `prepare()` throws
/// `SpeechReadiness` (never downloads); `finish()` may throw this.
enum SpeechSessionError: Error, Sendable {
    case excessiveAudioLoss(dropped: Int)
    case engineFailure(String)
    /// Zero buffers reached the feeder all session (dead/zombie mic):
    /// fail loud instead of completing empty (bt-sco-flap.md).
    case noAudioCaptured
}

extension SpeechSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .excessiveAudioLoss(let dropped):
            return "Too much audio was lost (\(dropped) buffers dropped)."
        case .engineFailure(let detail):
            return "Speech engine failed (\(detail))."
        case .noAudioCaptured:
            return "No audio reached the microphone."
        }
    }
}

/// Realtime feeder: the ONLY object the audio thread touches. Converter +
/// continuation live behind one `Synchronization.Mutex`; session state stays
/// on the actor. `feed` drops (never blocks) when no session is configured.
nonisolated final class AudioFeedBox: Sendable {
    private struct State {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var format: AVAudioFormat?
        var conversionFailures = 0
        let converter = BufferConverter()
    }

    private struct BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private let state = Mutex(State())

    init() {}

    func createStream() -> AsyncStream<AnalyzerInput> {
        state.withLock { s in
            s.converter.reset()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            s.continuation = continuation
            s.conversionFailures = 0
            return stream
        }
    }

    func configure(format: AVAudioFormat) {
        state.withLock { s in
            s.format = format
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let boxed = BufferBox(buffer: buffer)
        let deliverable: (AsyncStream<AnalyzerInput>.Continuation, AnalyzerInput)? = state.withLock { s in
            guard let continuation = s.continuation, let format = s.format else {
                return nil
            }
            let converted: AVAudioPCMBuffer
            do {
                converted = try s.converter.convertBuffer(boxed.buffer, to: format)
            } catch {
                // Counted, never logged per-buffer (realtime thread): surfaced
                // once per session at finish (bt-sco-flap.md). Silence with a
                // number beats silence with a shrug.
                s.conversionFailures += 1
                return nil
            }
            guard converted.frameLength > 0 else { return nil }
            return (continuation, AnalyzerInput(buffer: converted))
        }
        if let (continuation, input) = deliverable {
            continuation.yield(input)
        }
    }

    func conversionFailureCount() -> Int {
        state.withLock { $0.conversionFailures }
    }

    func finishInput() {
        let pending: (AsyncStream<AnalyzerInput>.Continuation, AnalyzerInput?)? = state.withLock { s in
            guard let continuation = s.continuation else {
                s.format = nil
                s.converter.reset()
                return nil
            }
            var trailing: AnalyzerInput?
            if let format = s.format,
               let flushed = try? s.converter.flush(to: format),
               flushed.frameLength > 0
            {
                trailing = AnalyzerInput(buffer: flushed)
            }
            s.continuation = nil
            s.format = nil
            s.converter.reset()
            return (continuation, trailing)
        }
        if let (continuation, trailing) = pending {
            if let trailing {
                continuation.yield(trailing)
            }
            continuation.finish()
        }
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

    private let relay: AudioBufferRelay
    private let permissions: PermissionsManager
    private let feedBox = AudioFeedBox()
    private let log = Logger(subsystem: "app.Oto", category: "speech")

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var finalizedText = ""
    private var contextualTerms: [String] = []

    init(
        relay: AudioBufferRelay,
        permissions: PermissionsManager = PermissionsManager()
    ) {
        self.relay = relay
        self.permissions = permissions
    }

    func setContextualStrings(_ terms: [String]) async {
        contextualTerms = terms
    }

    /// Resolve locale → verify assets → build session. Inspects readiness
    /// ONLY: anything but ready throws a specific `SpeechReadiness` with a
    /// recovery message. This method never downloads.
    func prepare() async throws {
        // Defensively tear down any stale active session so a leaked analyzer
        // or relay sink can never corrupt a new dictation.
        if analyzer != nil || transcriber != nil || resultTask != nil {
            await cancel()
        }

        var prepared = false
        defer {
            if !prepared {
                relay.reset()
            }
        }

        // 1. Microphone first (most actionable recovery).
        guard await permissions.ensureMicrophone() else {
            throw SpeechReadiness.microphoneDenied
        }

        guard SpeechTranscriber.isAvailable else {
            throw SpeechReadiness.unsupportedLocale
        }

        // 2. Resolve the system locale against what Apple supports. P3:
        // flag-gated snapshot (zero awaits on hit); the requery path reads
        // per session, so a language change without relaunch still dictates
        // (audit N3 — the snapshot invalidates on locale change, Settings
        // prepare, and age cap, so the guarantee survives the cache).
        let tLocale = PerfTrace.begin(.localeResolve)
        let resolved: Locale
        var pendingSnapshotSupported: [Locale]?
        if LocaleCacheExperiment.current().enabled,
           case .use(let cached) = LocaleSnapshotCache.shared.resolve()
        {
            resolved = cached
        } else {
            let supported = await SpeechTranscriber.supportedLocales
            guard let match = SpeechLocaleMatching.bestMatch(for: .current, in: supported) else {
                PerfTrace.end(.localeResolve, tLocale)
                throw SpeechReadiness.unsupportedLocale
            }
            resolved = match
            pendingSnapshotSupported = supported
        }
        PerfTrace.end(.localeResolve, tLocale)

        // 3. Readiness inspection — probe module for the status call.
        // Omit volatile results and audioTimeRange unless a live partial
        // listener is wired so the recognizer does no unnecessary work.
        let reportingOptions: Set<SpeechTranscriber.ReportingOption> = onPartial != nil ? [.volatileResults] : []
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: []
        )
        let tProbe = PerfTrace.begin(.assetProbe)
        let installed = await SpeechTranscriber.installedLocales
        let status = await AssetInventory.status(forModules: [transcriber])
        let readiness = SpeechReadinessMapper.map(
            microphoneGranted: true,
            resolvedLocale: resolved,
            installedLocales: installed,
            assetStatus: status
        )
        PerfTrace.end(.assetProbe, tProbe)
        // P3: refresh the snapshot from the values just read (requery path
        // only — a cache hit already resolved from these). Stored even when
        // readiness is not ready: the snapshot reflects system state, and
        // the next press re-probes, so the honest failure recurs; a
        // successful Settings prepare invalidates anyway.
        if let supported = pendingSnapshotSupported {
            LocaleSnapshotCache.shared.store(supported: supported, installed: installed)
        }
        guard readiness == .ready else { throw readiness }

        // 4. Build the single-analyzer session with lingering model retention
        // and user-initiated priority for responsive consecutive dictations.
        let tWarm = PerfTrace.begin(.engineWarm)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        if !contextualTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualTerms
            do {
                try await analyzer.setContext(context)
            } catch {
                log.notice("failed to set contextual strings: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            PerfTrace.end(.engineWarm, tWarm)
            throw SpeechSessionError.engineFailure("no compatible audio format")
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            PerfTrace.end(.engineWarm, tWarm)
            throw SpeechSessionError.engineFailure(error.localizedDescription)
        }

        let stream = feedBox.createStream()
        feedBox.configure(format: format)
        self.transcriber = transcriber
        self.analyzer = analyzer
        finalizedText = ""

        resultTask = Task { [weak self] in
            await self?.consumeResults(for: transcriber)
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            PerfTrace.end(.engineWarm, tWarm)
            feedBox.finishInput()
            await analyzer.cancelAndFinishNow()
            let task = resultTask
            resultTask = nil
            task?.cancel()
            await task?.value
            teardown()
            throw SpeechSessionError.engineFailure(error.localizedDescription)
        }

        // Attach AFTER the stream exists: pre-attach audio buffered in the
        // relay flushes here in order (capture-first, no lost first words).
        let feedBox = self.feedBox
        relay.attach { buffer in feedBox.feed(buffer) }
        prepared = true
        PerfTrace.end(.engineWarm, tWarm)
        log.info("speech prepared")
    }

    /// Close input → flush trailing frames → finalize through end of input →
    /// drain all final results → release. Then the drop counter decides: past
    /// threshold the transcript is untrustworthy and this throws instead.
    func finish() async throws -> String {
        feedBox.finishInput()
        let task = resultTask
        let tFinal = PerfTrace.begin(.finalizeAwait)
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
            PerfTrace.end(.finalizeAwait, tFinal)
            // Await natural completion of `consumeResults` so every final
            // result emitted during finalization drains into `finalizedText`.
            await task?.value
        } catch {
            PerfTrace.end(.finalizeAwait, tFinal)
            // Non-fatal by itself (Yap-proven): finals collected so far
            // still count; cancel and await the consumer before teardown.
            log.error("finalize failed, keeping collected finals")
            task?.cancel()
            await task?.value
        }
        resultTask = nil

        let text = finalizedText
        let dropped = relay.droppedBufferCount()
        let delivered = relay.deliveredBufferCount()
        let convFail = feedBox.conversionFailureCount()
        teardown()
        log.info("speech finished delivered=\(delivered, privacy: .public) dropped=\(dropped, privacy: .public) convFail=\(convFail, privacy: .public) chars=\(text.count, privacy: .public)")

        // Dead/zombie mic: zero buffers all session. Fail loud with an
        // honest reason instead of completing empty (bt-sco-flap.md).
        if delivered == 0 {
            throw SpeechSessionError.noAudioCaptured
        }
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
        let task = resultTask
        resultTask = nil
        task?.cancel()
        await task?.value
        teardown()
        log.info("speech cancelled")
    }

    // MARK: - Private

    private func consumeResults(for transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                guard !Task.isCancelled, self.transcriber === transcriber else { break }
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
