# Phase 0 — Establish the shell (EXECUTED + VERIFIED 2026-09-19)

Status: COMPLETE. Packaged build green, app launched via MCP, user
verified menu-bar menu + Settings opens. Chrome follow-ups (floating
titlebar, paddings) iterated live; placeholder chrome work STOPPED per
user call — Phase 5 `NavigationSplitView` sidebar makes it moot (lights
float over the sidebar's own material; sidebar/content contrast is the
native macOS look, cf. `03_NATIVE_SWIFTUI_UI.md:61,186`).

## 1. Goal (from `Docs/START_HERE_PRODUCT.md` Phase 0)

A packaged, signed `Oto.app` that is a menu-bar utility with one native
Settings window — the foundation every later phase builds on. No audio,
no Speech, no shortcuts, no insertion in this phase.

Spec checklist for Phase 0:

- [x] (already true) macOS baseline + bundle identifier
- [x] (already true) real `.app` builds
- [ ] microphone usage text and required entitlements
- [ ] sample SwiftData replaced (only after preferences boundary exists)
- [ ] native `MenuBarExtra` + `Settings` scenes
- [ ] Settings opens via menu, Command-Comma, and `SettingsLink` (same window)

## 2. Facts verified (not assumed)

From the local SDK (`MacOSX27.0.sdk`, SwiftUI `.swiftinterface`, arm64e):

- `MenuBarExtra.init(content:label:)` and `init(isInserted:content:label:)`
  exist, macOS 13.0+. Our deployment target is 27.0 — no `#available`
  needed.
- `Scene.menuBarExtraStyle(_:)` exists; `.menu` style is the correct
  choice for a menu-bar utility (spec: `03_NATIVE_SWIFTUI_UI.md`).
- `Settings.init(content:)` exists. Single `Settings` scene owns
  titlebar/traffic lights/lifecycle/Cmd-, automatically.
- `SettingsLink` (default + custom label) and
  `@Environment(\.openSettings)` both exist — the two programmatic
  routes to the same Settings window.
- `xcrun mcpbridge` works; Xcode MCP approved for this folder;
  baseline `BuildProject` succeeds with zero errors.

Current project state (`Oto.xcodeproj/project.pbxproj`):

- `MACOSX_DEPLOYMENT_TARGET = 27.0`, `PRODUCT_BUNDLE_IDENTIFIER = app.Oto`,
  `DEVELOPMENT_TEAM = 78458476CJ`, `ENABLE_APP_SANDBOX = YES`,
  `ENABLE_HARDENED_RUNTIME = YES`. No entitlements file, no usage
  descriptions, no `LSUIElement` key.
- `Oto/OtoApp.swift` uses `WindowGroup` + SwiftData `ModelContainer`;
  `Oto/ContentView.swift` + `Oto/Item.swift` are template samples.

## 3. Assumptions questioned

