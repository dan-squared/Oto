//
//  PermissionsManager.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AVFoundation
import Foundation
import Speech

/// Microphone + speech authorization with exact states (07 §4.4).
/// Both APIs verified current in the macOS 27 SDK (neither deprecated).
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
    /// speculatively at launch (07 §5.1).
    func requestMicrophone() async -> Bool {
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

    // MARK: - Speech recognition auth (exposed for Phase 5 UI; the Phase 2
    // dictation path does not gate on it — 07's permission table has no
    // speech-auth row, and prompting speculatively is banned.)

    func speechStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
