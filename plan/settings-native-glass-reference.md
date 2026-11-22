# Settings: native macOS reference treatment

Status: IMPLEMENTED. macOS build succeeds. Live visual inspection is still pending because launching the built app through desktop automation timed out.

## Goal

Bring Oto's existing Settings surface in line with both user-provided reference sets: native macOS window behavior, a resizable sidebar with a hard minimum width and no collapse control, the paired back/forward toolbar control, native menus/pickers/disabled states, in-sidebar search, and clear shortcut capture. Preserve Oto's actual settings, bindings, and account-free product model.

## Reference analysis

The screenshots show the same settings window across Account, General, Privacy, Integrations, Security, and About, in dark and light appearances, plus the shortcut recorder popover. At the screenshots' approximate 2× scale, the window is about 800×500 points and the sidebar is about 180–190 points wide.

- **Window and chrome:** rounded native macOS window with native traffic lights; a compact paired back/forward capsule at the upper left of the detail column. The content does not draw its own traffic lights or title bar.
- **Sidebar order and rhythm:** search field immediately below the traffic lights; a distinct identity row below it; then single-line destinations. Rows use a consistent icon tile, label baseline, full-width hover/selection target, and a quiet gray selected fill. The search field is about 30 points tall; rows have roughly 40–44 points of vertical pitch.
- **Detail layout:** detail content begins below the toolbar and uses a shared left/right inset around 20 points. Related settings are grouped in large soft-corner surfaces with thin separators. Groups have around 10 points of interior padding and 10–12 points between groups. Explanations sit below controls in muted text.
- **Typography and controls:** system sans, labels around 14–17 points, stronger group/page hierarchy, right-aligned values and controls. Toggles, segmented choices, steppers, and shortcut capture look like macOS controls. Error/destructive actions use system red sparingly.
- **Appearance:** dark and light versions keep the same geometry. The sidebar and toolbar use native material/vibrancy; detail groups remain mostly opaque tonal surfaces. Blue appears as the native focused search ring and active system controls, not as decorative color.
- **Shortcut capture:** the shortcut field opens a floating system-like recorder that explains the modifier sequence and has a visible Escape close action. This is a behavior and appearance reference only; Oto's existing recorder behavior remains authoritative.
- **Liquid Glass controls:** use SwiftUI's native glass button style for discrete icon actions and native segmented pickers for one-choice groups; keep menus and pickers native so popup material and selection behavior follow the OS.

The second reference set is from a browser's Settings window. It confirms that the desired result includes more than the Firstlight detail cards:

- The browser sidebar has a native search field, dense icon-and-label rows, a selected-row fill, and a separate gap between common items and feature groups. The active pane owns an icon/title/description header where that helps explain the feature.
- The top-left back/forward pair is a real navigation affordance with its own enabled/disabled state, positioned in the leading toolbar area. For Oto, that means browsing previously selected settings destinations, not undoing preference changes.
- Dropdown examples use native popup/menu treatments with a selected row and, when needed, explanatory descriptions or previews. Oto should use native `Picker`/`Menu` presentation for actual options, not custom painted menus.
- Shortcut examples use a compact keycap/record affordance and a transient glass-like recorder state. Oto already has keycap display, Escape cancel, Delete clear, conflict handling, and staged Save/Done behavior; the visual treatment should preserve those semantics.
- Disabled features are visibly subdued and their actions are genuinely disabled. Oto should express current unavailable states (for example, a feature waiting on permission/preparation) through existing truthful status and disabled state, never imply a feature exists when it does not.
- The example's preview art, cloud sync, account, and browser categories are app-specific and are not product content for Oto.

## Current Oto findings

- `SettingsRoot` already uses `NavigationSplitView` and native `List`, but fixes the sidebar to 210 points and has no search or identity region. The seven current destinations are General, Dictation, Dictionary, Snippets, History, Privacy, and Intelligence.
- Sidebar rows are custom Buttons inside the native List, with a monochrome 36-point row, hand-painted hover/selected fills, and 14-point labels. The page currently adds a 17-point title and 22-point horizontal inset.
- Settings panes use `OtoCard`, `OtoLine`, `OtoSwitch`, `OtoSegmented`, and other custom controls. Cards have 11-point corners, hairline outlines, and compact 11.5–13-point text. This is visually denser and more bespoke than the reference.
- The current window is a `WindowGroup` with manually wired Command-Comma, fixed 805×621 content size, title hiding, and a custom window locator. The product brief (`Docs/START_HERE_PRODUCT.md`) calls for one native `Settings` scene, `NavigationSplitView`, native forms and controls, and no recreated title bars or traffic lights. `OtoApp.swift` therefore needs to be considered along with the view.
- Oto has no account or profile feature. The reference's “Daniel / Account” row, account card, friend code, username, and email actions have no truthful equivalent in Oto and will not be added. The sidebar can identify Oto using the existing app name/icon if the native layout needs that visual anchor.
- Pane behavior is backed by shared stores and `SettingsUIState`; navigation must not recreate/reset settings state. Existing backend calls and permission, speech preparation, shortcut, persistence, and deletion behavior remain untouched.

