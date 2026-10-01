# Phase C — per-option fn copy table (v2, verified current)

Status: PLAN ONLY. Nothing implemented. Awaiting `execute` + the §1
matrix numbers.

Freshness (verified 2026-10-01, never from memory): ACP Xcode bridge
open (`Oto.xcodeproj`, scheme Oto). `SystemFnUsage` still
conservative-only (`Oto/Services/ShortcutRecorder.swift:261-288` —
every present integer → `.unknown`). Both caption surfaces read the
probe on appear and render `caption(for:)` with no per-option logic:
`Oto/Settings/ShortcutModal.swift:154` + `:209`,
`Oto/Onboarding/OnboardingView.swift:76` + `:304`. So Phase C touches
exactly one enum + its tests; both surfaces inherit. Parent plan
(`plan/fn-system-coexistence-and-doubletap-surface.md` Option A)
otherwise fully shipped; Options B/C stay rejected.

## 1. The one input only the user can provide

For each of the 4 "Press fn key to…" options
(System Settings → Keyboard), run and report ALL THREE columns:

| Settings option selected | `defaults read com.apple.HIToolbox AppleFnUsageType` | What a quick fn tap actually does |
|---|---|---|
| Show Emoji & Symbols | ? | ? |
| Start Dictation | ? | ? |
| Change Input Source | ? | ? |
| Do Nothing | ? | ? |

(Baseline known: current setting reads `0`.) The third column is
load-bearing, not decoration: the integer→meaning mapping is
established by TWO independent signals (selected label + observed
behavior). If they ever disagree, the integer maps to `.unknown` with
a note — never to the guessed option. Also report: any option that
yields no key at all (absent key = fifth mapping row → `.unknown`).

## 2. Exact file changes (after §1 lands)

1. `Oto/Services/ShortcutRecorder.swift`
   - `SystemFnUsage` gains `.emoji, .dictation, .inputSource, .none`
     (`.none` = Do Nothing).
   - `read` casts defensively (`as? Int`; a String or exotic plist
     type → `.unknown`) and maps ONLY confirmed integers; any
     unconfirmed integer, nil suite, or missing key → `.unknown`
     (fail-conservative preserved — future macOS values degrade to
     today's line, never to a wrong claim).
   - `caption(for:)` gains per-option strings (exact wording at
     implementation; every line names what works, since fn
     double-tap conversion is structurally impossible — the V6e line
     stays the `.unknown` text verbatim).
2. `OtoTests/ShortcutRecorderTests.swift`
   - Mapping pins: each confirmed integer → its case; unconfirmed
     integer (e.g. 999), nil suite, missing key, wrong-typed value →
     `.unknown`.
   - Literal caption pins per case (same style as today's
     `fnUsageCaptionIsConservativeToday`).
3. Nothing else. No modal/onboarding edits (wiring confirmed above);
   no dispatch/HID changes; no new state, no new permissions.

## 3. Verification (thorough)

- Build green; full suite green twice (proven flakes excepted).
- Device round, packaged Run, console live:
  1. Each of the 4 options → open modal → caption matches; same for
     the onboarding surface (second caption site — both must be
     screenshotted, not just the modal).
  2. Reopen persistence: set option, quit Oto, relaunch, reopen —
     caption still correct (read-on-appear, no Oto-side caching to
     go stale).
  3. Stale-window note: changing the option in Settings.app while
     Oto's modal sits open keeps the old line until reopen — copy
     only, self-heals; assert it heals, don't fix it.
  4. External keyboard smoke (if available): fn menu path unaffected.
- No catcher/dispatch re-run (untouched), standard fn tap/hold smoke
  per option stands.

## 4. Risks (each with its handling)

- **R1 shared integer.** If two options store one value, map it to the
  vaguest true statement covering both — never pick a side.
- **R2 cfprefsd staleness.** Freshly-changed options can read stale;
  worst case is one wrong caption line for one modal opening.
  Accepted, documented in §3.3's heal-check — not fixed (fixing
  means polling Apple's daemon; out of scope).
- **R3 macOS renumbering.** Major updates may move values; the
  `.unknown` default converts a renumber into the conservative line,
  not a lie. Re-run the §1 table yearly / on fn-copy bug reports.
- **R4 Dictation-option overlap.** With Apple's dictation on fn, two
  listeners coexist; captions stay inside the double-tap scope and
  never claim exclusivity over fn press behavior.
- **R5 scope creep.** Any per-option BEHAVIOR change (convert fn,
  consume, remap) is out — B/C rejected, copy only. If review asks
  for behavior, stop and re-plan instead of smuggling it in.
- Out of scope: 241-key identification (`plan/241-key-identification.md`),
  241-adjacent table gaps, external-keyboard-without-fn (hint path stands).
