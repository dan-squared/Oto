# Typed UI state + init split (hygiene cleanup)

## Goal

Replace the stringly-typed Settings UI state (`micText`/`speechText`/
`readinessText` compared as literals across two files) with typed stored
state and centrally-derived display strings — same pixels, same copy,
compiler-checked transitions. Optionally decompose `OtoApp.init`
(~138 lines) into ordered factories. Zero behavior change, zero
persisted-state migration (all of this state is in-memory).

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md`: one native Settings scene; History never
  stores prompt traces (untouched); coordinator owns session state
  (untouched — enforcement already uses the typed API, this plan only
  moves the *display* state to match).
- Current code truth (read this session):
  `Oto/Settings/SettingsUIState.swift:19-164` (stored strings + derived
  props, refresh paths), `Oto/Settings/PermissionRows.swift:15-67`
  (reads computed props only), `Oto/Onboarding/OnboardingView.swift:360-424`
  (one logic compare at :365, display reads elsewhere, local compare at
  :420), `Oto/Settings/DictationPane.swift:36-37` (reads computed props),
  `OtoTests/SettingsUIStateTests.swift:1-97` (pins current string behavior),
  `Oto/App/OtoApp.swift:77-214` (init), `Oto/Models/SpeechReadiness.swift:15-49`
  (typed `.ready` exists), `Oto/Support/PermissionsManager.swift:17-31`
  (`MicrophoneStatus` exists; `speechStatus()` returns Apple's
  `SFSpeechRecognizerAuthorizationStatus`).

## Facts verified against the local SDK (never from memory)

- ACP connected: workspace `Oto.xcodeproj`, scheme `Oto`, dest `My Mac`.
  Toolchain Xcode 27.0 (27A266a), Swift 6.4, `MacOSX27.0.sdk`,
  deployment target 27.0.
- This refactor adopts **zero new framework APIs** (pure Swift enums +
  the `@Observable`/`@AppStorage` patterns already in-tree; all three
  status types already imported and used), so there is no "What's new"
  surface to re-verify — stated explicitly so a later agent doesn't
  re-research it.
- `SFSpeechRecognizerAuthorizationStatus` is an `NS_ENUM` (Sendable-
  bridged, storable in `@MainActor @Observable` state); `MicrophoneStatus`
  and `SpeechReadiness` are `Equatable, Sendable` already.
- UI state is never persisted (no UserDefaults keys, no files) — retyping
  it carries zero upgrade/migration risk by construction.

## Assumptions questioned

1. "The strings drive permission logic." No — verified: enforcement is
   `DictationCoordinator.swift:311` + speech `prepare()`, both on the
   typed API. Strings drive display/tone/gating only. The refactor is
   hygiene (typo-proofing), not a permission fix — severity stays low.
2. "All consumers must change." No — computed props keep the names
   `micText/speechText/readinessText/speechReady/micAllowed/micTone/
   micDeniedGuidance/speechTone/languageText`, so `PermissionRows`,
   `DictationPane`, and most of `OnboardingView` compile untouched.
   Exactly one logic site changes (`OnboardingView.swift:365` →
   `micAllowed`).
3. "The init split is required." No — init has zero `try`/`fatalError`/
   force-unwraps and infallible constructors; decomposition is cosmetic.
   Phase B is explicitly optional/deferrable.

## Design (decisions + reasons)

- Stored state becomes typed-with-nil (nil = checking):
  `micPermission: PermissionsManager.MicrophoneStatus?`,
  `speechPermission: SFSpeechRecognizerAuthorizationStatus?`,
  `speechReadiness: SpeechReadiness?`. Display strings become computed
  with byte-identical copy ("Checking…", "Allowed", "Denied",
  "Not asked yet", "Not allowed", "Unknown"), so no pixel or copy
  changes anywhere.
- `speechReady` becomes `speechReadiness == .ready` — this kills the
  sharpest instance: today it compares against `"Ready"` while the
  producer is `errorDescription ?? "Ready"`, i.e. a dependency on Apple
  wording. After: typed end-to-end.
- `OnboardingView.swift:420` (`status == "Allowed"` on a local display
  param) stays a string compare deliberately: the strings are now derived
  in exactly one tested place, and threading a Bool through
  `permissionRow` churns 3 call sites for zero behavior change. Comment
  records this.
- `languageText` stays a String (locale-tag display, no logic).
- Tests get stronger, not just rewritten: impossible states become
  unrepresentable (today any typo'd string is a silent new state).

## Exact file changes

**Phase A — typed UI state (the real fix):**
1. `Oto/Settings/SettingsUIState.swift`
   - Stored strings → typed optionals (above); computed display props
     keep existing names + copy; `refreshPermissions()` assigns enums;
     `refreshSpeech()` stores `report.readiness`; `micAllowed/micTone/
     micDeniedGuidance/speechTone/speechReady` switch on typed values.
2. `Oto/Onboarding/OnboardingView.swift:365` — `micText == "Allowed"` →
   `micAllowed`; add comment at :420 noting the intentional display
   compare. Nothing else in the file changes.
3. `OtoTests/SettingsUIStateTests.swift` — `micToneMapping`,
   `speechToneMapping`, `initialValuesAreHonestPendings` drive typed
   state (`state.micPermission = .granted`, …) and assert identical
   display outputs; nil-state pendings asserted ("Checking…",
   `speechReady == false`).
4. `PermissionRows.swift`, `DictationPane.swift`: no changes.

**Phase B — init split (optional, cosmetic, deferrable):**
5. `Oto/App/OtoApp.swift` — extract private factory funcs returning
   tuples (media stack, stores, dispatch/flow/transforms), preserving
   exact order: wipe → migrate → construct → start → load-task →
   prewarm. No behavior change; do only if that file is being touched
   for another reason.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green.
- `xcodebuild test -scheme Oto` green (rewritten UIState tests + all
  existing pins, incl. sidebar metrics).
- ACP `RunSomeTests`: `SettingsUIStateTests` suite.
- Live matrix (packaged app; TCC-gated paths never validated from Debug):
  Settings panes render byte-identical strings; mic deny/allow +
  onboarding copy unchanged; Dictation readiness row unchanged.

## Risks / deferred decisions

- Risk ~zero by construction: display copy byte-identical, no persisted
  state, no enforcement-path contact, no new APIs. The only semantic
  delta is typo'd states becoming unrepresentable (the point).
- Deferred: `permissionRow` Bool-threading (:420), init split timing,
  `languageText` typing (display-only, never).
- If a future agent proposes "cleaning up" the hand-written `Equatable`
  witnesses, `Fake*` co-location, empty entitlements, the yield loop,
  `PermissionsManager` sites, or `Date()` uses: all verified
  intentionally-correct (see verification report 2026-10-05) — do not
  bundle them here.

## Open questions (recommendations marked)

- Q1 Thread a Bool through `permissionRow` instead of the :420 display
  compare? (Recommended: no — churn without behavior change.)
- Q2 Phase B now or when init next changes? (Recommended: defer.)
