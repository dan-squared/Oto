# Oto from-scratch rebuild plan

Status: planning and architecture handoff. This folder is intentionally documentation-only for this milestone. Do not use it as permission to rewrite the current implementation yet.

## Read this first

Oto is being re-planned around the proven workflow used by the local Yap audit:

```text
global input
    -> one coordinator
    -> capture target before Oto UI appears
    -> start microphone immediately
    -> bounded audio relay while SpeechAnalyzer prepares
    -> offline Apple Speech transcription
    -> deterministic dictionary/text cleanup
    -> layered insertion into the captured app
    -> bounded local history and recovery
```

The future implementation is a clean rebuild, not a patchwork migration of the current UI. The current source remains useful evidence and must not be deleted until the replacement has equivalent tests and a packaged-app validation path.

## Resolved rebuild decisions

- **Release platform:** the first rebuild targets macOS 26 or later on Apple silicon. Intel Macs and earlier macOS versions are outside the offline SpeechAnalyzer release claim. Package settings, conditional availability checks, onboarding copy, and QA must say the same thing; do not leave a macOS 14 deployment target in place and call it supported.
- **Implementation shape:** this is a controlled from-scratch rebuild. The current code is an auditable reference, not a migration base. Reuse an algorithm only after it has a named owner, a protocol boundary, and tests in the rebuild tree.
- **Settings navigation:** Oto adopts one native `Settings` scene with a `NavigationSplitView` sidebar, `List(selection:)`, and `Form` detail panes. Individual detail panes may use a native `TabView` for closely related subviews (for example, Dictionary/Snippets or Privacy/History); tabs never replace or duplicate the top-level sidebar. Typa's native `TabView` is a reference observation, not a second Oto root-navigation decision.
- **Typography:** system typography and control metrics own macOS chrome and native controls. Oto-authored copy follows the repository's pinned bundled-font policy only where it does not alter system-owned surfaces; no global installation or runtime font download is allowed.
- **Status language:** words such as “fixed”, “ready”, and “verified” refer to the rebuild only when a replacement test or packaged-app check proves them. Historical audits use “reference” or “observed” instead.
- **Release scope:** Apple Speech dictation, insertion, writing tools, history, and native Settings are v1. Apple Intelligence is an optional post-v1 writing layer using Apple's on-device `SystemLanguageModel`; it is not a user-managed local-model catalog, a speech engine, or a required v1 dependency.

## Reference repositories

