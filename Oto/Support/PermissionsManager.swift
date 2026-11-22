//
//  PermissionsManager.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import ApplicationServices
import AVFoundation
import Foundation

/// Microphone authorization with exact states (07 §4.4).
///
/// Speech Recognition is deliberately absent: Oto transcribes with
/// `SpeechAnalyzer`/`SpeechTranscriber`, which are authorized by the
/// microphone, not by `SFSpeechRecognizer.requestAuthorization`. The app never
/// introduces `SFSpeechRecognizer`, so it declares no speech-usage string — a
/// TCC request for that grant aborts the process when the launcher (Xcode,
/// Conductor) carries no `NSSpeechRecognitionUsageDescription` (three crash
/// reports, 2026-10-29…31).
/// Privacy copy stays to the framework guarantee: on-device modules do not
/// send captured audio to Apple servers (07 §3.1) — never claim more.
struct PermissionsManager: Sendable {
    enum MicrophoneStatus: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
    }

    func microphoneStatus() -> MicrophoneStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Asks only when the person attempts dictation or preparation — never
    /// speculatively at launch (07 §5.1). Nonisolated: the system calls
    /// the handler on a background TCC queue, and a MainActor-inherited
    /// closure traps there on entry (Debug SIGTRAP) — the callback must
    /// never inherit an executor. Resuming the continuation from any
    /// thread is explicitly legal (it hops to the awaiting task).
    nonisolated func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Returns true when capture may proceed: already granted, or granted
    /// through a just-in-time prompt.
    func ensureMicrophone() async -> Bool {
        switch microphoneStatus() {
        case .granted:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await requestMicrophone()
        }
    }
}

extension PermissionsManager {
    /// The AX prompt options key. Spelled as a literal because the C global
    /// (`kAXTrustedCheckOptionPrompt`) imports as shared mutable state and
    /// is rejected from checked contexts under Swift 6. Value verified at
    /// runtime 2026-09-21 (prints "AXTrustedCheckOptionPrompt"); stable
    /// since 10.9 per the SDK headers.
    nonisolated static let axPromptKey = "AXTrustedCheckOptionPrompt"
}
