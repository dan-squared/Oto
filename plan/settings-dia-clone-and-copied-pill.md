# Settings + onboarding Dia-clone rebuild + over-limit Copied-pill fix

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. User asks locked in

1. Onboarding title bar, alignment, and buttons must match the three
   reference screenshots (`.context/attachments/Lw6FqT|WXkbGQ|PCSHyp/image.png`).
2. `https://github.com/driceroland/Search` cloned (`.context/search-ref`,
   depth-1) and analyzed for UI rules, spacing, and settings — copy the
   pills, buttons, sidebar, and onboarding exactly.
3. This plan, with file:line references, for rebuilding Oto's Settings
   UI and onboarding.
4. The "… Copied" pill misfit: center it, pad it, text becomes just
   `Copied`.
5. How the repo built settings (verdict: NOT native — §1.5).
6. Latest-SwiftUI-only implementation; backends untouched.

Prior locks kept: onboarding has NO Skip (reference has one —
deliberate divergence, stated in §4.6), 620px-class compact window,
menubar re-run, Right-⌥ hold default, empty hands-free default.

## 1. What the reference repo is (verified, not assumed)

Native SwiftUI + AppKit browser (`Package.swift`: swift-tools 6.0,
`.macOS(.v14)`, Swift 5 language mode, 99 files under
`Sources/Search`). All refs below are `.context/search-ref/Sources/Search/`.

### 1.1 Palette — `Design.swift:13-59`

Ten named colors as **light/dark pairs** resolving against the window's
appearance (`NSColor(name:)` + `bestMatch`, never a cached bool):

| token | light | dark | use |
|---|---|---|---|
| ground | 1.0 | 0.11 | window/canvas |
| ink | 0.09 | 0.93 | text, filled controls |
| muted | 0.55 | 0.58 | secondary text |
| faint | 0.83 | 0.32 | tertiary, thumbs-off |
| hairline | 0.91 | 0.20 | 1pt strokes, rules |
| wash | 0.937 | 0.175 | tracks, fields, live tab |
| pinLive | 0.90 | 0.21 | selected pin |
| hover | 0.965 | 0.15 | hover fill |
| safe / unsafe | green / amber pairs | link security |

Rule to copy: **nothing outside the palette knows light from dark** —
views use tokens; the app object owns one `Look` (light/dark/system →
`NSApp.appearance`, applied async-next-runloop, `Design.swift:77-99`).

### 1.2 Metrics — `Design.swift:102-145`

Measured constants, never magic numbers in views: `lights 100`
(traffic-light run 19→79 + equal air), `strip 52`, `bare 34`,
`side 232` (min 176, max 440), `tabWidth 186`, `fieldWidth 560`.
Discipline to copy: every repeated number becomes one named constant.

### 1.3 Motion — `Design.swift:152-170`

One family: `glide` (spring 0.34/0.82, place-to-place), `settle`
(0.30/0.86, arrive/leave), `quick` (easeOut 0.14, hovers). Reduce
Motion → all nil (immediate). Single source, used everywhere.

### 1.4 Main window — `App.swift:40-45`, `Windows.swift:164-211`

`Window("Search", id:)` + `.windowStyle(.hiddenTitleBar)` +
`.defaultSize(1180×780)`. Extra windows are AppKit `NSWindow` +
`NSHostingView` (`.fullSizeContentView`, `titlebarAppearsTransparent`,
hidden title, ground bg, `tabbingMode .disallowed`). Resting
(hand-drawn, lights-behind) traffic lights: `App.swift:895-904`.
**This is the title bar in the screenshots**: hidden titlebar + grown
52pt strip carrying lights + tab row as one surface.

### 1.5 Settings is NOT native (user's suspicion: confirmed)

`SettingsPanel` (`Settings.swift:8-69`) is a **custom 660×500 card**
(168 rail + 1pt hairline + content; rounded-16 continuous, hairline
stroke, shadow black-16% r34 y12) presented in a **`.sheet`**
(`App.swift:540`: `sheet { SettingsPanel }`). No `Settings` scene, no
`TabView`, no `NavigationSplitView` anywhere in the repo (grepped —
zero hits). Rail rows (`PageRow`, `:92-121`): 30pt, 12pt icon in 16pt
column, 13pt title (medium when on), selected = ground fill + shadow +
ink text, hover ink-75%. Content (`:126-150`): 17pt semibold title +
`Door` xmark + `ScrollView` of `Caption` + `Card(Line + Rule)` groups.
Controls: `Switch` 30×18 ink/faint (`:781-798`), `Segmented` wash
track + sliding ground thumb via `matchedGeometryEffect` + shadow
(`:740-777`), `Pill` 11.5pt h10/v5 capsule — outline hairline, filled =
ink bg + ground text (`:859-889`), `Hunt` wash rounded-10 field
(`Plate.swift:150-183`), `Quick` mini-capsule (`Plate.swift:200-222`),
`Key` keycap wash rounded-6 minW44 (`Welcome.swift:417-433`), `Door`
26×26 rounded-8 hover (`Side.swift:797-828`).

