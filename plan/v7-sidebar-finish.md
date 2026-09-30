# V7: sidebar + settings-window finish (SDK-verified)

Status: **PLAN ONLY — nothing implemented.** Awaiting `execute`.
Supersedes `plan/v6b-sidebar-split-polish.md` (implemented, uncommitted) and
`plan/v6c-sidebar-refine.md` (half-implemented, uncommitted).

Verification sources: Xcode 27.0 workspace open via Xcode ACP
(`workspace-jBQm4csyP3` → `Oto.xcodeproj`, scheme `Oto`, test plan `Oto`,
destination My Mac / macOS 27.0, targets `Oto`, `OtoTests`, `OtoUITests`) and
the local SDK `MacOSX27.0.sdk`, deployment target 27.0. Every API below was
read out of `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` or
`SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` — line numbers are
from those files, not from memory.

---

## 0. Where the tree actually is (read this first)

- HEAD is `d724f5d` ("plan: V6b …"). Working tree = the V6b implementation
  (6-pane split, native `NavigationSplitView`, selection takeover, bigger
  catcher footer) **plus** part of V6c. **It does not compile.**
- Nothing is lost: Conductor checkpoint refs exist for this tree, and the
  branch/remote still point at `d724f5d`.
- One mechanical repair is already applied (not a design change): a duplicated
  `private struct SidebarRow: View {` line in `SettingsRoot.swift:121` left by
  an interrupted edit, which made the file unparseable. Nothing else touched.

Compile errors as of now (both are facts the old plan got wrong):

| Error | Cause | Fix |
|---|---|---|
| `cannot find 'NavigationSplitViewColumnVisibility' in scope` (`SettingsUIState.swift:35`) | That type does not exist in this SDK. The real type is `NavigationSplitViewVisibility` | §2.1 |
| `cannot find '$uiState' in scope` (`SettingsRoot.swift:67`) | `uiState` is a `let`, so no projected `Binding` | §2.2 |

---

## 1. Verified SDK facts (the load-bearing ones)

1. **`NavigationSplitViewVisibility`, not `…ColumnVisibility`.**
   `SwiftUI.swiftinterface:27541` — `public struct NavigationSplitViewVisibility: Equatable, Codable, Sendable`
   with statics `detailOnly`, `doubleColumn`, `all`, `automatic` (27542–27553).
   **It is not an `OptionSet`** → `contains(.sidebar)` does not exist. Hidden
   state must be derived as `visibility == .detailOnly`.
2. **Column-visibility initializers exist** for 2- and 3-column forms:
   `:27510`, `:27512` (2-col), `:27523`, `:27525` (3-col).
3. **`navigationSplitViewColumnWidth(min:ideal:max:)`** `:327` (single width
   overload `:325`). Used to lock the column at 210 so it cannot animate to a
   different width (one of the two "snap" causes).
4. **`toolbar(removing:)`** `:22851`; **`ToolbarDefaultItemKind.sidebarToggle`**
   `:22465` and **`.title`** `:22469` (macOS 15+). `.title` is the probe
   candidate for hiding the visible window title *without* emptying the title.
5. **`ToolbarTitleDisplayMode` has no `.hidden`** — `:27216`–`:27235` lists
   only `automatic`, `inline`, `inlineLarge` (`large` is
   `@available(macOS, unavailable)`). This is the hard proof that the earlier
   "dress the titlebar and hide the title" approach had no API behind it.
6. **Press feedback mechanism = `ButtonStyle`/`PrimitiveButtonStyle`.**
   `protocol ButtonStyle` `:13540`, `ButtonStyleConfiguration.isPressed`
   `:13555`, `protocol PrimitiveButtonStyle` `:10746`, `PlainButtonStyle`
   `:11258` (a `PrimitiveButtonStyle` that returns the label untouched).
   The in-tree `OtoPressable` uses
   `.simultaneousGesture(DragGesture(minimumDistance: 0))` — undocumented, does
   not fire on keyboard activation, and competes with the row's own tap
   gesture. Replaced (§2.3).
7. **No native hover effect on macOS.** `HoverEffect` is
   `@available(macOS, unavailable)` (`SwiftUICore…swiftinterface:2274`); the
   `.highlight` / `.lift` statics are iOS/tvOS/visionOS only (`:2277–2288`).
   `onHover(perform:)` (`SwiftUI…:8244`) is therefore the only macOS hover
   mechanism — the manual hover state stays, on purpose.