- **Yap:** [https://github.com/FrigadeHQ/yap](https://github.com/FrigadeHQ/yap)
  - Clone for comparison with `git clone https://github.com/FrigadeHQ/yap.git /private/tmp/yap-reference`.
  - Read `Sources/Coordinator/RecordingCoordinator.swift` first, then `Sources/Services/DictationSession.swift`, `AudioBufferRelay.swift`, `FunctionKeyMonitor.swift`, `TextInjector.swift`, `PermissionsManager.swift`, and their matching tests.
  - The current audited clone is `/private/tmp/oto-yap-audit`. Do not assume it exists on another machine; future agents should clone the canonical repository and inspect the commit they are using.
  - Yap is the behavioral reference for a small Apple Speech-only app, not a reason to copy its UI, automatic asset downloads, or dependency choices without review.
- **ElevenLabs UI bar visualizer:** [https://ui.elevenlabs.io/docs/components/bar-visualizer](https://ui.elevenlabs.io/docs/components/bar-visualizer)
  - This is a React/shadcn component. It cannot be imported into SwiftUI directly. Use its documented states and animation behavior as a reference, then implement an Oto-owned native `Canvas`/SwiftUI renderer.

### Source-of-truth order for future agents

1. [`START_HERE_PRODUCT.md`](../START_HERE_PRODUCT.md) for the current product boundary, sidebar information architecture, and phased starting order.
2. This folder for the from-scratch architecture and implementation phases.
3. [`OTO_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md`](../OTO_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md) for product flows, failure cases, and acceptance criteria.
4. [`OTO_ENGINEERING_PLAYBOOK.md`](../OTO_ENGINEERING_PLAYBOOK.md) for invariants, concurrency, privacy, and test rules.
5. [`YAP_BACKEND_AUDIT.md`](../YAP_BACKEND_AUDIT.md) for the local Yap source audit and decisions not to copy blindly.
6. [`OTO_APPLE_SPEECH_IMPLEMENTATION_PLAN.md`](../OTO_APPLE_SPEECH_IMPLEMENTATION_PLAN.md) for Apple Speech asset and locale details.

The numbered rebuild editions in this folder are the versions future agents should use while rebuilding: `07` Speech, `08` engineering, `09` product, `10` next step, `11` reliability, `12` shortcuts, `13` native UI audit, `14` YAP audit, and `16` the locked decision log. `15_ENGINEERING_WISDOM_AND_MISTAKES.md` records the failure patterns and repository rules learned during the first implementation attempt.

If two documents disagree, use this folder for implementation shape, `16_REBUILD_DECISIONS.md` for locked product choices, and the engineering playbook for safety invariants. Record the decision in the relevant document instead of silently choosing a third interpretation.

## Product boundary for the first rebuild

The first rebuilt release is Apple Speech-first and offline after the user explicitly prepares Apple-managed speech assets. It contains:

- hold-to-talk and hands-free global shortcut modes;
- a small custom Flow Bar for recording state only;
- native macOS Settings and native controls;
- personal dictionary and manual snippets;
- target-app-aware text insertion with clipboard recovery;
- opt-in local transcript history;
- no cloud speech, no silent downloads, no third-party model catalog, and no background intelligence dependency.

Smart writing and richer Apple Intelligence features are later layers. They must consume a finished raw transcript, preserve the source, and never be required to make ordinary dictation work. Oto does not ship a local-model catalog or third-party model loader.

## Apple references required before UI work

Future agents must read and use these official resources, not imitate screenshots with custom controls:

- [SwiftUI Get Started pathway](https://developer.apple.com/swiftui/get-started/)
- [Swift Get Started](https://developer.apple.com/swift/get-started/)
- [SwiftUI documentation overview](https://developer.apple.com/documentation/SwiftUI#Overview)
- [Apple macOS resources](https://developer.apple.com/macos/resources/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple Design Resources — macOS apps](https://developer.apple.com/design/resources/#macos-apps)
- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [SwiftUI `Settings`](https://developer.apple.com/documentation/swiftui/settings)
- [SwiftUI `SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)
- [SwiftUI `NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [SwiftUI `Form`](https://developer.apple.com/documentation/swiftui/form)
- [Apple HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Apple HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple HIG: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)

The SwiftUI pathway explicitly promotes declarative views, choosing the right container, structured navigation, and a data model separate from view layout. The rebuild follows those principles: system fonts and controls first, custom styling only for the Flow Bar, and feature services kept outside views.

## Target repository shape

Keep the tree shallow enough that a contributor can find ownership in under a minute:

```text
Oto/
├── Package.swift                         # or the Xcode project once signing begins
├── Sources/Oto/
│   ├── App/
│   │   ├── OtoApp.swift                  # scenes, dependency graph, lifecycle
│   │   ├── AppCommands.swift             # menu commands and keyboard-facing actions
│   │   └── AppState.swift                # app-owned observable presentation state
│   ├── Coordinator/
│   │   └── DictationCoordinator.swift     # sole session state owner
│   ├── Services/
│   │   ├── DictationSession.swift         # capture + SpeechAnalyzer lifetime
│   │   ├── AudioBufferRelay.swift         # bounded startup bridge
│   │   ├── AudioCaptureService.swift      # AVAudioEngine boundary
│   │   ├── TranscriptionService.swift     # Apple Speech protocol + adapter
│   │   ├── FunctionKeyMonitor.swift       # HID path for F-keys/dictation key
│   │   ├── ModifierHotkeyMonitor.swift    # ordinary shortcut path
│   │   ├── ShortcutRecorder.swift         # settings-only calibration UI
│   │   ├── TextInjector.swift             # target capture + layered insertion
│   │   └── TranscriptPipeline.swift        # deterministic cleanup/dictionary
│   ├── Models/
│   │   └── DomainModels.swift             # Sendable states and persisted values
│   ├── Storage/
│   │   ├── HistoryStore.swift
│   │   ├── DictionaryStore.swift
│   │   ├── SnippetStore.swift
│   │   └── LocalPersistence.swift
│   ├── Support/
│   │   ├── PermissionsManager.swift
│   │   ├── LaunchAtLoginService.swift
│   │   └── Diagnostics.swift
│   └── UI/
│       ├── Settings/                       # native Settings scene and panes
│       ├── FlowBar/                        # only custom visual surface
│       └── Scratchpad/                     # recovery/editing surface
├── Tests/OtoTests/
│   ├── Coordinator/
│   ├── Services/
│   ├── Storage/
│   └── UI/
└── Docs/OTO_REBUILD_PLAN/
```

Do not add `ViewModel` or `Intelligence` folders to the v1 target by reflex. A view should own presentation state; a service should own side effects; the coordinator should own the session; storage should own persistence. Add a new layer only when it has a clear owner and test seam. Post-v1 intelligence may become a separate module after the v1 gate, but it must not move core dictation responsibilities.

## Runtime contracts

These are the boundaries the implementation should recreate before any visual polish.

```swift
import AVFoundation

struct SessionContext: Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let targetBundleID: String?
    let targetPID: pid_t?
    let targetScreenID: CGDirectDisplayID?
}

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

enum DictationFailure: Error, Equatable, Sendable {
    case microphonePermission
    case accessibilityPermission
    case speechAssetsMissing
    case unsupportedLocale
    case targetUnavailable
    case insertionFailed
    case engine(String)
}

protocol AudioCapturing: AnyObject {
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws
    func stop()
}

protocol OfflineSpeechEngine: AnyObject {
    func prepare(locale: Locale, contextualStrings: [String]) async throws
    func start() async throws -> AsyncThrowingStream<String, Error>
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

protocol TargetCapturing {
    func capture() -> SessionContext
}

protocol TextInserting {
    func insert(_ text: String, into context: SessionContext) async throws -> InsertionResult
}

enum InsertionResult: Equatable, Sendable {
    case pasted
    case leftOnClipboard
}
```

## Coordinator shape

The exact type may be an actor or a main-actor object with a nonisolated audio boundary. The invariant is more important than the annotation: every terminal event enters the same owner and is checked against the same session ID.

```swift
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: DictationState = .idle

    private let target: TargetCapturing
    private let audio: AudioCapturing
    private let speech: () -> OfflineSpeechEngine
    private let insertion: TextInserting
    private let pipeline: TranscriptPipeline
    private let history: HistoryStoring

    private var session: SessionContext?
    private var speechTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var finishRequested = false

    func begin() {
        guard case .idle = state else { return }
        let context = target.capture()       // before Flow Bar or Settings UI
        session = context
        finishRequested = false
        state = .starting(context)

        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                try audio.start(onBuffer: { [weak self] buffer in
                    self?.receive(buffer, for: context.id)
                }, onLevel: { [weak self] level in
                    self?.publish(level, for: context.id)
                })
                let engine = speech()
                try await engine.prepare(locale: .current, contextualStrings: [])
                let stream = try await engine.start()
                guard isCurrent(context.id) else { await engine.cancel(); return }
                state = .recording(context)
                for try await partial in stream {
                    guard isCurrent(context.id) else { return }
                    publish(partial: partial, for: context.id)
                }
                if finishRequested { finish() }
            } catch is CancellationError {
                // Terminal cancellation is already owned by cancel().
            } catch {
                fail(error, for: context.id)
            }
        }
    }

    func finish() {
        guard let context = session, isCurrent(context.id) else { return }
        guard case .starting = state else {
            guard case .recording = state else { return }
            return finalize(context)
        }
        // Release can arrive while SpeechAnalyzer is preparing.
        finishRequested = true
    }

    func cancel() {
        guard let context = session else { return }
        guard !isTerminal(state) else { return }
        state = .cancelled(context)
        speechTask?.cancel()
        finishTask?.cancel()
        audio.stop()
        session = nil
    }
}
```

The snippet is a shape guide, not copy-paste production code. A real implementation must add a bounded relay, explicit cleanup ordering, late-result rejection, and tests for every transition.

## Phase gates

| Phase | Build only after this is true | Evidence |
| --- | --- | --- |
| 0. Skeleton | Packaged app launches with stable bundle ID and native Settings scene. | Build, signing, launch checklist. |
| 1. Input | Hold/release and hands-free state machines pass repeat/lost-key-up tests. | Unit tests plus signed-device shortcut check. |
| 2. Audio | Capture starts before SpeechAnalyzer and never blocks the realtime tap. | Relay overflow and audio interruption tests. |
| 3. Speech | Apple Speech is offline after explicit preparation and reports specific failures. | Fake engine tests plus device locale/asset check. |
| 4. Insertion | Original target is used; failures preserve text; clipboard is not overwritten. | Insertion fakes and cross-app device matrix. |
| 5. Personalization | Dictionary/snippets are deterministic, scoped, versioned, and deletable. | Store migration/import/delete tests. |
| 6. History | Final-only, opt-in, bounded local history works without audio retention. | Privacy and retention tests. |
| 7. UI | Settings uses native scenes/controls and Flow Bar states are cancellation-safe. | SwiftUI UI tests and Reduce Motion checks. |
| 8. Release | Signed packaged app, permissions, launch-at-login, and update path are verified. | Release checklist; real-device evidence is separate from CI. |

No phase may add cloud speech, a model downloader, or hidden background work to “make the demo pass.”
