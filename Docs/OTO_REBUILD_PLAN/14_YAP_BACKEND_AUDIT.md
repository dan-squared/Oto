# Yap backend audit for Oto

> **Rebuild edition:** This audit is the backend reference for the new implementation. Recreate behavior and contracts in Oto-owned code; do not vendor or blindly copy Yap source.

This document records the useful engineering patterns found in the local audit of [FrigadeHQ/yap](https://github.com/FrigadeHQ/yap). The source was reviewed from a shallow clone of the public repository on 2026-09-19. The goal is to borrow proven boundary decisions, not copy Yap’s product or dependencies wholesale.

Canonical reference: [https://github.com/FrigadeHQ/yap](https://github.com/FrigadeHQ/yap). A future agent can refresh the audit with `git clone https://github.com/FrigadeHQ/yap.git /private/tmp/yap-reference`, then inspect the commit used for the task. The existing local audit clone is `/private/tmp/oto-yap-audit`; it is evidence, not a vendored dependency.

## What Yap gets right

### 1. One small coordinator owns the recording lifecycle

`Sources/Coordinator/RecordingCoordinator.swift` is the central owner of idle, recording, transcription, insertion, cancel, and recovery behavior. Its services are injected through protocols, which lets tests drive the flow without a microphone, window server, or speech runtime.

Oto should keep the same rule: `DictationSessionController` (or its future coordinator actor) owns session transitions. A view, audio callback, engine, or shortcut monitor may emit an event, but must not independently finalize or insert text.

### 2. Audio capture starts before speech initialization completes

Yap’s `DictationSession`/`AudioBufferRelay` path buffers audio while `SpeechAnalyzer` is attaching, then flushes the buffered input. This prevents the first syllables from disappearing during engine startup.

Oto’s equivalent must remain bounded: a short startup buffer is useful, but it must have a hard capacity, a clear overflow policy, and cancellation cleanup. Do not turn this into an unbounded audio queue.

### 3. The analyzer asks for the compatible audio format

Yap uses the analyzer’s required format and a dedicated converter before yielding `AnalyzerInput`. This avoids assuming that every microphone is 16 kHz or that Bluetooth and built-in microphones have the same layout.

Oto should continue to derive the format from `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` and keep conversion outside the realtime tap.

### 4. Apple Speech is the only transcription path

Yap intentionally avoids `SFSpeechRecognizer` because older paths can fall back to Apple servers for some locales. It uses `SpeechAnalyzer`/`SpeechTranscriber`, enables volatile results for previews, and stops with an explicit unsupported/offline state when the on-device asset is unavailable.

This matches Oto’s offline promise. Asset preparation belongs in Settings; the shortcut must never trigger a download or silently switch engines.

### 5. Function-row keys use a HID event tap

Yap’s `FunctionKeyMonitor.swift` explains why AppKit and Carbon monitors are insufficient for the microphone/function row: macOS may consume media-row events before those monitors see them. It installs a head `CGEvent` HID tap, handles key-down synchronously, consumes the event to prevent macOS Dictation from opening, and dispatches the app action afterward.

Oto already has the same architectural seam in `GlobalHotkeyMonitor`. Keep the synchronous “should consume?” decision in the tap, keep session work out of the callback, re-enable taps disabled by timeout, and test F5 plus the dedicated Dictation-key alias on real hardware.

### 6. Repeats and press/release are modeled as a value-state machine

Yap’s tests cover a key-down, held repeat, key-up sequence instead of treating every event as a toggle. This is the right mental model for Oto:

- Hold-to-talk: first down starts; repeats are ignored; matching up finishes.
- Hands-free: first down toggles on; repeats and key-up do nothing; next non-repeat down toggles off.
- A lost key-up or monitor restart resets the state safely.

The onboarding recorder must prove the actual global path, not just save a key label.

### 7. Clipboard restoration is ownership-aware

Yap writes a session marker into the pasteboard and restores the previous snapshot only if the pasteboard’s change count and marker still match. This protects a person who copies something while an Electron/Chromium target is still reading Oto’s temporary text.

Oto should preserve this pattern, but keep the restoration delay measured and configurable through an injected clock in tests. A fixed delay without ownership checks is unsafe; ownership checks without allowing slow targets are also unsafe.

### 8. Paste fallback is layered for real applications

Yap tries System Events first and has a synthetic full Command-V fallback. It sends a real Command key-down/V key-down/V key-up/Command key-up sequence because Chromium/Electron apps can ignore a simplified event with only a modifier flag.

Oto should keep a layered insertion service with explicit outcomes: pasted, left on clipboard, secure input blocked, target unavailable, or permission missing. It must never claim success merely because a key event was posted.

### 9. Audio devices are rebuilt, not patched in place

Yap observes `AVAudioEngineConfigurationChange`, removes the old observer, tears down the tap, creates a fresh engine, checks for a degenerate format, and restarts. The comments call out an important macOS hazard: `installTap` can throw an Objective-C exception when a device’s format is transiently invalid, and Swift cannot catch that exception.

Oto should retain this fresh-engine recovery approach and add deterministic tests for device disconnect, Bluetooth format changes, and default-device changes during recording.

### 10. Permission recovery explains signed-build identity

Yap explicitly explains that ad-hoc development builds can receive a new TCC identity after each rebuild, even when System Settings appears to show a checked permission. Its reset/re-grant action uses `tccutil` for development recovery and distinguishes microphone, speech, Accessibility, and Automation.

Oto should keep this explanation in developer diagnostics, but avoid making destructive permission resets part of the normal user flow. Release builds must be stably signed before cross-app insertion claims are made.

### 11. History is local and bounded

Yap keeps history in SwiftData, with search/copy/delete behavior and no audio retention. Oto’s current bounded local history is compatible with this principle. Keep partials and active-app context out of history, make retention opt-in, and make deletion domain-specific.

### 12. The small scope is a performance feature

Yap deliberately avoids a model catalog, cloud account, telemetry, and a browser runtime. This is a useful product constraint for Oto’s first release: Apple Speech owns the speech model lifecycle, and Oto owns only capture, deterministic writing rules, insertion, recovery, and a small native UI.

## Practices Oto should not copy blindly

- Yap uses the third-party `KeyboardShortcuts` package for normal shortcuts. Oto may pin a verified version behind an explicit ordinary-shortcut boundary, while the function-row/HID path remains separate. The package does not remove the need for real-device QA. See [12_SHORTCUT_BACKEND_PLAN.md](12_SHORTCUT_BACKEND_PLAN.md).
- Yap’s permission flow includes Automation because its chosen paste route uses System Events. Oto should keep the minimum permission set justified by its actual insertion implementation and state the exact fallback behavior.
- Yap’s product has a compact onboarding window and custom HUD. Oto’s Settings must remain a native `Settings` scene; the Flow Bar is the only custom visual exception.
- Yap’s README reports memory and speed observations. Oto should not copy those numbers; measure Oto on supported devices and label evidence as automated, simulator, or real-device.

## Concrete Oto follow-ups

- [x] Add a bounded startup relay around `SpeechAnalyzer` initialization and test first-word retention.
- [x] Verify Oto’s existing `GlobalHotkeyMonitor` handles key-up as well as key-down in the HID tap and resets after tap timeout.
- [ ] Add onboarding calibration that exercises the real global shortcut in both interaction modes.
- [x] Keep captured target app identity and target screen immutable through finalization.
- [x] Add pasteboard marker/change-count tests for user copy during delayed Chromium paste.
- [x] Add fresh-engine recovery for device changes; device-level validation remains open.
- [ ] Add stable release-signing checks before claiming Accessibility/Automation reliability.
- [ ] Keep all Apple Speech asset preparation explicit in Settings and offline after setup.

## Primary source files reviewed

- `Sources/Coordinator/RecordingCoordinator.swift`
- `Sources/Services/FunctionKeyMonitor.swift`
- `Sources/Services/ModifierHotkeyMonitor.swift`
- `Sources/Services/AudioCaptureService.swift`
- `Sources/Services/TranscriptionService.swift`
- `Sources/Services/TextInjector.swift`
- `Sources/Services/PermissionsManager.swift`
- `Tests/RecordingCoordinatorTests.swift`
- `Tests/FunctionKeyTriggerTests.swift`
- `Tests/PasteboardSnapshotTests.swift`
