# Settings visual parity with Firstlight

## Goal
Match the supplied Firstlight settings references across Oto: continuous sidebar/titlebar material, neutral sidebar hover, intentional Liquid Glass segmented controls, restrained ordinary buttons and matching shortcut recorder fields/popovers. Remove the shortcut reset action and show Accessibility guidance only when permission is missing and a configured mode requires it.

## Specification sources
- User screenshots dated 2026-10-29 and direct request.
- Firstlight source: `mac/App/Interface/Settings/SettingsWindowController.swift`, `NeutralSettingsList.swift`, `HotkeyRecorder.swift`, `NativeFormControls.swift`, `NativeSettingsButtons.swift`, and `NativeHover.swift`.
- Oto existing shortcut capture/conflict rules and settings state.

## Facts verified
- Firstlight creates its settings window with `.fullSizeContentView`, hides the title, uses a unified toolbar, and keeps its sidebar split item non-collapsible.
- Firstlight's segmented selector uses a single Liquid Glass track and a separate selected capsule; its hotkey face uses a subtle fill/stroke rather than glass.
- Current local SDK is `MacOSX27.0.sdk`; the existing Firstlight source and Oto code use `glassEffect` APIs available in this toolchain.

## Exact files
- `Oto/Settings/SettingsRoot.swift`: native source-list sidebar, icon wells, selected and hover styling.
- `Oto/Settings/SettingsWindowController.swift`: create the fixed-width native settings window before content attachment so the sidebar material continues through the traffic-light area.
- `Oto/UI/Theme/OtoControls.swift`: segmented selector, keycaps, ordinary action button styles.
- `Oto/Settings/DictationPane.swift`, `ShortcutRecorderField.swift`: shortcut field styling, attempted-key error feedback, conditional permission note, and no reset control.
- `Oto/Settings/IntelligencePane.swift`: use the shared shortcut field and segmented selector; leave a rejected recorder open so it can accept another shortcut.
- `Oto/Settings/PermissionRows.swift`, `DictionaryPane.swift`, `HistoryPane.swift`, `SnippetsPane.swift`: replace blanket glass actions with standard bordered styles.
- `plan/settings-firstlight-parity.md`: this plan.

## Verification
Build the macOS app with the repository's Xcode scheme, launch the newly built app bundle, and inspect the changed files/diff. Do not run tests unless requested.

## Risks and deferred decisions
- The AppKit owner creates the one Settings NSWindow with the full-size content style before attachment; keep the split view non-collapsible.
- The recorder keeps Oto's existing local monitor/conflict implementation and now surfaces the attempted key combination in the same way as Firstlight.

## Additional parity details
- Match Firstlight's 760 × 500 point opening size, fixed 760-point content width, 440-point minimum height, and vertical-only resizing.
- Match 20-point sidebar icon wells, their half-point subtle border, selected/hover row fill, compact search spacing, and plain no-results state.
- Preserve Oto's native empty-state cards and disabled controls; verify they remain readable and visually subdued after button style changes.
- Remove reset-to-default actions from shortcut configuration surfaces.
