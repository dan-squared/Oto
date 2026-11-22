# Typa UI audit and Oto decisions

> **Rebuild edition:** This is a native macOS UI reference only. Use Apple’s official [SwiftUI Get Started](https://developer.apple.com/swiftui/get-started/), [SwiftUI documentation](https://developer.apple.com/documentation/SwiftUI#Overview), and [macOS HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos). Do not copy Typa’s private visual/window code into Oto Settings.

This note records the verified design lessons from the local shallow clone at
`/private/tmp/typa-reference` (the upstream project is
`dan-squared/typa`). It is intentionally about macOS behavior, not a visual
copy of Typa's brand.

## What Typa actually does

Typa's Settings scene is a normal SwiftUI `Settings` scene. Its content is a
`VStack(spacing: 0)` containing a native `TabView`, padded native grouped
`Form`s, a divider, and a small footer. The scene uses a 760 × 700 default
window. It does not attach its custom `WindowAccessor` to Settings.

Typa's `WindowAccessor` belongs only to the primary practice window. It changes
titlebar transparency, corner masks, and traffic-light placement for that
immersive surface. Copying that code into Oto Settings would make the settings
window less native and would recreate the overlay problem.

Typa also disables automatic AppKit window tabbing and does not declare
`LSUIElement`. Those details let Settings behave like an ordinary macOS window
with normal Dock and traffic-light behavior.

## Oto implementation

- Oto Settings stays on the native `Settings` scene with the chosen
  `NavigationSplitView`, `List(selection:)`, grouped `Form`, `Section`,
  `Toggle`, `Picker`, and system buttons. A selected detail pane may use a
  native `TabView` for tightly related subviews such as Dictionary/Snippets;
  Typa's root `TabView` is a reference option, not an alternate Oto root
  implementation.
- The Settings content uses a 760 × 700 minimum/ideal native window size. The
  content remains resizable through the normal macOS window controls. It has a
  restrained status footer; Liquid Glass is not applied to the window.
- `NSWindow.allowsAutomaticWindowTabbing` is disabled, and window restoration
  is not kept between launches.
- The Settings scene explicitly uses SwiftUI's `.windowStyle(.titleBar)` so
  the titlebar and traffic lights are AppKit-owned even when Oto is launched
  as a menu-bar utility.
- `LSUIElement` is false. Oto remains a menu-bar utility but now has normal
  application activation, a Dock presence, and the system generic app icon.
- The Flow Bar remains the only custom floating surface. Scratchpad is a
  separate utility panel and is not part of Settings.
- Oto does not install a font globally or fetch one at runtime. Settings and
  AppKit-owned chrome use system typography; Oto-authored copy follows the
  pinned bundled-font policy only where it does not change native control
  metrics or accessibility behavior.

## Validation rule

Always launch the packaged `.build/Oto.app`, not the bare SwiftPM executable.
The package has the bundle identifier and `Info.plist` that macOS needs for
native Settings activation, microphone permissions, Dock behavior, and
Accessibility recovery.

Use `scripts/run-app.sh` after a build; it refuses to use the raw executable
path that produces the missing-bundle warnings.
