# Settings chrome, Intelligence empty state, copy feedback, hold-vs-combo

Status: PLANNED + approved to implement (user: "plan this meticulously and
implement these details", verify with screenshots).

## Reported problems (from screenshots 2026-10-29 15:01–15:09)

1. The pane's master control (`+` for Dictionary/Snippets, switch for
   History) renders **immediately after the back/forward capsule** instead of
   the window's top-right, and the switch is clipped/masked by the toolbar
   layer.
2. The `+` **leaks into panes that have no accessory** (General, Intelligence,
   Privacy, About, Dictation).
3. Intelligence is **on by default**, has no empty state, and its history
   mirror reads the legacy key (`app.Oto.intelligenceEnabled`) while the pane
   writes `app.Oto.cleanupEnabled` — the two can disagree.
4. The info popover's arrow points at the **row**, not at the `i` button that
   opened it.
5. Copy has **no response**: the row icon never changes, and the only
   feedback is a line at the bottom of the pane.
6. Holding a bare modifier (e.g. ⌘) for push-to-talk, then pressing a combo
   that uses it (⌘1 polish), **strands the dictation session**: the HID layer
   marks "combination use" and swallows the release, but nothing cancels the
   session that already began.

## Facts verified in the tree

- `SettingsRoot` renders the accessory as `ToolbarItem(.primaryAction)`
  (SettingsRoot.swift 326–329). The window removes its title and is
  full-bleed, so the item is laid out next to `.navigation` items — measured
  in the screenshots, not a guess.
- Sidebar selection is `OtoSettingsList(selection: $selection)`: a direct
  `@Binding`, so `navigate(to:)` (the only place that calls
  `chrome.publish(nil)`) is **bypassed** by every sidebar click. That is why
  the `+` survives into General/Intelligence. Back/forward history has the
  same hole (sidebar clicks are never recorded).
- `IntelligencePane` writes `@AppStorage(CleanupSettings.enabledKey)` default
  `true`; `HistoryPane` mirrors `@AppStorage(IntelligenceSettings.enabledKey)`
  default `true` (legacy key). `CleanupBehavior.current` falls back to
  `enabled = true`; `TransformRunner.execute` and cleanup both gate on it.
- `OtoRowActions` rows attach `.popover` to the **row HStack** in all three
  panes, so the anchor is the row's leading edge.
- `HIDEventMonitor.decideRouted` marks `usedInCombination` on any key/mouse
  down (`markAllHoldsCombinationUse`) and `ModifierHoldState` then swallows the
  release. It emits **nothing**, so `ShortcutDispatch` never learns that the
  hold became a combo. The session begun on modifier-down is never finished
  and never cancelled. `cancelFreshHoldMicroSession` only covers sessions
  younger than 1 s, so a long hold is stranded by construction.
- `ShortcutTransition` is `ignore / begin / finish / reset`
  (Models/ShortcutModels.swift); `route` handles all four.
- The transform path already waits `comboSettle` (100 ms) and then cancels a
  fresh hold micro-session, then vetoes if dictation is still live. With the
  hold cancelled at combination time, a combo pressed during a long hold now
  resolves deterministically: dictation is discarded (pre-insertion) and the
  transform runs.

## Design

### 1. Accessory: a real top-right strip, not a toolbar item

- Delete the `.primaryAction` toolbar item. Keep the `.navigation` group.
- Render the accessory in `detailContent` with
  `.safeAreaInset(edge: .top, alignment: .trailing, spacing: 0)` when
  `chrome.accessory != nil`: 36 pt strip, trailing padding 16, control
  vertically centred. The pane column therefore has its own top-right corner,
  below the toolbar, and content is pushed down instead of being overlapped.
  No clipping, no masking, no dependence on toolbar layout.
- The switch uses `.toggleStyle(.switch).controlSize(.small)`; the action uses
  the existing glass circle (macOS 26 `.buttonStyle(.glass)`, fallback
  bordered). Both keep `.help` + `.accessibilityLabel`.

### 2. One selection path

- Add `private func select(_ pane: SettingsPane)` in `SettingsRoot`: clears
  the accessory, sets `selection`, records the visit (history stack), then the
  pane's `onAppear` publishes its own accessory.
- The sidebar binding becomes a computed `Binding` whose setter calls
  `select(_:)`; `navigate(to:)` delegates to it; back/forward keep their
  existing direct moves (no new visit).
- This fixes both the leak and the unrecorded sidebar visits.

### 3. Intelligence: off by default, empty state, top-right switch

- Default off: `@AppStorage(CleanupSettings.enabledKey) private var enabled =
  false`, and `CleanupBehavior.current` fallback becomes `enabled = false`.
  Absent keys ⇒ off + None (no behaviour change at dictation time: level
  defaults to None; transforms were already gated on `enabled`).
- `HistoryPane` mirror switches to `CleanupSettings.enabledKey`, default
  `false` — one key, one truth.
- Intelligence publishes the same `.toggle` accessory as History, routed
  through a `setEnabled(_:)` that writes the `@AppStorage` value.
