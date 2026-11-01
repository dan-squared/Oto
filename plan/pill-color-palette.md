# Pill colour palette — black by default, five colours to choose

Status: implemented with this plan (user ask, 2026-11-01 17:5x: *"can we add
a colour change inside the setting … make the default black … but the user
will have a colour palette that they can choose"*). Revised the same day
after the user's palette review — see §7 for the final five and why green
and amber are gone.

Companion to `plan/pill-liquid-chrome-v3.md` (chrome: no outline, no clip).
That plan's geometry, sheen and clip contracts are untouched here; this one
only answers "which hue is the body".

## 1. Goal

1. The pill's default is **black** (graphite glass), not the shipped red.
2. Settings → General → Flow Bar gains a **Colour** row: a palette the user
   can pick from.
3. Picking a colour recolours the pill live, with no restart and no lag
   beyond one poll (150 ms).

## 2. Facts verified before designing

- The pill's red was **hard-coded** in `PillChrome`: five body stops
  (`bodyCap…bodyCore`), a `glassTint`, and a `scrimColor`. Nothing read a
  setting. Making it user-selectable means one of two things: a colour wheel,
  or a fixed palette whose entries the chrome can be *derived* from.
- The five stops are a **linear white mix of one base hue**: measured against
  the shipped values, `mix(red, white, 0.80/0.50/0.25/0.06/0)` reproduces
  `1.00/0.80/0.83 → 0.97/0.81/0.83`, `0.99/0.52/0.58 → 0.92/0.53/0.56`, etc.
  So the existing design *is* a one-parameter recipe (`depth`), which is
  exactly what a palette needs.
- Persistence follows `FlowBarPosition`: a `String`-raw-value enum, a
  `defaultsKey`, a `freshDefault` shared by the writer (Settings
  `@AppStorage`) and the reader (`current()`), plus a fallback for an unknown
  stored string.
- `@AppStorage` supports a `String`-backed `RawRepresentable` enum directly,
  so the pane needs no observable model and the "one store" rule holds (a
  scalar preference, not app state).
- The pill already re-reads per-render settings every 150 ms poll
  (`FlowBarPosition.current()`), and `applyChrome()` is the single funnel for
  chrome-level state (Reduce Transparency). Colour belongs in that funnel,
  not in a second code path.

## 3. Decisions

**Fixed five-colour palette, not a colour wheel.** The ramp is derived from
the waist hue, and a free picker can produce pills the design forbids: a pale
yellow waist erases the white bars, a neon hue turns the pale caps into
plastic. A fixed palette with comparable luminance (0.10–0.25 relative)
keeps white-bar contrast for every choice, and five swatches is one row in
Settings — the same footprint as the Position row.

Final palette (revised 2026-11-01, see §7 — the values below, not the
first-draft six):

| Case | Role | Waist (sRGB) | Tip depth | Frost tint |
|---|---|---|---|---|
| `graphite` | **default** — black glass | 0.10 / 0.10 / 0.11 | 0.22 | none |
| `crimson` | the shipped red | 0.85 / 0.07 / 0.13 | 0.80 | 0.95 / 0.10 / 0.15 |
| `pink` | soft rose | 0.86 / 0.28 / 0.50 | 0.76 | 0.98 / 0.46 / 0.66 |
| `violet` | purple | 0.42 / 0.16 / 0.88 | 0.72 | 0.52 / 0.24 / 0.98 |
| `ocean` | sky blue (hue ~199°) | 0.06 / 0.53 / 0.74 | 0.80 | 0.10 / 0.66 / 0.98 |

**Graphite is untinted and keeps a low tip depth.** Lightening black by 80 %
yields a silver capsule — that is not "black glass". Graphite therefore takes
`tipDepth 0.22` (subtle graphite ramp) and `tintColor = nil`
(plenty of liquid glass: the system material adapts to the wallpaper instead
of having a colour pushed through the blur). Its shape comes from the sheen
and the bars, which is how the near-black pill read before the red redesign.

**Density is the pill's, hue is the user's.** Alphas (0.16 / 0.34 / 0.52 /
0.66 / 0.74) and the nine mirrored locations are shared by all colours, so
switching hue never changes how solid the pill feels. Only the waist colour
and the tip mix move.

**One crossfade, one funnel.** `applyChrome()` compares the resolved colour
with the installed one and, on change, animates `tintGradient.colors` +
`bg.fillColor` over `PillChrome.colorMorphDuration` (0.22 s, ease-out). The
first install snaps (`setDisableActions`) — the pill must not fade in from a
default the user never picked. A repoll with the same colour does nothing, so
the 150 ms poll cannot restart the animation.

## 4. Exact changes

- **`Oto/UI/FlowBar/PillColor.swift`** (new): `PillColor` enum (raw values are
  persisted strings; `defaultsKey = "app.Oto.pillColor"`,
  `freshDefault = .graphite`, `current()`/`save()` with unknown-string
  fallback, `displayName`, `base`, `tipDepth`, `tint`, `swatch`) and
  `PillPalette` (the derived nine-stop ramp, `scrim`, `bodyColors(opaque:)`,
  `mix(_:toward:by:)`). `nonisolated` so the pill, the swatch and the tests
  can all build one.
- **`Oto/UI/FlowBar/PillLayers.swift`**: `PillChrome` loses the five red stops,
  `glassTint`, `scrimColor`, `bodyStops`, `bodyLocations`, `bodyColors` — they
  moved to `PillPalette`. It gains `colorMorphDuration`. `PillContentView`
  gains `colorProvider` (injectable, defaults to `PillColor.current()`),
  `activeColor`, reads the colour in `applyChrome()`, installs the palette in
  `init`, and exposes hooks: `rampWaistColor()`, `rampWaistAlpha()`,
  `rampStopCount()`, `frostTint()`, `veilColor()`.
- **`Oto/Settings/GeneralPane.swift`**: `@AppStorage("app.Oto.pillColor")`
  defaulting to `PillColor.freshDefault`, and a `Colour` row
  (`HStack` + `Spacer` + picker) in the Flow Bar section, same grammar as
  `Position`.
- **`Oto/Settings/PillColorPicker.swift`** (new): five 15 pt swatch buttons,
  hairline edge (a graphite chip needs one), selection ring at −3 pt padding,
  `.help()` and AX labels per colour.
- **Tests**: `OtoTests/FlowBar/PillColorTests.swift` (new — default is
  graphite, unknown string falls back, save/current round-trip, key pinned,
  distinct raw values/names, 9 stops for every colour with mirrored alphas,
  waist is densest, `opaque: true` is fully opaque everywhere, graphite is
  untinted and dark, chromatic waists keep their hue within 2 %, swatches are
  opaque and equal the waist). `PillLayersTests.colourChoiceReachesTheRampAndFrost`
  asserts the wiring: graphite → `frostTint() == nil`, ocean → blue waist +
  a tint, and a same-colour repoll is a no-op.

## 5. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` → BUILD
   SUCCEEDED.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests`
   → **625 tests in 64 suites passed**.
3. Two stale expectations from the 2026-11-01 wave recalibration
   (`VisualizerMathTests.smoothingIsFrameRateIndependent`,
   `LevelEngineTests.levelMatchesTheDBMapping`) were failing before this
   change; they now derive their expected values from
   `attackKeeper`/`releaseKeeper` and the dB-window constants instead of
   copied numbers.
4. On device (user): Settings → General → Flow Bar → Colour — five swatches,
   graphite selected on a fresh profile; picking another colour crossfades the
   pill within a frame or two; quitting and relaunching keeps it.

## 6. Risks / deferred

- **No agent-side look judgement.** Screen capture is TCC-denied in this
  environment, so "does graphite read as black glass on a real wallpaper" is
  the user's call. If it reads grey, the lever is `tipDepth` (lower) and
  `scrimAlpha` (higher) — not a second layer.
- **The brightest waists are the ones that were cut.** Green and amber sat
  inside the luminance band that keeps white bars legible over the ramp +
  veil, but that band was computed, not seen; the user removed both on
  review (§7). Blue and pink were re-picked inside the same band by
  calculation and then accepted on device. If a colour ever looks washed out,
  the fix is its `base`, not the shared alphas.
- A free colour picker stays out of scope (contrast guarantee, see §3). If it
  is ever wanted, it needs a legibility gate (luma clamp on the waist) first.

## 7. Palette review — the final five (2026-11-01, user)

The first draft shipped six (graphite, crimson, ocean, violet, moss, amber).
The user's review, with two reference images:

> "let's add a colour pink — soft pink … make the blue this kind of colour …
> and remove the orange colour and the green colour."

Changes, all inside `PillColor`:

- **`moss` and `amber` deleted.** Not hidden, not deprecated — no case, no
  swatch, no stored value. Keeping them "just in case" would have left two
  chips the user had rejected in the one row where every chip must be a
  choice they want.
- **`pink` added** — soft rose, waist `0.86 / 0.28 / 0.50` (hue 337°, white
  contrast 4.0 : 1). Deliberately not a hot magenta: the pill still has to
  read as glass, not as a notification badge.
- **`ocean` re-hued to the user's reference glass button.** The reference's
  own waist is `(57, 196, 253)` — hue 197°, relative luminance 0.47, on which
  the white bars would vanish. So the *hue* is kept and the *lightness* drops:
  waist `0.06 / 0.53 / 0.74` (hue ~199°, contrast 4.0 : 1), `tipDepth` raised
  to 0.80 so the caps land on `(0.81, 0.91, 0.95)` — close to the reference's
  pale tips `(0.73, 0.89, 0.98)`. The frost tint is the reference colour
  nearly verbatim, `0.10 / 0.66 / 0.98`; the tint is what the glass shows, so
  that is where the bright reference blue belongs.

**Case name stays `ocean`, not `sky`.** The raw value is the persisted
string and the rule is that raw values are never renamed; `ocean` for a
bright tropical-cyan blue reads correctly anyway. A profile that stored a
value which no longer exists falls back to `freshDefault` (graphite) —
benign, and covered by `PillColorTests`.

`PillLayersTests.colourChoiceReachesTheRampAndFrost` no longer pins a channel
literal for blue; it compares against `PillColor.ocean.base`, so re-hueing a
palette entry cannot silently fail a test that is only meant to check the
wiring.
