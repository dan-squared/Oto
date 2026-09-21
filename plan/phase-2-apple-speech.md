# Phase 2 — Real Apple Speech (VERIFIED COMPLETE 2026-09-20)

Status: COMPLETE. Automated 35/35 green + user manual proof on-device:
offline hands-free dictation transcribes correctly (menu transcript
showed spoken words), mic-denied fails distinctly, cancel is clean.
Grep gates pass. Console tracking via MCP `GetConsoleOutput` is now the
standard observation method (no more pastes).

## 1. Goal (START_HERE_PRODUCT.md Phase 2 + 10_NEXT_STEP §3)

Replace the two fakes behind the UNCHANGED coordinator seams with real,
offline Apple Speech:

```text
mic → AVAudioEngine tap → bounded relay → SpeechAnalyzer/SpeechTranscriber → finals
```

- Microphone + Speech authorization with exact recovery states.
- Explicit asset readiness + preparation — Settings-only, never on
  shortcut press.
- Locale selection + clear unavailable states.
- No network in the record path; prepared language dictates offline.
- All 14 Phase 1 tests stay green (fakes untouched); new deterministic
  tests cover only pure/testable parts (locale matching, readiness
  mapping, relay bounds).

## 2. Sources read for this plan

- `Docs/OTO_REBUILD_PLAN/07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md` (full) —
  esp. §§3.1–3.3 (engine choice), 4.2 (concurrency/bounded delivery),
  4.3 (session tactics 1–10), 4.4 (permissions table), 6.1/6.4
  (invariants, interruptions).
- `Docs/OTO_REBUILD_PLAN/02_RECORDING_WORKFLOWS.md` — recovery table,
  capture-first ordering, finals-only insertion.
- `Docs/START_HERE_PRODUCT.md` Phase 2 scope + speech boundary bans.
- macOS 27 SDK, verified by grep (not memory — §3).
- Yap reference: `TranscriptionService.swift` (137), `AudioCaptureService.swift`
  (127), `AudioBufferRelay.swift` (49), `BufferConverter.swift` (46),
  `SpeechLocale.swift` (43), `PermissionsManager.swift` (mic/speech parts)
  at `/private/tmp/yap-reference` 6596874. Assessed pattern-by-pattern (§4).

## 3. SDK facts verified (macOS 27 SDK)

- `SpeechAnalyzer` is a `final actor`: `init(modules:)`,
  `prepareToAnalyze(in:)`, `start(inputSequence:)`,
  `finalizeAndFinishThroughEndOfInput()`, `cancelAndFinishNow()`,
  `bestAvailableAudioFormat(compatibleWith:)` (+ `considering:` variant).
  One analyzer = one input sequence (matches one-session machine).
- `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`,
  `Preset` incl. `.progressiveTranscription`; `supportedLocales` /
  `installedLocales` async statics; `results` async sequence of
  `Result` with `isFinal: Bool`, `text: AttributedString`.
- `AssetInventory`: `status(forModules:)` → `Status`
  (`unsupported/downloading/supported/installed`, Comparable);
  `assetInstallationRequest(supporting:)` → request with
  `downloadAndInstall()`; `reserve(locale:)` / `reservedLocales`.
- `AnalyzerInput(buffer: AVAudioPCMBuffer)` is NOT deprecated in 27
  (only the `.buffer` getter is); plus a new 27 sample-buffer init we
  do not need in v1.
- Mic permission: `AVAudioApplication.recordPermission` /
  `requestRecordPermissionWithCompletionHandler` (macOS 14+, current).
- Speech permission: `SFSpeechRecognizer.authorizationStatus` /
  `requestAuthorization` — still present, NOT deprecated in 27 headers.
  (Apple's doc note, cited by 07 §3.1, distinguishes server-oriented
  auth from on-device modules — our privacy copy must stay precise,
  but the API stands.)
- Entitlement groundwork already done: Phase 0 added
  `com.apple.security.device.audio-input` under sandbox (verified in
  code signature). No new entitlements for Phase 2.

## 4. Yap assessment: adopt / reject / improve

ADOPT (validated against §3, all current):

- Fresh `AVAudioEngine` per start + degenerate-format guard
  (`sampleRate > 0, channelCount > 0`) — the uncatchable-ObjC-exception
  lesson; tap the input's hardware format, never assume 16 kHz.
- Drop-and-rebuild engine on `stop()` (releases BT headset low-quality
  mode) and on `AVAudioEngineConfigurationChange` with re-entrancy
  guard; tear down observer/tap on failure, never half-running graph.
- Capture-first ordering: relay reset → capture start → resolve locale
  → prepare → attach sink (first words preserved).
- Finish ordering: finish input stream → `finalizeAndFinishThroughEndOfInput()`
  → cancel result task → release analyzer/module refs (short-lived
  analyzer per session, 07 §3.2).
- `reportingOptions: [.volatileResults]`, `attributeOptions: [.audioTimeRange]`;
  finals appended, volatiles display-only.
- Three-step locale matching (exact → language+region ignoring
  extensions → language-any-region), sorted candidates for stability;
  `locale.language.region` (not `.region`) for the language's region.
- Cached `AVAudioConverter` with `primeMethod = .none`; per-buffer
  capacity from sample-rate ratio.
- Auth approach: `AVAudioApplication` (mic) + `SFSpeechRecognizer`
  (speech) — both current per §3.

REJECT (violates our locked rules):

- `ensureModel` DOWNLOADS assets inside `begin()` (the dictation path)
  when the locale isn't installed. Oto rule: shortcut path inspects
  readiness only and fails with a recovery message; download happens
  exclusively via the explicit Settings action. Our `prepare()` must
  never call `downloadAndInstall`.

