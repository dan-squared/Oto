# Dictation feedback sounds — Apple's own start / done / failure tones

Status: **IMPLEMENTED 2026-11-03** (see §10 for what shipped and what the
build/tests proved). §1–§9 are the plan as approved; §8 R2 was resolved during
implementation, not deferred — the duck now waits out the tone.

Scope: three short cues played by the app around a dictation session. No
change to the pill's visuals, the coordinator's state machine, insertion, or
speech.

## 1. The ask

> "the default tap sound when the shortcut is pressed and the default ready
> when release and the words are pasted and warning when something fails or
> error message or need permission modal appears" — user, 2026-11-03.
> Follow-up: "find the default macOS dictation sound that the native macOS
> dictation uses". Answer accepted: use Apple's own tones.

The starting idea was the npm package `cuelume`, which synthesises Web Audio
cues at runtime and ships **no audio files** (`cuelume@0.2.8`, MIT, 224 KB of
`dist/*.js`; `dist/sounds/recipes.js` is declarative layers — tones, filtered
noise, attack/decay/peak). "Extracting" it therefore means either porting the
synthesis or rendering it offline, which is real DSP work for a benefit that
disappears once the native tones are available. Superseded by the decision in
§3.

## 2. Verified facts (measured on this Mac, not from memory)

### 2.1 The files

| Cue | Path | `afinfo` |
|---|---|---|
| Start ("listening") | `/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf` | 0.454 s, 44.1 kHz, 1 ch, Int16, 40 042 bytes |
| Stop ("done") | `.../SystemSounds/system/end_record.caf` | 0.427 s, 44.1 kHz, 1 ch, Int16, 37 662 bytes |
| Failure | `/System/Library/Input Methods/DictationIM.app/Contents/Resources/UnableToStartDictationSound.caf` | 0.400 s, 44.1 kHz, 2 ch, Int16, 74 656 bytes |

Content (Goertzel scan at 30 ms windows, `.context/dictation-sounds/`):

- `begin_record` — one D6 note at 1175 Hz, mallet decay; a faint second strike
  at ~120 ms. Peak RMS 0.063 at t=0, below 0.001 by 0.20 s.
- `end_record` — A5 (880 Hz) for ~80 ms, then D6 (1175 Hz) decaying. Peak RMS
  0.066 at 0.10 s.
- `UnableToStartDictationSound` — a low 83 / 420 Hz buzz, flat-ish decay.

Both are quiet, mastered well under full scale (peak RMS ≈ 0.06), so they need
no volume trim to sit beside media.

Why these are *the* dictation pair, stated honestly:

- they are the only record start/stop pair in the system sound library
  (`/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/`
  has exactly one `begin_record` and one `end_record`);
- `DictationIM.app` ships only the failure cue — its binary references
  `cancelSound`, `notifyUserOfCommandFailureUsingSound` and
  `UnableToStartDictationSound`, and nothing else sound-like, so start/stop
  must come from the shared library;
- `SpeechObjects/…/DefaultRecognitionSound.aiff` (77 ms blip, 22.05 kHz) is
  Voice Control's recognition beep, **not** dictation — excluded.

Confidence: high that these are the tones, not proof. Verification step §9
step 4 is the human check (play both).

### 2.2 Playback mechanics (probe compiled against the local SDK)

`AVAudioPlayer` is current, not deprecated (`AVAudioPlayer.h`,
`API_AVAILABLE(macos(10.7))`).

| measured | begin | end | failure |
|---|---|---|---|
| `AVAudioPlayer(contentsOf:)` | 9.67 ms (cold) | 0.37 ms | 0.20 ms |
| `prepareToPlay()` | 105.44 ms (cold) | 6.60 ms | 6.53 ms |
| decodes | yes, duration matches `afinfo` | yes | yes |

- Two `AVAudioPlayer` instances on the same file both play simultaneously
  (`a.play() && b.play()`, both `isPlaying`) → a 2-voice round-robin pool works
  without an `AVAudioEngine`.
- The files are world-readable (`-rw-r--r-- root:wheel`) and the app is not
  sandboxed (`ENABLE_APP_SANDBOX = NO`, `Oto/Oto.entitlements` is empty), so no
  sandbox extension or bookmark is needed.
- Cold `prepareToPlay` is ~105 ms → it must not run on the press path.

### 2.3 Where ducking sits

`MediaDuck` saves the output device volume and sets it to 0 while recording
(`Oto/Services/MediaDuck.swift`), so any cue played during recording is
inaudible.

