# Catcher remake v4 — pill morph, minimal UI, adaptive — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Supersedes v3 for scope: §A void-case fix RETAINED (the catcher must
fire — unchanged design, §2); scratchpad DEMOTED to optional-last
(§8, by reference to the v2 file — not built now, built only if
users demand it). This file meticulously plans the CATCHER ONLY:
UX + UI, simple, responsive, adaptive, morphing from the pill.

## 1. Reference analysis (attached image, measured intent)

The reference: dark rounded card; top row = mark left, dim hint
center, circled ✕ right; large transcript; Copy bottom-right.
User cuts (explicit, applied): NO logo mark, NO stroke circle on ✕
(plain `xmark`, no `.circle`), NO hint text beside ✕. What remains —
the whole surface: **plain ✕ top-right, the dictated words, Copy
bottom-right.** Nothing else competes.

Recorded tradeoff (user decision stands): dropping the hint removes
the first-encounter teaching ("why did this appear instead of
insertion?"). Accepted because the surface now nails one point —
your words are kept, Copy takes them — and the trigger itself
(void/failed paste) is self-explanatory after the first Copy. If
the device pass shows first-run confusion, the fallback is a
first-show-only hint, NOT a permanent row (stated so nobody
re-adds it silently).

## 2. Void-case fix (retained from v3 §A/B — unchanged)

Dictating into the void returns `.inserted` (posted-unverified,
`RealTextInsertion.swift:255`) ⇒ `.completed` ⇒ router nil ⇒ no
catcher, transcript gone. Fix: read-only AX editable-focus check
(`AXTextField`/`AXTextArea` roles; SDK-verified:
`AXAttributeConstants.h:1009` + `:45`, `AXRoleConstants.h:360-361`,
`AXUIElement.h:148`) after reactivate, before clipboard touch:
`.noField` → new `.noEditableField` → new `.noTextField` failure
(kept recovery) → router fires; `.unknown`/timeout → today's
behavior exactly. Files: NEW `EditableFocusCheck.swift`; EDIT
`Transcript.swift` (+1 result case), `RealTextInsertion.swift`
(injected `FocusChecking`, sited pre-clipboard), `DictationState.swift`
(+1 failure case, `==` group, summary copy), `DictationCoordinator.swift`
(one mapping branch), `FlowBarState.swift` (router match). Tests:
role-mapping units, fake-focus insertion tests (clipboard untouched,
zero posts on divert; full legacy path on unknown), router both
settings, coordinator mapping, summary pin. Matrix: Finder/desktop,
Safari body, VS Code editor/terminal, Slack composer, Chrome
omnibox, password field (secure path unchanged), AX revoked
(untrusted path unchanged), auto-copy OFF parity.

## 3. UI spec (exact — the whole surface)

Container (unchanged geometry — no re-pinning churn): 464×168,
centered on the session screen via `FlowBarPanel.resolveScreen`
(shared chain), `.floating` + `[.canJoinAllSpaces,
.fullScreenAuxiliary]`, `hidesOnDeactivate = false`, prewarmed at
app scope (appearance must never wait on construction).

Content (top to bottom):
1. Top row: `Spacer` + plain `xmark` button (`.borderless`,
   44pt minimum hit target via padding — a11y, no visual circle).
   Action = hide only (retention §5 verbatim).
2. Transcript: `.title3`, 2-line limit, tail truncation, top-
   aligned with 14pt top padding (current values — the freed hint
   row becomes breathing room, not a re-layout).
3. Bottom row: `Spacer` + Copy (`.bordered`; "Copied" feedback
   1.5s disabled state, stays open — unchanged).
4. NOTHING else. No mark, no hint, no third button (Retry stays
   in the menu — both reference frames + v1 Q2 agree).

Adaptive palette (★user requirement — kills the hardcoded dark
card `NoTargetModal.swift:111-113`): NEW shared struct (pure,
unit-tested, dark≠light pinned):
- Dark: card near-black (current `0.055` triple, pinned by test),
  transcript white 0.9, ✕ white 0.6, shadow black 0.5 r22 y6
  (current, unchanged).
- Light: card system-card white equivalent, transcript black
  0.85, ✕ black 0.55, shadow black 0.25 r22 y6.
- Copy `.bordered` adapts natively; gray tint kept both modes.
- Fonts are Dynamic-Type automatic (`.title3`); no fixed line
  heights that could clip larger sizes (responsive typography).
- Grep-gate: zero hardcoded fills in either catcher file after.

Responsive (every axis named):
- Theme: palette both schemes + morph covered in both (matrix).
- Screen: existing 4-step chain + visible-frame clamp (small
  screens, notch, multi-display — unchanged, matrix row).
- Text: 2-line truncate + full text one Copy away (long/paste-
  bomb rows: 50k-char scroll-free truncate, Copy carries all).
- Time: prewarmed show path (no construction on the gesture);
  morph 0.22s (below); Reduce Motion = instant (existing gate).

## 4. Pill → catcher morph (★user requirement)

The pill is alive at route-fire time (`syncRecovery` runs BEFORE
`syncPanel`'s vanish — `FlowBarController.swift:142-145`), so the
morph origin is real geometry, not a fabrication:
1. On route fire with a visible pill: snapshot pill frame
   (`pinnedScreen` + `currentWidth` + slot via existing
   `FlowBarPosition.frame` — no new recipe) on the session screen.
2. Catcher panel (prewarmed, hidden) takes the pill frame at
   alpha 0 → `orderFront` (never key — nonactivating mask stays)
   → ONE 0.22s `.easeOut` animator gesture: frame → centered
   464×168 end frame + alpha → 1, while the pill runs its existing
   melt in parallel → `orderOut` pill at completion. Content
   crossfades as part of the same alpha ramp. One surface grows
   out of the other; nothing flashes, nothing pops.
3. Fallbacks (stated, no silent behavior): pill frame unavailable
   (already hidden, headless) → current centered fade-in,
   byte-identical to today. Reduce Motion → instant swap.
   Interrupted (route re-fire mid-morph): generation guard
   (pill-melt precedent) + idempotent `show`.
4. Honest limit (recorded so nobody gold-plates): this is a
   frame+alpha morph on proven animator primitives (pill land,
   modal show, ghost fade — same path), NOT cross-window
   matched-geometry (impossible — v2 F3). 0.22s matches the
   snappiest existing gesture (pill land `snapDuration` family);
   the matrix judges "fast, not laggy", one retune max.

## 5. UX behavior (unchanged rules, restated for completeness)

- Fires: `targetGone` / `insertionFailed` / NEW `noTextField`
  (modal ON) or auto-copy (OFF) — once per session key (existing
  `lastRouteKey` guard).
- Owns its text copy at show; survives next `begin`; closes via ✕
  or Copy-then-✕ only (retention Q3 — the scratchpad demotion
  changes nothing here; Edit hooks from v2/v3 are NOT added).
- Kill-switch `app.Oto.noTargetModal` unchanged (default ON,
  tests pin).
- Menu parity unchanged (Copy/Retry recovery rows).
- Escape: hides locally (retained), never touches sessions.
- History: untouched (finals already recorded at finalize).

## 6. Exact file changes

1. §2 fix files (7 items — §2 list verbatim).
2. NEW `Oto/UI/Scratchpad/CatcherPalette.swift` — adaptive struct
   (§3; pure; both schemes pinned by tests).
3. EDIT `NoTargetModal.swift` — content reflow per §3 (drop mark +
   hint + circled-X chrome; plain ✕ 44pt target; palette render;
   geometry 464×168 untouched) + `showFromPill(pillFrame:text:
   displayID:)` morph entry (§4) + generation guard; plain `show`
   kept as fallback.
4. EDIT `FlowBarController.swift` — pass pill frame into the
   catcher route (frame snapshot before vanish; RM gate through).
5. NEW/EDIT tests: palette units, reflow pins (no mark/hint
   views — assert the absence: `markCount == 0`-style structural
   pins so nobody re-adds), style-bit (nonactivating retained),
   morph fallback units (nil frame → plain show; RM → instant),
   router + mapping + summary (from §2). Morph timing + focus +
   both-scheme pixels are device-matrix, stated not faked.
6. NO coordinator/inserter/menu changes beyond §2's mapping
   branch. NO scratchpad files. NO Edit hooks.

## 7. Verification steps

- Build clean zero warnings; new tests green; full suite green
  TWICE; gates (unwraps, banned primitives, hardcoded-fill grep).
- Device §2 matrix (Finder/desktop → catcher FIRST — the reported
  hole — then editor/composer/omnibox/terminal/password/AX/OFF).
- Device catcher matrix (packaged `.app`): morph <0.25s no hitch
  repeated; RM instant; light + dark card/copy/morph; small
  screen clamp; 50k-char truncate + full Copy; ✕ retains;
  next-session survives; Copy→⌘V; Escape; first-run feel (hint
  trade-off §1 — report confusion honestly, fallback ready).
- Then merge (green twice + both matrices).

## 8. Scratchpad — OPTIONAL, LAST, IF-DEMANDED (not built)

Spec parked intact at `plan/phase-6c2-scratchpad-v2.md` (Edit
entry points, titled key window, raw/working AI seam, palette —
now shared with §3's struct). Triggers for revival, any one:
repeated user asks for on-device editing, void-case Copy
insufficient in practice, or Phase-7 drafts needing a home. Until
then: zero code, zero hooks, zero surface. This section is the
whole scratchpad plan — nothing else is owed.

## 9. Risks

- Morph origin race (pill vanished between snapshot and orderFront):
  fallback path covers; snapshot+orderFront are adjacent MainActor
  statements, no suspension between (stated in code).
- Centered-travel feel on tall displays: matrix judges; retune is
  duration-only (0.22s ±), never a redesign.
- First-run hint-less confusion: §1 fallback ready, not pre-built.
- AX-read sandbox denial: degrades to `.unknown` ⇒ today; matrix
  proves on the signed build.

## 10. Open questions — none. `execute` builds §2 then §§3-4.
