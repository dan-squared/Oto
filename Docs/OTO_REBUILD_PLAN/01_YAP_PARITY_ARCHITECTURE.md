# YAP parity architecture

This document translates the local Yap audit into an Oto-owned design. It describes behavior and boundaries to reproduce; it does not authorize copying Yap source. The audited clone contains an MIT `LICENSE`, but any copied expression still requires attribution and a deliberate maintenance decision. Prefer reimplementing the contracts below in Oto’s own code.

## Local source reviewed

The audit was performed against `/private/tmp/oto-yap-audit` on 2026-09-19. The most useful files were:

| Yap source | Oto lesson |
| --- | --- |
| `Sources/Coordinator/RecordingCoordinator.swift` | One owner for start, stop, cancel, insert, history, and HUD. |
| `Sources/Services/DictationSession.swift` | Start capture before analyzer preparation; keep a session-level relay. |
| `Sources/Services/AudioBufferRelay.swift` | Lock-protected bounded queue prevents first-word loss without unbounded memory. |
| `Sources/Services/StreamingTranscriber.swift` | Feed the format required by SpeechAnalyzer and publish partials separately from final text. |
| `Sources/Services/FunctionKeyMonitor.swift` | F-keys and the built-in Dictation key need a head HID event tap. |
| `Sources/Services/ModifierHotkeyMonitor.swift` | Ordinary modifier shortcuts are a separate backend converging on the same coordinator. |
| `Sources/Services/TextInjector.swift` | Capture target early, paste through layered routes, and restore the clipboard only while Oto owns it. |
| `Sources/Services/PermissionsManager.swift` | Explain TCC identity and distinguish microphone, speech, Accessibility, and Automation. |
| `Sources/Services/AudioCaptureService.swift` | Rebuild the audio engine after device configuration changes. |
| `Sources/Services/HistoryStore.swift` | Keep bounded final-only local history; do not retain audio or partials. |
| `Tests/RecordingCoordinatorTests.swift` | Test lifecycle with fake services, not a microphone or window server. |
| `Tests/FunctionKeyTriggerTests.swift` | Test physical key down, repeat suppression, and key up as a state machine. |
| `Tests/PasteboardSnapshotTests.swift` | Test clipboard ownership and user-copy races. |

## What to reproduce

### 1. Two input paths, one transition path

```text
ordinary shortcut (modifier + key)
    -> AppKit/KeyboardShortcuts boundary
    -> ShortcutTransitionState

F5 / Dictation key / function row
    -> CGEvent HID tap
    -> ShortcutTransitionState

ShortcutTransitionState
    -> DictationCoordinator.begin / finish / toggle
```

The HID callback decides synchronously whether to consume an event. It must not start audio, await, touch SwiftUI, or finalize text. Both backends must produce the same value events so hold-to-talk behavior cannot drift between keyboards.

```swift
enum ShortcutEvent: Sendable, Equatable {
    case keyDown(isRepeat: Bool)
    case keyUp
    case monitorLost
}

enum ShortcutTransition: Sendable, Equatable {
    case begin
    case finish
    case ignore
    case reset
}

struct ShortcutStateMachine: Sendable {
    private(set) var isDown = false

    mutating func reduce(_ event: ShortcutEvent, mode: InteractionMode) -> ShortcutTransition {
        switch (mode, event) {
        case (.holdToTalk, .keyDown(false)) where !isDown:
            isDown = true
            return .begin
        case (.holdToTalk, .keyDown):
            return .ignore // hardware repeat
        case (.holdToTalk, .keyUp) where isDown:
            isDown = false
            return .finish
        case (.handsFree, .keyDown(false)):
            isDown.toggle()
            return isDown ? .begin : .finish
        case (_, .keyUp), (_, .keyDown), (_, .monitorLost):
            isDown = false
            return .reset
        }
    }
}
```

The actual code should use the project’s `InteractionMode` and test the ambiguous cases explicitly: lost key-up, tap timeout, app wake, Accessibility revocation, and a second key-down during finalization.

### 2. Capture first, prepare SpeechAnalyzer second

Yap avoids the common first-word loss bug by opening the microphone before the speech analyzer is ready:

```swift
func start() async throws {
    relay.reset()
    try capture.start(
        onBuffer: { [relay] buffer in relay.receive(buffer) },
        onLevel: { [weak self] level in self?.publish(level) }
    )

    let locale = try await localeResolver.resolve(userLocale)
    let engine = speechEngineFactory.make()
    try await engine.prepare(locale: locale, contextualStrings: dictionary())
    let partials = try await engine.start()

    relay.attach { buffer in engine.feed(buffer) }
    consume(partials, from: engine)
}
```

