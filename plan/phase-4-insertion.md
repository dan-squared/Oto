# Phase 4 — Target-aware insertion (EXECUTED 2026-09-20, awaiting device matrix)

Status: built per plan. Bridge build green, 74/74 unit green (60 existing +
14 new), UI suite untouched. Grep gates pass (`NSAppleScript` → 0 hits,
`downloadAndInstall` → 1 site). Answers applied: synthetic-only (no
Automation), Yap timings adopted, `targetScreen` populated best-effort.
Deviations: `TargetApplication` gained an explicit init (the synthesized
memberwise init inexplicably rejected the new `displayID` field — logged
below); `copyElement/copyAXValue` use `unsafeDowncast` after CFTypeID checks
(CFTypeRef bridges neither `as` nor `as?` here).

Device-found P0 (app-switch paste) + fix 2026-09-20: synthetic Cmd-V lands
wherever is frontmost at post time, and the single early reactivate lost to
mid-finalize switches. Fix: `confirmTarget()` re-verifies focus immediately
pre-post (bounded reactivate+settle retries); persistent mismatch restores the
clipboard synchronously and returns `recoverableFailure` — transcript kept,
never pasted into the wrong app. Regression tests:
`switchedTargetNeverPastesAndRestoresClipboard`,
`slowActivationStillPastesAfterRecovery`. 76/76 unit green after.

## 1. Goal (START_HERE Phase 4 + 10 §4 + 11 matrix)

Replace the last two fakes behind the UNCHANGED coordinator seams with real
capture + real paste. Coordinator, speech, shortcuts untouched:

```text
begin → capture frontmost (NSWorkspace) + screen (AX, best-effort)
finalize → AX-trust gate → secure-input gate → reactivate → clipboard + full Cmd-V
         → marker/changeCount-guarded restore → inserted / recoverableFailure
```

## 2. Sources read for this plan

- `01_YAP_PARITY_ARCHITECTURE.md:165-211` (§4 target capture + insertion,
  §5 clipboard ownership, "no Automation unless required").
- `02_RECORDING_WORKFLOWS.md` — recovery table (AX-denied, secure input,
  target-gone), capture-before-UI, never-substitute-frontmost.
- `11_RELIABILITY_TEST_MATRIX.md:36-80` — target × interruption matrix,
  clipboard-restoration acceptance.
- `15_ENGINEERING_WISDOM_AND_MISTAKES.md:113-121` — wrong-app paste lesson,
  marker + change-count restore rule.
- `10_NEXT_STEP.md:102-124` — cross-app + interruption matrix.
- Yap `/private/tmp/yap-reference` 6596874, read in full: `TextInjector.swift`
  (209), `FocusedWindow.swift` (70), `SecureInput.swift` (41) — boundary
  evidence only, reimplemented Oto-owned.
- macOS 27 SDK verified (not memory): `AXUIElementCreate/Copy/Set` present
  (`AXUIElement.h:133-223,356`); `kAXValue/FocusedWindow/FocusedUIElement`
  present (`AXAttributeConstants.h:71,115,116`); `IsSecureEventInputEnabled`
  present (`CarbonEventsCore.h:3064`); `NSAppleScript` NOT deprecated
  (`NSAppleScript.h:46` — skipping System Events is a choice, see §4);
  `CGEventTapCreate` + HID-tap key-event trust rule (`CGEvent.h:260-300`).

## 3. Yap assessment: adopt / reject

ADOPT (all current in 27 SDK, Oto-owned with attribution):
- Capture-first ordering (`captureTarget()` before any UI).
- Full 4-event Cmd-V (down/down/up/up) from a private `CGEventSource` with
  device-left-Command bits — Chromium rebuilds modifiers from the raw stream;
  simplified flags silently fail in Electron.
- `prePasteDelay` 0.03 / `restoreDelay` 0.1 as starting values (matrix-tunable).
- Full-fidelity snapshot (every type, item order) + marker (`com.oto.session-marker`)
  + change-count double-guard; restore only if both still match.
- `waitForModifiersToClear` (0.6s) — load-bearing for us: our default trigger
  IS a held modifier; without it a fast paste could swallow ⌥ into ⌘V.
- Reactivate-if-inactive + 120ms settle before paste.
- No-editable-element gate (Electron reports none — any such check refuses
  Slack/VS Code).
- Secure-input Holder PID via IOKit (best-effort, nil-tolerant).

REJECT (with doc backing, not taste):
- **System Events / AppleScript route.** 01 permits it but forbids adding
  Automation permission "unless the final insertion route actually requires
  it". Nothing requires it: the synthetic route covers native + Electron.
  Skipping it keeps TCC to mic + AX only. Enforce with a grep gate
  (`NSAppleScript` → zero hits). Revisit only if the matrix proves an app
  class the tap cannot reach.
- **AX value-set as a route.** Setting `kAXValueAttribute` replaces the whole
  field value — insert-vs-replace is per-app undefined, and no doc guarantees
  cursor insertion. Paste semantics (insert at cursor) are universal. AX stays
  as gate + liveness + screen, never as writer.

## 4. Planned changes

New files:
- `Oto/Services/RealTargetCapture.swift` — `TargetCapturing`: `capture()` reads
  `NSWorkspace.shared.frontmostApplication` (bundleID + pid) + best-effort
  screen via AX focused-window geometry (Yap `FocusedWindow` pattern,
  nil-tolerant); `isAlive` via `NSRunningApplication(pid:)?.isTerminated`.
  Sync read kept (seam is sync; matrix verifies off-main read, fallback logged
  in §6).
