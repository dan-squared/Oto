# Empty states — neutral chips, coloured icons

Status: implemented 2026-11-01 (user ask, with the reference's "Sync" empty
state: *"instead of making the buttons colorful make them like this image
give the icons color and make the color based on the pill color
selections"*). Corrected the same day: the icons looked colourless because
the first pass derived one accent from the *selected* pill colour, and the
default (graphite) resolves to neutral. The rule now: **three chips, three
pill-palette hues, always coloured** — *"only the icons … you should add a
colour to the icons only. Use the pill colours that are available already
in the code."*

## 1. What changed

The illustrative chip row (History, Dictionary, Snippets, Apple
Intelligence) used three pastel fills — violet, blue, green — as *chip
backgrounds*. That made the chips the loudest thing in a pane whose whole
job is to be quiet, and the hue had nothing to do with the app's own
colour language.

Now, following the reference:

- **Chip = neutral**: `wash` fill, `hairline` border, `ink` label. The chip
  is a container, not a decoration.
- **Icon = colour**: an 11 pt glyph tinted from one of the pill's own
  `PillColor` cases. Each row uses three — crimson, ocean, violet — so the
  icons carry the reference's three-hue rhythm using hues the app already
  defines. Nothing new is invented.
- **The primary action stays neutral** (`ink` plate, `ground` text); it was
  never coloured, and the reference confirms it.

## 2. Colour rule

`PillColor.accent(forDark:)`:

- light ground → `base` (the waist): deep enough for an 11 pt glyph on
  `wash` (≥ 3:1 for all five).
- dark ground → `tint` (the frost colour): the waist sinks into a dark
  card, the tint is the value the glass actually shows.
- graphite → `0.11` / `0.70` white pair, i.e. monochrome (unused by the
  chips now, kept so the function is total).

One source of truth: the same `PillPalette` the pill renders from, so a
palette change can never leave Settings behind.

## 3. Exact changes

- `Oto/Settings/OtoEmptyState.swift`: `OtoEmptyChip` carries `color:
  PillColor`; the chip renders neutral with the icon tinted from it.
- `Oto/UI/FlowBar/PillColor.swift`: `accent(forDark:)`.
- `Oto/UI/Theme/OtoPalette.swift`: `chipViolet`/`chipBlue`/`chipGreen`
  deleted (no other caller).
- `HistoryPane`, `DictionaryPane`, `SnippetsPane`, `IntelligencePane`: each
  chip names `color: .crimson / .ocean / .violet`.

## 4. Verification

Build + full test suite. The chip row is decorative (`.allowsHitTesting(false)`,
`accessibilityHidden(true)`), so no test asserted its colours; there is
nothing to re-pin. On device: the three icons must read as three distinct,
saturated hues on both light and dark panes, with the plates neutral.