- Empty state (when `!enabled`), same `OtoEmptyState` composition:
  - symbol `sparkles`, title "Apple Intelligence is off"
  - message: "Oto can tidy your words on this Mac — fillers, grammar, a light
    rewrite. Nothing is uploaded."
  - chips: "Cleanup" (violet), "Transforms" (blue), "On-device" (green)
  - CTA "Turn On Apple Intelligence" → `enabled = true`
  - footnote: "Runs on this Mac's Neural Engine. Turn it off anytime."
  - when `availability != .available`: the availability copy replaces the
    message and there is no CTA (never promise a switch that cannot work).
- Enabled state keeps the existing form unchanged.

### 4. Info popover anchored to the eye

- Move `.popover(...)` from the row `HStack` onto the `info.circle`
  `OtoRowButton` in Dictionary, Snippets and History. The arrow now points at
  the button that opened it (recorder vocabulary unchanged: 252 pt,
  ultraThinMaterial, radius 20, `Close esc`).

### 5. Copy responds where the click happened

- History and Snippets keep a `copiedID: UUID?` + reset task. A successful
  write sets it; the row's copy button renders `checkmark` (tone `.ok`) with
  help "Copied" for 1.2 s, then returns to `doc.on.doc`. The existing
  bottom-of-pane feedback line stays (it names the paste step).
- No clipboard semantics change: the overwrite guard still runs first; only a
  real write flashes the tick.

### 6. Hold-to-talk vs. combination (the risky one)

Rule: **another key/mouse-down while a bare-modifier hold is down means the
hold was never dictation.** It is discarded (cancel, pre-insertion), not
finished (never inserts), and the combo keeps its normal meaning.

- `ShortcutEvent` gains `case combinationBegan` ("another input arrived while
  this slot's modifier was held"). Equality updated.
- `HIDEventMonitor.markAllHoldsCombinationUse()` returns the first slot that
  transitioned from clean → combination. `decideRouted` returns it as a fourth
  element; `handle` dispatches `.combinationBegan` for that slot **before** the
  primary emit (so a function-key slot's own event is unaffected). Only the
  first other input emits — later ones are already marked.
- `HotkeyTransitionState.step(.combinationBegan)`:
  - `.holdToTalk` while down → `isDown = false`, return `.cancel`;
  - otherwise → `.ignore` (hands-free keeps running: that is its point).
- `ShortcutTransition` gains `.cancel`; `ShortcutDispatch.route(.cancel)` uses
  a **generation-gated** cancel (`beginGeneration` / `beginSettledThrough`,
  the same gate the double-tap conversion uses) so a cancel that lands before
  the begin's ID is stored still cancels the session. `holdTap.reset()` so a
  discarded press cannot pair with the next tap.
- The monitor still swallows the release (typing Option-U never dictates), and
  the transition state has already forgotten the press, so no double finish.
- The transform path is unchanged: its 100 ms settle now finds no live hold
  and runs; `cancelFreshHoldMicroSession` stays as the race backstop.
- Bare-fn keeps its own confirmation path (unchanged).

### 7. Verification

- Unit tests:
  - `HotkeyTransitionStateTests`: combinationBegan cancels a hold, ignores
    hands-free, ignores when up.
  - `HIDDecideDualTests`: combination emits `.combinationBegan` for the held
    slot exactly once, then the release emits nothing; hands-free slot also
    receives it (dispatch ignores by mode).
  - `DictationCoordinatorTests`/cleanup default test: absent key ⇒
    `enabled = false`.
  - `SettingsChromeTests`: accessory is cleared by `select`, published by the
    pane, and a toggle closure writes through.
- Build + full `OtoTests`.
- Screenshots via the in-app probe (window `contentView` capture, light and
  dark), extended with:
  - `OTO_SETTINGS_PANES=general,dictionary,snippets,history,intelligence` walks
    panes after `settings.show()`;
  - `OTO_SETTINGS_INFO=1` opens the first row's info popover (probe
    notification, DEBUG-only);
  - `OTO_SETTINGS_COPY=1` copies the first row and captures the tick.
- Check against the report: accessory at the detail column's top-right on
  Dictionary/History/Intelligence and **absent** on General/Privacy/About;
  Intelligence empty state at default; popover arrow on the `i`; tick after
  copy.

## Risks / deferred

- `safeAreaInset` reserves a strip only when an accessory exists, so panes
  without one keep today's pixels; panes with one lose 36 pt of content height
  (scrollable, acceptable).
- Default-off Intelligence changes fresh-install UI only; explicit user values
  and the legacy migration are untouched.
- Combination-cancel discards a live dictation if the user presses any key
  while holding the talk modifier. That is the existing intent (release was
  already swallowed); the difference is that the session no longer sticks.
- Mouse clicks during a hold also cancel (consistent with the existing
  combination rule). Recoverable: nothing was inserted.

## Open questions (defaults chosen, not blocking)

1. Should the accessory strip also carry a title? No — the sidebar names the
   pane.
2. Copy tick duration 1.2 s — long enough to read, short enough to retry.
