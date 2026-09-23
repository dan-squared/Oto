# Catcher buttons v7 — spring feel, no hover resize — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Scope: press/hover motion on the two catcher buttons ONLY. Stroke
(mask), morph, palette, divert: untouched, unquestioned.

## 1. Feel spec (user directives, exact)

- ✕: NO resize on hover (drop the 1.06 grow). Hover = brighten
  only (dim→ink, 0.12s easeOut — kept). Click = playful squish
  that bounces back: scale → ~0.88 with a bouncy spring, subtle
  (small displacement, never a full press-and-hold look).
- Copy: squish-and-bounce on BOTH hover and click, subtle:
  hover → ~0.97 spring-back on leave; click → ~0.92 spring-back
  on release. Rest appearance pixel-identical to today's gray
  bordered button (padding, radius, tint) — only motion changes;
  "Copied" disabled behavior unchanged.
- Reduce Motion: springs collapse to end values (system behavior,
  no custom gate needed — stated, verified by inspection matrix).

## 2. API choice (researched, current SDK 27.0)

Explicit `.spring(response:dampingFraction:)` over the presets:
`.bouncy` is too bouncy for chrome, `.snappy`/`.smooth` are
under-damped for "playful". Chosen values — ✕ press:
`response: 0.22, dampingFraction: 0.5` (quick squish, one visible
rebound); Copy hover/press: `response: 0.28, dampingFraction: 0.55`
softer, one rebound. Displacement does the "subtle" (0.88/0.92/
0.97), the spring does the "playful". All drive `scaleEffect`
bound to `configuration.isPressed` / hover bool — the standard
ButtonStyle motion pattern, building on SDK 27 (compile = currency
proof). No custom gesture recognizers, no timers, no AppKit.

## 3. Exact file changes

1. `Oto/UI/Scratchpad/NoTargetModal.swift` —
   a. `CatcherXStyle`: remove hover scale (foreground-only hover);
      press path becomes spring squish:
      `scaleEffect(isPressed ? 0.88 : 1.0)` +
      `.animation(.spring(response: 0.22, dampingFraction: 0.5),
      value: isPressed)`. Hover brighten + 0.12s easeOut kept.
   b. NEW `CatcherCopyStyle: ButtonStyle` (same file): draws the
      current gray rounded button identically at rest
      (system `.bordered` look: secondary fill, corner radius to
      match, same padding — review-gated pixel parity), motion:
      `scaleEffect(pressed ? 0.92 : hovering ? 0.97 : 1.0)` +
      `.animation(.spring(response: 0.28, dampingFraction: 0.55),
      value: …)` on both drivers; `hovering` fed by the view's
      existing `.onHover` pattern (new `@State copyHovering`).
      Disabled ("Copied") state passes through untouched.
   c. View wires both styles; nothing else in the file moves.
2. Tests: none added, none changed (spring motion is
   feel-matrix-only — no meaningful headless assertion exists;
   compile + suite-green is the gate). Stated so the count (272)
   staying flat is expected, not a miss.

## 4. Verification steps

- Build clean zero warnings; full suite green ONCE (no test
  changes — the twice-rule binds merges, this rides the next one).
- Device feel matrix (packaged `.app`): ✕ hover = brighten, zero
  size change; ✕ click = squish + single rebound; Copy hover =
  faint squish-back on leave; Copy click = bounce on release;
  RM = instant end-states; rapid click-spam never sticks scaled
  (spring re-targeting); light + dark identical motion.
- One retune of constants max (response/damping/displacement),
  then pin — same discipline as the wave retunes.

## 5. Risks — single risk: custom Copy style drifting from system
`.bordered` pixels (radius/padding/tint). Mitigated by
review-gated parity + matrix; fallback is reverting Copy to
`.bordered` and keeping springs on ✕ only (one-line).

## 6. Open questions — none. `execute` builds §3.