### 1.6 Welcome is an overlay, not a window (`App.swift:547`)

`if browser.welcoming { WelcomePanel }.ignoresSafeArea()` over the
main window + `Motion.settle`; done = `prefs.welcomed = true`
(`Welcome.swift:273-276`). So the screenshots' traffic lights are the
**main window's** chrome behind the overlay. Panel (`Welcome.swift:31-58`):
ground ignoresSafeArea, content maxWidth **520**, padding 40,
asymmetric slide ±40 + opacity keyed `.id(page)`. Hero: mark + 34pt
medium title + 14.5pt muted body (lineSpacing 3, maxW 400). Page
heading (`:278-289`): 26pt medium + 14pt muted lineSpacing 2.
Footer (`:195-223`): 6pt dots (ink vs faint-60%, spacing 6), Back/Skip
plain 13pt muted, `Big` capsule 13pt medium h16/v9 (filled = ink bg +
ground text; unfilled = wash + hover) + `.keyboardShortcut(.defaultAction)`.
Choice rows (`:332-353`): 13.5 ink / 11.5 faint, row spacing 12,
section spacing 22/14. `Way` cards (`:357-415`): mini window drawings,
chosen = wash fill + ink-35% stroke.

## 2. Mapping onto Oto (decisions, conflicts stated)

- **Oto has no main window** (menu-bar app), so the Search pattern maps
  by surface, not by hierarchy:
  - *Settings* → keep the **native `Settings` scene** (Cmd-comma /
    `SettingsLink` targeting, house rule "no custom traffic lights",
    `START_HERE_PRODUCT.md`
    native-Settings mandate). The scene keeps native chrome; its
    **content** becomes the Search rail clone (rail + hairline +
    pages). No sheet (no parent window exists). The "sidebar" ask IS
    this rail — Oto has no browser sidebar to clone; Flow Bar untouched.
  - *Onboarding* → already AppKit-hosted (`OnboardingWindowController`);
    dress it toward the reference: `titlebarAppearsTransparent` +
    hidden title + ground bg + 520 column + 26/14pt type + dots/Back/Big
    footer. Standard live lights stay (house rule — Search's hand-drawn
    resting lights are NOT cloned: they need titlebar-view injection,
    fragile against the native scene).
- **Colors verbatim**: Theme kit copies the §1.1 pair values exactly
  for Settings + onboarding surfaces (user: "copy exactly that"). The
  pill GPU renderer keeps its tuned near-black (0.055) — out of scope
  except the message label styling in §3.
- **Type verbatim**: 13 / 13.5 / 11.5 / 17 / 26 / 34pt sizes + weights +
  lineSpacings from §1.5–1.6. No `.title`/`.headline` semantic sizes in
  new code (reference uses explicit `.system(size:)` everywhere).
- **Motion**: adopt glide/settle/quick + Reduce-Motion nil-gating for
  NEW code only. Pill/catcher springs (0.15–0.28s family) are tuned and
  tested — never retuned here.
- **No-Skip stands** against the reference (locked ask): footer is
  dots + Back + Big(Continue/Finish).

## 3. Over-limit Copied-pill: root cause + fix (2 lines + test retarget)

Root cause, both in `Oto/UI/FlowBar/FlowBarController.swift`:
(1) `:343` latches greedy filler — `CatcherText.pillWords(text)` =
leading words + `"… Copied"` measured to 76pt (`NoTargetModal.swift:54-77`);
(2) `:289` renders it with `centerText: false` → a long LEFT-aligned
string in a fixed-size pill. Exactly the reported symptom.

Fix (render path `PillLayers.swift:373-376` already centers + clips —
untouched):
1. `:343` → `overLimitText = "Copied"`.
2. `:289` → `centerText: projection.state == .message` (message centers
   in the symmetric ±8.25 label frame — centered + padded by
   construction; width unchanged, still no resize per design).
3. Delete now-dead `CatcherText.pillWords` (grep-gated, sole caller).
4. Deliberate test updates: delete `NoTargetModalTests.pillWordsFitPillWidth`
   (`:169-183`, incl. the `"hi… Copied"` pin); extend
   `FlowBarControllerTests.overLimitFailureShowsCopiedPillThenHides`
   (`:138-160`) to assert the latched text is exactly `"Copied"`;
   fix the stale comment at `VisualizerMathTests:133`. Nothing else
   in `PillLayersTests` / controller tests touches this path (all pass
   `text: nil`).