8. **`WindowResizability` has three cases**: `automatic`, `contentSize`, and
   **`contentMinSize`** — `:607`–`:620`, macOS 13+. `contentMinSize` is the
   documented fix for the resize-snap class (§2.4).
9. **No singular `Window` scene in this SDK.** Scene structs present:
   `Settings<Content>` `:533`, `MenuBarExtra` `:2092`, `WindowGroup<Content>`
   `:2510`, `UtilityWindow<Content>` `:19382`. `OpenWindowAction`
   (`:3777`) has `callAsFunction(id:)` `:3788` and value-based overloads
   `:3784`/`:3792`, but **no "focus the existing window" mode** → single-window
   discipline stays hand-rolled and must be pinned by a test (§2.5).
10. **`WindowGroup` title overloads**: `Text` `:2522`,
    `LocalizedStringKey` `:2528`, `StringProtocol` `:2529`, plus no-title
    `init(id:makeContent:)` `:2516`. So both "empty title" and "named title"
    are legal; only one of them can win visually (§2.5).
11. **`CommandGroupPlacement.sidebar` exists** `:27783` → "Show/Hide Sidebar"
    belongs in the View menu, natively.
12. `listRowInsets(_:)` `:1187` and `listRowInsets(_:_:)` `:1194` exist.
13. `Material` statics live in SwiftUICore (`:7995`–`:8017`: `regular`,
    `thick`, `thin`, `ultraThin`, `ultraThick`, `bar`). Not needed — the native
    sidebar vibrancy is strictly better here (§2.2).
14. `ToolbarItemPlacement.navigation` `:7773` is available on macOS → a native
    toolbar item can host the sidebar-reopen control (no overlay, no titlebar
    clutter).
15. The app is a **regular** app (`INFOPLIST_KEY_LSUIElement` is not set), so
    the View menu (and ⇧⌘S) exists whenever a window is open.
16. `toolbar(removing: .sidebarToggle)` in the tree is correct per fact 4 — the
    phantom ">>" button class is genuinely removed, not hidden.

---

## 2. Exact changes

### 2.1 Column state — the type that actually exists

`Oto/Settings/SettingsUIState.swift`

```swift
// Sidebar column visibility (owned here so the split view, the View-menu
// commands and the reopen control share one source).
var columnVisibility: NavigationSplitViewVisibility = .all   // was: the nonexistent type

/// True while the sidebar column is on screen. Pure — unit-tested.
/// NavigationSplitViewVisibility is not an OptionSet (SDK :27541), so this
/// is the only honest membership test.
var sidebarVisible: Bool { columnVisibility != .detailOnly }

func setSidebar(_ visible: Bool) {
    let next: NavigationSplitViewVisibility = visible ? .all : .detailOnly
    guard next != columnVisibility else { return }   // idempotent, no re-animate
    withAnimation(OtoMotion.settle) { columnVisibility = next }
}
```

### 2.2 Settings root — native rows, translucent indicator, no wash, no overlap

`Oto/Settings/SettingsRoot.swift`

1. `let uiState: SettingsUIState` → `@Bindable var uiState: SettingsUIState`.
   `@Observable` class, so the memberwise initializer keeps the same call site
   in `OtoApp` (`SettingsRoot(dispatch:uiState:login:…)`) — no other file
   changes. The other panes keep taking it as `let`; untouched.
2. Sidebar `List` changes:
   - **Delete** `.background(OtoPalette.wash.opacity(0.45))`. That wash is what
     makes the column look opaque; removing it lets the native sidebar
     vibrancy show through, which is literally "more transparent" and is
     automatically correct in both schemes. Keep
     `.scrollContentBackground(.hidden)` so the `List` paints no ground of its
     own.
   - Keep `.listStyle(.sidebar)`, `.toolbar(removing: .sidebarToggle)`,
     `.navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 210)`.
3. **Rows become native `Button`s** (replacing `Label` + `.onTapGesture`):
   ```swift
   Button { selection = item } label: { rowContent(item) }
       .buttonStyle(OtoBounce())          // press physics, §2.3
       .listRowBackground(fill)           // selection/hover surface
       .accessibilityLabel(item.title)
       .accessibilityAddTraits(selection == item ? [.isSelected] : [])
   ```
   Why: a `Button` gives the documented `isPressed` (needed for the bounce),
   the correct VoiceOver role, and keyboard activation. Selection stays a
   `@State` + explicit fills — the system accent selection is precisely what
   painted blue and bolded the text, proven by the V6b screenshots, and no
   tint/weight/`listRowBackground` combination talked it out of that.
