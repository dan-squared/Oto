# First-launch onboarding (permissions + hold-to-talk + try-it)

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 1. Goal

A 3-step first-run window that ends with a working setup: what Oto is,
permissions granted, hold-to-talk kept or changed (default Right ⌥),
one live test dictation. Reuses existing components only — no new
backends, no custom chrome (house rule: Flow Bar is the only custom
surface; this is a native `Window` in the catcher card aesthetic).

## 2. Shape (3 steps, progress dots, Skip always live)

1. **Welcome** — one line what Oto does ("Hold a key, speak anywhere,
   release to insert"), Continue. No permissions touched yet.
2. **Permissions** — three rows with live status + action buttons,
   reusing `PermissionsManager` + the existing prompt pattern
   (`DictationPane`/`PrivacyHistoryPane` `requestAccessibilityPrompt`):
   Microphone (`ensureMicrophone`), Accessibility (AX prompt; explains
   tap + insertion + why the shortcut needs it), Speech recognition
   (status; system grant path). Continue enabled always (never trap
   the user), each row shows granted/pending honestly.
3. **Shortcut + try-it** — hold-to-talk card reusing `KeycapField` +
   hold-key menu + `updateHoldTrigger` (same gate/conflicts as
   Settings; hands-free stays empty with one line noting double-tap
   works with zero setup). Below it, a try-it field + "Finish".
   Finish/dismiss marks onboarding seen.

- Shows once: versioned key (`app.Oto.onboardingVersion`, absent =
  show; `NoTargetModalSettings` precedent). Re-openable from the menu
  ("Take the tour") — one line in `OtoMenuBarView`.
- Window: native `Window` scene in `OtoApp` (`openWindow` on first
  launch when key absent), fixed size (~600×460), standard traffic
  lights, ESC = Skip (same as dismiss, marks seen — never nag twice).

## 3. Exact file changes

1. `Oto/Onboarding/OnboardingView.swift` (new): 3-step pager,
   progress dots, Back/Continue/Skip/Finish; owns no services (takes
   dispatch/permissions/preparer as params, like Settings panes).
2. `Oto/Onboarding/OnboardingStore.swift` (new, or fold into view):
   version-key read/write; pure enough for unit tests.
3. `Oto/App/OtoApp.swift`: add `Window("Welcome to Oto", id:)`
   scene; open on launch when unseen (defer past compositions, no
   launch-path blocking); pass existing instances (no duplicates —
   audit S2 rule).
4. `Oto/UI/OtoMenuBarView.swift` (check name): "Take the tour" item
   reopening the window.
5. Reuse untouched: `KeycapField`, `ShortcutRecorderModifier`,
   `KeyNames`, dispatch gate, `PermissionsManager`,
   `NoTargetModalSettings` key pattern.

## 4. Tests (deterministic, no hardware)

- Store: absent→show, marked→skip, version bump re-shows (new).
- Staging/gate reuse needs no new tests (same code paths as Settings).
- Existing suites untouched, must stay green.

## 5. Verification

- Build green; full suite green twice.
- Device matrix: fresh profile (deleted prefs) shows window on launch;
  grant each permission from its button; change hold key (applies +
  persists); try-it dictation inserts; relaunch never reshows; menu
  reopens; ESC/Skip marks seen; screenshot both schemes.

## 6. Risks / deferred

- TCC prompts need user gesture — all requests ride buttons ✓.
- AX prompt opens System Settings (existing blessed path) — user may
  grant later; rows stay honest, Continue never blocked.
- Out of scope: hands-free setup (empty by design + double-tap note),
  login-item prompt, analytics, custom window chrome.