### Why the sidebar currently does not collapse

This is confirmed in source, not a visual guess:

1. `SettingsRoot` applies `.toolbar(removing: .sidebarToggle)`, which removes the default toggle that `NavigationSplitView` adds.
2. The manual show/hide alternatives exist only as View-menu commands (`⌘⇧S` and `⌃⌘S`) and as a sidebar reopen button that only appears after the sidebar has already been hidden. There is no visible hide button in the expanded sidebar state.
3. The sidebar width is locked at min = ideal = max = 210 points. That prevents the user from resizing the split column; it is separate from visibility, but adds to the sense that the sidebar is fixed.
4. The window is a `WindowGroup` with a fixed content frame and `.windowResizability(.contentSize)`, with the title toolbar item removed. This produces a normal app window rather than the platform-managed settings window described in Apple's SwiftUI guidance.

Apple documents that `NavigationSplitView` supplies the sidebar toggle by default and that its visibility can also be driven through `NavigationSplitViewVisibility`. The first implementation path should restore the native toolbar item and keep the split view's visibility binding; do not replace it with another custom toggle unless the system item fails in the final window configuration.

## SwiftUI and window research

There is no single SwiftUI “native settings window preset” that reproduces these screenshots. The native effect comes from composing the app's `Settings` scene, `NavigationSplitView`, sidebar `List`, `.searchable(..., placement: .sidebar)`, and system toolbar items/controls. Apple says the current macOS sidebar treatment and toolbar controls receive Liquid Glass automatically; custom glass should be reserved for a control that cannot use a system component.

- `Settings` is the dedicated scene for app preferences; Apple says it manages the Settings menu item/window. `SettingsLink` opens the scene or brings its existing window forward. This aligns with Oto's canonical product document and removes manual `WindowGroup`/Command-Comma/window-finding workarounds, subject to verifying this app's menu-bar-only launch lifecycle in the built app.
- `.searchable(text:placement:prompt:)` with `.sidebar` places a sticky native search header in a macOS navigation sidebar. Search should filter Oto destination names and relevant terms, focus through the native search keyboard path, preserve the current selection if it remains visible, and show an honest no-results state.
- `NavigationSplitViewVisibility` provides a binding for showing/hiding the leading column. The current removal of `.sidebarToggle` explains the missing visible collapse affordance. Keep the column resizable using reasonable minimum/ideal/maximum widths rather than locking all three to 210.
- `.toolbar` supports `ToolbarItemPlacement.navigation` for navigation actions. Implement real back/forward movement through visited settings panes and disable each button at the ends of the history. This is what the reference's arrows represent; they are not undo/redo controls.
- Native `Picker`/`Menu`, `Toggle`, `Stepper`, disabled button state, `popover`, and `sheet` should own their platform presentation. Keep the existing shortcut capture engine and use its current field/modal state as the content for the native-feeling recording presentation.
- Liquid Glass is introduced by system chrome and navigation structure automatically in the target platform. Do not put `.glassEffect()` on entire settings cards; reference setting groups use tonal surfaces, with system glass concentrated in toolbar/sidebar/floating controls. Validate transparency settings and inactive-window appearance.

### Xcode documentation bridge result

`xcrun mcpbridge --help` confirms the local bridge binary exists. A JSON-RPC `initialize` request returned: “Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model Context Protocol, or run `sudo xcrun mcp-server enable`.” No Xcode documentation MCP tools are exposed to this chat, so this pass used the official Apple Developer documentation and the installed local SDK. No attempt was made to change the user's Xcode/MCP security setting or run a privileged enable command.

## Design direction

Use macOS's own window scene, materials, toolbar items, menus, and controls for the recognizable native finish. Keep the `NavigationSplitView` as the structural base; restore its system sidebar toggle, allow its width to resize, and add native search scoped to Oto's settings destinations and searchable setting labels/help text, with keyboard focus and no-results behavior. Add functional back/forward pane history in the navigation toolbar. Keep the current product destinations unless a user-facing IA decision is explicitly made later; filter/search them rather than silently removing destinations. Use the app identity only as an app identity, not a fake account.

