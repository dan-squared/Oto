# Oto — Apple Speech-first implementation plan

> **Rebuild edition:** This copy is the active SpeechAnalyzer reference for the from-scratch backend. Read [`README.md`](README.md), [`16_REBUILD_DECISIONS.md`](16_REBUILD_DECISIONS.md), [`01_YAP_PARITY_ARCHITECTURE.md`](01_YAP_PARITY_ARCHITECTURE.md), and [`15_ENGINEERING_WISDOM_AND_MISTAKES.md`](15_ENGINEERING_WISDOM_AND_MISTAKES.md) first. Do not add local-model, cloud, or automatic-download paths while implementing this document.

> **Status:** Product and engineering plan for the first production release.
>
> **Execution companions:** Read [09_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md](09_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md) first for product flows and acceptance criteria. Follow [08_ENGINEERING_PLAYBOOK.md](08_ENGINEERING_PLAYBOOK.md) for concurrency, shortcut, insertion, persistence, and handoff rules.
>
> **Scope decision:** Oto ships as a native macOS dictation application powered by Apple's on-device Speech framework. It does **not** ship third-party model downloads, local-model management, a Rust sidecar, or a cloud transcription fallback. Earlier model-engine work is intentionally outside the release build, rather than a runtime dependency.

> **Platform decision:** the first rebuild supports macOS 26 or later on Apple silicon. The package, availability checks, Settings copy, and device matrix must agree. Intel and earlier macOS versions are not part of the v1 support claim.

## 1. The product we are building

Oto should make one action feel dependable:

1. The person holds or taps their chosen global shortcut.
2. Oto captures from the chosen microphone and gives a calm, small visual confirmation.
3. Apple Speech recognizes the audio on the Mac after its language assets have been prepared.
4. Oto applies the person's deterministic dictionary and snippet rules.
5. Oto inserts the finished text into the app that was active at the beginning of dictation, preserves the clipboard, and gets out of the way.

The first release wins by being boringly dependable, private by default, fast after the first setup, and visually restrained. It must not imitate a larger model catalog product at the cost of memory, startup speed, or recovery quality.

### Product promises

- **Offline after setup.** Preparing an Apple Speech language may require the Mac to be online. Dictation must never initiate a download, use a cloud recognizer, or silently change engines.
- **One active recording.** A second shortcut press can never create a second audio graph, analyzer, or insertion attempt.
- **No silent loss.** Cancellation creates no insertion and no history entry. An insertion failure is visible and actionable.
- **No silent surprise.** Natural-language snippet expansion is off by default. History is off by default. Text enhancement is never automatic unless the person deliberately turns it on in a future release.
- **Small resident footprint.** No speech model is bundled or held in Oto memory. Apple owns the system asset lifetime; Oto owns only the short-lived capture and analysis session.
- **Native feeling.** Menu-bar presence, an unobtrusive floating status pill, keyboard-first controls, real AppKit settings-window behavior, and macOS permissions instead of custom substitutes.

### Non-goals for the first release

- Third-party local STT models (Whisper, Parakeet, Qwen, Nemotron, Cohere).
- Online transcription or an automatic cloud fallback.
- Team accounts, syncing, analytics that contain audio or transcript text, and collaboration.
- Voice-command automation that could execute destructive actions in another app or external service.
- Always-on listening or a background wake word.
- Automatically inferred writing tone, app contents, clipboard context, or contact data.

## 2. Historical reference: what the pre-rebuild project had

The following table describes the pre-rebuild project as audited. It is reference evidence, not proof that the replacement implementation exists or is verified.

| Area | Current implementation | Release assessment |
| --- | --- | --- |
| App shell | `MenuBarExtra` plus a retained AppKit `NSWindow` for Settings | Correct direction; must be tested as a packaged signed app. |
| Native STT | `AppleSpeechEngine` using `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`, and an async input/result stream | Good boundary; needs device validation and a deliberate transcriber choice. |
| Asset setup | Explicit Settings-only Apple asset preparation; dictation refuses to download | Keep. This is the right offline contract. |
| Audio | `AVAudioEngine` input tap, mic list/selection, bounded chunk buffer | Good safety principle; needs route-change and long-session validation. |
| Shortcut | Configurable shortcut, F5/dictation-key alias, HID event tap, hold-to-talk and hands-free state machine | Good architecture; global behavior requires a signed-device matrix. |
| Insertion | Captures the original foreground app, uses the clipboard and synthetic Command-V, then restores rich clipboard data | Correct broad compatibility fallback; this is a high-risk area that needs targeted QA. |
| Text rules | Local dictionary, scoped rules, snippets, protected URL/email/path ranges, local optional history | Strong v1 value; needs clearer rule semantics and integration QA. |
| Feedback | Flow Bar with idle, start, record, finalizing, success, cancellation, and failure states | Direction is right; the rendering lifecycle and reduced-motion behavior need final validation. |
| Tests | Deterministic unit coverage for text processing, shortcut state, VAD, audio queue, preferences, and clipboard snapshots | Useful base, but no real-device integration evidence yet. |

### Current source map

| Responsibility | Current source |
| --- | --- |
| App and settings-window lifecycle | `Sources/Oto/App/OtoApp.swift` |
| Session lifecycle and state transitions | `Sources/Oto/Core/DictationSessionController.swift` |
| Apple Speech adapter and asset setup | `Sources/Oto/Core/TranscriptionEngine.swift` |
| Audio capture/device routing | `Sources/Oto/Core/AudioCaptureService.swift` |
| Shortcut state and event tap | `Sources/Oto/Input/GlobalHotkeyMonitor.swift` |
| Cross-application insertion | `Sources/Oto/Input/TextInsertionService.swift` |
| Dictionary, snippets, and history | `Sources/Oto/Text/TranscriptPipeline.swift` |
| Floating feedback surface | `Sources/Oto/UI/FlowBar.swift` |
| Product settings UI | `Sources/Oto/UI/SettingsView.swift` |

## 3. Research conclusions and design decisions

### 3.1 Apple Speech is the correct v1 engine

Apple documents `SpeechAnalyzer` as the actor that manages a speech analysis session, receives an input sequence, and coordinates modules that expose results as asynchronous sequences. One analyzer can process **one input sequence at a time**. That maps directly to Oto's one-session state machine. [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)

