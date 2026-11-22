//
//  ZeroAudioTests.swift
//  OtoTests
//
//  bt-sco-flap.md: a session that captured zero buffers (dead/zombie mic)
//  must fail loud with .noAudioCaptured — never complete empty. The service
//  path is headless-testable (no analyzer without prepare); the coordinator
//  path is fake-driven.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct ZeroAudioTests {
    // No prepare, no audio: finish must throw noAudioCaptured, not return "".
    @Test func finishWithoutAudioThrowsNoAudioCaptured() async {
        let service = AppleSpeechService(relay: AudioBufferRelay())
        do {
            _ = try await service.finish()
            Issue.record("expected noAudioCaptured, got empty success")
        } catch let error as SpeechSessionError {
            guard case .noAudioCaptured = error else {
                Issue.record("expected noAudioCaptured, got \(error)")
                return
            }
        } catch {
            Issue.record("expected SpeechSessionError, got \(error)")
        }
    }

    @Test func noAudioCapturedCarriesHonestMessage() {
        #expect(SpeechSessionError.noAudioCaptured.errorDescription == "No audio reached the microphone.")
    }
}