Use native window/sidebar/toolbar materials for the glass effect. Do not spread blur over the entire detail area or apply glass to every card: in the reference, the glass is primarily the window chrome and sidebar, while settings groups read as quiet, opaque surfaces. Replace custom faux-native controls in Settings with native SwiftUI `Toggle`, `Picker`, `Stepper`, `TextField`, and related controls where behavior maps cleanly; retain purpose-built controls only where the current interaction requires them (notably shortcut recording and specialized speech readiness).

## Exact files in scope

1. `Oto/Settings/SettingsRoot.swift` — restore the native sidebar toggle; use an adjustable split width; add native in-sidebar search; add real back/forward destination history via leading toolbar actions; simplify custom row overrides where the native sidebar row already matches; refine content spacing to the reference.
2. `Oto/App/OtoApp.swift` and `Oto/UI/OtoMenuBarView.swift` — migrate the existing Settings `WindowGroup` to the product-mandated native `Settings` scene and use `SettingsLink`/`openSettings` for settings entry points; preserve the menu-bar app and single-window behavior.
3. `Oto/Settings/SettingsUIState.swift` — if required, own selected destination, visited-path history, and column visibility across pane changes; do not reset feature state unnecessarily.
4. Existing pane files (`GeneralPane.swift`, `DictationPane.swift`, `DictionaryPane.swift`, `SnippetsPane.swift`, `HistoryPane.swift`, `PrivacyPane.swift`, `IntelligencePane.swift`, `ShortcutModal.swift`, `ShortcutRecorderField.swift`) — reflow existing rows into the reference's grouped density; use native menus, pickers, switches and disabled states when semantics match; preserve current shortcut recorder and permission/readiness explanations and all actions/bindings.
5. `Oto/UI/Theme/OtoControls.swift`, `Oto/UI/Theme/OtoPlate.swift`, and `Oto/UI/Theme/OtoPalette.swift` — adjust or retire Settings-only custom treatments only when no other surface depends on them. Flow Bar and onboarding visuals are out of scope.
6. Existing settings window locator/command code and its tests only as required by the scene migration. Do not change unrelated app/window behavior.

## Platform facts checked