- `Oto/Services/RealTextInsertion.swift` — `TextInserting`, thin live edge over
  a pure `InsertionDecision` (§5 test seam): trust gate → secure-input gate →
  reactivate → modifiers-clear wait → snapshot → marker write → pre-paste delay
  → full Cmd-V → scheduled guarded restore → `.inserted`. Any gate trip writes
  clipboard (leave-on-clipboard) and returns `.recoverableFailure(reason)` —
  coordinator already preserves `recoveryTranscript` on that path, no edits.
- `Oto/Services/PasteboardOwnership.swift` — `PasteboardReceipt`
  (marker + changeCount + `stillOwned`, per 01:199) + full-fidelity
  snapshot/restore (attribution comment). Pure over injected pasteboard —
  hermetic tests on `NSPasteboard(name:)`, never `.general`.
- `Oto/Support/SecureInput.swift` — `IsSecureEventInputEnabled` gate +
  best-effort IOKit holder name (Oto-owned port, attribution comment).
- `OtoTests/PasteboardOwnershipTests.swift` — receipt match/mismatch
  (user-copy race → no restore), snapshot round-trip incl. multi-type items.
- `OtoTests/InsertionDecisionTests.swift` — gate-ordering matrix
  (untrusted → secure → dead-target → post → restore-guard) without hardware.

Modified:
- `Oto/App/OtoApp.swift` — wire real capture + real insertion into the
  coordinator (fakes stay for tests). Nothing else.
- `Oto/Models/Transcript.swift` — no change (`inserted/recoverableFailure`
  already encodes the contract; 01's richer enum rejected to avoid coordinator
  + 14-test churn for zero behavioral gain).

Explicitly NOT in Phase 4: System Events route (see §3); AX value-set writing;
target-screen UI use (populated, consumed in Phase 6); Flow Bar/menus for
recovery display (reason strings flow through existing `failed` state);
sandbox change (stays ON; matrix decides); DEBUG menu additions (paste IS the
proof — the Phase-2 transcript line is already gone).

## 5. Test seam (craftsman split)

`RealTextInsertion` takes an `InsertionEvents` closure struct
(isTrusted/secureEnabled/postPaste/sleep). Production injects the live edge;
tests inject scripts. `InsertionDecision.next(preconditions)` is pure and
exhaustively matrix-tested; the live edge (CGEvent posting, AX queries) is
proven ONLY by the device matrix — stated plainly, not smuggled into unit
tests via mocks that prove nothing.

## 6. Verification

- Bridge `BuildProject` green; new suites green; all 62 existing green.
- Grep gates: `downloadAndInstall` → 1 site; `NSAppleScript` → 0;
  `SFSpeechRecognizer` → permissions only (Phase 2 invariants hold).
- Device matrix (user, packaged app, per 11): Safari bar + rich field, Electron
  composer, VS Code editor + terminal, Terminal prompt, secure field ×
  app-switch mid-record/mid-finalize, target-quit, copy-during-restore,
  AX-revoke, mic unplug, sleep/wake, repeat-hold. Acceptance per 11:73-76 —
  one insertion or clear recovery, never wrong-app, never lost clipboard,
  usable after every interruption without relaunch.

## 7. Risks and deferred decisions

- Off-main `frontmostApplication` read: works in practice, not doc-guaranteed.
  Fallback (capture on MainActor in dispatch pre-begin) logged, not built.
- Posted-but-unverifiable Cmd-V returns `.inserted` (Yap parity). Structural
  guarantee (right target + clipboard + full sequence + guarded restore), not
  per-keystroke proof. The 0.1s restore + async-reader lesson is the mitigation.
- IOKit holder-PID under sandbox: best-effort; the `IsSecureEventInputEnabled`
  boolean gate is what insertion depends on, and it needs no entitlement.
- Sandbox × event-post/AX-query stays open until the matrix says otherwise
  (carried since Phase 0).
- Hold watchdog (lost-key-up strand): still deferred (Phase 3 risk log).

## 8. Open questions for the user

1. System Events route: never (recommend — no Automation permission) vs. add
   as third layer if the matrix finds an unreachable app class?
2. Adopt Yap's 0.03/0.1/0.6/120ms timings as-is (recommend — tune in matrix)?
3. Populate `targetScreen` now best-effort (recommend — Phase 6 needs it,
   nil-tolerant) vs. leave nil until Phase 6?

## 9. Device findings (2026-09-20)

- App-switch P0: early reactivate lost to mid-finalize switches → wrong-app
  paste. Fixed with pre-post `confirmTarget()` + sync restore + recovery.
- Follow-up: 3 attempts too strict — alive-but-backgrounded target failed
  instead of reactivating (11 demands the original still be used). Budget to
  8 (~1s); every attempt logged under `insertion` (pids only); coordinator
  now logs the previously-silent `insertionFailed` terminal. 76/76 green.

- activate() verdict (device logs): `activate=false` on all 8 attempts —
  macOS refuses activation from our sandbox. Added DEBUG probe
  ("Probe activation (Finder)"): Finder-false proves sandbox cause.
- Clipboard ghost (device report): give-up path wrote then restored,
  leaving transcript second in manager history. Fixed by ordering:
  confirm #1 (bounded) BEFORE any clipboard write, single-read micro-
  verify #2 pre-post. Clipboard untouched on give-up. 77/77 green.