4. Row metrics (final numbers):
   | Token | Value | Note |
   |---|---|---|
   | content height | 36 | your ask (was 32) |
   | label size | 14pt regular | your ask (+1px) |
   | icon frame | 16×16, 12pt medium | bounded, no overflow |
   | fill corner radius | 8, continuous | |
   | fill insets | horizontal 6, **vertical 4** | 44pt pitch → **8pt clear gap** between a hovered row and the selected pill (your "they are touching") |
   | selected fill | `white.opacity(0.85)` dark / `black.opacity(0.85)` light | explicit literals, never adaptive tokens (the light-mode white-pill bug) |
   | hover fill | `OtoPalette.hover`, unselected only | |
   | selected text/icon | `black` dark / `white` light | explicit |
   | unselected text | `OtoPalette.muted` | unchanged by hover — the "bold on hover" was a muted→ink contrast illusion, so removing the text shift removes the effect structurally |
   | unselected icon | white dark / `muted` light | your adaptive answer |
5. **Reopen control moves out of the `.overlay` into a native toolbar item.**
   The current `.overlay(alignment: .topLeading)` is a real bug: when the
   sidebar is hidden the button lands on top of the detail page title. Replace
   with, inside the sidebar closure:
   ```swift
   .toolbar {
       if !uiState.sidebarVisible {
           ToolbarItem(placement: .navigation) { OtoDoor(systemName: "sidebar.left", help: "Show sidebar") {
               uiState.setSidebar(true)
           } }
       }
   }
   ```
   The titlebar stays clean; nothing floats over content.
6. Root frame `.frame(width: 805, height: 621)` → `.frame(minWidth: 805, minHeight: 621)`
   (pairs with §2.4 so the window can grow and never tracks content).
7. Detail column untouched apart from the animation in §2.4.

### 2.3 Bounce — the documented press mechanism, applied once

`Oto/UI/Theme/OtoControls.swift`

- **Delete** `OtoPressable` (the `DragGesture` modifier) — replaced, not
  layered.
- Add:
  ```swift
  /// Press physics for every plain button: a small spring squish on click
  /// that reads as bounce. PrimitiveButtonStyle, so the label renders exactly
  /// as .plain does today (PlainButtonStyle is the same shape, SDK :11258)
  /// and `configuration.isPressed` is the documented press signal (:13555).
  /// Reduce Motion disables the scale entirely.
  struct OtoBounce: PrimitiveButtonStyle {
      let scale: CGFloat = 0.96
      func makeBody(configuration: Configuration) -> some View {
          configuration.label
              .scaleEffect(configuration.isPressed ? scale : 1)
              .animation(OtoMotion.reduced ? nil
                         : .spring(response: 0.25, dampingFraction: 0.55),
                         value: configuration.isPressed)
      }
  }
  ```
- Swap `.buttonStyle(.plain)` → `.buttonStyle(OtoBounce())` at all 9 in-app
  plain-button sites (`OtoControls.swift`, `SettingsRoot.swift`,
  `ShortcutModal.swift`, `OnboardingView.swift`). One physics for the whole app;
  catcher Copy/Cancel, modal Done, rail actions, onboarding Continue, sidebar
  rows and the reopen control all gain it for free. Sizes, fonts, radii and
  hover behavior are untouched.

### 2.4 Snap — two verified causes, two fixes

1. **Window tracks content.** `.windowResizability(.contentSize)` makes the
   window size a function of the content's ideal size, and the ideal size
   changes when the column hides → the window itself jumps. Switch to
   `.contentMinSize` (SDK `:620`, macOS 13+): opens at `defaultSize`
   (805×621), can grow, and no longer re-fits to content. Combined with the
   root `minWidth/minHeight` frame (§2.2.6) the panes — all of which already
   scroll — absorb the extra room.
2. **Detail reflows instantly while the column animates.** Every visibility
   change goes through `SettingsUIState.setSidebar` (§2.1), which wraps the
   mutation in `withAnimation(OtoMotion.settle)` so the content reflow is
   animated in step with the column instead of jumping.
3. The column width stays locked at 210 (min == ideal == max) so it cannot
   animate to a different width.

Motion cannot be screenshotted; smoothness is a human-matrix item (§4).

### 2.5 The window title, and how the window stays identifiable

The ask: "I'm not liking the Settings at the top — can we remove it?"
Fact 5 says there is no title-hiding display mode, so there are exactly three
options, and the probe picks the winner:

