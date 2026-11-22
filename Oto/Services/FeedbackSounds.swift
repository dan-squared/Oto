//
//  FeedbackSounds.swift
//  Oto
//
//  The three moments a dictation session can sound — press, stop, failed —
//  played from Apple's own dictation tones: `begin_record.caf` and
//  `end_record.caf` from the shared system sound library, plus the
//  "dictation could not start" tone `DictationIM.app` ships. Nothing is
//  bundled: the files are read from the system at launch, so the repo carries
//  no Apple audio and people hear the palette they already know from macOS
//  dictation.
//
//  The stop tone belongs to the release, the way native dictation sounds it —
//  not to the transcript. The result may take a second to land, and a tone
//  then would read as a late, mysterious ping; a failure still gets the error
//  tone on top, so "stop" never claims the words arrived.
//
//  Latency rule: loading an AVAudioPlayer is cheap (0.2–10 ms measured) but
//  the first `prepareToPlay()` costs ~105 ms cold, so every voice is loaded and
//  prepared at launch. `play` only picks a voice and calls `play()` — no file
//  I/O, no allocation, no Task on the press path.
//
//  Volume: these files are mastered quietly (peak RMS ≈ 0.06), so they sit
//  beside media without a trim. Media ducking zeroes the output while
//  recording, which is why cues must be emitted after
//  `DictationCoordinator.restoreMedia` — not next to the state assignment.
//

import AVFoundation
import Foundation
import os

/// The three moments one dictation session can sound. One failure cue covers
/// every failure: Apple ships exactly one, and a second error vocabulary would
/// have to be synthesised or sourced.
enum DictationCue: String, CaseIterable, Hashable, Sendable {
    /// The shortcut began a session.
    case listening
    /// The person stopped — key-up, second press, or the Flow Bar's stop.
    /// This is the native dictation moment, not the transcript's.
    case stopped
    /// Something needs the person: a permission card, a catcher, a failure.
    case failed

    /// Pure mapping: `nonisolated` so tests and logs can read it anywhere.
    nonisolated var asset: FeedbackSoundAsset {
        switch self {
        case .listening: .beginRecord
        case .stopped: .endRecord
        case .failed: .unableToStart
        }
    }
}

/// One system file per cue. The directories are OS layout, not API — verified
/// on this Mac (macOS 26 / Xcode 27 SDK) and resolved with a readability
/// check, so a future move degrades to silence instead of a broken path.
enum FeedbackSoundAsset: String, Sendable {
    case beginRecord = "begin_record.caf"
    case endRecord = "end_record.caf"
    case unableToStart = "UnableToStartDictationSound.caf"

    nonisolated var directories: [String] {
        switch self {
        case .beginRecord, .endRecord:
            [
                "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system",
            ]
        case .unableToStart:
            [
                "/System/Library/Input Methods/DictationIM.app/Contents/Resources",
            ]
        }
    }

    /// Resolves the file, preferring `directory` when one is given. An
    /// explicit directory wins outright — a caller pointing somewhere means
    /// exactly that place, never a silent fall back to the system copy (which
    /// would hide a broken test or a broken dev override).
    nonisolated func url(in directory: URL? = FeedbackSoundSettings.directoryOverride) -> URL? {
        if let directory {
            let candidate = directory.appendingPathComponent(rawValue)
            return FileManager.default.isReadableFile(atPath: candidate.path) ? candidate : nil
        }
        for path in directories {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(rawValue)
            if FileManager.default.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Kill-switch setting. Default ON (absent key = ON), same shape as
/// `MediaDuckSettings.isEnabled` so a test can pin the literal.
enum FeedbackSoundSettings {
    nonisolated static let key = "app.Oto.feedbackSounds"
    /// Dev-only: `OTO_FEEDBACK_SOUND_DIR=/tmp/cues` A/Bs a whole cue set
    /// without a rebuild. Unset in production, ignored when the file is absent.
    nonisolated static let directoryOverrideKey = "OTO_FEEDBACK_SOUND_DIR"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    nonisolated static var directoryOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment[directoryOverrideKey],
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// The seam the coordinator and the shortcut layer talk to. MainActor (the
/// player owns AVAudioPlayer instances) and Sendable so it can be captured by
/// the app's `@Sendable` feedback closure. A spy in tests is a MainActor class.
@MainActor
protocol FeedbackSounding: Sendable {
    func play(_ cue: DictationCue)
}

/// Two prepared voices per cue, so a quick second cue never cuts the first.
/// Nothing is retained after the tone ends: AVAudioPlayer stops itself and
/// the pool holds no file handles open between plays.
@MainActor
final class FeedbackSoundPlayer: FeedbackSounding {
    nonisolated static let voicesPerCue = 2

    /// Injectable so tests never depend on this Mac's OS layout.
    init(directory: URL? = FeedbackSoundSettings.directoryOverride) {
        for cue in DictationCue.allCases {
            guard let url = cue.asset.url(in: directory) else {
                Self.log.notice("cue missing: \(cue.asset.rawValue, privacy: .public)")
                continue
            }
            var voices: [AVAudioPlayer] = []
            for _ in 0 ..< Self.voicesPerCue {
                guard let voice = try? AVAudioPlayer(contentsOf: url) else { break }
                voice.volume = 1
                _ = voice.prepareToPlay()
                voices.append(voice)
            }
            guard !voices.isEmpty else {
                Self.log.error("cue unreadable: \(cue.asset.rawValue, privacy: .public)")
                continue
            }
            pool[cue] = voices
        }
    }

    /// Synchronous on purpose: the press path must not hop or allocate.
    func play(_ cue: DictationCue) {
        guard FeedbackSoundSettings.isEnabled() else { return }
        guard let voices = pool[cue], !voices.isEmpty else { return }
        let voice: AVAudioPlayer
        if let idle = voices.first(where: { !$0.isPlaying }) {
            voice = idle
        } else {
            // Both voices still ringing: take the next one round-robin.
            let next = ((cursor[cue] ?? -1) + 1) % voices.count
            cursor[cue] = next
            voice = voices[next]
            voice.stop()
        }
        voice.currentTime = 0
        _ = voice.play()
    }

    /// Test seam: which cues resolved to real files. A cue missing from this
    /// set is silent by design (see `FeedbackSoundAsset`), never a crash.
    var loadedCues: Set<DictationCue> {
        Set(pool.keys)
    }

    /// How long the start tone runs, measured from the file itself (0 when it
    /// did not resolve). The coordinator hands the media duck this much room so
    /// the tone is not cut to a click the instant preparation finishes.
    var startCueLength: Duration {
        guard let voice = pool[.listening]?.first else { return .zero }
        return .seconds(voice.duration)
    }

    private var pool: [DictationCue: [AVAudioPlayer]] = [:]
    private var cursor: [DictationCue: Int] = [:]
    private static let log = Logger(subsystem: "app.Oto", category: "feedbackSound")
}
