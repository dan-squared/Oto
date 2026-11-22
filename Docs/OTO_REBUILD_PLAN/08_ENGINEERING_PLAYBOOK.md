# Oto engineering playbook

> **Rebuild edition:** This copy governs the new implementation inside `OTO_REBUILD_PLAN`. The current source is reference material. Read [`README.md`](README.md), [`16_REBUILD_DECISIONS.md`](16_REBUILD_DECISIONS.md), and [`15_ENGINEERING_WISDOM_AND_MISTAKES.md`](15_ENGINEERING_WISDOM_AND_MISTAKES.md) before making structural changes.

> **Read before changing Oto.** This is the working agreement for every contributor and subagent. It exists because dictation software fails at boundaries: an audio callback is late, a key-up disappears, an app changes while a transcript finalizes, a permission changes, or a harmless-looking UI change creates a second session.
>
> The release product is Apple Speech-first, fully offline after Apple-managed assets are prepared, and menu-bar-first. It must never use cloud transcription, Private Cloud Compute, or a background model download during dictation.

Related documents: [rebuild README](README.md), [product and execution plan](09_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md), [Apple Speech plan](07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md), and [reliability test matrix](11_RELIABILITY_TEST_MATRIX.md).

The current implementation is reference material while the rebuild track is designed. Do not start a broad rewrite from this playbook alone: read the rebuild folder for the YAP-inspired boundaries, phase gates, SwiftUI references, and source layout.

**Platform decision:** v1 targets macOS 26 or later on Apple silicon. Do not leave the historical macOS 14 package setting or an unqualified Intel support claim in implementation or QA documentation.

## 1. Engineering invariants

These are requirements, not suggestions. If a proposed implementation breaks one, stop and redesign it.

1. **One physical interaction owns one session.** A session has a unique ID and only the coordinator may transition it. Key repeat, duplicate callbacks, and two terminal events cannot create two recordings or two insertions.
2. **The target is captured once.** Capture application identity, insertion target, and target screen when a session starts. Never insert into the app that merely happens to be frontmost when processing ends.
3. **Finish and cancel are mutually exclusive.** Both are idempotent terminal transitions. A late result from a cancelled or superseded session is discarded.
4. **The real-time audio callback stays real-time.** It does no UI work, logging, unbounded allocation, blocking I/O, actor hop, or unbounded task creation.
5. **Raw final text is the source of truth.** Dictionary replacement is deterministic. Intelligence produces a separate, reversible draft; it never overwrites the source.
6. **Core dictation needs no network after preparation.** If an asset or capability is missing, stop with a direct recovery action. Do not improvise a cloud fallback.
7. **Text cannot be silently lost.** Failed insertion preserves a recoverable transcript. Cancelled sessions preserve nothing unless the person explicitly saved a draft.
8. **Settings are native macOS.** The Flow Bar is the only intentional custom visual surface. Do not replace native controls with replicas.
9. **User data is local, minimal, and deletable.** No audio retention, no hidden external-app context, no raw transcripts in diagnostics, and no opaque persistence blobs.
10. **A passing unit test is not a claim of device reliability.** State exactly what is automated and what still requires a signed build on real hardware.

## 2. The failure modes that most often sink dictation apps

### 2.1 Audio callback overload

**Easy mistake:** create `Task { @MainActor in ... }` for every audio buffer, allocate arrays, emit logs, or update SwiftUI directly from the input tap.

**Why it fails:** a microphone produces a continuous real-time stream. Work queues build faster than they drain, increasing memory, latency, cancellation time, and the chance that the Flow Bar appears frozen.

**Required design:**

- The tap only validates/copies or retains the minimum safe audio data and signals a single bounded buffer/channel.
- A dedicated consumer converts/feeds speech analysis off the main actor.
- Meter updates are coalesced to a modest visual rate; dropped meter frames are acceptable, dropped final audio is not.
- The coordinator owns start/stop. The tap never decides to insert, cancel, or mutate UI state.
- Measure queue depth and discarded stale buffers in debug builds only, without logging user audio/text.

**Review blocker:** any per-buffer main-actor task, synchronous disk/network call, or unbounded producer queue.

### 2.2 Terminal-state races

**Easy mistake:** let Escape, key-up, the Flow Bar button, silence detection, engine error, and app shutdown each call their own `stop()` method.

