# Settings: full-height sidebar behind the traffic lights + recorder glow

Status: PLANNED (not implemented). Awaiting "execute".

## Goal

1. **Sidebar reaches the top of the window.** In the Firstlight reference the
   sidebar material runs the full height of the window and the traffic lights
   sit *on* it. Oto's sidebar starts 52 pt below the top, under a separate dark
   titlebar band.
2. **The shortcut recorder answers on the glass, not in a box.** When a
   combination is refused, the recorder popover tints its upper section red and
   fades to clear — no inset red border. When a combination lands, the same
   wash flashes green.

## Specification sources

- User screenshots, 2026-10-29: Oto current state, Firstlight settings
  (sidebar behind traffic lights), Firstlight shortcut recorder (red glow).
- Firstlight source in `~/Downloads/Firstlight-source`:
  - `mac/App/Interface/Settings/SettingsWindowController.swift` — window shape:
    `.fullSizeContentView`, `titlebarVisibility .hidden`,
    `titlebarAppearsTransparent`, `.unified` toolbar, and **the
    `NSSplitViewController` is the window's `contentViewController`**.
  - `mac/App/Interface/Settings/HotkeyRecorder.swift` — the glow: a
    `LinearGradient` from `Color.green.opacity(0.3)` at `.top` to clear at
    `.bottom`, applied as the background of the popover's key section only,
    `easeOut(0.1)` in / `easeOut(0.38)` out, red copy for a refusal.
- Local SDK: `MacOSX27.0.sdk`, Xcode 27.1, deployment target 27.0 (verified in
  `Oto.xcodeproj/project.pbxproj`), so Liquid Glass sidebar behavior needs no
  availability gate.

## Facts verified (not assumed)

Measured with a standalone AppKit/SwiftUI probe built against the same SDK
(`.context/split-probe/`, artifacts kept there):

| Shape | split view frame in a 760×500 window | sidebar hosting view | SwiftUI content top |
|---|---|---|---|
| Oto today: split inside `NSHostingController` | `(0, 0, 760, 448)` | `170×448`, safe area `0` | 0 |
| Split as window `contentViewController` (Firstlight) | `(0, 0, 760, 500)` | `170×500`, safe area top `52` | 52 |
| Split inside hosting controller + `.ignoresSafeArea()` | `(0, 0, 760, 500)` | `170×500`, safe area top `52` | 52 |

Visual proof (same probe): `probe-current-oto-shape.png` reproduces the user's
screenshot exactly — dark band above the sidebar, sidebar starting at 52 pt.
`probe-fixed-fullbleed.png` matches Firstlight — sidebar colour behind the
traffic lights, sidebar/detail content correctly inset to 52 pt, unified
toolbar floating over the detail column with no bar over the sidebar.

View hierarchy of the sidebar item (probe dump), which decides the material
question:

```
_NSSplitViewItemViewWrapper (0, 0, 180, 500)
  NSGlassEffectView (0, 0, 180, 500)     <- AppKit already supplies the sidebar glass
    ContentHolderView
    _NSCoreHostingView<RootView>
NSTitlebarBackgroundView (0, 0, 180, 52) <- stays transparent with titlebarAppearsTransparent
```

## Root cause

`SettingsRoot.body` puts the `NSSplitViewController` inside an
`NSHostingController` (`SettingsSplitView`, an `NSViewControllerRepresentable`).
The hosting view is the window's content view and reports
`safeAreaInsets.top = 52`, so SwiftUI lays the representable out inside the
safe area — the split view is only 448 pt tall and its sidebar can never paint
behind the traffic lights. Nothing in the window setup
(`fullSizeContentView`, `titlebarAppearsTransparent`) is wrong; the split is
simply positioned too low.

## Decision: which fix

Two shapes produce identical geometry. Choose `.ignoresSafeArea()` on the
representable:

- It keeps `SettingsRoot` as the single SwiftUI owner of selection, search
  text, and the back/forward history, and keeps the `.toolbar` items declared
  in SwiftUI.