- The press cue is played at key-down, before the duck (duck happens on the
  `starting → recording` transition, after `audio.start()` + `speech.prepare()`).
- The done cue and every failure cue must be emitted **after**
  `restoreMedia(sessionID:)`. In `DictationCoordinator` that is already true at
  the sites in §5.3, with one ordering nuance recorded there.

## 3. Decision

**Use Apple's tones, read from the system at runtime. Do not bundle them, do
not render cuelume, do not add a package dependency.**

Rationale: it is the sound macOS users already map to "listening / done";
it is zero bytes in the repo; copying Apple's `.caf` into the bundle would
redistribute Apple's audio, which is not ours to ship.

Fallback: if a file is missing (OS layout change), the cue is silent and one
log line records it at launch. No beep, no crash, no per-press log spam.

## 4. Cue map

| Moment | Cue | Owner |
|---|---|---|
| Shortcut begins a session (hold down, fn confirmed, hands-free first press) | start tone | `ShortcutDispatch` |
| Hands-free second press (stop) | **nothing** | — |
| Escape / Flow Bar cancel | nothing | — |
| Insertion verified (`.inserted`) | done tone | `DictationCoordinator` |
| Empty / silent-skip session completes | nothing (no words landed) | — |
| Mic denied (permission card appears) | failure tone | `DictationCoordinator` |
| Audio capture / speech preparation / finalize failure | failure tone | `DictationCoordinator` |
| Target gone, insertion failed, no text field (catcher appears) | failure tone | `DictationCoordinator` |

The hands-free stop press is deliberately silent: pressing again starts
finalization, and the done tone arrives when the text actually lands. The
loader in the pill is the in-between signal within the first poll. Playing the
start tone there would name the wrong moment ("listening" while the session is
ending), and pressing a control that immediately shows work needs no extra
acknowledgement. Deferred alternative if it ever feels dead: play nothing new,
but move the loader to paint on the same runloop tick as the press.

One tone for every failure is confirmed by the user (2026-11-03): Apple ships
exactly one "dictation could not start" cue, and inventing a second error
vocabulary would mean synthesising or sourcing a sound, which is what this plan
avoids.

**Superseded by §10.4 (same day, user direction):** the done tone is no longer
tied to `.inserted`. It sounds at the stop — key-up, second press, Flow Bar
stop — the way native dictation does, and a later failure still adds the error
tone on top. Read `.landed` below as `.stopped` emitted from
`finalizeSession`.

## 5. Exact changes

### 5.1 New — `Oto/Services/FeedbackSounds.swift`

(Directory is a `PBXFileSystemSynchronizedRootGroup`, so a new file needs no
project edit.)

```swift
/// The three moments one dictation session can sound.
enum DictationCue: Equatable, Sendable {
    case listening   // shortcut pressed, session begins
    case landed      // transcript inserted
    case failed      // anything that needs the person's attention
}
```

- `enum FeedbackSoundSettings` — `key = "app.Oto.feedbackSounds"`,
  `isEnabled(defaults:)` default **true** (absent key = on), same shape as
  `MediaDuckSettings.isEnabled` so a test can pin the literal.
- `enum FeedbackSoundAsset` — one case per cue, with
  `candidates: [String]` (absolute paths, in order) and a `displayName`
  for logging. `begin_record` / `end_record` resolve under
  `…/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/`,
  failure under `…/DictationIM.app/Contents/Resources/`. Each case also
  honours an optional `OTO_FEEDBACK_SOUND_DIR` override so a test (or a
  developer with a mocked layout) can point at a temp directory — the same
  debug-affordance pattern as `InsertionExperiment.current()`.
- `@MainActor protocol FeedbackSounding: Sendable { func play(_ cue: DictationCue) }`
- `@MainActor final class FeedbackSoundPlayer: FeedbackSounding`
  - `init()` builds the pool: 2 `AVAudioPlayer`s per cue, `prepareToPlay()`
    each, `volume = 1`. Missing file → that cue's pool stays empty, one
    `Logger(subsystem: "app.Oto", category: "feedbackSound").notice(...)`.
  - `play(_ cue:)`: `guard FeedbackSoundSettings.isEnabled() else { return }`;
    pick the next player round-robin (`(index + 1) % pool.count`), reset
    `currentTime = 0`, `play()`. No `await`, no Task, no allocation on the
    press path.
  - `nonisolated static func resolve(_ asset:) -> URL?` — pure, testable,
    reads the override first, then the candidate list, checking
    `FileManager.isReadableFile`.
  - Defensive: if `prepareToPlay()` failed at launch, `play()` still tries
    once (cheap, and a one-off failure should not silence the app forever).

