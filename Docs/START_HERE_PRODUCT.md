# Oto — Start Here and Product Direction

This is the first document to read when starting work in the Oto Xcode project. It defines the product boundary and implementation order for the rebuild. The numbered documents in `Docs/OTO_REBUILD_PLAN/` contain the deeper technical plans and test matrices.

## Product in one sentence

Oto is a quiet, native macOS dictation utility: press a shortcut, speak, release, and the finished text is inserted into the app that was active when dictation began.

Oto should feel immediate, private, recoverable, and dependable. The core experience must remain useful without an account, cloud speech, or a user-managed model catalog.

## Locked product boundary

### Speech

- Apple Speech is the only speech-to-text engine in the release path.
- Speech is prepared explicitly by the person in Settings and then works offline when the selected Apple-managed assets are available.
- Oto never downloads speech assets during a shortcut press.
- Oto never silently falls back to a cloud transcription service.
- Do not add Whisper, Parakeet, Qwen, Nemotron, Cohere, MLX, GGUF, Rust sidecars, or third-party model downloads to this product path.

### Intelligence

Oto may use Apple's on-device Foundation Models (`SystemLanguageModel`) for optional writing assistance. This is not a user-managed local-model catalog and it is not a second speech engine.

Intelligence is a post-transcript layer. It receives finalized text only, creates a reversible draft, and never sits on the microphone or insertion critical path. If Apple Intelligence is unavailable, ordinary dictation must still work.

Possible later features:

- Email, message, code, meeting-note, and journal modes.
- Tone changes such as professional, friendly, concise, or confident.
- List and table structure from spoken text.
- Summaries, action items, and follow-up drafts for long recordings.
- Voice editing commands such as delete, rewrite, and summarize.

These features must be introduced one at a time, with an availability explanation and an offline test. They must never overwrite the raw transcript without a preview or undo path.

## Navigation and information architecture

Eight permanent sidebar destinations are too many. The sidebar should represent user goals, not implementation components.

### First-release sidebar

```text
Dictation
Writing
History
General
```

When the first Apple Intelligence feature is actually shipped and tested, add:

```text
Intelligence
```

Do not show an empty or disabled Intelligence page just to reserve a name. The architecture can support it before the sidebar exposes it.

### Dictation detail tabs

```text
Behavior    Shortcuts    Audio    Speech
```

This contains hold-to-talk, hands-free mode, shortcut calibration, microphone selection, speech readiness, and language preparation. Shortcuts and Audio should not be separate sidebar destinations.

### Writing detail tabs

```text
Dictionary    Snippets    Formatting
```

Dictionary and snippets are both personal writing behavior. Start with manual snippets; spoken triggers are a later feature.

### History detail tabs

```text
Transcripts    Retention    Privacy
```

History is opt-in, local, bounded, and deletable. Never store raw audio, clipboard snapshots, target-app contents, or hidden Apple Intelligence prompt traces.

### General detail tabs or sections

```text
Launch    Flow Bar    Appearance    About
```

General contains low-frequency app behavior. It must not duplicate microphone, speech, or shortcut controls.

### Navigation rules

- Use one native `Settings` scene.
- Use `NavigationSplitView` with a native `List(selection:)` sidebar.
- Use `Form` and native macOS controls for settings details.
- Use `TabView` only inside a selected sidebar destination when the tabs share one task context.
- Do not create nested sidebars or a second custom settings window.
- Do not recreate traffic lights, title bars, toggles, pickers, or form cards.
- Use `SettingsLink` and the SwiftUI `openSettings` action so every Settings entry point targets the same native window.
- Keep the sidebar short enough that every item is visible without scrolling on a normal settings window.

## Core user journeys

### First launch

1. Oto starts as a menu-bar utility.
2. The person sees a short explanation of the shortcut and privacy model.
3. Oto requests microphone and Accessibility permissions only when the related action is needed.
4. Settings explains Apple Speech readiness and offers an explicit offline preparation action.
5. The person can test the shortcut in a safe text field before using another app.

### Hold-to-talk

```text
shortcut down
→ capture target app and screen
→ show Flow Bar
→ start audio capture
→ feed Apple Speech
→ shortcut up
→ finalize transcript
→ apply deterministic dictionary rules
→ insert into captured target
→ show success or recoverable failure
```

Release during Speech preparation means “finish when ready”; it must not cancel the session accidentally.

### Hands-free

```text
shortcut press
→ start recording
→ shortcut press again
→ finalize and insert
```

Both modes use the same coordinator and terminal-state rules. They must not have separate recording implementations.

### Failure recovery

Every uncertain result remains recoverable. If insertion fails, Oto keeps the transcript available in the Flow Bar, Scratchpad, or clipboard fallback. Oto must never claim success merely because a paste event was sent.

## Architecture to build

The Xcode-generated `NavigationSplitView` is a useful shell, not the finished product. Replace the sample `Item` model and sample list with these boundaries:

```text
Oto/
├── App/
│   ├── OtoApp.swift
│   ├── AppCommands.swift
│   └── AppState.swift
├── Coordinator/
│   └── DictationCoordinator.swift
├── Services/
│   ├── AudioCaptureService.swift
│   ├── SpeechService.swift
│   ├── ShortcutMonitor.swift
│   ├── ShortcutRecorder.swift
│   ├── TargetCaptureService.swift
│   ├── TextInsertionService.swift
│   └── TranscriptPipeline.swift
├── Models/
├── Storage/
│   ├── PreferencesStore.swift
│   ├── DictionaryStore.swift
│   ├── SnippetStore.swift
│   └── HistoryStore.swift
├── Support/
│   ├── PermissionsManager.swift
│   └── Diagnostics.swift
└── UI/
    ├── Settings/
    ├── FlowBar/
    └── Scratchpad/
```