- Making the split the `contentViewController` (Firstlight's shape) would
  force the toolbar to be rebuilt in AppKit and the navigation state hoisted
  into a model, for no visual gain.

Assumption questioned: does `.ignoresSafeArea()` also let the titlebar paint
over the sidebar? No — the probe shows no `NSTitlebarBackgroundView` fill and
the sidebar glass reaching y = 0.

## Exact file changes

1. **`Oto/Settings/SettingsRoot.swift`**
   - `body`: `SettingsSplitView(sidebar:detail:)` → append `.ignoresSafeArea()`
     before `.toolbar { … }`.
   - `sidebarContent`: drop `.background(.regularMaterial)`. AppKit's
     `NSGlassEffectView` already fills the sidebar item full height; a second
     SwiftUI material on top is what would make the strip above/below the old
     52 pt line disagree. Firstlight adds no background either.
     Fallback if the live result reads too transparent: restore
     `.background(.regularMaterial)` and re-check the seam.

2. **`Oto/UI/Theme/OtoControls.swift`** — new shared view, next to `OtoKey`:

   ```swift
   /// The recorder's answer painted on the popover glass: a wash from the top
   /// edge that fades to clear. Red while a combination is refused, green in
   /// the moment one lands. Never a border box — the tint is the surface.
   struct OtoRecorderGlow: View {
       enum Tone { case refused, accepted }
       var tone: Tone?
       @Environment(\.accessibilityReduceMotion) private var reduceMotion
       var body: some View { … }   // LinearGradient + opacity, animation
   }
   ```

   Values: refused `Color.red.opacity(0.32)` → `.opacity(0)` top-to-bottom,
   `easeOut(0.12)` in; accepted `Color.green.opacity(0.30)` → clear,
   `easeOut(0.1)` in and `easeOut(0.38)` out; `.allowsHitTesting(false)`,
   `.accessibilityHidden(true)`; Reduce Motion renders the tint with no
   animation.

3. **`Oto/Settings/DictationPane.swift`** (`ShortcutCapturePopover`)
   - Delete the `.overlay { RoundedRectangle(cornerRadius: 10)…strokeBorder(.red.opacity(0.72))…shadow(…red…) }`
     block (lines ~214–223).
   - Apply `.background { OtoRecorderGlow(tone: glow) }` to the chips/caption
     section only (above the `Divider()`), matching the reference where the
     footer stays clear.
   - `@State private var glow: OtoRecorderGlow.Tone?`; set `.refused` on
     `onInvalid`/blocked conflict, clear it when the modifier monitor sees a
     new attempt (`flagsChanged`), set `.accepted` on a successful save.
   - Successful save: stop listening and resume dispatch immediately, keep the
     popover for the flash, then `onClose()` after 0.45 s. Refusal keeps the
     popover open exactly as today.

4. **`Oto/Settings/ShortcutRecorderField.swift`**
   (`TransformShortcutCapturePopover`)
   - Same replacement of the red border overlay (lines ~378–387) and same glow
     state on its chips/caption section.
   - Split "listening" from "presented": an internal `capturing` state feeds
     `ShortcutRecorderModifier`; a successful capture sets `capturing = false`,
     flashes green, then sets `isListening = false` after 0.45 s so the parent
     binding dismisses the popover after the flash.

5. **`Oto/Settings/IntelligencePane.swift`**
   - `captureTransform` success path: remove `recording = nil` (the popover now
     dismisses itself after the green flash). Keep `refreshTransforms()` and
     `transforms.start()` immediate so the new shortcut is live at once.

6. **`OtoTests/SettingsUIStateTests.swift`**
   - `sidebarUsesCompactResizableWidth` still asserts the pre-Firstlight values
     `194`/`218`; the code is `170`/`180` (`SettingsRoot.minimumSidebarWidth`,
     `SettingsRoot.sidebarWidth`). Pre-existing failure — update the
     expectations so the suite is green.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. Launch the built app, open Settings, screenshot the window: sidebar colour
   reaches the window's top edge behind the traffic lights, search field and
   rows start below them, detail content starts below the toolbar, no dark
   band, no seam at 52 pt.
3. Open a dictation shortcut recorder: press a blocked combination → red wash
   on the glass, no border box, red copy, popover stays open. Press a valid
   combination → green flash, then the popover closes and the row shows the
   new chips. Repeat for an Intelligence transform slot.
4. `xcodebuild test -scheme Oto -destination 'platform=macOS'`.

## Risks and deferred decisions

- Removing the explicit sidebar material changes the sidebar's tone slightly;
  judged from the live screenshot, revertible in one line.
- The green flash is a 0.45 s hold, not Firstlight's "stay open, press ⌫ to
  delete". Keeping Oto's close-on-save behavior is deliberate; revisit if the
  flash reads as too quick.
- Delaying dismissal adds one async task per popover; it must be cancelled on
  `onDisappear` so a re-opened recorder never closes itself.
- Unrelated to this plan: the Settings window's fixed 760 pt width and the
  stale width test above are the only other known drift in this area.

## Open questions

- Should the recorder stay open after a successful capture (Firstlight shows
  "Press ⌫ to delete" and lets another combination be pressed straight over
  it), or keep Oto's close-on-save with the green flash? Plan assumes the
  flash.

---

# Round 2: About pane, full-screen refusal, app scopes

Status: IMPLEMENTED (2026-10-29). Build green; unit suite green (563 tests).

## Goal

1. **About is its own destination**, as in Firstlight, so General stays about
   behavior.
2. **Settings cannot go full screen**, and the green zoom button is not
   clickable.
3. **Dictionary and Snippet scopes are picked, not typed.** "One app" becomes
   "Selected apps": a multi-select list of installed apps. Selecting an app
   covers that app's own extensions and agents.
4. The sidebar fix also restored the back/forward toolbar items (see below).

## Facts verified

- **Toolbar items were missing before this change.** Printing
  `window.toolbar?.items` at launch gave `[]` both with and without
  `.ignoresSafeArea()`. Cause: `makeWindow()` assigned a fresh `NSToolbar`
  *after* `contentViewController`, discarding the items SwiftUI had installed.
  Removing that assignment makes SwiftUI install its own toolbar:
  `items = [2]`, and the screenshots show ‹ › in the detail column.
- **The sidebar keeps `.background(.regularMaterial)`.** A/B captures with and
  without it: without, `cacheDisplay` renders the AppKit `NSGlassEffectView`
  as flat white; with, the material composites and matches the shipped look.
  Removing the material would have changed the sidebar's tone for no
  geometry gain, so it stays.
- **Green button disabled** verified in the About capture: the zoom light is
  grey while the other two are coloured.

## File changes

1. **`Oto/Settings/SettingsWindowController.swift`**
   - Drop the explicit `NSToolbar` (SwiftUI owns the toolbar now).
   - `collectionBehavior`: remove `.fullScreenPrimary`, insert `.fullScreenNone`.
   - `standardWindowButton(.zoomButton)?.isEnabled = false`, re-applied in
     `windowDidBecomeKey` because AppKit revalidates titlebar buttons on focus.
2. **`Oto/Settings/SettingsRoot.swift`**
   - New `.about` pane (title, `info.circle`, search terms); General no longer
     claims "about/version".
3. **`Oto/Settings/AboutPane.swift`** (new) — 72 pt icon, name, version
   (short + build), one-line product statement, copyright, and a Details
   section with version and bundle identifier. Same shape as Firstlight's.
4. **`Oto/Settings/GeneralPane.swift`** — About section removed (moved, not
   duplicated); unused `appVersion` deleted.
5. **`Oto/Support/InstalledApps.swift`** (new) — one cached, lazy index of
   user-facing apps from `/Applications`, `/Applications/Utilities`,
   `/System/Applications`, `/System/Applications/Utilities`, `~/Applications`,
   plus running apps. Filters: `CFBundlePackageType == APPL`, no `NSExtension`,
   no `LSUIElement`/`LSBackgroundOnly`, no bundle nested inside another `.app`,
   and running apps must be `.regular` (this is what removed `chronod`,
   `AccessibilityVisualsAgent`, `AirPlay Screen Mirroring`, `JournalWidget`,
   `CalendarWidgetExtension`, `com.apple.CoreSimulator.…`). Verified: 91 apps,
   zero widget/agent/extension/daemon entries.
6. **`Oto/Settings/AppScopePicker.swift`** (new) — Everywhere / Selected apps
   segmented control plus a popover checklist (search, app icons, Clear,
   count). Rows are left-aligned so checkboxes share one column.
7. **`Oto/Storage/DictionaryStore.swift`**
   - `DictionaryRule.bundleID: String?` → `bundleIDs: [String]` (empty =
     everywhere). Custom `Codable` reads the v1 `bundleID` key and writes
     `bundleIDs` only when non-empty, so existing files and exports keep
     working without a schema bump.
   - `duplicateKey()` uses the sorted scope set (order-free).
   - `applyDictionaryRules` uses `DictionaryRule.scopeMatches`, which treats a
     scope as the app family: `com.apple.journal` covers
     `com.apple.journal.*`, and a rule stored against a helper still fires in
     the parent app. The dot boundary keeps `com.a.Journal` away from
     `com.a.Journalist`.
   - `add`/`update`/import normalise scopes (trim, dedupe, reject blanks);
     `.emptyBundleID` → `.emptyAppScope` with picker-shaped copy.
8. **`Oto/Storage/SnippetStore.swift`** — same model change and legacy decode
   (`bundleIDs`), same `.emptyAppScope`.
9. **`Oto/Settings/DictionaryPane.swift` / `SnippetsPane.swift`** — the bundle
   ID text field is replaced by `OtoAppScopePicker`; rows show app names
   (`InstalledApps.names`), not reverse-DNS.
10. **Tests** — call sites updated to `bundleIDs`; new coverage for multi-app
    matching, family matching, order-free duplicates, and legacy `bundleID`
    decoding for both stores.

## Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` — green.
- `xcodebuild test -only-testing:OtoTests` — 563 tests green.
- Captures (in-process `cacheDisplay`, no Screen Recording permission here):
  About pane; dictionary editor with "Selected apps" → "2 apps"; picker
  popover listing only real apps with aligned checkboxes.
- `OtoUITests.testSettingsOpensAsOneNativeWindow` fails in this environment on
  onboarding's "Finish" button (UI automation, unrelated to these changes).

## Deferred

- App icons for a few system utilities render as generic documents in cached
  captures; `NSWorkspace.icon(forFile:)` returns real 32 pt icons for them, so
  this is a capture artifact, not a UI bug.
- Scopes are matched by bundle-ID family. If an app's extensions do not share
  its bundle-ID prefix, they are not covered — no such case seen on this Mac.