- Workspace guidance says Xcode 27.0, macOS 27.0 SDK, and deployment target 27.0. The installed toolchain reports Xcode 27.1 (build 27A9275), and `xcrun --sdk macosx --show-sdk-path` resolves to `MacOSX27.0.sdk`.
- The SDK's `SwiftUI.swiftinterface` exposes `.searchable(text:placement:prompt:)`, `NavigationSplitViewVisibility`, `Settings`, `SettingsLink`, `OpenSettingsAction`, `.glassEffect`, `.toolbar(removing:)`, and `.navigation` toolbar item placement. The app's macOS 27.0 deployment target includes these APIs.
- Apple primary references: [Settings](https://developer.apple.com/documentation/swiftui/settings), [SettingsLink](https://developer.apple.com/documentation/swiftui/settingslink), [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [NavigationSplitViewVisibility](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility), [SearchFieldPlacement.sidebar](https://developer.apple.com/documentation/swiftui/searchfieldplacement/sidebar), [Adding a search interface](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app), [ToolbarItemPlacement.navigation](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/navigation), [toolbar(removing:)](https://developer.apple.com/documentation/swiftui/view/toolbar%28removing%3A%29), [Liquid Glass overview (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/323/), and [What’s new in SwiftUI (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/269/).
- Apple documentation confirms the native search placement and toggle APIs. Exact behavior of the `Settings` scene with Oto's menu-bar-only lifecycle, toolbar layout, and split view sizing must still be confirmed with an app build/run; docs alone do not prove the final pixels.
- No third-party dependencies or private APIs are needed.

## Verification plan

- Build with `xcodebuild -scheme Oto -destination 'platform=macOS' build` after implementation.
- Inspect the finished settings window in light and dark appearances at the reference-sized window and a narrower resized window. Check that the sidebar can be shown/hidden with the native control, search focus/results/no-results, row selection and hover, keyboard navigation, text clipping, toolbar history, native picker menus, shortcut capture, truly disabled rows, and that navigation preserves loaded values.
- Confirm Command-Comma, App menu, and menu-bar entry open the same native Settings window. Confirm no duplicate traffic lights/title bar and no regression to the menu-bar-only app flow.
- Do not run the test suite or add tests unless requested; keep any required existing locator/command test edits limited to changed behavior.

## Execution notes

- Implemented the native `Settings` scene, sidebar search, functional pane back/forward history, native switch/segmented/menu pickers, and settings group surfaces. Per the user's follow-up, the default sidebar toggle is hidden.
- Reduced the default settings window to 740×580 points (660-point minimum width), removed the app identity icon and heading, removed the section gap between sidebar destinations, and added visible sidebar/button hover feedback.
- Sidebar width is user-resizable from a 194-point minimum to 270 points, with a 218-point ideal width. The split view is held at `.all` and the built-in toggle is removed, so it cannot collapse; native `List` owns hover and selection visuals.
- Follow-up toolbar correction: the history controls are now declared in the detail column's toolbar scope, so SwiftUI places the paired back/forward group at the detail pane's leading edge, after the sidebar. The sidebar toggle is removed at both the split-view and detail toolbar scopes.
- Shortcut row shows compact keycaps for the active hold binding and uses SwiftUI's Liquid Glass button style for its edit action. Choice groups use the native segmented picker at large control size; dropdowns remain native menu pickers.
- `xcodebuild -scheme Oto -destination 'platform=macOS' -derivedDataPath /private/tmp/oto-derived-data CODE_SIGNING_ALLOWED=NO build` succeeded when run outside the file sandbox. The in-sandbox attempt could not launch Swift's macro plugin server.
- No tests were run, in line with the repository and task instructions.
- The Xcode documentation MCP bridge reports that MCP access is disabled in Xcode Settings → Intelligence → Model Context Protocol. The built app's live window could not be inspected because desktop automation timed out while launching it, so final appearance and interactions still need an on-device visual pass.
- Because ACP is disabled in Xcode, checked current Apple Developer documentation and the installed macOS 27 SwiftUI SDK declarations. Apple documents glass button styles and split-view width/toggle modifiers directly.

## Follow-up correction requested

The user reviewed the implementation and asked to remove the sidebar collapse affordance and app identity icon, reduce the default window width, remove the artificial gap between Privacy and Dictionary, keep only the compact back/forward pair, reduce toolbar whitespace, improve custom control spacing, and make hover states more visible. This follow-up overrides the first pass's assumption that the sidebar toggle should remain visible.

- Remove the default sidebar toggle and title toolbar item while preserving the split view and functional history controls.
- Remove the identity row (including the app icon) and merge sidebar destinations into one uninterrupted list.
- Tighten the default/minimum window width and sidebar width; preserve content readability at the minimum size.
- Add explicit visible hover feedback to sidebar rows and custom buttons, while keeping native controls for settings values.
- Update obsolete static UI assertions to match the new compact resizable sidebar; do not run tests.
- Build and run `git diff --check`. Live visual verification remains attempted but unavailable due desktop automation timing out in the previous pass.

## Risks and open implementation choices

- A native `Settings` scene owns menu presentation and may own parts of its title bar and sizing. Verify how that interacts with Oto's one-window requirement and onboarding guard before removing the current window locator.
- Apple explicitly documents `.sidebar` search as a sticky macOS sidebar header attached to the toolbar, and documents the `NavigationSplitView` sidebar toggle as a default item. Prefer those defaults over the prior custom search-field fallback.
- Navigation history should be implemented as meaningful settings-pane history; avoid a purely decorative forward/back pair.
- Native controls will use the platform accent color and spacing, while current Oto controls are monochrome and custom. Keep colors and control affordances semantic; let the OS draw focus and switch states.
- The supplied screenshots show a larger usable width than Oto's current 805-point window. Preserve the compact reference scale as the target default, then allow resizing to keep long Dictation rows usable.
- The user asked for a visual match, not an information-architecture rewrite. Preserve all current destinations and feature behavior during this pass; any later consolidation into the older product brief's four-goal sidebar requires a separate explicit scope decision.

## Sources

- User-provided screenshots dated 2026-10-25.
- User-provided browser settings screenshots dated 2026-10-25 (native sidebar, settings search, toolbar history, dropdown/popover, disabled item states).
- `Docs/START_HERE_PRODUCT.md` — native Settings scene, NavigationSplitView, native controls, and product boundary.
- `AGENTS.md` — plan-before-execute rule, local Xcode/SDK as platform truth, and no custom traffic lights.
- Current implementation: `Oto/Settings/SettingsRoot.swift`, `Oto/App/OtoApp.swift`, `Oto/Settings/SettingsUIState.swift`, and `Oto/UI/Theme/`.
- Local SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk`.
- Apple Developer SwiftUI references linked in “SwiftUI and window research.”