### 5.2 `Oto/App/OtoApp.swift`

- Construct `let feedbackSounds = FeedbackSoundPlayer()` early in `init()`
  (before `ShortcutDispatch`), store it in a `private let`, and pass it to:
  - `DictationCoordinator(…, feedback: { cue in Task { @MainActor in feedbackSounds.play(cue) } })`
  - `ShortcutDispatch(coordinator:sounds:)`.
- Preload cost at launch: measured ~0.2–10 ms per file plus ~105 ms cold for
  the first `prepareToPlay()`. Accepted one-time cost in `init` (which already
  loads persistence and constructs stores). If launch time ever regresses,
  the fallback in §10 is a background preload that plays nothing until ready.

### 5.3 `Oto/Coordinator/DictationCoordinator.swift`

- New injected dependency, last parameter, default `nil` so every existing
  test constructs unchanged:
  ```swift
  private let feedback: (@Sendable (DictationCue) -> Void)?
  ```
- One private helper, no suspension, no state access:
  ```swift
  private func announce(_ cue: DictationCue) { feedback?(cue) }
  ```
- Emit sites (line numbers from today's file):

  | Line | Path | Emit |
  |---|---|---|
  | 359 | mic denied, pre-audio | `announce(.failed)` after state set |
  | 369 | audio capture failure | same |
  | 390 / 392 | speech preparation failure | same, once, after the if/else |
  | 525 | finalize speech failure (after `restoreMedia`) | `announce(.failed)` |
  | 590 | target gone (after `restoreMedia`) | `announce(.failed)` |
  | 611–612 | `.inserted` | `announce(.landed)` after `state = .completed` |
  | 620 | insertion failed (restore ran at 608) | `announce(.failed)` |
  | 630 | no text field (restore ran at 608) | `announce(.failed)` |

  No emit at: silent-skip complete (497), empty complete (542), cancel (238),
  `starting`/`recording`/`finalizing`/`inserting` transitions.

- **Ordering nuance (the one place to be careful).** The 525 and 590 paths set
  `state = .failed` *before* `await restoreMedia`, so the emit goes after the
  restore line, not next to the state assignment — otherwise the cue plays
  into a zeroed system volume. This is safe with the existing cancel-wins
  ordering: `currentSessionID` is already `nil` by then (set at 515 / 584), so
  `cancel()`'s `currentSessionID == sessionID` guard makes it a no-op and
  cannot turn the state into `.cancelled` mid-restore.
- The 359/369/390 paths never ducked, so they are audible immediately; they
  emit at the state assignment.

### 5.4 `Oto/Services/ShortcutDispatch.swift`

- New init parameter `sounds: (any FeedbackSounding)? = nil` (stored), so all
  existing tests compile.
- In `route(_:mode:)` (line 677): `case .begin:` → `sounds?.play(.listening)`
  **before** the generation counter/Task hop, so the tone is not behind an
  async hop.
- `.cancel` → nothing (the press was a modifier being used as a shortcut).
  `.finish` → nothing (see §4).
- fn-hold needs no special case: it routes `.begin` only after confirmation
  (line ~597), so a bare fn tap that belongs to macOS stays silent.

### 5.5 `Oto/Settings/GeneralPane.swift`

- `@AppStorage("app.Oto.feedbackSounds") private var feedbackSounds = true`.
- Lives in the existing **Flow Bar** section (user decision, 2026-11-03), after
  the Position and Colour rows, before the `OtoPanelNote`: sound is part of the
  pill's feedback language, not app behavior. It is the only toggle in that
  section, so it uses the same plain `VStack` row grammar as the Behavior
  switches rather than `OtoSegmented`:
  - title: `"Play sounds while dictating"`
  - note: `"A short tone when dictation starts, when your words land, and when something needs you."`
  - identifier: `"FeedbackSoundsToggle"`
- The literal is pinned to `FeedbackSoundSettings.key` by test (same pattern as
  `CatcherToggle` / `MuteToggle`).

## 6. Tests

New `OtoTests/FeedbackSoundsTests.swift` (`@MainActor`, Swift Testing):

- `defaultIsOn` — fresh defaults → enabled; `false` → disabled.
- `settingsKeyIsPinned` — literal equals `FeedbackSoundSettings.key`.
- `resolverPrefersOverride` — temp dir with fake `.caf` files → override wins.
- `resolverFindsSystemFilesOnThisMac` — skip when the OS layout is unexpected
  (`#expect` guarded by `try #require`, not a hard failure on another machine).
- `missingAssetIsSilent` — a cue whose file does not exist does not crash and
  does not log per play.

Extend `OtoTests/DictationCoordinatorTests.swift`:

- `insertedAnnouncesLandedOnce` — fake session → cues == `[.landed]`.
- `silentSkipAnnouncesNothing` (peak 0) and `emptyTranscriptAnnouncesNothing`.
- `failureAnnouncesFailed` for: mic denied, audio start error, prepare error,
  finalize error, target gone, insertion failed, no text field (one test each,
  reusing the existing `makeSUT` knobs).
- `cancelAnnouncesNothing`.
- `failureIsAnnouncedAfterRestore` — inject a recording fake duck; assert the
  cue index is after `duck.restore` in the same event log.

Extend `OtoTests/ShortcutDispatchDualTests.swift`:

- `pressAnnouncesListening` (hold down → `[.listening]`).
- `releaseAnnouncesNothing`, `handsFreeStopPressAnnouncesNothing`.
- `combinationCancelAnnouncesNothing` (⌘-hold → ⌘1).

## 7. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'`.
3. Packaged, signed `.app`: 10 holds and 10 hands-free sessions; each must play
   the start tone with no audible delay and the done tone exactly when text
   appears. Also: mic denied (System Settings → Privacy → Microphone off) → the
   failure tone with the permission card; catcher (Finder desktop) → failure
   tone with the card; Esc during hold → silence.
4. Compare by ear with `afplay` on the system files (`.context/dictation-sounds/`).
5. Toggle off in Settings → relisten: no tone, no relaunch.
6. Media duck interaction: play music, dictate 5 times, confirm the start tone
   is not audibly cut off (§8 R2).
7. Check Console for one launch-time line per missing asset only.

## 8. Risks and deferrals

- **R1 — private system path.** The `CoreAudio.component` and `DictationIM.app`
  locations are not public API. Mitigation: candidate list + `isReadableFile`
  check + one log line + silent fallback. If Apple moves them, only this table
  changes.
- **R2 — resolved during implementation (see §10.2).** The duck zeroes the
  output volume instantly, and this project's measured press→ready is ~110–140 ms
  steady state (`.context/attachments/B9qUiA/…`: 347 → 147 → 109 → 141 → 140 ms),
  so the 454 ms start tone would have been cut roughly a third of the way in on
  every warm press. The coordinator now holds the duck for the tone's measured
  length (`startTone: Duration`, default `.zero` in tests).
- **R3 — launch cost.** ~0.2–10 ms per file plus ~105 ms cold prepare, once.
  If unacceptable, move to `Task.detached` preload with silent-until-ready.
- **R4 — `end_record` is 427 ms with a quiet A5 lead-in.** It reads as "done",
  but it is longer than a UI blip; if it feels slow in use, a shorter trim
  (first 150 ms) is a one-line change in the resolver's assets, not a redesign.
- **R5 — two sessions in quick succession.** Round-robin of 2 per cue covers
  the only realistic overlap (double-tap convert, error immediately after a
  press).
- Deferred: a per-cue volume preference; a sound preview row in Settings; a
  "mute when the system is in Do Not Disturb" rule (Apple's tones already
  respect the output device volume; there is no public DND read that would not
  be guesswork).

## 9. Decisions taken (2026-11-03)

1. Hands-free stop press: **silent**, done tone on landing (reasoning in §4).
2. **One failure tone for everything**, including the catcher (§4).
3. Toggle lives in **General → Flow Bar**, after Position and Colour (§5.5).

Nothing is open. Awaiting `execute`.

## 10. Implementation record (2026-11-03)

### 10.1 What shipped

| File | Change |
|---|---|
| `Oto/Services/FeedbackSounds.swift` | new: `DictationCue`, `FeedbackSoundAsset` (paths + resolver, override directory wins outright), `FeedbackSoundSettings` (key, default on, `OTO_FEEDBACK_SOUND_DIR`), `FeedbackSounding`, `FeedbackSoundPlayer` (2 prepared voices per cue, round-robin, `startCueLength`) |
| `Oto/Coordinator/DictationCoordinator.swift` | `feedback:` sink + `announce(_:)`; `startTone: Duration`; emit sites §5.3; duck lead §10.2 |
| `Oto/Services/ShortcutDispatch.swift` | `sounds:` param; press cue first in `route(.begin)` |
| `Oto/App/OtoApp.swift` | builds the player before any trigger is live, wires coordinator + dispatch, passes `startCueLength` |
| `Oto/Settings/GeneralPane.swift` | `@AppStorage("app.Oto.feedbackSounds")` + "Play sounds while dictating" in Flow Bar (screenshot: `.context/feedback-sounds/settings-general.png`) |
| `OtoTests/FeedbackSoundsTests.swift` | 23 tests: cue map, ordering, duck lead, settings, resolver, player |
| `OtoTests/ShortcutDispatchDualTests.swift` | 3 press-cue tests |

### 10.2 The one change beyond the plan: the duck waits out the start tone

Plan R2 assumed 150–300 ms of preparation would leave most of the tone intact.
Measured press→ready on this repo is ~110–140 ms steady state, so the duck would
have cut the 454 ms tone to a click on every warm press.

Resolution: the coordinator takes `startTone: Duration` (default `.zero`, so no
existing test gains a delay) and, when it is non-zero and the toggle is on,
sleeps that long after `.recording` before `await mediaDuck?.duck(...)`. The
player supplies the real value (`startCueLength`, read from the decoded file, not
a magic constant). A re-check after the sleep means a session that finished or
was cancelled inside the tone window never ducks at all — the "late duck leaves
the user muted" hazard the post-duck identity guard already covers is closed
before the duck instead of after it.

Trade accepted: up to ~454 ms of media at full volume at the very start of a
session. The person is still waiting for the tone before speaking, so nothing
reaches the transcript, and the tone is not itself transcribed as speech (a
1175 Hz mallet decay; the recogniser discards it).

### 10.3 Verified

- `xcodebuild … build` and `build-for-testing` succeed.
- `FeedbackSoundsTests` 23/23, `ShortcutDispatchDualTests` 27/27 (incl. the 3
  new cue tests), full `OtoTests` bundle green (recorded in the run log for this
  change).
- General pane screenshot confirms the row: Flow Bar → Position, Colour, "Play
  sounds while dictating" (on by default), note text, then the panel note.
- Not verified by ear in this run: the packaged app playing the tones is the
  human step (§7 step 3–6); the `.caf` copies for listening live in
  `.context/dictation-sounds/`.

### 10.4 The stop tone moved to the release (native dictation feel)

User feedback the same day: "the sound effect is not playing when the dictation
is stopped" — the sound arrived only when the transcript was inserted, which is
both late and, on a failure path, never. Direction: prefer the native dictation
feel, then improve on it.

Shipped:

- `DictationCue.landed` → `.stopped`. The cue names the gesture, not the
  transcript; `.stopped` maps to `end_record.caf` exactly as `.landed` did.
- `DictationCoordinator.finalizeSession` now does `await restoreMedia` +
  `announce(.stopped)` immediately after `await audio.stop()`. That is the
  single finalize funnel for key-up, hands-free second press, Flow Bar stop,
  and release-during-`starting` (`finishRequested`), so every honest stop
  sounds once. The later terminal `restoreMedia` calls are idempotent no-ops.
- `announce(.landed)` was removed from the `.inserted` branch. A successful
  insert adds no second tone: the stop already said it, as in native dictation.
- Failures keep `announce(.failed)` at every terminal, so a stopped-then-failed
  session plays stop → error. That is the deliberate "better than native" part:
  native has no error vocabulary for a session that already started, and this
  one never lets the stop tone claim words that did not land.
- Cancel stays silent (an abort, not a stop), and the silent-skip / empty-final
  paths now sound the stop tone too — it reports the gesture, not the words.

Mechanics that forced the shape:

- The duck zeroes the output for the whole recording, and `end_record.caf` runs
  0.43 s. Restoring only at the terminal point would swallow the tone, so the
  duck is given back at stop. Media therefore resumes while the words are being
  finalised (a few hundred ms) instead of after insertion — a small, welcome
  side effect, and safe because `audio.stop()` runs first, so nothing leaks
  into the capture.
- The tone is emitted after the restore await, never next to the state
  assignment, keeping the rule from §5.4.

Tests updated to pin the new contract: success `[.stopped]`, silent session and
empty final `[.stopped]`, post-recording failures `[.stopped, .failed]`,
pre-audio failures still `[.failed]`, cancel empty, and the timeline
`[.ducked, .restored, .cue(.stopped), …]`. `LoggingDuck.restore` is now
idempotent like the real duck so the extra terminal restore does not show up.