| | Mechanism | Keeps title for AX/Exposé/Window menu | Cost |
|---|---|---|---|
| **A (first choice)** | keep `WindowGroup("Settings", id:)`, add `.toolbar(removing: .title)` (`:22469`) | yes | may be a no-op for a window that has no toolbar — probe decides |
| B (fallback) | `WindowGroup("", id:)` (`:2529`) | no | guard predicate must change (§below) |
| C (rejected) | `.windowStyle(.hiddenTitleBar)` (`:12412`) | no | removes the traffic lights — not a Mac window anymore |

Single-window discipline (fact 9: no "focus existing" API), with a pinned,
unit-tested predicate extracted so it cannot rot:

```swift
enum SettingsWindowLocator {
    /// The one Settings window Oto owns, or nil.
    /// Predicate is a pure function of an NSWindow so it can be unit-tested
    /// against synthetic windows (no scene, no run loop).
    static func settingsWindow(in windows: [NSWindow]) -> NSWindow? { … }
}
```
- If A wins: predicate is `title == "Settings"` (unchanged, exact).
- If B wins: predicate is `styleMask.contains(.titled) && title.isEmpty
  && !(window is NSPanel)` — the onboarding window is AppKit with a real
  title, the catcher panels are `NSPanel`s, so the only titled+untitled
  window in the app is Settings.
- Both open paths (the ⌘-comma command and the menu-bar entry) call the same
  `reveal()` helper: existing → `makeKeyAndOrderFront` + `NSApp.activate`;
  none → `openWindow(id:)`. Unchanged semantics, now one tested function.

**New View-menu commands** (fact 11, fact 15):
```swift
CommandGroup(after: .sidebar) {
    Button("Show Sidebar") { uiState.setSidebar(true) }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(uiState.sidebarVisible)
    Button("Hide Sidebar") { uiState.setSidebar(false) }
        .keyboardShortcut("s", modifiers: [.control, .command])
        .disabled(!uiState.sidebarVisible)
}
```
Finder's exact pair, so muscle memory works, and the disabled state is honest
instead of silently doing nothing.

### 2.6 Selection translucency — the one tunable number

`Oto/UI/Theme/OtoPalette.swift` gains a single named constant so "tinted
translucent" is a one-number decision rather than a hunt:

```swift
/// Selected-row fill. 0.85 keeps the row unmistakable while letting the
/// sidebar material read through it. The probe screenshots 0.85 against a
/// lighter 0.18/0.10 wash; the user picks with their eyes.
nonisolated static let selectedFillOpacity: CGFloat = 0.85
```
Both schemes use the same alpha with opposite polarity, so the two looks stay
mirrored by construction. The probe ships both PNGs.

### 2.7 Cleanup

- **Delete** `OtoUITests/ProbeTests.swift` after the probe run (it is a
  throwaway that fails on purpose, and it is currently untracked).
- No other dead code: `grep` finds zero references to `WritingPane`,
  `PrivacyHistoryPane`, or `PaneSection` anywhere in `Oto/`, `OtoTests/`,
  `OtoUITests/`. The project's groups are file-system synchronized
  (`project.pbxproj:175,196,217`), so the four new pane files need no project
  edits.

---

## 3. Files touched (complete list)

| File | Change |
|---|---|
| `Oto/Settings/SettingsUIState.swift` | correct visibility type + `sidebarVisible` + `setSidebar` (§2.1) |
| `Oto/Settings/SettingsRoot.swift` | `@Bindable`, native `Button` rows, metrics, translucent fill, no wash, toolbar reopen control, min frame (§2.2) |
| `Oto/UI/Theme/OtoControls.swift` | `OtoBounce` replaces `OtoPressable`; 4 style swaps (§2.3) |
| `Oto/UI/Theme/OtoPalette.swift` | `selectedFillOpacity` (§2.6) |
| `Oto/App/OtoApp.swift` | `.contentMinSize`, title mechanism per probe, `SettingsWindowLocator` + `reveal()`, Show/Hide Sidebar commands (§2.4, §2.5) |
| `Oto/Settings/ShortcutModal.swift`, `Oto/Onboarding/OnboardingView.swift` | `.plain` → `OtoBounce()` (2 lines each) |
| `OtoTests/SettingsUIStateTests.swift` | column-state pins (§4) |
| `OtoTests/FlowBar/NoTargetModalTests.swift` | already updated for chrome 110 in the tree — verify, don't re-edit |
| `OtoUITests/SettingsUITests.swift` | six sidebar labels (already updated in the tree) — verify, don't re-edit |
| `OtoUITests/ProbeTests.swift` | extend → run → **delete** (§4) |