## 4. Exact file changes (views only — same stores/dispatch/gate calls)

New `Oto/UI/Theme/` kit (backend-free SwiftUI; zero service imports):
1. `OtoPalette.swift` — 8 tokens as light/dark `NSColor` pairs +
   `Color` twins, `bestMatch` resolution (Search `pair()` pattern).
2. `OtoMotion.swift` — glide/settle/quick + `reduced` flag
   (`NSWorkspace.accessibilityDisplayShouldReduceMotion`).
3. `OtoControls.swift` — `OtoPill`, `OtoBig`, `OtoSwitch` (30×18),
   `OtoSegmented` (matchedGeometryEffect thumb), `OtoDoor` (26×26),
   `OtoKey` (keycap, minW44), `OtoHunt`, `OtoQuick` — numbers from §1.5.
4. `OtoPlate.swift` — `OtoCard` (r11) + `OtoRule` (inset 14) +
   `OtoLine` (title 13 / detail 11.5, h14/v11) + `OtoCaption`.

Rebuilds (same view-models, same call sites):
5. `SettingsRoot.swift` — rail layout (168 rail + hairline + content,
   700×540 fixed; +40×+40 over Search's 660×500 for Oto's recorder
   rows), `PageRow` pills, persisted page key untouched in spirit
   (keep per-page state where it lives today). **Toolbar `TabView`
   dies with this** — deliberate: Cmd-comma/`SettingsLink` target the
   scene, not the tab control, so platform integration is unchanged.
6. Dictation/Writing/Privacy/General panes — re-expressed as
   Caption + Card + Line rows with OtoControls; **every binding, gate,
   recorder, and prepare call byte-identical** (KeycapField, dispatch
   gate, `PermissionsManager`, `SpeechAssetPreparer` as today).
7. `OnboardingView.swift` — reference restyle (§2): ground
   ignoresSafeArea, 520 column, title/body sizes, Big footer buttons,
   asymmetric transitions; controller adds transparent-titlebar
   dressing. Pages/copy/gate logic untouched.
8. `ShortcutModal.swift` — reskin only: cards → OtoCard, rows →
   OtoLine, footer → OtoPill/OtoBig. Staging/gate/swap logic untouched.
9. Catcher (`NoTargetModalView`) — reskin only: Copy → filled OtoPill
   ("Copy"/"Copied"), ✕ → OtoDoor, palette tokens; geometry, mask,
   timings, auto-close untouched. (Prior spacing-only constraint is
   superseded by this clone ask for buttons/pills specifically —
   spacing values stay as built.)
10. §3 Copied fix.

Tests: palette pair-resolution test (light/dark component values under
aqua/darkAqua); §3 retargets; full suites must stay green. No
appearance-snapshot tests (window-server dependent — device matrix
owns pixels).

## 5. SDK verification (`MacOSX27.0.sdk`, Xcode 27.0 27A266a)

Newly-adopted APIs confirmed present: `matchedGeometryEffect` ×1,
`strokeBorder` ×8, `contentShape` ×2 (`SwiftUICore…arm64e…swiftinterface`);
`sheet`, `scrollIndicators`, `onHover`, `SettingsLink`, `WindowGroup`
(previously verified). Continuous rounded corners + Capsule already
used in-tree. No new entitlements; no private API; no dependency.

## 6. Verification

- Build green; suite green twice (environmental XCTWaiter-flake
  protocol stands: clean-tree rerun if it strikes).
- Screenshot matrix (light + dark): Settings rail vs §1.5 numbers,
  onboarding vs reference rhythm, `Copied` pill centered, catcher
  reskin. Full catcher + shortcut + dictation rounds re-run (views
  changed, backends didn't — trust but verify: record/swap/prepare/
  over-limit dictate/insert/void-catcher/Copy-close).

## 7. Risks / non-goals

- Native Settings chrome stays (titlebar + lights): the reference's
  hidden-titlebar look is NOT cloned there — undressable scene +
  house rule. Stated, not snuck.
- Settings fixed 700×540: per-page `ScrollView` (reference has one)
  absorbs small-screen overflow; matrix proves it.
- `Form`/grouped style, toolbar tabs, and all custom v7 button motion
  in rebuilt surfaces are replaced by the Theme kit — one visual
  language afterward, no half-migrated rows (plan covers all four
  panes + modal + catcher button in one change for exactly this reason).
- Backends (speech, insertion, HID/Carbon, history, duck, flow
  controller) are call-identical; any behavioral diff found in review
  blocks the change.

## 8. Open questions

One: §2 "colors verbatim" — recommended YES (pairs carry both schemes,
so light mode stays correct). Say `execute` to build as specced.