IMPROVE (Yap gap vs 07 §4.2):

- Yap's relay drops beyond 250 buffers silently (no count, no failure).
  07 requires: drop-oldest, COUNT drops, fail the session past a small
  threshold. Our relay adds the counter + threshold failure.

## 5. Planned changes

New files:

- `Oto/Models/SpeechReadiness.swift` — `SpeechReadiness` enum:
  `.unsupportedOS` (defensive; target is 27), `.unsupportedLocale`,
  `.assetsNotPrepared`, `.assetsPreparing`, `.microphoneDenied`,
  `.ready`. Pure mapping from
  (`AssetInventory.Status`, installed?, resolved?, micStatus) via
  `SpeechReadinessMapper` — unit-tested without hardware.
- `Oto/Services/SpeechLocaleMatching.swift` — pure `bestMatch`
  (adopt Yap's three-step algorithm as Oto-owned code with attribution
  comment). Unit-tested with synthetic candidate lists.
- `Oto/Support/AudioBufferRelay.swift` — lock-protected, capacity 250,
  drop-oldest + drop counter; `droppedBufferCount` surfaced; threshold
  constant (fail past N, exact N set from device testing later —
  default 50). `receive/attach/reset` only; no UI/FFT/await on the
  realtime path.
- `Oto/Support/BufferConverter.swift` — cached-converter port
  (attribution comment), realtime-safe (no allocation beyond output
  buffer).
- `Oto/Services/AppleAudioCapture.swift` — real `AudioCaptureServing`:
  fresh engine per start, degenerate guard, config-change rebuild,
  drop-on-stop. Callbacks (`onBuffer/onLevel`) do nothing but forward.
- `Oto/Services/AppleSpeechService.swift` — real `SpeechServing`:
  `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
  (initial module choice `SpeechTranscriber`, fixed per build per
  07 §3.3 — NOT user-selectable, NO `DictationTranscriber` fallback);
  `prepare()` = resolve locale → check `installedLocales` + `status`
  → throw `SpeechReadiness` error on anything but ready (NEVER
  download); `finish()` = close input, drain once,
  `finalizeAndFinishThroughEndOfInput()`, await finals; `cancel()` =
  serialized teardown. Short-lived analyzer, released at terminal.
  Partial hook: `onPartial` closure property, wired to nothing in
  Phase 2 (Flow Bar lands Phase 6); volatiles never touch insertion.
- `Oto/Services/SpeechAssetPreparer.swift` — explicit
  `prepare(locale:)` for Settings-only use: resolve → status →
  `assetInstallationRequest?.downloadAndInstall()` → `reserve(locale:)`.
  The ONLY caller of `downloadAndInstall` in the codebase; assert
  this in review (grep gate).
- `Oto/Support/PermissionsManager.swift` — mic (`AVAudioApplication`)
  + speech (`SFSpeechRecognizer`) status/request with exact states;
  precise privacy copy (on-device, no audio to Apple servers — 07 §3.1).

Modified files:

- `Oto/App/OtoApp.swift` — wire REAL audio + REAL speech into the
  coordinator (fakes stay for tests). DEBUG menu gains
  "Prepare offline speech" (explicit download trigger) alongside the
  two simulate items. All three DEBUG items die by Phase 5/3.
- `Oto/UI/OtoMenuBarView.swift` — third DEBUG item (see above).
- `OtoTests/` — new `SpeechLocaleMatchingTests` (pure matching),
  `SpeechReadinessMappingTests` (status matrix),
  `AudioBufferRelayTests` (bound/flush/reset/drop-count).
  All 14 coordinator tests untouched and green.

Explicitly NOT in Phase 2: mic device selection UI, locale picker UI,
full Settings product (Phase 5); shortcut monitor (Phase 3); real
insertion (Phase 4); dictionary/snippets/history (Phase 6);
`SpeechDetector`/VAD (07 §3.5 — hands-free auto-stop stays out);
Foundation Models (post-v1, 07 §§3.6–3.8 — not imported, not linked).

## 6. Verification

- `BuildProject` green; `RunAllTests` 14 old + new suites green.
- `grep downloadAndInstall` → exactly one call site
  (`SpeechAssetPreparer`); `grep SFSpeechRecognizer` → permissions
  only, never transcription.
- Manual (user-assisted, per 10_NEXT_STEP §3): prepare language online
  → disconnect network → DEBUG hold → real offline dictation; then
  (fresh unprepared locale path) → clear "prepare in Settings" failure,
  no download attempted. Mic-denied path checked via TCC revoke.
- Invariants spot-checked (07 §6.1): one engine tap, one analyzer,
  no insert of volatiles, stale-task discard (already unit-proven).

## 7. Risks and deferred decisions

- First-session analyzer latency unmeasured — measure before any
  warm-session optimization (07 §3.2 forbids pre-building it).
- `installTap` ObjC-exception class of fault: mitigated by
  fresh-engine + degenerate guard (Yap-proven), but first real-device
  run is the actual proof.
- BT headset format mismatch (48 kHz device / 44.1 client): converter
  + hardware-format tap cover it; needs the device matrix (Phase 4/6).
- `SFSpeechRecognizer` auth wording: keep privacy copy to the framework
  guarantee (07 §3.1); revisit if Apple deprecates it in a later SDK.
- Partial-result delivery has no consumer until Phase 6; hook only.

## 8. Open questions for the user

1. Preparation trigger: third DEBUG menu item now (recommend — proves
   behavior before Phase 5 UI), vs. minimal Settings section now?
2. Locale: default to system locale with unsupported-locale failure
   (recommend — picker UI is Phase 5), vs. DEBUG locale override too?
