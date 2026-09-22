# Solid re-verification + what we do next — PLAN ONLY

Status: PLANNING ONLY (2026-09-22). Nothing implemented by this file.
It re-verifies `plan/forward-audit-spike-merge.md` + `plan/phase-6c-modal-and-media-duck.md`
against the live toolchain on this Mac and locks the ordered next steps.

## 1. Goal and scope

Answer three things with evidence, not memory: (A) is the forward plan still
solid against the latest SDK + canonical docs; (B) did anything in SDK 27
change the mute/modal decisions; (C) what we do next, in order. No code,
no spike, no mute — authorization only.

## 2. Spec sources (canonical order)

1. `Docs/START_HERE_PRODUCT.md` — canonical on conflict. Apple Speech only,
   one coordinator, Flow Bar the only custom surface, Phase 7 gated behind
   the core Speech release gate.
2. `Docs/OTO_REBUILD_PLAN/10_NEXT_STEP.md` — the packaged-app integration
   gate is the next milestone; profiling before intelligence; explicit
   do-not-do list (no cloud, no model catalog, no custom Settings chrome).
3. `plan/phase-6c-modal-and-media-duck.md` — modal NOW (6C1) / mute LATER
   (Phase 7, behind sandbox spike). Still valid, see §4.
4. `plan/forward-audit-spike-merge.md` — audit verdict + 9-item failure
   analysis + spike→mute→merge order. Merge already executed (§5).
5. Local SDK truth on this Mac, re-verified this session (§3). Never memory.

## 3. Facts verified against the local SDK (this session, exact locations)

Toolchain: Xcode 27.0 (27A266a), Swift 6.4, `MacOSX27.0.sdk`, deploy 27.0.
Tree: `main` == `origin/main` == `abu-dhabi` at `ab1c011`; `git diff
origin/main --stat` empty; build `SUCCEEDED` fresh this session.

