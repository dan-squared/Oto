//
//  WritingPolishService.swift
//  Oto
//
//  One Intelligence action: Clean up. Post-transcript only: receives finalized
//  text, streams back a draft. Never touches audio, insertion, or storage —
//  the coordinator owns those, and this service is not in its path.
//
//  Model discipline (grep-gated, same pattern as the download gate in
//  SpeechAssetPreparer): `SystemLanguageModel` ONLY. Never
//  `PrivateCloudComputeLanguageModel` (cloud — banned by the product
//  boundary), never shell out to `fm respond` / `fm serve` (the CLI license
//  binds programmatic CLI access; the framework path needs no CLI at all).
//

import Foundation
import FoundationModels
import os

/// Availability of the on-device writing model, mapped to honest user copy
/// at the call site (never a bare bool — every unavailable reason teaches).
enum PolishAvailability: Equatable, Sendable {
    case available
    case unavailable(copy: String)
}

/// The single Intelligence seam. `Sendable`-conforming so the coordinator,
/// panes, and sheets can all hold it without isolation questions.
protocol PolishServing: Sendable {
    /// Synchronous property read — safe to call from anywhere, including
    /// tests and `.onAppear`. Never downloads, never prompts.
    func availability() -> PolishAvailability
    /// Streams cumulative draft snapshots. Finishes empty on error (the UI
    /// treats empty as "couldn't clean up", raw intact). Cancellation
    /// propagates: breaking the loop cancels generation.
    func streamCleanup(_ text: String) -> AsyncStream<String>
    /// Warms the model while a preview surface is already open, so the first
    /// tap streams instantly. Memory cost only while visible; never called
    /// on the dictation path.
    func prewarm()
}

/// Rule for the Clean up affordance: offered only when the user left it on
/// AND the model is actually available. Pure — unit-tested.
func polishActionVisible(availability: PolishAvailability, enabled: Bool) -> Bool {
    enabled && availability == .available
}

/// Live implementation over Apple's on-device model.
final class LivePolishService: PolishServing, @unchecked Sendable {
    private let log = Logger(subsystem: "app.Oto", category: "polish")

    /// Fixed instructions (own copy — pinned by test, changeable with the
    /// test). Narrowly rewriting-class: grammar + filler, meaning preserved,
    /// same language, output only.
    nonisolated static let instructions =
        "Clean up the grammar and remove filler words. Preserve the meaning exactly. " +
        "Keep the same language. Output only the cleaned text, no commentary."

    private static let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 512)

    private let lock = NSLock()
    /// Single-slot prewarmed session (codebase pattern: lock-disciplined,
    /// invalidated after one use — a session accumulates transcript context,
    /// and cleanup must stay stateless).
    nonisolated(unsafe) private var warmSession: LanguageModelSession?

    func availability() -> PolishAvailability {
        Self.map(SystemLanguageModel.default.availability)
    }

    /// Pure availability→copy mapping (unit-tested). The enum is non-frozen,
    /// so `@unknown default` future-proofs new reasons as honest ignorance.
    static func map(_ availability: SystemLanguageModel.Availability) -> PolishAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(copy: "This Mac doesn't support Apple Intelligence, so cleanup isn't available.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(copy: "Turn on Apple Intelligence in System Settings to use cleanup.")
            case .modelNotReady:
                return .unavailable(copy: "The on-device model is still preparing. Try again shortly.")
            @unknown default:
                // Future reasons must surface as honest ignorance, never
                // as availability.
                return .unavailable(copy: "Cleanup isn't available right now.")
            }
        }
    }

    func prewarm() {
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        lock.withLock { warmSession = session }
    }

    func streamCleanup(_ text: String) -> AsyncStream<String> {
        let session: LanguageModelSession = lock.withLock {
            defer { warmSession = nil }
            return warmSession ?? LanguageModelSession(instructions: Self.instructions)
        }
        let prompt = "Clean up this dictation transcript:\n\(text)"
        return AsyncStream { continuation in
            let task = Task {
                do {
                    let stream = session.streamResponse(to: prompt, options: Self.options)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    log.error("cleanup stream failed: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Scripted fake: chunks in order, optional error (finishes empty),
/// availability override. No store references — it cannot persist by
/// construction (pinned by the no-persistence test).
final class FakePolishService: PolishServing {
    var availabilityResult: PolishAvailability = .available
    var chunks: [String] = []
    var shouldError = false

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedPrompts: [String] = []
    nonisolated(unsafe) private var prewarmCount = 0

    var prompts: [String] { lock.withLock { recordedPrompts } }
    var prewarms: Int { lock.withLock { prewarmCount } }

    func availability() -> PolishAvailability { availabilityResult }

    func prewarm() {
        lock.withLock { prewarmCount += 1 }
    }

    func streamCleanup(_ text: String) -> AsyncStream<String> {
        lock.withLock { recordedPrompts.append(text) }
        let chunks = chunks
        let shouldError = shouldError
        return AsyncStream { continuation in
            let task = Task {
                guard !shouldError else {
                    continuation.finish()
                    return
                }
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