The scenes should be composed natively:

```swift
@main
struct OtoApp: App {
    var body: some Scene {
        MenuBarExtra("Oto", systemImage: "waveform") {
            OtoMenuBarView()
        }

        Settings {
            SettingsRootView()
        }
    }
}
```

The coordinator owns session transitions. Views display state and send user intent; they do not start audio, paste text, or decide whether a session has finished.

```swift
enum DictationState: Equatable, Sendable {
    case idle
    case starting(SessionContext)
    case recording(SessionContext)
    case finalizing(SessionContext)
    case inserting(SessionContext)
    case completed(SessionContext)
    case cancelled(SessionContext)
    case failed(SessionContext?, DictationFailure)
}
```

Finish and cancel are idempotent and mutually exclusive. Every asynchronous result is checked against the active session ID before it can update state or insert text.

## Phased working order

### Phase 0 — Establish the shell

- Confirm the supported macOS baseline and the packaged bundle identifier.
- Build an actual `.app`; do not validate TCC or global shortcuts from a raw executable.
- Add microphone usage text and required entitlements.
- Replace the generated SwiftData sample only after the new preferences boundary exists.
- Add the native `MenuBarExtra` and `Settings` scenes.
- Confirm Settings opens through the menu, Command-Comma, and `SettingsLink`.

### Phase 1 — Prove one fake end-to-end session

Use a fake audio/speech service and prove:

```text
shortcut → coordinator → fake transcript → target capture → insertion boundary
```

Test finish, cancel, repeated stop, app switching, and insertion failure before using real audio.

### Phase 2 — Add Apple Speech

- Implement microphone and Speech authorization.
- Implement explicit asset readiness and preparation in Settings.
- Add locale selection and clear unavailable states.
- Keep the network out of the recording path.
- Test prepared-language dictation with networking disabled.

### Phase 3 — Add global shortcuts

- Implement hold-to-talk and hands-free using the same coordinator.
- Build the shortcut recorder with Escape-to-cancel and invalid-input recovery.
- Suspend global registration while recording a new shortcut.
- Verify actual global down/hold/up behavior in a packaged app.

### Phase 4 — Add target-aware insertion

- Capture target application and screen before Oto presents UI.
- Use layered Accessibility and clipboard insertion.
- Restore the clipboard only when the clipboard change-count marker proves it is still Oto-owned.
- Preserve text when the target disappears or a secure field rejects insertion.

### Phase 5 — Add the native Settings product

Build the four first-release sidebar destinations and their tabs. Use native `Form`, `List`, `TextField`, `TextEditor`, `Picker`, `Toggle`, `LabeledContent`, sheets, and file import/export.

### Phase 6 — Add Flow Bar, dictionary, snippets, and history

The Flow Bar is the only custom visual surface. It reflects coordinator state and supports reduced motion/transparency. Then add the local writing stores and opt-in history.

### Phase 7 — Add optional Apple Intelligence

Only after the core Apple Speech release gate passes:

- Add `SystemLanguageModel` availability checks.
- Add reversible post-transcript drafts.
- Preserve the raw transcript.
- Add previews, cancellation, and offline tests.
- Keep intelligence unavailable without affecting ordinary dictation.

## Engineering rules

- One coordinator owns recording state.
- Audio callbacks do no UI work and create no unbounded task per buffer.
- Queues are bounded and cancellation is explicit.
- Target identity is captured at start, never inferred at finalization.
- All terminal paths are safe to call repeatedly.
- Raw transcript, transformed draft, and inserted result are separate values.
- No cloud speech, silent downloads, third-party model loading, or hidden app-content scraping.
- Do not add a dependency until its release, license, package identity, and device behavior are verified.
- Do not optimize visual polish before the packaged app passes one real dictation flow.

## Official references

Use Apple documentation as the source of truth for platform behavior:

- [SwiftUI Get Started](https://developer.apple.com/swiftui/get-started/)
- [Swift Get Started](https://developer.apple.com/swift/get-started/)
- [SwiftUI documentation](https://developer.apple.com/documentation/SwiftUI#Overview)
- [Apple macOS resources](https://developer.apple.com/macos/resources/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [SwiftUI `Settings`](https://developer.apple.com/documentation/swiftui/settings)
- [SwiftUI `SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)
- [SwiftUI `NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [SwiftUI `Form`](https://developer.apple.com/documentation/swiftui/form)
- [SwiftUI `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Speech asset inventory](https://developer.apple.com/documentation/speech/assetinventory)
- [Foundation Models `SystemLanguageModel`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

## Definition of a useful first milestone

The first milestone is not a beautiful Settings screen. It is a packaged Oto app where:

1. Settings opens as a native macOS settings window.
2. A fake shortcut starts and ends one coordinator-owned session.
3. A prepared Apple Speech language can dictate offline.
4. The transcript is inserted into the application that was active at start.
5. Cancel, permission failure, app switching, and insertion failure leave a recoverable result.

Once that slice is reliable, the rest of the product can be built as small, testable additions rather than another rewrite.