Apple documents `AssetInventory` as the system-managed store for the machine-learning assets required by speech modules. Assets are downloaded from Apple's servers during installation, persist across launches, may be shared with other apps, and can be reserved per locale. Oto must configure modules and ask the system to prepare assets; it must never own, copy, checksum, or delete those assets. [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)

Apple's current documentation also explicitly differentiates old `SFSpeechRecognizer` server-oriented authorization from the modern `SpeechAnalyzer` transcriber modules: the latter do not send captured voice audio to Apple servers. Oto should keep its public privacy language precise and avoid claiming more than that framework guarantee. [Speech-recognition authorization note](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)

**Decision:** Use Apple SpeechAnalyzer as the only production transcription runtime. Keep the public engine protocol so future engines can be developed on a branch without leaking model choices into the v1 interface.

### 3.2 Do not load a model continuously

There is no Oto-owned model to keep warm in this release. Creating a short-lived analyzer per dictation is the appropriate default because it prevents a stuck audio/analyzer session from contaminating the next one and minimizes resident app state. The system's assets remain installed and managed by macOS.

**Decision:** Retain no analyzer across a completed session. Measure the real post-setup start latency before introducing any warm-session optimization. If measurement later proves a problem, add only a bounded `prepared` state that has no open microphone tap and expires on idle, memory pressure, sleep, or an error.

### 3.3 `SpeechTranscriber` versus `DictationTranscriber` is a validation decision, not a branding decision