**Why it fails:** all of them can occur together. The result is duplicate finalization, use-after-teardown, a panel outliving its view, or insertion after cancellation.

**Required design:**

- Model states explicitly: `idle → preparing → recording → finalizing → inserting → completed`, plus `cancelled` and `failed`.
- Attach every callback and asynchronous task to a session ID. Before observable work, verify that ID is still current and the state permits the transition.
- Expose one idempotent `finish(reason:)` and one idempotent `cancel(reason:)` through the coordinator. Services return events; they do not transition sessions themselves.
- Cancel first invalidates the session, then tears down audio/engine/UI. A late final result cannot revive it.
- Await cleanup in a predictable order and keep presentation teardown separate from source-of-truth session state.

**Review blocker:** boolean combinations such as `isRecording`, `isStopping`, `isCancelled` spread across views and services without a single transition owner.

### 2.3 Global shortcut false confidence

**Easy mistake:** save a keyboard shortcut from a local SwiftUI recorder and call it finished.

**Why it fails:** local event handling does not prove the event tap works outside Oto. F-keys differ by hardware, macOS may intercept Dictation, event taps can time out, and Accessibility permission can change while the app runs.

**Required design:**

- Record down and up events, modifiers, hardware key code, and display representation.
- Register only one active interaction route: hold-to-talk or hands-free. Release is part of hold-to-talk, never its own mode.
- Deduplicate key repeat. A key-down starts at most one session; its matching key-up finishes that same session.
- Confirm the saved shortcut through the actual global monitor in an in-app calibration test, then test it in external apps during device QA.
- Recheck accessibility/event-tap health after wake, permission change, and monitor timeout. Surface a precise repair action.
- Make F5/Dictation aliases optional physical-key mappings, not assumptions. Supply a nonfunction fallback.

**Review blocker:** a “Shortcut ready” status with no global-path calibration, or a fallback that starts/stops a different session after app focus changes.

### 2.4 Wrong-app insertion and clipboard damage

**Easy mistake:** use the current frontmost app at finalization, then set the pasteboard, wait a fixed delay, paste, and blindly restore it.

**Why it fails:** the person may switch apps, the original app may close, a target may paste slowly, or the person may copy something during the delay. That can leak text or overwrite their clipboard.

**Required design:**

- Capture the insertion target and app identity at session start. Verify target liveness just before insertion.
- Never fall back to the current frontmost app. If the original target is gone or denied, retain a recovery object with Copy and Scratchpad actions.
- Treat the pasteboard as borrowed. Record its change count and the exact temporary content Oto owns. Restore only when it has not changed since Oto wrote it and only after paste completion is confirmed as far as the platform permits.
- Secure fields, password managers, remote desktops, and apps rejecting accessibility insertion are expected failure modes. Explain and offer recovery; never claim success based merely on a keystroke being sent.
- Unit-test target app closed, app switch, pasteboard altered during insertion, delayed target, and insertion denied.

**Review blocker:** `frontmostApplication` called at insertion time, fixed-time clipboard restoration without ownership checks, or raw transcript discarded after a failed paste.

### 2.5 Apple Speech asset and language ambiguity

**Easy mistake:** collapse every failure into “Apple Speech setup needed,” or fetch assets when the user presses the dictate shortcut.

**Why it fails:** people cannot recover from an ambiguous error, and background preparation turns an offline app into one that unexpectedly stalls or consumes network resources.

**Required design:**

- Keep asset inspection and preparation in a dedicated Apple speech asset service.
- Distinguish unsupported OS, unavailable language, asset absent, asset preparing, microphone denial, engine failure, and accessibility denial.
- Make “Prepare Offline” explicit in Settings and show its progress/status there. Dictation either starts promptly or explains what is missing.
- Select language/locale deliberately and construct audio analysis from the engine’s best available audio format.
- Never silently use `SFSpeechRecognizer` or a cloud path as a compatibility fallback.

**Review blocker:** a generic setup message, a network action triggered by the global shortcut, or an undeclared cloud speech fallback.

### 2.6 Swift concurrency and actor reentrancy

**Easy mistake:** assume an actor method remains exclusive across `await`, hold a lock while awaiting, or put the whole service graph on `@MainActor`.

