# Forward plan: audit verdict, failure analysis, media-mute spike, merge — plan

## 1. Goal and scope

Three things in one document: (A) a verified cross-check of everything
on `abu-dhabi` vs `origin/main` against the current toolchain;
(B) a failure analysis — every known failure class, why it happened,
what fixed it, and what is still open; (C) the forward work in order:
sandbox spike → media mute → merge. Nothing is implemented by this
plan; it authorizes work, starting with the spike.

## 2. Spec sources

- `Docs/START_HERE_PRODUCT.md` (canonical): Apple Speech only, one
  coordinator, Flow Bar the only custom surface, native Settings,
  Phase 7 gated behind the core Speech release.
- `plan/phase-6c-modal-and-media-duck.md` §§3–4 (mute design + spike
  gate), `plan/pre-merge-rigor-audit.md` (prior audit, 224-test era),
  `plan/installtap-crash.md`, `plan/bt-sco-flap.md`,
  `plan/buffer-size.md` (failure records).
- Local SDK truth on this Mac (never memory): Xcode 27.0 (27A266a),
  Swift 6.4, `MacOSX27.0.sdk`, deployment target 27.0 — re-verified
  this session (table §4).

## 3. Audit verdict (verified this session)

| Check | Evidence | Verdict |
|---|---|---|
| Toolchain | `xcodebuild -version` → 27.0 27A266a; `swift` → 6.4 (swiftlang-6.4.0.34.1); SDK → MacOSX27.0.sdk | Current |
| Build | `xcodebuild -scheme Oto -destination 'platform=macOS' build` | SUCCEEDED, zero errors |
| Suite | Full `xcodebuild test`, fresh this session | **247 passed, 0 failed** (audit-era 224 + 23 new pins since) |
| Diff | `git diff origin/main --stat` | 50 files, +5740/−27, all committed + pushed to `origin/abu-dhabi` (`f903a5f`); tree clean except untracked `.context/` scratch (stays out) |
| Force unwraps | Repo-wide grep for `as!`/`try!`/`)!` outside comments | Zero in product code; test scaffolding uses `guard`-let (the two `!`s my peak tests briefly had were removed before commit) |
| Banned primitives | `Timer(`, `print(`, `NSLog(`, `addGlobalMonitor`/`addLocalMonitor` (outside the pre-existing recorder field) | Zero new |
| Coordinator discipline | Diff review | Session-ID re-checks after every suspension incl. the new silent-skip settle; cancel-wins preserved; no view writes into session fate |
| 6C1 catcher modal | `NoTargetModal.swift` + `NoTargetModalTests` + controller routing in `FlowBarController.syncRecovery` | Implemented, tested, device-confirmed by user |
| S1+S2 solidifying | `fbe97df` + current grep (no `noticeDeadline!`, no ghost unwraps) | Done |

## 4. SDK re-verification (current SDK, this session)

| API | Finding |
|---|---|
| Tap | Old `installTapOnBus:bufferSize:format:block:` IS deprecated (`AVAudioNode.h:117`); code uses modern `installAudioTap(onBus:bufferSize:format:)` — correct |
| `vDSP_create/destroy_fftsetup` | No deprecation attribute (`vDSP.h:367,372`, vecLib path) — engine stays |
| Haptics | `.alignment`/`.levelChange`, `.default`/`.now` match `NSHapticFeedback.h:15-31` exactly |
| Speech path | `SpeechTranscriber` + `AssetInventory` + `SpeechAnalyzer`; `SFSpeechRecognizer` correctly avoided |
| `NSView.displayLink(target:selector:)` | macOS spelling in use; `+displayLinkWithTarget:` is iOS-only — correct |
| `floatChannelData` | Current, no deprecation (`AVAudioBuffer.h:152`) |
| `NSLock` in async | Bare `lock()`/`unlock()` are **unavailable in async contexts** in this SDK — the silent-skip read uses `withLock` (build-enforced, committed) |
| Mute foundation | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc') + Get/SetPropertyData present and current (`AudioToolbox/.../AudioHardwareService.h:49-202`; only the ancient `VirtualMaster*` aliases are deprecated) — **correction to the 6C plan: the header lives in AudioToolbox.framework, not CoreAudio** |
| Entitlements | `app-sandbox` + `audio-input` ONLY — volume-set from sandbox is unproven (hence the spike, §6) |

## 5. Failure analysis — why each failure happened, status

1. **installTap NSException crash (PID 19574).** Cause: TOCTOU —
   format read from the node went stale during a BT flap, and the
   mismatch raises an *uncatchable* NSException (even the `error:`
   variant). No do/catch could ever hold it. Fix (in tree):
   `format: nil` (live format, no stale read) + degenerate-format
   guard + fresh engine per start. Status: closed, device matrix clean
   since.