| # | Claim | Evidence (this Mac, today) | Verdict |
|---|---|---|---|
| F1 | Tap path uses the current API | `AVAudioNode.h:117` deprecates `installTapOnBus:bufferSize:format:block:`; the Swift projection in `AVFAudio.swiftmodule:247` is the throwing `installAudioTap(onBus:bufferSize:format:tapProvider:)`; `Oto/Services/AppleAudioCapture.swift:190` calls exactly that with `format: nil` | SOLID, no change |
| F2 | `floatChannelData` current | `AVAudioBuffer.h:152`, no deprecation attribute | SOLID |
| F3 | `NSView.displayLink(target:selector:)` is the macOS spelling | `NSView.h:662` (`displayLinkWithTarget:` → `displayLink(target:selector:)`); iOS-only `+displayLinkWithTarget:` correctly avoided | SOLID |
| F4 | Speech path is the Apple-only path | `SpeechTranscriber`, `SpeechAnalyzer` (`@available(anyAppleOS 26,*)`, watchOS unavailable), `AssetInventory.status(forModules:)` all present in `Speech.swiftmodule`; `AppleSpeechService.swift:171` builds one short-lived analyzer per session, `prepare()` never downloads, `SFSpeechRecognizer` correctly absent | SOLID |
| F5 | Mute foundation present, header corrected | `'vmvc'` (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`) + Get/Set/HasPropertyData in `AudioToolbox/.../AudioHardwareService.h:49-202`; only the ancient `VirtualMaster*` aliases deprecated (`:71,:74`); `kAudioDevicePropertyMute` (`'mute'`) in `CoreAudio/AudioHardware.h:1306` | SOLID — correction to 6C stands: AudioToolbox, not CoreAudio |
| F6 | Sandbox blocks the only open question | `Oto/Oto.entitlements` = `app-sandbox` + `audio-input` ONLY; zero `MediaDuck`/`vmvc` references in `Oto/` (grep clean) — no mute code exists before the spike, as gated | SOLID, spike still required |
| F7 | Coordinator discipline intact | `DictationCoordinator.swift`: session-ID re-checks at `:124-125, :231-233, :249, :258, :264, :284-286` incl. post-settle; 120 ms settle at `:311`; cancel-wins at `:145-159`; silent-skip constants (0.01 / 500 ms) at `:50-52` | SOLID |
| F8 | Modal shipped per the load-bearing call | `Oto/UI/Scratchpad/NoTargetModal.swift` exists, owned at app scope (`OtoApp.swift`), observed via shared poll (`FlowBarController`), toggle `app.Oto.noTargetModal` default ON (`DictationPane.swift`) | SOLID |
| F9 | Suite shape | 246 `@Test` funcs counted in `OtoTests/` (Swift Testing; last full `xcodebuild test` greens recorded in the forward plan: 247 passed twice on the merged commit) | SOLID, no silent test loss |

### SDK-27 deltas found during THIS re-verification (new since the 6C plan)

- D1: `SpeechAnalyzer.Options` gained `ignoresResourceLimits` + `ModelRetention`
  cases `lingering` / `processLifetime` (`Speech.swiftmodule:448-476`,
  both `@available(anyAppleOS 27,*)`). DECISION: **do not adopt.**
  Our one-analyzer-per-session design matches the default `whileInUse`
  retention; `ignoresResourceLimits` opts out of resource limits we have no
  reason to fight, and `processLifetime` retention contradicts the
  short-lived-analyzer teardown (`teardown()` releases every terminal path).
  Revisit only with measured evidence of model-reload latency, per the
  10_NEXT_STEP profiling rule (measure, don't guess).
- D2: Obj-C `installTapOnBus:bufferSize:format:error:block:` is now
  `API_AVAILABLE(macos(27.0))` (`AVAudioNode.h:160`) while the no-error
  variant is formally deprecated (`:117`). Our Swift call already resolves
  to the throwing projection — no code change, but the deprecation confirms
  we are on the surviving API.
- D3: `SystemLanguageModel` confirmed present (`FoundationModels.swiftmodule`)
  — relevant only as a Phase-7-later consumer of finalized text. No action now.

## 4. Assumptions questioned (and settled)

- A1 "Maybe adopt the new analyzer options while we're here." → No (§3-D1).
  Unmeasured API adoption is the opposite of solid.
- A2 "Maybe build the mute without the spike since vmvc headers exist." → No.
  Headers prove the API exists, not that a sandboxed process may write it.
  That is exactly the unproven step the spike exists to test. Same verdict
  class as the HID tap question: one experiment, then one decision.
- A3 "Maybe re-verify device feel before the spike." → Already done by the
  user (waves, silent-skip, Escape, mic-deny zero-flash, card radii all
  device-confirmed; nothing to re-pin). The spike needs no device work.
- A4 "Maybe the merge needs redoing." → No. `main` fast-forwarded cleanly
  (`f0f59f4` → `ab1c011`), both local branches and `origin/main` agree,
  working tree clean except gitignored `.context/`. Merge is history.

## 5. Exact file changes by THIS plan

None. Planning only. The single artifact is this file. Committed + pushed
as a record so later agents inherit the reasoning without re-researching.

## 6. What we will do next, in order (authorized, not started)

1. **Sandbox spike FIRST (~30 min, throwaway, decides step 2).** Separate
   scratch project outside the repo (keeps `main` pristine; deleted after).
   Sandboxed probe: read `'vmvc'` on the default output → attempt set+restore
   → log success or the sandbox denial → record one line here. Owner and
   exact probe code get one line amended into this plan at build start.
2. **Media mute ONLY behind a green spike** (6C design unchanged):
   NEW `Oto/Services/MediaDuck.swift` (`@MainActor`, nonisolated HAL calls;
   save → 0.0 on `.recording`, restore on every terminal state, idempotent
   per session ID) + crash-recovery flag in UserDefaults (launch-restore) +
   Dictation-pane toggle default ON + `MediaDuckTests` (save/duck/restore,
   double-restore, flag round-trip with fake HAL). Denial → feature shelved,
   never re-architected; dictation without it is the confirmed status quo.
3. **Phase-7 intelligence stays gated** behind the core release gate
   (`START_HERE_PRODUCT.md` + `10_NEXT_STEP.md` release checklist): offline
   dictation, cross-app matrix, interruption matrix, profiling. No
   `SystemLanguageModel` work before then.

## 7. Verification steps (for steps 6.1–6.2, when executed)

- Spike: recorded result + denial-or-success log line; probe deleted; this
  plan amended with the outcome.
- Mute (if built): clean build; new tests green; full suite green TWICE
  (standing rule — never merge on a single green after the flaky-red
  history); device matrix: built-in + BT duck/restore, kill −9
  mid-dictation → relaunch restores volume, toggle OFF → zero HAL calls.
- Standing backstops every step: two-green-runs rule, zero-unwrap /
  no-banned-primitive greps, session-ID discipline review.

## 8. Risks / deferred (unchanged)

- BT absolute-volume headsets may ignore `'vmvc'` — per-device matrix
  entries; degrade is an honest log line, never a failure state.
- Sandbox denial kills the feature, not the release (mute was always
  Phase-7-optional).
- Deferred: editable scratchpad (6C2), per-app mute exceptions,
  duck-to-15%, `ignoresResourceLimits` revisit (needs measured evidence).

## 9. Open questions

None open. Prior answers stand: scratch probe outside the repo, mute
default ON if the spike greens, merge already executed. The only decision
left is the user's `execute` on step 6.1.