**Why it fails:** `await` permits reentrancy. A stop may overtake start, an old task may publish after a new session begins, and the UI actor can starve audio/analysis.

**Required design:**

- Use a `DictationCoordinator` actor (or equivalently isolated owner) for state and session ID.
- Snapshot values before `await`; validate state and session ID after it.
- Keep AppKit/SwiftUI presentation on `@MainActor`; keep capture, storage, and analysis off it.
- Prefer structured tasks owned by a session. Cancel and await them during terminal transitions.
- Inject a clock and use cancellation-aware sleeps for grace periods. Never make tests wait on wall time.

**Review blocker:** detached work that can outlive a session without an owner, or code that assumes state did not change after `await`.

### 2.7 Persistence and schema drift

**Easy mistake:** keep growing dictionaries, snippets, history, and prompt data inside arbitrary `UserDefaults` encodings, then change structures in place.

**Why it fails:** corruption becomes invisible, upgrades cannot be migrated safely, deletion behavior is unclear, and support cannot distinguish bad data from code bugs.

**Required design:**

- `AppStorage`/`UserDefaults` is only for small scalar preferences and selected pane/mode.
- Store user-authored collections as versioned files under Application Support through one store per domain.
- Write atomically, validate before replacing the current file, retain a short local migration backup, and make schema migrations explicit and tested.
- Import into a staging value, validate duplicates/scopes/length, then commit as one transaction. Do not partially import.
- Delete only the requested domain. “Clear History” must never delete dictionary/snippets/settings; write tests proving that.

**Review blocker:** unversioned persistent collection data, destructive migration without backup, or a broad “reset” operation not scoped by domain.

### 2.8 Offline intelligence overreach

**Easy mistake:** treat model output as an action, infer private context from the active app, or silently use Private Cloud Compute when the on-device model cannot answer.

**Why it fails:** it breaks the offline promise, can hallucinate consequential details, and makes a dictation app feel untrustworthy.

**Required design:**

- Use only on-device `SystemLanguageModel`; do not instantiate server/PCC capability.
- Intelligence receives a deliberately small, explicit input: raw final transcript, chosen mode, and selected local context if enabled.
- Require structured, bounded draft output. Validate it before display and preserve the raw source alongside it.
- Never perform side effects: no mail, reminder, calendar, file edit, shell command, or network call.
- If unavailable, return raw dictation normally and make the unavailable reason readable.

**Review blocker:** an automatic rewrite inserted without review, active-app document extraction, or any cloud/PCC dependency.

### 2.9 UI regressions disguised as polish

**Easy mistake:** replace native Settings behavior with cards, custom toggles, fake traffic lights, fixed window frames, decorative large icons, or an animated Flow Bar renderer that is not cancellation safe.

**Why it fails:** interaction becomes inconsistent and lifecycle code becomes more fragile. Oto already saw settings opening trouble and Flow Bar stop crashes.

**Required design:**

- Use `Settings`, `SettingsLink`, `NavigationSplitView`, `List`, `Form`, native buttons/toggles/pickers, standard titlebar, and file import/export APIs.
- Bundle a pinned official Inter release for Oto-authored text only. Use a 14-point body baseline; do not globally install or fetch it at runtime.
- Keep the custom Flow Bar isolated behind a small presentation boundary. Every state has a stable label and a Reduced Motion path.
- Do not use `TimelineView` or autonomous animation that can outlive panel/view dismissal without a repeat-dismiss stress test.
- Test light/dark, Reduce Motion, high contrast, VoiceOver, keyboard-only navigation, window resizing, and more than one display.

**Review blocker:** custom standard controls, fixed root settings dimensions, unpinned font source, or an animation lifecycle not covered by cancellation tests.

## 3. Do / avoid table

| Do | Avoid |
| --- | --- |
| Capture an immutable `SessionContext` at key-down. | Re-query the frontmost app after transcription finishes. |
| Let a single coordinator serialize transitions. | Let views, buttons, engine callbacks, and hotkeys each stop a session. |
| Bound non-critical work and coalesce UI meters. | Spawn one task per microphone buffer or meter sample. |
| Verify a key through the real global event path. | Treat a local key recorder as proof of a usable shortcut. |
| Keep a raw transcript until successful insertion or explicit discard. | Throw text away after sending a paste command. |
| Report a specific missing requirement with one recovery action. | Say “setup needed” for every failure. |
| Use versioned, atomic local stores. | Hide growing product data in a mutable preference blob. |
| Keep intelligence optional and reversible. | Let generated output cause external side effects. |
| Bundle a pinned Inter release with its license notice. | Depend on a developer’s installed font or an unversioned download. |
| State the boundary of automated evidence. | Claim real-device reliability from simulator/unit tests. |