2. **BT SCO flap → "completed (empty)" (session 523C250B).** Cause:
   `engine.start()` raced SCO bring-up; 7 s of speech captured zero
   audio with no error anywhere. Fix (in tree): rebuild debounce
   (1.5 s quiet window), delivered/dropped buffer counts, and
   fail-loud `.noAudioCaptured` instead of silent empty completion.
   Status: closed.
3. **Buffer-size compliance.** Tap 4096 sits in the documented
   [100, 400] ms request range (256 ms @16 kHz, 85 ms @48 kHz);
   downstream (converter, relay, analyzer) is frameLength-dynamic.
   Status: closed, pinned.
4. **Pill flash before permission card.** Cause: pill rendered during
   `.starting` while denial surfaced a poll later. Fix: synchronous
   mic gate (controller) + coordinator fast-fail before `audio.start`.
   Status: closed, device-confirmed zero-flash.
5. **Loader on silent sessions.** Cause: voicelessness knowable only
   after `speech.finish()`. Fix: capture-time session peak + gate
   (peak < 0.01 AND > 500 ms audio → complete directly). Timing
   hole analyzed and closed: the read is whole-session at release, so
   think-then-talk always takes the full path; 120 ms settle covers
   trailing-edge audio. Status: closed, device-confirmed.
6. **Dead/static bars.** Causes: 150 ms poll dropping 3 of 4 analyzer
   updates + independent per-band smoothing toward ~12 Hz tap targets.
   Fix: vsync display link, 16 ms drain, neighbor coupling, retuned
   attack/sway. Status: closed, device-confirmed feel.
7. **Permission truncation ("Requir…").** Cause: `NSButton` bezel
   padding varying by machine pushed width over the ceiling. Fix:
   string-measured widths + 460 ceiling. Status: closed.
8. **Flaky red suite run (EscapeCancel + coordinator tests, 0.000 s).**
   Analysis: failures at 0.000 s in setup, on code paths untouched by
   the change, passing immediately before and on every run after
   (now 3+ consecutive greens). Verdict: test-runner/environment
   flake, not product code. Standing rule (unchanged): never merge on
   a single red — rerun; two consecutive greens required. This plan's
   §3 counts come from fresh consecutive-green runs.
9. **OPEN — sandboxed volume-set.** `vmvc` write from inside
   app-sandbox is unproven (same open question class as the HID tap).
   Not a failure yet — an experiment that has never been run. Gated
   by the §6 spike; no mute code before its result.

## 6. Forward work, in order

**Step 1 — Sandbox spike (first, ~30 min, decides Step 2).**
Probe app (not Oto): sandboxed target, minimal CoreAudio read of
`'vmvc'` on the default output, attempt a set+restore, log success or
the sandbox denial. Exact files: NEW throwaway probe target (never
shipped; deleted after) + one-line result appended to this plan.
Success → Step 2 sandboxed. Denial → mute decision rides the same
sandbox verdict as the HID tap (one decision, not two); the feature
is shelved, not re-architected.

**Step 2 — Media mute (only behind a green spike).**
Per the 6C design (still valid, SDK re-confirmed §4): NEW
`Oto/Services/MediaDuck.swift` (`@MainActor`, nonisolated HAL calls;
save → set 0.0 on `.recording`, restore on every terminal state,
idempotent per session ID) + crash-recovery flag in UserDefaults
(launch-restore) + Dictation-pane toggle (default ON) + `MediaDuckTests`
(save/duck/restore, double-restore, flag round-trip with fake HAL).
Owner TBD at build start (controller observation vs coordinator);
one-line amendment here before coding.

**Step 3 — Merge `abu-dhabi` → `main`.**
Preconditions: spike recorded (either outcome), suite green twice,
device matrix for any Step-2 behavior, `.context/` excluded. Merge
itself is a plain fast-forward/PR per Conductor flow — no code work.

## 7. Verification steps

- Spike: recorded result + denial-or-success log line; probe deleted.
- Mute (if built): build clean, new tests green, full suite green
  twice; device: built-in + BT duck/restore, kill −9 mid-dictation →
  relaunch restores volume, toggle OFF → zero HAL calls.
- Merge: final `git diff origin/main --stat` review, suite count
  recorded, push, PR with the audit table (§3) pasted in.

## 8. Risks / deferred

- BT absolute-volume headsets may ignore `'vmvc'` — per-device matrix
  entries; degrade is an honest log line, never a failure state.
- A sandbox denial kills the feature, not the release — the mute was
  always Phase-7-optional; dictation quality without it is the status
  quo the user already confirmed as working.
- Editable scratchpad (6C2), per-app mute exceptions, duck-to-15% —
  all deferred, unchanged.
- Tooling dropped/truncated edits twice in this repo's history: the
  two-green-runs + grep-gates rule (§5.8) is the backstop for every
  step above.

## 9. Open questions

1. Spike first as a throwaway probe target in this workspace — good,
   or do you want it as a separate scratch project?
2. If the spike greens, is mute-default-ON (6C recommendation: speaker
   bleed ruins transcripts) still your call?
3. Merge timing: right after the spike result, or hold for the mute
   build to land too?