1. **"Remove docs from Resources."** WITHDRAWN per user instruction —
   `Docs/` stays untouched (it is the prior project's research brain).
   Trade-off recorded: the `.md` files ship inside `Oto.app/Resources`
   (~KBs, harmless for dev). Revisit only if bundle hygiene matters at
   release. Decision: defer, user owns it.
2. **Sandbox vs. future needs.** `ENABLE_APP_SANDBOX = YES` is fine for
   Phase 0 (mic entitlement works in sandbox). But Phases 3–4 need a
   global event tap (HID) and AppleScript/System Events paste — both are
   painful or impossible in sandbox. Assumption challenged: keep sandbox
   ON for Phase 0, but flag that Phase 3 will likely force it OFF
   (with hardened runtime kept). No action now; decision point logged.
3. **`LSUIElement` (Dock icon).** Typa audit (`13_TYPA_UI_AUDIT.md`) used
   `LSUIElement=false` (menu-bar utility with Dock presence). Oto spec
   says "starts as a menu-bar utility" but never locks Dock vs. no-Dock.
   Assumption challenged: do NOT set `LSUIElement` in Phase 0 — default
   (Dock icon) keeps Settings/Cmd-, behavior standard while we prove the
   shell. Revisit in Phase 5 with the full Settings product.
4. **Bundle identifier `app.Oto`.** Keep for Phase 0 — TCC and signing
   already work under it (packaged build succeeds). Changing it later
   resets TCC permissions; so treat it as frozen after this phase.
5. **SwiftData sample timing.** Spec: "replace the generated SwiftData
   sample only after the new preferences boundary exists." The shell
   needs no persistence, so the minimal move is: stop *using* the sample
   (no `WindowGroup`, no `ContentView`), but delete `Item.swift` only
   when `PreferencesStore` lands (Phase 1). Deleting now would look
   cleaner but violates the spec order — follow the spec.
6. **Settings content scope.** Phase 0 needs only proof that the window
   opens three ways — not the 4-destination product (that's Phase 5).
   A placeholder `SettingsRootView` with one section ("Oto / Phase 0
   shell") is enough. Resist building Dictation/Writing/History/General
   now.

## 4. Planned changes (execute only on approval)

1. `Oto/OtoApp.swift` — replace `WindowGroup` with:
   `MenuBarExtra("Oto", systemImage: "waveform") { OtoMenuBarView() }`
   + `.menuBarExtraStyle(.menu)`, plus `Settings { SettingsRootView() }`.
   Remove `ModelContainer`/`Item` wiring from the app entry (keep
   `Item.swift` file on disk per §3.5).
2. New `Oto/UI/OtoMenuBarView.swift` — menu content: app name, a
   `SettingsLink`, `Divider`, `Quit` (via `NSApplication.terminate`).
   No custom views; standard `MenuBarExtra(.menu)` content.
3. New `Oto/UI/SettingsRootView.swift` — placeholder `Form` proving the
   Settings scene works. Explicitly marked Phase-0-only.
4. `Oto/ContentView.swift` — deleted (nothing references it after the
   app entry changes). `Oto/Item.swift` — kept until Phase 1.
5. Microphone usage text — `NSMicrophoneUsageDescription` via the Xcode
   `AddInfoPlist` tool. Draft copy: "Oto needs microphone access to
   transcribe your dictation on-device with Apple Speech."
   (Copy is user-visible; user may reword at review.)
6. Entitlements — create `Oto/Oto.entitlements` with
   `com.apple.security.device.audio-input = true` (required for mic
   under sandbox). No other entitlements in Phase 0.
7. `AGENTS.md`/`opencode.json` — no changes needed (MCP already configured).

## 5. Verification (all through Xcode MCP)

- `BuildProject` succeeds, zero errors.
- `RenderPreview`-style check is N/A (no UI preview target); instead:
  `RunProject`, then confirm (user-assisted, 60 seconds):
  menu-bar icon appears → menu opens → Settings opens;
  Cmd-, opens the same window; `SettingsLink` in the menu opens it.
- Confirm `Oto.app` contains `NSMicrophoneUsageDescription`
  (read built Info.plist) and the entitlements file is code-signed in.
- Explicit non-goals: no mic prompt triggered yet (no audio code),
  no shortcut registration, no TCC validation beyond build identity.

## 6. Risks and deferred decisions

- Sandbox will likely be disabled in Phase 3 (event tap + System Events).
  Flagged, not decided.
- `LSUIElement` undecided until Phase 5.
- Bundle ID `app.Oto` treated as frozen after this phase (TCC reset cost).
- Docs-in-Resources kept per user instruction; revisit at release.

## 7. Open questions (resolved during execute)

1. Mic usage copy — user delegated wording; finalized as
   "Microphone required for dictation."
2. `Item.swift` stays on disk (unused) until Phase 1 per spec — confirmed.

## 8. Granted exception to the titlebar rule (user-approved)

The user overrode the "no titlebar customization" rule narrowly for the
Settings window look. Allowed pass, and ONLY this pass:

- Transparent titlebar + hidden title text + no separator +
  full-size content view on the native `Settings` scene.
- Technique: minimal `Oto/Support/SettingsWindowAccessor.swift`,
  following `/private/tmp/typa-reference/WindowAccessor.swift`
  ("standard" path only).
- Still banned: hiding buttons, corner masks, forced window sizes,
  custom-drawn chrome.
- Amendment (user-approved, reference screenshots): traffic-light
  *position* may use reference-like insets (leading 20, top 16).
  Buttons keep Apple's look; only their padding changed.
- Correction after testing: transparent-window approach
  (`.clear` + non-opaque, Typa immersive-style) made Oto see-through
  because grouped-Form vibrancy has nothing solid behind it. Final
  approach keeps the window fully standard and opaque; only the
  titlebar is blended (transparent + hidden title + no separator +
  strip view hidden). Reference: Typa practice window is opaque dark
  with floating lights, not glass.
- The no-op `.windowStyle(.hiddenTitleBar)` was removed (proven ignored
  on `Settings` scenes).
- `Docs/` untouched — this exception lives here, not in the audit docs.
