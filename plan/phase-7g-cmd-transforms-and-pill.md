# Phase 7g: Cmd transforms, horizontal cards, divider-less pill

> Follow-up to 7d–7f (shipped, uncommitted) from live testing with the
> truncated-pill screenshot: (1) Opt+digit transforms don't fire on the
> user's machine → defaults move to Cmd+1/2/3 (explicit request), (2) Auto
> Cleanup cards go horizontal with per-card examples (shared triplet
> removed), (3) divider leaves the pill (user call), (4) pill still
> truncates + card selection feels buggy.

## Diagnosis (pill screenshot: `Conc… | spinner` + dead space)

> Short label + minimum-width clamp + exact-fit text field. `Concise`
> measures ~40pt; chrome adds ~47; the 120 min-clamp wins → ~32pt of dead
> space right of the spinner (the "spinner left, empty right"). The label
> frame equals the measured width exactly, and the text cell needs +2–4px
> beyond measure or it ellipsizes (the `…`). Two-part cure: a text slack
> constant in BOTH width math and label layout (single source — exact-fit
> can never recur) + lower min to 96 (uniform small pills, less dead
> space). Divider removal shrinks chrome with it.

## Goal

- Transform defaults Cmd+1/2/3 (explicit request — stated cost: global
  Cmd+digit hotkeys preempt per-app Tab switching while Oto runs; each is
  re-recordable). Default hold returns to Right Option so factory defaults
  satisfy Rule B (Opt hold vs Cmd combos = different families, zero
  cross-fire — the 7e full-circle, forced by the policy).
- Cards horizontal (3-across, equal widths), each with title + one-line
  description + one short example; shared triplet deleted. Hit-testing
  hardened (`contentShape(Rectangle())` — plain-styled buttons with
  spacer content can have hole-y hit areas; the likely "buggy" mechanism).
- Pill: no divider (layer, layout, chrome, and tests go), label + spinner
  only; spinner snug to the right edge (test-pinned); slack kills ellipsis.
- Second-press staleness: 7e's hide-invalidation + 7f's serial scope
  already cover it; this slice adds no new mechanism — matrix confirms on
  a FRESH build (the reporter was likely running a pre-7e .app from
  Finder, which bypasses scheme args AND predates both fixes).

## Spec sources

- 7d–7f plans (design record — untouched); user pill screenshot (truncation
  + dead space); generic wireframe (direction only).
- Code facts verified by reading: `TransformShortcuts.default` (Opt trio),
  `defaultHoldToTalk` (Right Cmd), `ModifierHotkeyMonitor.configure`
  (combo-only path — Cmd combos ride it unchanged), `KeyNames` chips
  (glyphs render Cmd combos already), `OtoCard` (plain container — no
  nested-button conflict class for the cards bug; contentShape is the fix).

## Assumptions questioned

- *"Cmd+digits are safe global defaults."* They are not unconditionally:
  stated loudly in the reply (Tab-switch hijack). Shipped anyway per
  explicit request — re-recordable, and Rule B still guards collisions.
- *"Keep the divider but fix alignment."* Rejected per explicit user call
  (remove it). Fewer elements, fewer failure modes.
- *"Cards bug needs a rewrite."* Logic verified sound (binding writes
  through `@AppStorage`); the plausible defect is hit-testing, fixed with
  one modifier. If taps still misbehave on-matrix, the next suspect is a
  stale build, then master-off disabled state.

## Exact file changes

1. `ShortcutModels`: `TransformShortcuts.default` → Cmd+1/2/3;
   `defaultHoldToTalk` → Right Option (comment rewritten: Opt hold + Cmd
   transforms = different families, the policy-consistent pair;
   double-tap still works). Nothing else moves (modal preset, onboarding
   initial, reset all derive from these).
2. `IntelligencePane`: cards → `HStack` 3-across (equal widths), each
   title + detail + short example line; shared triplet + dead
   `levelDescription` deleted; `contentShape(Rectangle())` on card +
   chip buttons; transform guidance text ⌥1 → ⌘1.
3. `VisualizerMath`: drop divider chrome; add `workTextSlack = 6`,
   `workSpinnerGap = 8` (renamed — no divider left to gap);
   `workMinWidth = 96`; chrome = pad×2 + gap + spinner + slack.
4. `PillLayers`: delete divider layer + layout + `showOnly` line;
   update() positions spinner at label-right + gap; `workLayoutFrames`
   drops divider (label + spinner).
5. Tests: factory default renders Right ⌥; transform defaults are
   Cmd trio; factory-satisfies-policy re-pinned (Opt hold + Cmd trio);
   gate clean-triple baseline becomes Opt hold; width tests assert
   slack (width − text ≥ chrome) + new min; pill test asserts spinner
   snug (width − spinner.maxX ≤ pad + 1) and drops divider asserts;
   frame test drops divider ordering.

## Verification

- [ ] Build green; full unit green (UI smoke excluded — proven
  pre-existing failure).
- [ ] Matrix (user, FRESH Xcode Run — not a Finder launch): transforms
  fire first press, every press; cards tap 1:1 with checkmark following;
  pill shows `Cleanup`/`Polish`/`Concise`/`Professional` full-word,
  spinner snug right, no `|`; second press repaints fully (no stale text,
  no vanish); top slot by default.

## Risks

- Global Cmd+1/2/3 preempts in-app Tab switching while Oto runs
  (explicitly requested; re-recordable; stated in reply, not buried).
- Fresh-install hold is Right Option again (7e's Right-Command move
  reverted as its reason — Cmd transforms — took its place). Stored
  Right-Cmd holds keep working (advisory only, never migrated).