The relay must have a hard ceiling and a documented overflow policy. A short startup buffer is for analyzer startup, not a recording archive:

```swift
final class AudioBufferRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private let capacity = 32
    private var sink: ((AVAudioPCMBuffer) -> Void)?

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let sink {
            lock.unlock()
            sink(buffer)
            return
        }
        if pending.count == capacity { pending.removeFirst() }
        pending.append(buffer)
        lock.unlock()
    }

    func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let buffered = pending
        pending.removeAll(keepingCapacity: true)
        self.sink = sink
        lock.unlock()
        buffered.forEach(sink)
    }

    func reset() {
        lock.lock()
        pending.removeAll(keepingCapacity: false)
        sink = nil
        lock.unlock()
    }
}
```

### 3. Analyzer-owned audio format

Never assume that built-in and Bluetooth microphones share one sample rate or channel layout. Ask SpeechAnalyzer for its compatible format, then convert off the realtime callback:

```swift
let inputFormat = capture.inputFormat
let analyzerFormat = await analyzer.bestAvailableAudioFormat(
    compatibleWith: inputFormat
)
let converter = AudioConverter(from: inputFormat, to: analyzerFormat)

for await buffer in relay.stream() {
    try Task.checkCancellation()
    let converted = try converter.convert(buffer)
    try await analyzer.process(AnalyzerInput(buffer: converted))
}
```

Any `installTap` failure caused by a transient or zero-channel format is a capture restart, not a retry loop that keeps the broken engine alive. Observe `AVAudioEngineConfigurationChange`, tear down the old tap, create a fresh engine, and report a recoverable state.

### 4. Target capture and insertion

Capture the target before presenting the Flow Bar. Never re-query the current frontmost app after recognition:

```swift
struct TargetApplication: Sendable, Equatable {
    let bundleID: String?
    let processID: pid_t?
    let displayID: CGDirectDisplayID?
}

let context = SessionContext(
    id: UUID(),
    startedAt: clock.now,
    targetApplication: targetCapture.capture(),
    interaction: interaction
)
```

Insertion should have explicit outcomes rather than a Boolean:

```swift
enum InsertionResult: Equatable, Sendable {
    case pasted
    case leftOnClipboard(reason: RecoveryReason)
    case permissionRequired
    case targetUnavailable
}
```

The first route may use System Events where permission exists. The fallback posts a complete Command-V sequence (Command down, V down, V up, Command up) because Electron/Chromium apps can ignore a simplified modifier flag. If no route can be dispatched, leave the final text on the clipboard and expose Copy/Scratchpad recovery. Never claim insertion merely because an event was posted.

### 5. Clipboard ownership

Yap’s important safety property is not the delay; it is ownership. Oto writes a unique marker, records the pasteboard change count, and restores the previous snapshot only if the marker and ownership count still match:

```swift
struct PasteboardReceipt: Equatable, Sendable {
    let marker: String
    let changeCount: Int

    func stillOwned(by pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == changeCount
            && pasteboard.string(forType: .init("com.oto.session-marker")) == marker
    }
}
```

Use an injected clock in tests. If the user copied something during the delay, do not restore over it. If the target is slow, keep the Oto text available rather than risk a destructive restore.

## What not to reproduce blindly

- Do not copy Yap’s UI/HUD; Oto’s Flow Bar is a separate product decision.
- Do not add cloud transcription or legacy server-capable speech APIs.
- Do not add Automation permission unless the final insertion route actually requires it.
- Do not assume ad-hoc development signing gives stable TCC identity. Global shortcuts and Accessibility must be validated from a packaged, signed app.
- Do not copy benchmark numbers from Yap. Measure Oto on supported devices and label simulator, unit-test, and real-device evidence separately.
- Do not add a third shortcut backend for F-keys. Normal shortcuts and HID keys must converge at one state machine.

## Definition of parity

Parity means the same user-visible guarantees, not identical class names:

1. The first spoken word is retained while the analyzer prepares.
2. One physical gesture produces at most one session and one insertion.
3. A cancelled or superseded session cannot publish a late transcript.
4. The original target app receives text or the user gets recoverable text.
5. Mic/device/permission failures are explainable and recoverable.
6. No network is needed during dictation after explicit asset preparation.
7. The lifecycle is unit-testable without launching a microphone or window server.
