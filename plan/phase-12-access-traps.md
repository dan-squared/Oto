# Phase 12 — access traps (shortcuts, catcher keyboard, retry target, speech remedy, app picker)

## Goal

Remove the traps that punish exploration and non-pointer users: clearing
one shortcut killing both, catcher actions unreachable from keyboard,
Retry posting to focus-at-click-time, the speech-permission dead end,
and bundle-ID-as-typing. Small, mostly UI + model-migration work; no new
frameworks; focus-steal defense stays intact throughout.

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md`: recoverable failures, honest status,
  native Settings. The traps below violate the spirit (surprise,
  dead ends) more than the letter.
- Current code truth (read 2026-10-06):
  `Oto/Settings/ShortcutModal.swift:102-103` (recorder hint),
  `:213-215` + `:260-281` (trash affordances), `:383-402`
  (stageClear; empty-slot clear is already a no-op), `:470-511`
  (applyDone; `:504-506` either clear → global off),
  `:513-519` (reset); `Oto/Models/ShortcutModels.swift:264-280`
  (DualShortcutConfiguration: one global `enabled`; per-slot deferred
  in-comment), `:463-524` (staging incl. `disablesGlobally`);
  `Oto/Services/ShortcutDispatch.swift:84` (configuration),
  `:123/:378/:492` (the three `configuration.enabled` gates);
  `Oto/UI/Theme/OtoControls.swift:58-70` (OtoPill IS a real Button —
  the catcher blocker is never-key panel, not the buttons);
  `Oto/UI/Scratchpad/NoTargetModal.swift:179-180` + `:236`
  (orderFront never key), `:342-354` (Copy + 300 ms auto-close),
  `:410-413` (Copy button);
  `Oto/UI/OtoMenuBarView.swift:68-84` (Retry posts to frontmost at
  click; failure bundles two causes);
  `Oto/Coordinator/DictationCoordinator.swift` recovery sites (all
  hold `context.target` — expected-app source available);
  `Oto/Settings/PermissionRows.swift:59-67` (speech status-only),
  `Oto/Onboarding/OnboardingView.swift:386-392` (empty speech action);
  `Oto/Settings/DictionaryPane.swift:129-137` (scope segmented +
  manual field, preview trims at `:146`), `SnippetsPane` mirror
  (`:115`); `Oto/Settings/HistoryPane.swift:67` (raw bundle IDs).

## Facts verified against the local SDK (never from memory)

- ACP connected this session: workspace `Oto.xcodeproj`, scheme `Oto`,
  dest `My Mac`. Toolchain Xcode 27.0 / Swift 6.4 / MacOSX27.0.sdk.
- Zero new framework APIs planned: `NSWorkspace.frontmostApplication`
  (in-tree precedent: retry path), per-slot model fields (plain
  Codable), `NSAlert`/`.confirmationDialog` (in-tree),
  `SFSpeechRecognizer.requestAuthorization` (long-standing API —
  confirm availability + prompt behavior in SDK 27 at implement time,
  with the Settings-deep-link fallback if it misbehaves).
- Clearing is currently the ONLY global off-switch in the product (no
  other caller sets enabled false) — removing its global effect
  without replacement would strand users with no off-switch. The
  design below accounts for this.

## Assumptions questioned

1. "Catcher needs key status for keyboard access." No — key status
   would steal focus from the app the user may be typing in (the
   defense's whole point). The menu path (Copy recovery, full-text
   since Phase 10) is already keyboard-operable via Ctrl-F2 → menu;
   VoiceOver can already activate non-key buttons via VO-Space. The
   fix is signage + announcement, not focus theft.
2. "Retry can re-verify against the captured target." Not as built —
   recovery keeps text only. The design stores the expected app at
   failure time (all four recovery sites hold `context.target`).
3. "A full running-apps picker is needed." No — a frontmost Fill
   button covers the real flow (open Mail → Fill → save); manual
   field stays for power users and non-running apps.

## Design (decisions + reasons)

**Item 1 — per-slot enable (P0-8; product call inside).**
- Recommended: real per-slot flags, not a master switch. The factory
  default (hands-free unassigned + master enabled) already proves
  slots are independent; the global boolean was always the wrong
  shape.
- `DualShortcutConfiguration` gains `holdEnabled`/`handsFreeEnabled`
  (default true). Codable compat: `decodeIfPresent ?? true`, EXCEPT
  preserve a stored global-off as both-off (migration matrix in
  tests). Clearing a slot sets only that slot's flag false; recording
  a combo re-enables it; Reset restores both-on + factory kinds.
  `ShortcutStaging.disablesGlobally` dies; donePreview goes per slot.
- The three `configuration.enabled` gates (`ShortcutDispatch`
  `:123/:378/:492`) each gain their slot's flag (verify slot context
  per site at implement; final grep must show zero bare reads).
- Cleared-hold state gets named guidance in-row ("Push to talk has no
  shortcut — record one to dictate") instead of silent global death.

**Item 2 — catcher keyboard path (no focus theft).**
- Card footnote: "Tip: menu bar → Copy recovery transcript works from
  the keyboard." (True today via Ctrl-F2 + Phase-10 full-text copy.)
- AX polish: transcript exposed with label; buttons labeled where
  missing; post an `NSAccessibility` announcement on Copy (real VO
  win, tiny).
- Copied auto-close 300 ms → 1000 ms (matches the file's own "1s"
  comment; 300 ms is imperceptible). Test sleeps retimed
  proportionally. Panel stays never-key — explicitly not revisited.

**Item 3 — retry target honesty.**
- Recovery carries the expected app: extend the kept recovery with the
  source bundle ID at all four failure sites (optional field —
  tolerant by construction; verify `Transcript`'s Codable shape at
  implement time, same precedent as HistoryEntry's tolerant decode).
- Retry mismatch → `NSAlert` confirm naming both apps ("Frontmost is
  X — transcript was for Y. Paste anyway? [Paste/Cancel]"). Pure
  `shouldConfirmRetry(frontmost:expected:)` + tests; alert at call
  site; matrix for the dialog.
- Success feedback always names the app ("Posted to X — check it."),
  replacing the bundled failure copy with per-cause lines.

**Item 4 — speech remediation.**
- `SpeechStatusRow` + onboarding speech row gain the real action:
  primary `requestAuthorization` then `refreshPermissions()` (in-
  product fix, no errand); Settings-deep-link fallback if the prompt
  path misbehaves (URL verified at implement time). Checkmark-when-
  Allowed pattern kept consistent with sibling rows.

**Item 5 — frontmost Fill + localized names.**
- Dictionary + snippet editors: "Use frontmost app" button sets
  `bundleID` from `NSWorkspace.shared.frontmostApplication` and flips
  scope off-global. Manual field stays.
- History rows: display helper mapping bundleID → localized app name
  (`runningApplications(withBundleIdentifier:)` first name, fallback
  raw ID). Pure + tested.

## Exact file changes

1. `Oto/Models/ShortcutModels.swift` — per-slot flags + tolerant
   decode + migration (global-off → both-off); staging per-slot
   semantics (retire `disablesGlobally`).
2. `Oto/Services/ShortcutDispatch.swift` — slot-aware gates at the
   three sites; zero bare `configuration.enabled` reads after.
3. `Oto/Settings/ShortcutModal.swift` — clear messaging per slot,
   cleared-hold guidance, Reset covers flags; Done never touches a
   global (it no longer exists).
4. `Oto/UI/Scratchpad/NoTargetModal.swift` — footnote, AX labels +
   Copy announcement, auto-close 1000 ms.
5. `Oto/Coordinator/DictationCoordinator.swift` + `Oto/Models/
   Transcript.swift` — expected-app on kept recovery (all four
   sites).
6. `Oto/UI/OtoMenuBarView.swift` — retry mismatch confirm + named
   success/failure copy.
7. `Oto/Settings/PermissionRows.swift` + `Oto/Onboarding/
   OnboardingView.swift` — speech action wiring.
8. `Oto/Settings/DictionaryPane.swift` + `SnippetsPane.swift` — Fill
   buttons; `HistoryPane.swift` — localized names via pure helper.
9. Tests: migration matrix (old blob variants), per-slot gating
   (hold-off/hands-free-alive + mirror), clear-keeps-other,
   mismatch pure, name-mapping fallback, footing/copy updates where
   touched, auto-close retimed sleeps. No panel-focus tests (needs
   key window; matrix owns it).

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green;
  `xcodebuild test` green (new + all pins).
- ACP `RunSomeTests` on touched suites.
- Live matrix (packaged app):
  1. Clear hands-free → Done → hold still dictates; clear hold →
     named guidance, Reset restores; old global-off profile migrates
     to both-off.
  2. Ctrl-F2 → menu → Copy recovery pastes full text, no pointer.
  3. Retry with switched frontmost → confirm names both apps; accept
     posts, success names the app.
  4. Denied speech → Allow flow completes in-product; onboarding row
     matches Settings.
  5. Mail frontmost → Fill → `com.apple.Mail` saved; History shows
     "Mail"; unknown ID falls back raw.

## Risks / deferred decisions

- Migration decode compat is the load-bearing risk (tolerant-decode
  precedent cited twice in this tree for a reason); matrix item 1
  proves old blobs both ways.
- Never-key policy untouched — no focus-theft regression possible
  from item 2 by construction.
- `Transcript` extension shape verified at implement (optional-field
  tolerant precedent assumed; confirm, don't assume).
- Deferred: full running-apps picker (Fill covers it), SFSpeech URL
  fallback (only if prompt path misbehaves), P1-35 remainder (menu
  badge/sticky status — still behind beta evidence per the 10 s call).

## Open questions (recommendations marked)

- Q1 Per-slot enable vs master switch? (Recommended: per-slot — the
  factory default already proves slot independence.)
- Q2 Copied auto-close 300 → 1000 ms? (Recommended: yes — matches
  the file's own comment; imperceptible today.)
- Q3 Fill-vs-full-picker? (Recommended: Fill + manual field.)
