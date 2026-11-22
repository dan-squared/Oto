//
//  DemoDriver.swift
//  Oto
//
//  DEBUG-only video-capture probe. Injects a scripted final transcript through
//  the existing fake audio/speech seams so a demo needs no microphone and no
//  Apple Speech preparation. Real target capture, insertion, catcher,
//  dictionary and cleanup still run, so the footage is honest UI.
//
//  Env:
//    OTO_DEMO_TEXT   explicit final transcript (wins over mode)
//    OTO_DEMO_MODE   hold | handsFree | catcher | cleanup | dictionary
//    OTO_DEMO_AUTO   1 = begin/finish a session on a bounded timer
//

#if DEBUG

import Foundation

enum DemoDriver {
    enum DemoMode: String, Sendable {
        case hold
        case handsFree
        case catcher
        case cleanup
        case dictionary
    }

    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["OTO_DEMO_TEXT"] != nil
            || env["OTO_DEMO_AUTO"] != nil
            || env["OTO_DEMO_MODE"] != nil
    }

    static var auto: Bool {
        ProcessInfo.processInfo.environment["OTO_DEMO_AUTO"] == "1"
    }

    static var mode: DemoMode {
        let raw = ProcessInfo.processInfo.environment["OTO_DEMO_MODE"] ?? ""
        return DemoMode(rawValue: raw) ?? .hold
    }

    static var script: String {
        if let text = ProcessInfo.processInfo.environment["OTO_DEMO_TEXT"], !text.isEmpty {
            return text
        }
        return script(for: mode)
    }

    /// Pure table, pinned by test.
    nonisolated static func script(for mode: DemoMode) -> String {
        switch mode {
        case .hold:
            return "Send this to Daniel tomorrow."
        case .handsFree:
            return "This is hands-free."
        case .catcher:
            return "Remember to buy oat milk tomorrow."
        case .cleanup:
            return "Um, like, you know, send this to Daniel tomorrow, um, okay?"
        case .dictionary:
            return "oh my god that was fast"
        }
    }

    /// Fake audio has a loud stub peak so the coordinator takes the normal
    /// transcription path (no silent-skip) and the pill behaves as usual.
    static func makeServices() -> (audio: FakeAudioCapture, speech: FakeSpeechService) {
        (FakeAudioCapture(), FakeSpeechService(finalText: script))
    }

    /// One bounded session for auto mode: no loops, no repeats.
    @MainActor
    static func driveAuto(coordinator: DictationCoordinator) {
        guard auto else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let id = await coordinator.beginHold() else { return }
            try? await Task.sleep(for: .seconds(2))
            await coordinator.finish(id)
        }
    }
}

#endif