## 4. Required test seams

Production code should depend on narrow protocols or injected values at boundaries. Fakes must be easy to construct in tests.

- **Clock:** deterministic grace-period, timeout, and retry tests.
- **Audio capture:** controlled buffers, interruption, device disconnect, and start/stop failure.
- **Speech engine:** partial/final/error timing, late final after cancellation, asset availability.
- **Global hotkey source:** down/up/repeat, lost key-up, timeout, accessibility revocation.
- **Target capture/insertion:** app switch, process exit, secure-field denial, delayed paste acknowledgment.
- **Pasteboard:** change-count ownership and a user copy during Oto insertion.
- **Persistence:** migration, validation failure, partial import, scoped deletion, disk/write failure.
- **Intelligence service:** unavailable model, malformed structured output, cancellation, raw-text recovery.

If a service cannot be faked without booting macOS UI or touching a real microphone, it is too entangled. Extract a boundary before adding behavior.

## 5. Minimum test matrix for every session change

Automate these where possible; list device-only evidence separately.

1. Hold key down, receive repeats, release: exactly one session and one finalization.
2. Start then Escape: no insertion, no history entry, late final discarded.
3. Start, click Flow Bar Stop: exactly one finalization; repeat rapidly without crash.
4. Start, switch app, release: captured target is used or recovery appears—never the new foreground app.
5. Start, original target quits: no accidental paste; Copy/Scratchpad recovery remains.
6. Insertion changes pasteboard, user copies something, delayed target returns: user clipboard survives.
7. Mic disconnects or default device changes: capture ends safely and state explains recovery.
8. Wake from sleep and permission revoked: shortcut/check state revalidates instead of silently failing.
9. Asset absent: shortcut performs no download and gives the exact preparation route.
10. Repeated start/cancel cycles: no memory/session leak, stuck Flow Bar, duplicate observer, or late UI update.
11. Dictionary/snippet app scope: captured bundle ID produces the expected result.
12. Reduce Motion: Flow Bar remains readable with no essential animated signal.

## 6. Future-agent workflow

### Before touching code

1. Read this playbook, the product plan, and the relevant feature file plus its tests.
2. State the boundary you own, the invariant at risk, and the automated/manual proof you will add.
3. Search existing code before introducing a second coordinator, persistence format, hotkey path, or UI component.
4. Keep the change inside one feature boundary unless the dependency inversion itself is the stated task.

### While implementing

1. Prefer the smallest reversible change that proves the architecture.
2. Make terminal work cancellation-aware and session-ID checked.
3. Preserve user data on any uncertainty. Recovery is better than a clever fallback.
4. Do not fold refactors, visual redesign, behavior changes, and data migration into one untestable change.
5. Add a diagnostic only if it is local, privacy-safe, and has a defined retention/deletion policy.

### Before handoff

Report all five items:

1. User-visible outcome.
2. Files changed and why.
3. Invariants preserved and tests run.
4. Manual/device validation still required.
5. Risks, assumptions, and follow-up work—not optimism.

## 7. Stop conditions: ask before proceeding

Stop and request a product decision when a change would:

- require network use after setup or introduce a cloud fallback;
- collect active-app content, clipboard data, contacts, or audio beyond the declared flow;
- change what is inserted automatically rather than offer a draft;
- alter/deletes persistent user data or needs an irreversible migration;
- lower the supported macOS baseline or add a large runtime/dependency;
- change global shortcut defaults or introduce a shortcut conflict policy;
- claim Apple Intelligence capability without on-device availability and offline testing.

## 8. Definition of done

A feature is done only when it has a precise product behavior, a named owner/boundary, deterministic tests for its critical failures, accessible native UI where applicable, privacy semantics, recovery behavior, and honest real-device QA notes. A screenshot, a clean compile, or a happy-path unit test is not enough.