Backend, stores, coordinator, shortcut layer, catcher, pill, onboarding logic
and the menubar: **untouched**.

---

## 4. Execution order and verification

1. **Build first.** `xcodebuild -scheme Oto -destination 'platform=macOS' build`
   must go green before anything else — right now it does not, and the two
   errors in §0 are the gate.
2. **Probe (throwaway).** Extend `ProbeTests` to (a) print every `NSApp.windows`
   entry — `title`, `identifier`, class, `styleMask`, `frame` — after ⌘-comma,
   and (b) save screenshots to `.context/probe/` for: light sidebar, dark
   sidebar, hovered row next to the selected row, collapsed sidebar (toolbar
   item), title variant A, title variant B, and both selected-fill alphas.
   Read the dump, then **delete the probe file**.
3. **Apply the winner from §2.5/§2.6** using what the probe proved.
4. **Build green**, then
   `xcodebuild test -scheme Oto -destination 'platform=macOS'` — suite green
   twice (the flake protocol from earlier rounds stands: known host-crash and
   focus victims are re-run in isolation and reported honestly, never hidden).
5. **New pins** (cheap, pure, no hardware):
   - `columnVisibility == .all` on a fresh state; `sidebarVisible == true`;
     `setSidebar(false) == .detailOnly` and `sidebarVisible == false`;
     `setSidebar(true)` restores `.all`; a repeated `setSidebar` is a no-op.
   - `SettingsWindowLocator.settingsWindow(in:)` returns the Settings window and
     rejects an `NSPanel` and a titled window with a non-empty title (synthetic
     `NSWindow`s — no scene needed).
   - `OtoPalette.selectedFillOpacity` is in `(0, 1]` and the same value is used
     in both schemes (guards against a one-sided regression).
6. **Screenshots to the user** for sign-off on: sidebar both schemes, the
   8pt hover/indicator gap, the title, the collapsed state, and both pill
   alphas.
7. **Human matrix (cannot be automated):** collapse → reopen round trip,
   bounce feel on Copy / Cancel / Continue, hover without any text shift,
   window resize from the bottom-right corner, both schemes.

---

## 5. Risks and the honest caveats

1. **`toolbar(removing: .title)` may be a no-op** (it targets a toolbar item,
   and this window may have no toolbar). Fallback B costs the window's AX/Exposé
   name. Both are probed before I commit to either.
2. **`.contentMinSize` makes the Settings window user-resizable**, which it was
   not before (it was pinned by `.contentSize`). This is the native behavior
   and the fix for the snap, but it is a behavior change — flagged here so it
   is a decision, not a surprise. All six panes already scroll, so nothing
   breaks at small sizes (the minimum stays 805×621).
3. **Translucency over vibrancy stacks translucency on translucency** — the
   reason the probe ships both alphas and both backgrounds before I pick.
4. **Motion is not verifiable by screenshot.** Snap and bounce are verified by
   mechanism (animation-wrapped state change, locked column width, documented
   `isPressed`) and judged by you.
5. **The flake protocol stays honest:** the pre-existing rotating host-crash /
   focus failures are re-run in isolation and reported, never suppressed.
6. **One-way doors:** deleting `OtoPressable` and `ProbeTests` is a revert away
   (both are additive changes on top of `d724f5d`).

---

## 6. Open questions — my recommendation on each

| # | Question | Recommendation |
|---|---|---|
| Q1 | Selected-pill strength: `0.85` (near-solid chip) or a lighter `0.18` white / `0.10` black wash? | **0.85, mirrored** — it stays unmistakable with no accent color, and the probe ships both so you can overrule me with one look |
| Q2 | Hide the title via `.toolbar(removing: .title)` (keeps the name in Exposé/AX) or empty title (clean everywhere)? | **A, fall back to B** — keeping the name is worth more than the Exposé label |
| Q3 | Make the Settings window user-resizable (`.contentMinSize`) as part of the snap fix? | **Yes** — it is the documented mechanism and every pane already scrolls |
| Q4 | Toolbar reopen control vs. the current floating overlay? | **Toolbar item** — the overlay overlaps the page title when the sidebar is hidden, which is a visible bug today |
| Q5 | Rows as native `Button`s (needed for press physics + correct VoiceOver role) — any objection? | **No objection expected** — the pixels are unchanged; only the press and AX layers change |