Apple describes `SpeechTranscriber` as appropriate for normal conversation and general purpose, while `DictationTranscriber` is similar to system dictation and compatible with older devices. Both are analyzer modules; Oto must run **one chosen transcription module** in a session, not race or merge two engines. `DictationTranscriber` supports progressive results that may be revised until marked final. [SpeechDetector module relationships](https://developer.apple.com/documentation/speech/speechdetector) and [DictationTranscriber results](https://developer.apple.com/documentation/speech/dictationtranscriber/result)

**Decision:** Keep the `TranscriptionEngine` interface and choose one module for the first rebuild. Use `SpeechTranscriber` as the initial implementation unless the device matrix finds a blocking correctness or availability issue; keep `DictationTranscriber` as a gated alternative, not a runtime fallback or user setting.

- Validate `SpeechTranscriber` for final accuracy, partial stability, start-to-first-result, release-to-final, memory footprint, and repeated cancellation.
- If it fails a release criterion, validate `DictationTranscriber` with the appropriate short and long dictation presets and record the decision in the decision log.
- Do not race, merge, silently switch, or expose both modules in Settings. The selected module is fixed for a build and must be named in release notes.

### 3.4 Dictionary corrections need two layers

Oto already has a dependable deterministic text-replacement layer. It is the right first line because a person can see, edit, disable, scope, export, and test it.

Apple additionally supports `AnalysisContext.contextualStrings`, words and phrases grouped by tag that should be recognized even if they are absent from the system vocabulary. This is promising for names and product terms, but it is recognition guidance rather than a guaranteed replacement mechanism. [AnalysisContext](https://developer.apple.com/documentation/speech/analysiscontext)

**Decision:**

1. Keep deterministic post-processing as the authoritative v1 dictionary.
2. Add an internal, bounded contextual-vocabulary projection later: enabled global dictionary entries only, deduplicated, normalized, and capped by an experimentally chosen count/character budget.
3. Attach it using `SpeechAnalyzer.setContext(_:)` before audio begins.
4. Never rely on contextual vocabulary for capitalization, exact spelling, or sensitive snippet expansion; the deterministic layer remains the final authority.
5. Ship the projection only after it is demonstrated to improve names without regressing ordinary words in the target language.

### 3.5 Voice activity detection should reduce work, not decide correctness

Apple's `SpeechDetector` can be used with a transcriber to gate transcription when there is no speech, but Apple warns that an overly aggressive detector can drop spoken audio and reduce accuracy. Its medium sensitivity is the recommended starting point, not a universal answer. [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)

**Decision:**

- Hold-to-talk: the key release remains the sole normal end condition. Do not add auto-stop to this mode.
- Hands-free: retain the current conservative local silence detector as a provisional end trigger, with an explicit pre-speech grace period and sustained trailing silence. It must never finish before meaningful speech begins.
- Evaluate `SpeechDetector` on real hardware as an optional gate for hands-free sessions only. Compare missed first/last words, power use, and stop latency against the existing detector.
- Provide a visible cancel action in every recording state. A detector decision is never irreversible until the session finalizes.

### 3.6 Foundation Models are enhancement-only, never a transcription dependency

The `SystemLanguageModel` is an on-device Apple Foundation Model and has explicit availability states, including unsupported devices/regions, Apple Intelligence disabled, and a model that is not ready. Apple also states that model versions can change with OS updates, so prompts need version-aware QA. [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) and [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels)

**Decision:** Do not include Foundation Models in the first dictation loop. A later optional “Polish text” action may use it only after final text exists, only when `SystemLanguageModel.default.availability == .available`, with a raw-text undo/copy path, no hidden cloud route, no transcript retention, and no impact on the ability to dictate.

### 3.7 Apple Intelligence can be Oto’s offline writing layer (post-v1)

The requested intelligence features are technically viable on capable Macs through `SystemLanguageModel`, Apple’s on-device Foundation Model. It is not the same product as the Private Cloud Compute model: Apple's comparison states that `SystemLanguageModel` works offline, while Private Cloud Compute requires a network connection and has daily limits. [Apple's on-device and Private Cloud Compute comparison](https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute)

**Non-negotiable offline decision:** Oto imports and uses only `SystemLanguageModel`. It must never instantiate, fall back to, suggest, or silently route to `PrivateCloudComputeLanguageModel`. An offline network test is a release requirement for every intelligence feature.

Foundation Models supports ordinary responses, streaming responses, and guided generation into a Swift structure. It also limits the on-device context window and permits only one active request per session. That makes a small one-operation-at-a-time service, with structured output and an explicit preview, the correct architecture. [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession) and [Foundation Models generation guidance](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

**Decision:** After the v1 Apple Speech release gate, optionally add an `OfflineIntelligenceService` after the core dictation session finalizes. It receives finalized text and a deliberately minimal local context object, produces a reversible draft, and never sits on the microphone/audio path. The core raw transcript is always available if generation is unavailable, rejected, cancelled, or wrong.

#### Offline Intelligence architecture

```text
Apple Speech final text
          │
          ▼
TranscriptProcessor (dictionary + explicit snippets)
          │ raw, finalized text remains available
          ▼
OfflineIntelligenceCoordinator
  ├─ chosen mode or bounded automatic suggestion
  ├─ app category (bundle ID only)
  ├─ user-approved local references, if any
  └─ SystemLanguageModel — on-device only
          │
          ▼
Structured draft + source transcript + operations available
          │
          ├─ Insert draft
          ├─ Insert original
          ├─ Copy
          ├─ Open in Scratchpad
          └─ Discard
```

`OfflineIntelligenceService` should own a short-lived `LanguageModelSession` per independent request. This prevents accidental history leakage between dictations, avoids the framework's one-request-at-a-time session error, and makes cancellation straightforward. A multi-turn session is allowed only inside a visible editing sheet for the one current draft, never across unrelated recordings.

#### Shared data model

Use value types and explicit provenance. No model result should overwrite the source string.

```swift
enum WritingMode: String, Codable, CaseIterable {
    case auto, email, message, code, meetingNotes, journal
    case professional, friendlier, shorter, confident
    case linkedInPost, socialPost, translate
}

struct IntelligenceContext: Sendable {
    let targetBundleIdentifier: String?
    let targetAppCategory: TargetAppCategory?
    let locale: Locale
    let approvedReferences: [LocalReference]
}

struct IntelligenceDraft: Sendable, Identifiable {
    let id: UUID
    let sourceText: String
    let mode: WritingMode
    let output: StructuredDraft
    let createdAt: Date
}
```

`StructuredDraft` should be an `@Generable` schema, not a model-generated blob that Oto has to parse with regular expressions. For example it can include `title`, `subject`, `body`, `bullets`, `actionItems`, `suggestedIntent`, and `plainText`. Each mode declares the small subset it expects. Guided generation gives the app a typed response it can preview and render safely.

Use deterministic generation options for operational features such as intent choice, reminders, lists, and action items. A creative mode such as journal or social post may allow a higher-variation setting, but must still make editing and raw-text restoration immediate. Apple's current examples use greedy sampling where consistent output is important. [Apple's guided-generation example](https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models)

#### Availability, cancellation, and capacity

- Gate all intelligence controls behind `SystemLanguageModel.default.availability`. Show the exact local reason: device not eligible, Apple Intelligence not enabled, model not ready, unsupported locale, or a generation error. Never let this block ordinary dictation. [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- Check `supportsLocale(_:)` for language-sensitive features; fall back to raw transcription rather than generating in an unsupported language.
- Before generating, use `tokenCount(for:)` to enforce a conservative input budget. The on-device model has a bounded context window, so long content must be chunked rather than silently truncated.
- Expose Cancel while generating. Cancellation keeps the source text and immediately offers Insert Original, Copy Original, and Scratchpad.
- Do not stream text directly into another app. Streaming is acceptable inside Oto's editable preview, but insertion happens only after the person chooses a final result.
- Test every prompt family on each supported macOS model generation. Apple notes that the on-device model changes with OS releases, so prompt behavior must be evaluated as part of OS upgrade QA. [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels)

## 3.8 Detailed offline intelligence feature plan

### A. Smart Mode and intent detection

The useful behavior is **automatic suggestion, not invisible automatic rewriting**. Intent classification is probabilistic; a person dictating “email the team” may want plain words in Notes, not a synthetic email. Oto should make an automation easy to accept and trivial to bypass.

1. `Auto` mode starts with deterministic signals: current app bundle identifier, a user-chosen app-to-mode mapping, and whether the person invoked a mode-specific shortcut.
2. The model receives only the final transcript, the app category (for example `mail`, `messaging`, `editor`, `notes`), and the requested operation. It does **not** receive surrounding text from the target app.
3. A guided `IntentPlan` returns one suggested mode, short rationale copy suitable for UI, and a structured output draft.
4. If the app mapping is unambiguous and the person has enabled “Apply suggested formatting in this app,” Oto can open a draft preview automatically. It must still offer **Insert original** as a first-class action.
5. If intent is ambiguous, show compact mode chips in the Flow Bar/Scratchpad: `Email`, `Message`, `Notes`, `Keep raw`. Do not invent confidence percentages.
6. Mode selection is stored locally per app only when the person explicitly saves the preference.

Mode contracts:

| Mode | Structured output | Safety rule |
| --- | --- | --- |
| Email | subject, greeting, body, sign-off | Never fabricate recipients, facts, deadlines, or attachments. |
| Message | concise message text | Retain concrete names/numbers verbatim; do not add emotional claims. |
| Code | code block or comment plus plain-language explanation | No execution, file writing, terminal commands, or project-context reading. |
| Meeting notes | title, bullets, action-item candidates | Mark owners/dates as “mentioned” or “needs confirmation” unless explicit in source. |
| Journal | first-person edited prose | Keep the source accessible; never store it as history unless history is already opted in. |

### B. Instant structure and formatting

This feature is a good match for typed output. It should turn a spoken result into a well-rendered draft, not mutate the external app live.

- **Lists:** return an ordered/unordered list structure and render it as native rich/plain text depending on the insertion target.
- **Tables:** return column names and rows only when the spoken data unambiguously contains a repeatable row shape. Otherwise show a clean list rather than a hallucinated table.
- **Shorthand:** expand only with a mode-specific rule. For example, keep “ASAP” in a Slack-style message unless the person chooses professional-email mode, where “as soon as possible” may be preferable.
- **Reminder candidates:** return `title`, `dateText`, `timeText`, `notes`, and `ambiguities`. Do not create a Reminder, Calendar event, or notification automatically. The person must review and press Create, after which a separate local Reminders integration can request its own permission.
- **Numbers/dates:** retain the raw spoken phrase beside a parsed suggestion when ambiguity exists (“next Friday”, “at three”). Do not invent time zones.

### C. Contextual rewrite and tone control

Tone rewrite should be an explicit post-transcription operation with no hidden context.

- Present mode chips and a command palette: Professional, Friendly, Shorter, More confident, LinkedIn post, Social post, Translate.
- Send the final transcript plus a narrow instruction such as “Preserve facts, names, quantities, and commitments. Do not add information.”
- Render original and draft in a side-by-side or toggle preview. Accepting inserts the chosen version; Raw always remains one click away.
- “Talking to my boss” is a user-written instruction or a saved private style preset, never inferred from contacts, mail data, or app contents.
- Keep saved style presets as local short instructions. Do not feed complete historical writing samples into the model by default.

### D. Smart snippets and private context

Smart snippets are useful but are the highest privacy and surprise risk in this list.

**Release-safe base:** exact local snippets plus explicit spoken triggers, e.g. “Oto insert weekly update.”

**Opt-in smart expansion:** a person may create a template with labeled fields, such as:

```text
Weekly update
Template: “This week I completed {{wins}}. Next I will {{next_steps}}.”
Allowed context: current transcript only
```

The model can fill fields only from the current final transcript and explicitly selected local references. It must label missing data as a placeholder rather than invent it.

Recent transcript references require a separate **Use selected history as context** choice. The default is no history context, even if local history is enabled. The picker shows exactly which entries will be supplied, permits removing each one, and never includes audio, clipboard contents, target app contents, contacts, or files.

Names, signatures, and static personal details should remain deterministic snippets, not model inference. Store them locally and never send them to a cloud model because Oto has no cloud model path.

### E. Meeting and long-form intelligence

Long-form work is viable, but needs a deliberate pipeline because the on-device model has a bounded context window.

1. Treat meeting capture as a separate explicit recording mode with a visible persistent indicator and a privacy reminder; it must never be activated by hands-free dictation accidentally.
2. Segment finalized transcript text into token-budgeted, sentence-boundary chunks. Never split a word or discard the source.
3. Generate a structured chunk summary locally for each chunk using a new one-request session.
4. Run a final local aggregation over summaries, not the entire raw transcript, to create title, themes, decisions, action-item candidates, owners mentioned, deadlines mentioned, and next steps.
5. Preserve each result's source range so Oto can display “based on this passage.”
6. Require review before copying, inserting, creating a reminder, or drafting a follow-up email.
7. Store the raw transcript and meeting artifact only if the person explicitly opts into history/meeting storage; otherwise discard both after the session closes.

For a follow-up email, use a draft only: subject/body/sign-off. Never send mail, alter an existing message, or read “the last email” without a future, separately consented integration.

### F. Cross-app intelligence

Oto can safely use the foreground app's identity. `NSWorkspace.frontmostApplication` returns the current key-event receiving app, which is enough to select a local style profile. [NSWorkspace frontmost application](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)

Allowed v1 context:

- bundle identifier;
- app name/category that Oto maps locally;
- a user-selected saved style profile for that app;
- the final transcript itself;
- optional, explicitly selected Oto history entries.

Not allowed without a separately designed and consented feature:

- reading visible text, previous emails, Slack conversations, editor buffers, browser pages, contacts, calendar data, or clipboard contents;
- discovering people/terms from another app silently;
- sending messages, modifying documents, or creating external records.

“Continue from last email” therefore becomes **“Continue from a draft you selected in Oto”** in the first intelligence release. Oto can offer a local Drafts list and let the person choose a previous Oto-created draft as context. That remains offline and understandable.

### G. Voice editing commands

Voice commands must operate on Oto's local draft before text is inserted, never blindly edit a foreign app.

Commands are enabled only in an explicit **Voice editing** mode, with a spoken prefix such as “Oto, …”. This avoids treating ordinary sentences like “delete the last sentence” as a destructive instruction.

| Spoken command | Local action |
| --- | --- |
| “Oto, delete last sentence” | Deterministic sentence deletion in the local draft with Undo. |
| “Oto, make the previous paragraph a list” | Send the selected local paragraph to the on-device model, preview result. |
| “Oto, translate the last part to Spanish” | On-device translation draft; preserve source and target-locale selection. |
| “Oto, summarize everything I said so far” | Local structured summary of the visible draft/chunk summaries. |
| “Oto, make this professional” | Run the selected rewrite mode on the local draft. |

Use deterministic parsing for fixed commands where possible. Use Foundation Models only for transformations. Every destructive command has Undo, every generative command has preview/cancel, and none manipulates an already-inserted external document.

## 4. Target architecture

The current code has the right concepts, but the production shape should make ownership and cancellation unambiguous.

```text
Menu bar / Settings / Flow Bar
              │ main-actor commands and presentation state
              ▼
      DictationCoordinator (one session state machine)
              │
  ┌───────────┼───────────────────────────┐
  ▼           ▼                           ▼
Shortcut   AudioCapture               AppleSpeechSession
service    service                    (one analyzer, one transcriber)
  │           │                           │
  └───────────┴── bounded audio delivery ─┘
              │ final text only
              ▼
      TranscriptProcessor
  dictionary → explicit snippets → history decision
              │
     raw final text ────────────────────┐
              │                         │
              ▼                         ▼
   OfflineIntelligenceService       TextInsertionService
  (optional draft/preview only)           │
              │                           ▼
              └──── chosen text ──→ original target app
```

### 4.1 State model

Represent mutually exclusive session states with one enum instead of loosely related flags. The presentation layer observes it; services do not mutate it directly.

```text
idle
  → requestingMicrophone
  → preparingSpeech
  → recording
  → finalizing
  → inserting
  → idle

Any active state → cancelling → idle
Any active state → failed(recoverable reason) → idle after acknowledgement
```

Rules:

- Only `DictationCoordinator` transitions the state.
- Every session receives a unique opaque session ID for logging and stale-task rejection.
- A task resumes from an `await` only if its session ID still matches the active session.
- `cancel`, `finish`, device loss, sleep, and app termination converge through one idempotent teardown path.
- Never call analyzer finalization and cancellation concurrently. The current code already guards this class of fault; keep the invariant in one tested teardown method.
- The UI may optimistically show a state, but it cannot start/stop audio by itself.

### 4.2 Concurrency boundaries

- Keep UI state and AppKit operations on the main actor.
- Keep the capture callback exceptionally small: copy/convert only what must cross the real-time boundary; no disk I/O, SwiftUI updates, regex work, logging with transcript content, or analyzer calls there.
- Use one bounded async delivery mechanism between capture and analysis. Its overflow policy must be written down and surfaced in diagnostics: for v1, drop oldest audio only when overloaded, count drops, then fail the session if loss passes a small threshold rather than quietly producing a corrupted transcript.
- Treat each dictation as a structured end-to-end operation. Avoid detached tasks. Store and cancel only the few unstructured tasks whose lifetime is user-driven (result consumption, audio drain, transient Flow Bar dismissal).
- Use `os.Logger` with redacted values and a session correlation ID. Never log raw audio, transcript text, dictionary contents, clipboard data, or snippets.

### 4.3 Speech-session implementation tactics

1. Resolve the current dictation locale against `supportedLocales`; preserve a specific region only when Apple exposes it, otherwise make the language-level fallback explicit in the UI.
2. On Settings open and after a system-language change, refresh the asset state. Do not check network reachability as a proxy for readiness.
3. Before a session, construct only the chosen module and verify the installed asset state.
4. Ask `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` for the selected module before deciding any conversion path. The current direct `AnalyzerInput` path is supported, but the format must be device-tested rather than assumed. [SpeechAnalyzer audio formats](https://developer.apple.com/documentation/speech/speechanalyzer)
5. Call `prepareToAnalyze(in:)` once before marking the session recording. The UI state is “Starting” until preparation actually succeeds.
6. Feed a single `AsyncStream<AnalyzerInput>` in original audio order.
7. Treat progressive output as display-only. It may change. Only final results enter the dictionary, snippets, history, and insertion path.
8. On release: stop capture, close input, drain accepted audio exactly once, call `finalizeAndFinishThroughEndOfInput()`, await the final result stream, then process and insert exactly once.
9. On cancellation: immediately stop capture, prevent further audio delivery, cancel result consumption, cancel the analyzer through the serialized teardown path, and discard partial text.
10. Release all analyzer/module references after each terminal state. Let macOS retain its own assets.

### 4.4 Permissions and recovery

Oto needs distinct recovery paths because one generic “permission error” is not useful.

| Capability | Need | Detection | Recovery action |
| --- | --- | --- | --- |
| Microphone | Capture input | `AVAudioApplication` record permission and a valid nonzero input format | Open Privacy & Security → Microphone; refresh device list afterwards. |
| Accessibility | Global HID event tap and cross-app paste | `AXIsProcessTrusted()` | Explain both uses; open Privacy & Security → Accessibility; re-check when app becomes active. [AXIsProcessTrusted](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) |
| Apple Speech assets | On-device recognition | `AssetInventory.status(forModules:)` for the configured module | Settings-only “Prepare offline” action; clear language-specific failure copy. |
| Launch at login | Optional presence | `SMAppService.mainApp` status | Register/unregister explicitly and direct a declined user to Login Items. [SMAppService main app](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) |

Never send a person to Settings automatically during dictation. Show the immediate problem in the Flow Bar, offer one icon-only action with an accessible label, and keep the detailed explanation in Settings.

### 4.5 Cross-app insertion

No macOS API can make every protected text field writable. Oto must be honest about that limit.

1. Capture the frontmost application at the start of a session, including its process identity.
2. At insertion time, verify the target is still running and activate it.
3. Put only the finalized text on the general pasteboard.
4. Synthesize Command-V only after Accessibility is granted.
5. Restore the full multi-item, multi-representation clipboard snapshot after a short, validated pasteboard transaction window.
6. If the target has exited, Accessibility was revoked, or pasteboard setup fails, do not paste into the current foreground app. Keep the finalized text available in Oto and show “Copy transcript” / “Open Scratchpad” recovery actions.
7. Do not promise insertion into secure fields. Test them, report actual behavior, and make their failure a normal recoverable state.

The default command path should remain paste-based because it works across native and many Electron apps. Direct Accessibility text-value replacement is a future, per-control optimization only; it needs stricter target validation and must always fall back to the paste path.

## 5. Detailed feature plan

### 5.1 Onboarding and first useful dictation

The first run should be a short readiness check, not a wizard.

1. Show a compact “Oto is ready when these are ready” screen in Settings: microphone, Accessibility, Apple Speech language assets, and shortcut.
2. Ask for microphone permission only when the person begins the readiness check or attempts dictation.
3. Ask for Accessibility only when they choose global shortcut/insertion setup; describe it in human terms: “hear your shortcut anywhere and paste the finished text into your current app.”
4. Keep Apple asset download as an explicit “Prepare offline” button. Show preparing, ready, unsupported language, and retry states. Never expose model file sizes or a fake Oto-managed download percentage.
5. Offer a safe in-app test field. Verify audio, live partial text, final text, cancellation, and insertion without leaving the app.
6. Make the default shortcut clear: **F5 / the Dictation key**. State that macOS function-key behavior can vary and provide a recorder plus a readiness test.

### 5.2 Shortcut behavior

**Default:** Hold F5 (or the corresponding physical Dictation key) to talk; release to finalize.

**Hands-free:** Press once to start; press again to finish. Silence auto-stop is optional behavior of this mode only.

Implementation rules:

- Use the existing pure `HotkeyTransitionState` as the source of truth for down/repeat/up behavior.
- De-duplicate AppKit monitor and HID event-tap delivery by event family and active pressed state; never create two begin calls from one physical press.
- Consume only the configured function-row event when Oto is handling it. Do not swallow unrelated function keys or modified key combinations.
- Re-enable a disabled event tap promptly, then surface a non-blocking diagnostic if it repeatedly times out.
- When Accessibility is unavailable, keep Settings and menu commands usable; label the global shortcut as unavailable instead of pretending it is registered.
- Build a small shortcut recorder that supports Escape cancel, conflict warnings, function keys, modifier combinations, and a safe default/reset. Do not accept modifier-only keys or normal unmodified letters.
- Keep `Command-Control-V` (paste last) and `Option-S` (Scratchpad) separate from the primary dictation shortcut and detect collisions inside Oto.

### 5.3 Flow Bar

The Flow Bar is feedback, not a control center. It should be compact and clearly communicative at a glance.

| State | Visual meaning | Interaction |
| --- | --- | --- |
| Idle | Hidden unless the person opts into an always-visible minimal indicator | None. |
| Starting | Quiet microphone glyph plus a subdued preparation pulse | Cancel. |
| Recording | Frosted translucent black pill, microphone glyph, responsive level bars, one clear stop/cancel control | Cancel. |
| Finalizing | Static waveform/progress state; no fake countdown | Cancel until finalization reaches an irreversible boundary. |
| Success | Short check confirmation, then disappear | No required action. |
| Cancelled | Brief calm dismissal confirmation, then disappear | No required action. |
| Failure / permission | Symbol, concise status, icon-only recovery affordance with text accessibility label | Open the relevant Settings page. |

The requested visual direction is a **transparent frosted pill with a moving soft gradient behind the content**, not decorative liquid glass. The treatment should stay almost black and white; the gradient is a low-opacity status texture, not a colored notification system.

Motion rules:

- Animate only the low-amplitude backdrop shift and audio-level response during recording.
- No continuous high-contrast motion while idle.
- Use `@Environment(\\.accessibilityReduceMotion)` to stop the moving gradient and use a stable surface plus level changes when Reduce Motion is enabled. Apple explicitly recommends avoiding large or simulated-depth animation in that mode. [SwiftUI Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- Important state changes must be understandable without motion, color, or sound. Apple's HIG calls for purposeful, optional motion and brief precise feedback. [Motion HIG](https://developer.apple.com/design/human-interface-guidelines/motion)
- Use VoiceOver announcements for recording start, completion, cancellation, and recovery-required errors, but do not announce every partial result. [Accessibility announcements](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/post%28element%3Anotification%3A%29)
- Avoid another `TimelineView`-driven rendering lifecycle for the Flow Bar until a teardown stress test proves it safe. Use one cancellable state-driven animation and ensure dismissing a panel cannot retain its view graph.

### 5.4 Settings information architecture

Keep the present five sections, with each page answering one question.

| Section | Purpose | Must contain |
| --- | --- | --- |
| Dictation | “How do I speak?” | readiness, shortcut, hold/tap mode, microphone, Flow Bar, Apple Speech setup. |
| Dictionary | “How do I teach Oto names and terms?” | searchable rules, enable/disable, scope, import/export, test field, duplication feedback. |
| Snippets | “What text should Oto expand?” | manual snippets first, explicit trigger safety, scope, enable/disable, preview. |
| Privacy | “What stays on this Mac?” | clear offline statement, history toggle, delete all text data, permission status. |
| History | “What did I dictate?” | optional local list, copy/reinsert/delete/clear, no audio retention. |

Layout rules derived from the provided references:

- 236-point sidebar, grouped labels, 40-point selectable rows, 2-point row spacing, 10-point continuous-corner selection/hover surface.
- A readable content column that uses `maxWidth`, not a hard content width. Let the settings window resize; preserve comfortable outer margins and use cards only for related controls.
- Tabs are for closely related content on one page; use a visible selected underline plus hover state. Do not create a decorative marketing banner.
- Use recognizably macOS controls for toggles, menus, shortcuts, deletion confirmation, and file import/export.
- Keep text contrast and hit targets compliant. Apple's current HIG says macOS controls should aim for 28 by 28 points and that spacing around controls matters as much as size. [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### 5.5 Dictionary

Dictionary entries should be boring, exact, and reversible.

```text
spoken form:   post gres
replacement:   PostgreSQL
scope:         Every app | This app only
enabled:       Yes / No
```

Rules:

- Match full words/phrases case-insensitively, then output the saved replacement exactly.
- Prefer the longest non-overlapping match.
- Never replace inside URLs, email addresses, or filesystem paths.
- Show an inline test result before saving a rule.
- Scope by stable bundle identifier, show a human app name in the UI, and treat a missing/exited app as global only when the rule is explicitly global.
- Cap entry lengths, count, and import size to defend the text pipeline from accidental large data.
- Import a versioned JSON schema; preview imported additions/conflicts; do not overwrite without confirmation.
- Export only rules, never history unless a separate explicit export is added later.

For the first release, dictionary correction happens after final recognition. Contextual vocabulary is a separately measured enhancement, as described in section 3.4.

### 5.6 Snippets

Ship snippets in two safe stages.

**Stage A — manual snippets (release requirement)**

- Create, edit, duplicate, enable/disable, scope, and delete snippets.
- Insert manually from a searchable menu or Scratchpad; this must work with no speech recognition ambiguity.
- Provide preview, copy, and explicit “Insert into previous app” actions.

**Stage B — spoken triggers (only after Stage A is stable)**

- Default trigger grammar: “Oto insert *snippet name*.”
- Natural-phrase expansion remains off by default because “my email” can occur as ordinary speech and may contain sensitive text.
- Perform trigger recognition only on final transcript text, never an unstable partial.
- Let people choose whether the trigger phrase is removed from the inserted result.
- If no unique enabled snippet matches, leave the recognized phrase unchanged and show no destructive error.
- Do not add programmable snippets, shell execution, web requests, or clipboard interpolation in v1.

### 5.7 History and privacy

- History is opt-in, local only, text only, and disabled by default.
- Do not retain audio, audio levels, partial transcripts, raw recognition alternatives, clipboard snapshots, or target-app contents.
- Bound local history to a reasonable count and provide per-item delete plus clear all.
- Make “clear all personal data” erase dictionary entries, snippets, and history only after a clear confirmation that names each category.
- Default diagnostics are aggregate timings/counters only. Include a “copy diagnostics” action that excludes personal text.
- If distribution later adds crash reporting, disable transcript/audio collection and document the provider and retention explicitly.

## 6. Reliability and performance plan

### 6.1 Required invariants

1. There is at most one active `AVAudioEngine` tap.
2. There is at most one active `SpeechAnalyzer` session.
3. `finish` and `cancel` are serialized and idempotent.
4. Only a final result can mutate history or call insertion.
5. A stale task cannot mutate the active state after a newer session begins.
6. The audio queue is bounded under all conditions.
7. The Flow Bar never retains a terminated analyzer or starts a dictation task.
8. An unavailable permission/device/asset has a specific recovery route.
9. Oto never changes the clipboard without either restoring it or offering a visible recovery transcript after an insertion failure.
10. Oto is useful with no network after Apple Speech setup.

### 6.2 Measurements to record locally (no transcript content)

Record durations and counters keyed to an opaque session ID:

- shortcut press → microphone capture started;
- capture started → analyzer prepared;
- first audio chunk → first partial result;
- release/toggle stop → final result;
- final result → insertion event posted;
- session end-to-end;
- input format, sample rate, and channel count;
- queue high-water mark and dropped-chunk count;
- result count, final-result count, cancellation count;
- preparation/asset/error category (never the message's personal data);
- memory warning, sleep/wake, device-change, and event-tap disable counts.

Use the numbers to find regressions, not to rank users or collect analytics. Establish device baselines before setting performance targets.

### 6.3 Profiling method

1. Profile a signed Release build, not only `swift test` or a debug executable.
2. Capture separate traces for first session after app launch, repeated short dictation, long dictation, rapid start/cancel, hands-free auto-stop, microphone change, and sleep/wake.
3. Use Instruments Time Profiler, Allocations/Leaks, Hangs, and Swift Concurrency views.
4. Examine the audio callback first: it must not allocate repeatedly beyond unavoidable buffer copying or block on main-actor work.
5. Examine SwiftUI invalidation: microphone-level changes must redraw only the Flow Bar waveform subtree, not Settings or menu state.
6. Compare the two Apple transcriber candidates only with the same mic, language, scripted speech, OS build, and release build.
7. Treat a crash, dropped final, wrong-app paste, or any uncaught timeout as a correctness failure before optimizing milliseconds.

### 6.4 Interruption handling

| Event | Required behavior |
| --- | --- |
| Microphone revoked/removed | Stop input, discard unfinished transcript, explain, refresh devices, allow a clean new session. |
| Audio route/default changes | Re-query devices; preserve selection by UID when present, otherwise fall back to system default and communicate it. |
| Accessibility revoked | Keep recording functional, prevent cross-app insertion, retain final text for copy/Scratchpad, show precise recovery. |
| Apple asset evicted/not ready | Fail before microphone capture where possible; expose Settings-only preparation. |
| Sleep/wake | Cancel active work, remove tap, invalidate any prepared session, and require a new press. |
| App resigns active | Continue only if a valid original target was captured; do not redirect text to the new foreground app. |
| Event tap disabled | Re-enable once, reset pressed state, and never leave a hold-to-talk session stuck recording. |
| Repeated stop/cancel | First terminal intent wins; later calls are no-ops. |
| App quit | Tear down audio and analyzer synchronously enough to avoid a dangling tap; do not attempt final insertion. |

## 7. Test and release plan

### 7.1 Automated tests to add

| Layer | Tests |
| --- | --- |
| Session state machine | Legal/illegal transitions, stale session IDs, start while stopping, finish/cancel races, final result exactly once. |
| Speech adapter | Asset status mapping, unsupported locale fallback, input stream close ordering, final stream wait, cancellation ordering through a fake engine. |
| Audio queue | Capacity, overflow policy, cancellation while draining, duration/format accounting. |
| Shortcut | F5 and dictation-key aliases, key repeat, local/global duplicate delivery, monitor restart, event-tap timeout reset, recorder conflicts. |
| Insertion | Target loss, accessibility denial, pasteboard write failure, multi-item restoration, no fallback to the wrong foreground app. |
| Text processor | Dictionary precedence/protected ranges/scope/import validation; snippets and ambiguity; history opt-in/deletion. |
| Preferences | Migration, defaults, privacy toggles, unavailable feature states. |
| UI | Settings navigation, button accessibility labels, reduced-motion Flow Bar variant, status/error copy, destructive confirmation. |

New deterministic Swift tests should prefer Swift Testing. Keep XCTest where it is needed for UI automation and performance metrics. Use fakes for audio, speech, time, and insertion so that race tests do not need a microphone or Apple assets.

### 7.2 Real-device matrix

Do not release based only on the unit suite. Run [`11_RELIABILITY_TEST_MATRIX.md`](11_RELIABILITY_TEST_MATRIX.md) on signed builds and add these dimensions:

- At least one supported Apple-silicon Mac from each claimed hardware family. Do not add an Intel test target unless the product decision explicitly expands the support claim.
- Fresh install with no mic permission, no Accessibility permission, and no prepared language asset.
- Prepared offline mode with the network disabled.
- Each supported system dictation language; unsupported system language behavior.
- Built-in mic, USB mic, Bluetooth headset, and unplug/replug behavior.
- Safari, Slack, an Electron app, VS Code editor and terminal, Terminal, Notes/TextEdit, and representative secure fields.
- Hold-to-talk, hands-free, menu command, Flow Bar cancel, Escape, paste last, Scratchpad, and selected custom shortcut.
- Light/dark appearance, high contrast, larger text, VoiceOver, Reduce Motion, multiple displays, full-screen app, and Spaces.
- Repeated cancellation, 30+ minute idle process lifetime, sleep/wake, app relaunch, OS permission changes while running.

For every failure, capture: Oto build, macOS build, hardware, input device, shortcut setting, language/asset state, target app/version, permission state, session correlation ID, and last Flow Bar state. Never include dictated content in a default bug report.

### 7.3 Shipping requirements

- Set a real bundle identifier, versioning policy, Developer ID signing, Hardened Runtime, and notarization pipeline.
- Audit `Info.plist` copy. `NSMicrophoneUsageDescription` must accurately describe local dictation. Do not request `NSSpeechRecognitionUsageDescription` unless the app actually introduces `SFSpeechRecognizer`; Apple identifies that authorization path as separate from SpeechAnalyzer modules. [Apple's authorization guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
- Validate the app from a clean macOS account, not only a developer machine with inherited privacy grants.
- Verify login-item registration with `SMAppService`, including decline, disable, and update behavior. [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)
- Publish a plain-language privacy policy: Apple-managed language asset setup, on-device speech processing, no Oto cloud transcription, optional local history, no audio retention, and permissions purpose.
- Include third-party licenses only for assets actually shipped. The Apple-first build should have no model-runtime license burden.
- Provide an in-app “Copy support diagnostics” item that excludes text/audio and points to the privacy policy.

## 8. Ordered implementation backlog

This order preserves product reliability. It intentionally has no calendar estimates.

### Release-critical core

1. **Close the current Flow Bar crash/reliability loop.** Stress start/stop/cancel/dismiss hundreds of times on device; verify no retained panel/view animation work after dismissal.
2. **Finish the explicit session coordinator.** Consolidate begin, finish, cancel, interruption, and error cleanup under one session-ID state machine with fake-engine tests.
3. **Validate and select the Apple transcriber.** Run the controlled `SpeechTranscriber`/`DictationTranscriber` comparison and record the chosen configuration in code and release notes.
4. **Harden Apple asset readiness.** Refresh state correctly; show a specific unavailable/downloading/ready/unsupported UI; verify a fresh install and offline-after-setup flow.
5. **Harden F5/dictation-key behavior.** Verify event-tap permission, both physical key-code forms, duplicate-event avoidance, and keyboard-specific failure recovery.
6. **Harden insertion.** Add target-liveness protection, clear fallback actions, pasteboard restoration assertions, and cross-app manual QA.
7. **Finish interruption recovery.** Route changes, permission changes, sleep/wake, app switching, event-tap timeouts, and rapid cancellation must all lead to a clean reusable idle state.

### Release-critical product completeness

8. **Complete the readiness-first Settings experience.** One source of truth for each requirement and a safe in-app test field.
9. **Finish dictionary UX.** Search, test, import preview, scoped rules, conflict feedback, accessibility, and contextual-vocabulary experiment behind an internal flag.
10. **Finish manual snippets.** Editing, scope, insertion menu, preview, safe explicit trigger rules, and tests.
11. **Finish Scratchpad.** Reliable open/close, submit/cancel, copy, and insert-to-original-target behavior.
12. **Finish history and privacy controls.** Opt-in, local-only wording, per-item actions, clear all, bounded storage, and migration testing.
13. **Complete Flow Bar polish.** All defined states, reduced motion, VoiceOver announcements, screen/Space placement, dynamic content width, and no text-only “Settings” button in the pill.
14. **Build the offline intelligence foundation.** Add availability gating, on-device-only model construction, a short-lived request/session coordinator, structured draft schema, cancellation, source preservation, offline network tests, and prompt evaluation fixtures.
15. **Build Smart Mode.** Add deterministic app-category mappings, opt-in automatic suggestion, email/message/code/meeting/journal mode contracts, mode chips, and raw-text recovery.
16. **Build structured formatting and tone tools.** Add list/table/reminder candidates, rewrite presets, translation, an editable preview, and insert-original/copy/Scratchpad choices.
17. **Build safe smart snippets and voice editing.** Ship exact/manual snippets first, then explicit spoken triggers and template fields; implement local-draft-only commands with Undo and previews.
18. **Build the explicit long-form mode.** Token-bounded local chunking, structured chunk summaries, aggregation, evidence ranges, optional local retention, and review-only follow-up-email drafts.
19. **Add launch at login and menu-bar lifecycle QA.** Ensure the app stays agent-style, Settings opens reliably, and quit/panel cleanup is correct.

### Quality gate

20. **Add test doubles and expand automated tests** in section 7.1, including prompt fixtures and structured-output validation.
21. **Run the real-device matrix** in section 7.2; fix all correctness failures before tuning performance.
22. **Profile and reduce regressions.** Use measurements in section 6.2, then optimize only confirmed bottlenecks.
23. **Prepare distribution.** Signing, notarization, privacy text, update strategy, fresh-account test, and support diagnostics.

### Expanded capability, only after the core release gate remains green

24. Improve smart-mode prompts and tests per OS/model version without changing the offline-only guarantee.
25. Add the optional contextual-vocabulary projection if measured results justify it.
26. Reconsider third-party/offline model engines only when there is a demonstrated Apple Speech gap. Keep them behind the existing engine boundary, as a separately packaged and benchmarked product decision—not a hidden dependency in the lightweight release.

## 9. Decisions to reject unless new evidence changes them

| Tempting alternative | Why not now |
| --- | --- |
| Bundle or download open-source models “just in case” | Increases binary/disk/memory footprint, update and licensing surface, startup complexity, and failure modes without helping Apple Speech v1 reliability. |
| Maintain a Rust/Swift dual runtime for v1 | Two audio, lifecycle, diagnostics, and compatibility systems make core correctness harder; the product has chosen one native runtime. |
| Start downloading speech assets when the user presses the shortcut | Violates the offline promise, creates a confusing first-use failure, and makes latency/network state part of dictation. |
| Keep a microphone/analyzer permanently open | Wastes resources, complicates privacy expectations, and makes recovery after sleep/device changes harder. |
| Auto-expand natural snippets by default | A common phrase can expand private or long text into the wrong application. |
| Insert partial results continuously into the target app | Produces flicker, duplication, undo complexity, and unsafe edits when recognition revises itself. |
| Make Flow Bar animation convey the only state | Fails Reduce Motion and accessibility requirements; text/symbol/state must remain clear. |
| Fallback to the current frontmost app when the original target disappears | Risks pasting confidential text into the wrong application. |
| Claim universal secure-field support | macOS and target apps intentionally restrict it; Oto must present a recoverable limitation. |

## 10. Definition of done for the first release

Oto is ready to ship when all of the following are true:

- A fresh person can prepare a supported Apple Speech language once, disconnect from the network, and dictate successfully.
- Hold-to-talk and hands-free both start/stop exactly once across tested keyboards, or the UI clearly reports the Accessibility prerequisite.
- The Flow Bar survives sustained start/stop/cancel stress with no crash or stale panel, honors Reduce Motion, and exposes accessible recovery controls.
- Final text is inserted once into the captured app or kept safe for copy/Scratchpad; it is never inserted into a newly focused unrelated app.
- Dictionary, manual snippets, Scratchpad, and optional history work locally, predictably, and can be erased.
- On capable Macs, every enabled intelligence mode uses `SystemLanguageModel` on-device only, preserves the source, offers cancel/undo or preview, and succeeds with the network disabled.
- Smart Mode uses app identity and explicitly approved local references only; it never reads surrounding target-app content or performs an external side effect automatically.
- Long-form intelligence respects the model context budget through local chunking and makes every summary/action item reviewable before use.
- Microphone, Accessibility, missing asset, device change, app switching, sleep/wake, and cancellation each have tested recovery behavior.
- The deterministic test suite passes; the signed app passes the real-device/cross-app test matrix; performance traces identify no unbounded queue, leak, or repeated main-thread stall.
- The shipped package is signed, notarized, private by default, accurately documented, and contains no unused model runtime.

## 11. Research references

The plan relies on current primary Apple documentation. Verify these again when upgrading the SDK because Speech and Foundation Models APIs evolve with macOS releases.

- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)
- [AnalysisContext](https://developer.apple.com/documentation/speech/analysiscontext)
- [Asking Permission to Use Speech Recognition](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Private Cloud Compute comparison](https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute)
- [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels)
- [NSWorkspace frontmost application](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
- [AXIsProcessTrusted](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
- [SwiftUI Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- [Apple Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Apple Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
