# Permission-denied mini modal (mic) — plan

## Goal

When dictation fails with `.microphoneDenied`, show a mini modal at the pill slot
(388×~60, mockup `.context/attachments/RnFwOd/image.png`) instead of the pill
flashing on and melting out. Clicking "Grant Permission" opens System Settings at
Privacy & Security → Microphone. The modal and (post-merge) the catcher are
appearance-aware. Full catcher work stays deferred until after the merge, per user.

## Spec sources

- Mockup: black rounded card, red circled `!`, white "Microphone Permission Required",
  cream "Grant Permission" button (dark-mode rendering).
- `Docs/START_HERE_PRODUCT.md` (canonical): failures stay recoverable; v7 moved errors
  to concise menu status — this is a deliberate single exception: mic-denied has a
  direct user action (grant), so a pill-slot modal with a button is the recovery path.
  All other failures keep current behavior (menu only).
- Current flow: `DictationCoordinator.runPreparation` → `.failed(context, .microphoneDenied)`
  (`DictationCoordinator.swift:232`) → projection hidden → pill melts; menu reads
  "failed: microphone denied". Menu copy stays unchanged.

## Facts verified against the local SDK (never from memory)

- Mic state already modeled: `AVAudioApplication.shared.recordPermission` /
  `requestRecordPermission` (`PermissionsManager.swift:25,41`). When status is
  `.denied`, `requestRecordPermission` no-ops (no re-prompt) — directing to Settings
  is the only path. (Apple frameworks behavior; code already assumes it.)
- No blessed API opens the Microphone privacy pane (codebase precedent:
  Accessibility uses `AXIsProcessTrustedWithOptions`, `DictationPane.swift:269-276`,
  explicitly "no raw Settings URLs" — but no equivalent exists for Microphone).
- Panel recipe exists: `FlowBarPanel.makePanel` (nonactivating, floats all spaces)
  + `resolveScreen` (target → mouse → main → origin) — reuse, no new windowing code.
- Test precedent: headless controller tests (`NoTargetModalTests.prewarmBuildsWithoutShowing`)
  — panel construction needs no screen; `show()` no-ops headless via nil screen.
- No Appearance setting exists in the app (General has Launch/Flow Bar/About only) —
  so "appearance aware" means follow **system** light/dark (SwiftUI `colorScheme` /
  semantic colors in the hosting view), not an in-app toggle.

## Assumptions questioned

- **Settings deep link** (web search unavailable this session — MUST verify by click):
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
  Two fallbacks, tried in order: `…security?Privacy` (Privacy & Security root) →
  `x-apple.systempreferences:` (Settings main page). If the deep link 404s on the
  user's macOS, the fallback still lands somewhere useful; manual click test is the
  ground truth and is in the verification matrix.
- **388 width**: user's number; height ~60 driven by content (icon 22 + text + button
  padding 12). Positioned by the existing `FlowBarPosition.frame` slot math at the
  current Top/Bottom slot on the target screen — same place the pill would be.
- **Dismissal**: persist while denied (no timeout, no ✕ — mockup has neither); hidden
  the moment coordinator state leaves `.failed` (next dictate attempt reshows it if
  still denied). Rationale: the condition is still true, and a timeout would reintroduce
  the "coming on going" flicker the user complained about.

## Design (appearance-aware)

| | Dark (mockup) | Light |
|---|---|---|
| Card | near-black `#0E0E11`, corner ~16 | white, same radius + soft shadow (window `hasShadow` already on) |
| Icon | red circled `!` (`exclamationmark.circle`, `.red`) | same red icon |
| Title | white, semibold ~14 | dark (`primary`) |
| Button | cream `#EDE6D6` fill, black text | dark fill (`#1C1C1E`), white text |
| Implementation | SwiftUI view reading `@Environment(\.colorScheme)`; NSHostingView in `makePanel` panel follows system appearance automatically |

Catcher appearance (post-merge, recorded here so it isn't lost): replace `NoTargetModalView`'s
hardcoded `Color(red: 0.055, green: 0.055, blue: 0.065)` / white-text scheme with the same
semantic treatment. Not in this change.

## Exact file changes

1. **NEW `Oto/UI/FlowBar/PermissionModal.swift`**
   - `PermissionModalController` (`@Observable @MainActor`, `NoTargetModalController` precedent):
     `prewarm()`, `show(displayID:position:)`, `hide()`, `isVisible`/`hasPanel` test hooks.
     Width constant 388; frame from `FlowBarPosition.frame(width:on:position:)`.
   - `PermissionModalView` (SwiftUI): `HStack` icon + title + `Spacer` + button; fixed
     388×~60; colorScheme-driven palette above.
   - `openMicrophonePrivacySettings()`: pure URL-builder (testable) + `NSWorkspace.shared.open`
     with the 3-level fallback chain.
2. **`Oto/App/OtoApp.swift`**: create `PermissionModalController`, pass into
   `FlowBarController` (same shape as `modalController`); `prewarm` at start.
3. **`Oto/UI/FlowBar/FlowBarController.swift`**: in the recovery section, route
   `.failed(_, .microphoneDenied)` → permission modal (once per session key, same
   `lastRouteKey` pattern); hide pill panel while shown; hide modal whenever state
   leaves `.failed`. Other failures untouched.
4. **NEW `OtoTests/FlowBar/PermissionModalTests.swift`**: deep-link URL builder test
   (exact Microphone string + fallbacks), once-per-key routing test, prewarm-without-show
   test (`NoTargetModalTests` precedent).

## Verification steps

- [ ] Build clean + full suite green (new tests included)
- [ ] Grep gates hold (no new force unwraps; URL strings only in the one builder)
- [ ] Manual matrix (user's side): deny mic → dictate → modal appears at current slot
      (no pill flash); flip Top/Bottom → next deny shows at new slot; toggle system
      Light/Dark → modal re-renders correctly; click Grant Permission → Settings lands
      on Microphone (or fallback level, reported); grant → dictate → modal gone, waves live

## Risks / deferred

- Settings deep-link string unverified (search down) — fallbacks + click test cover it.
- `NSWorkspace.open` from a sandboxed app is allowed for system URLs — but confirm no
  sandbox exception surfaces during the click test (entitlements: `Oto/Oto.entitlements`).
- Catcher appearance + catcher completion: explicitly post-merge.

## Open questions — RESOLVED (user, this session)

1. Light-mode palette — APPROVED (white card / dark text / dark button).
2. Dismissal — 5s timeout then fade out, no ✕. (Recommended 5 over 3: time to
   read + reach the button; macOS banner persistence class.)
3. Merge after matrix passes, catcher next — confirmed.
4. Grant button branches without TCC reads: `.notDetermined` → system prompt
   (the "access giving window"); `.denied` → Settings deep link with 2 fallbacks.
   Deep-link anchor unverified locally (not in Settings bytes, search down) —
   user click-tests during matrix.
