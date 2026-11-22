# Native SwiftUI and macOS UI plan

This document is intentionally a native baseline. Recreate the workflow first; only the Flow Bar should be custom in the first release. Do not reproduce a screenshot with hand-built traffic lights, cards, toggles, title bars, or picker popovers.

## Apple material to read before editing UI

- [macOS resources](https://developer.apple.com/macos/resources/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple Design Resources — macOS apps](https://developer.apple.com/design/resources/#macos-apps)
- [Apple Developer Documentation](https://developer.apple.com/documentation/)
- [SwiftUI Get Started](https://developer.apple.com/swiftui/get-started/)
- [SwiftUI documentation overview](https://developer.apple.com/documentation/SwiftUI#Overview)
- [SwiftUI `Settings`](https://developer.apple.com/documentation/swiftui/settings)
- [SwiftUI `SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)
- [SwiftUI `NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [SwiftUI `Form`](https://developer.apple.com/documentation/swiftui/form)
- [SwiftUI `WindowStyle`](https://developer.apple.com/documentation/swiftui/windowstyle)

Apple’s macOS resources page links the current Xcode, documentation, release notes, HIG, design templates, SF Symbols, and Icon Composer. Treat those as the source of truth for current platform behavior. Verify availability with `#available` when using newer APIs.

## Window and scene contract

The settings window must be created by a SwiftUI `Settings` scene. That is what gives AppKit ownership of the native title bar, traffic lights, window lifecycle, keyboard equivalent, and restoration behavior:

The following is an illustrative scene skeleton. `AppModel` is the app-owned observable presentation state supplied by the dependency graph; it is not a second session coordinator.

```swift
@main
struct OtoApp: App {
    @State private var model = AppModel.live

    var body: some Scene {
        MenuBarExtra("Oto", systemImage: "waveform") {
            MenuBarMenu()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRoot()
                .environment(model)
        }
        .defaultSize(width: 760, height: 620)
        .windowStyle(.titleBar)
    }
}
```

Rules:

- Never create a second settings `NSWindow` controller.
- Never draw or reposition traffic lights.
- Never use `titlebarAppearsTransparent` for Settings.
- Do not force a fixed root width/height. Use a default scene size and content minimum only when required for legibility.
- Use `SettingsLink` for the menu action; it should target the same scene as Command-Comma.
- Disable automatic window tabbing only if it is a deliberate app-wide decision, not as a substitute for a real Settings scene.
- Build and test the packaged `.app`; a raw SwiftPM executable does not have stable TCC or LaunchServices identity.

## Native navigation

Use a `NavigationSplitView` for content-rich settings. Use `List(selection:)` and `Form` instead of custom sidebar rows and cards:

```swift
enum SettingsPane: Hashable, CaseIterable, Identifiable {
    case general, dictation, writing, privacyHistory

    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .writing: "Writing"
        case .privacyHistory: "Privacy & History"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .writing: "textformat"
        case .privacyHistory: "lock.shield"
        }
    }
}

struct SettingsRoot: View {
    @State private var selection: SettingsPane? = .dictation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationTitle("Oto")
        } detail: {
            switch selection ?? .dictation {
            case .general: GeneralSettings()
            case .dictation: DictationSettings()
            case .writing: WritingSettings()
            case .privacyHistory: PrivacyHistorySettings()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
```

`NavigationSplitView` is the first-rebuild root-navigation decision. A detail pane may use a native `TabView` when it contains two or more tightly related views—Writing may group Dictionary and Snippets, and Privacy & History may group History and Privacy. Those tabs are local to the selected sidebar pane; they must not replace or duplicate the sidebar. Typa's root `TabView` is reference evidence for spacing and native scene ownership, not an alternate Oto root architecture.

## Native controls and typography

Use system fonts and system controls for the first rebuild:

```swift
Form {
    Section("Interaction") {
        Picker("Shortcut behavior", selection: $preferences.mode) {
            Text("Hold to talk — release to finish")
                .tag(InteractionMode.holdToTalk)
            Text("Hands-free — press to start and stop")
                .tag(InteractionMode.handsFree)
        }

        LabeledContent("Shortcut") {
            ShortcutRecorderButton(configuration: $preferences.shortcut)
        }
    }

    Section("Microphone") {
        Picker("Input", selection: $preferences.deviceID) {
            Text("System default").tag(Optional<String>.none)
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
        Button("Refresh microphones") { refreshDevices() }
        Button("Open microphone permissions") { openMicrophoneSettings() }
    }
}
.formStyle(.grouped)
```

Guidelines:

- Let the system font, Dynamic Type, control metrics, accent color, and appearance do the work.
- Use a 14-point body baseline only where a label needs an explicit size; do not set a global font modifier.
- Use SF Symbols at the system scale and weight. Do not use giant icons as headings.
- Use `LabeledContent`, `Section`, `Toggle`, `Picker`, `TextField`, `TextEditor`, `Button`, `ContentUnavailableView`, `fileImporter`, and `fileExporter` before reaching for AppKit bridges.
- Keep explanatory copy short and secondary. The control label must remain understandable without reading a paragraph.
- Preserve keyboard navigation, VoiceOver labels, high-contrast appearance, larger text, and Reduce Motion.

Native system typography is mandatory for macOS-owned chrome and controls. Oto-authored labels may use the repository’s pinned bundled-font policy after native layout, accessibility, and window behavior are correct; never install a font globally or fetch one at runtime.

## Settings information architecture

Keep the first release small:

1. **General** — launch at login, Flow Bar visibility, sounds, diagnostics.
2. **Dictation** — readiness, offline asset preparation, interaction mode, shortcut, microphone.
3. **Writing** — personal dictionary and manual snippets.
4. **Privacy & History** — history opt-in, retention, deletion, local-data explanation.

Move AI modes, tone controls, and context selection to a later phase. They should not occupy a blank or disabled pane in the first release.

## Flow Bar boundary

The Flow Bar is not a second Settings system. Keep it isolated behind a presentation protocol:

```swift
@MainActor
protocol FlowBarPresenting: AnyObject {
    func show(state: FlowBarState, on action: @escaping (FlowBarAction) -> Void)
    func update(state: FlowBarState)
    func dismiss()
}
```

The view may use a frosted/translucent pill, level bars, and a restrained gradient if those are validated against Reduce Motion and contrast settings. Do not put speech, audio, insertion, or permission logic inside the view. The coordinator owns state and the Flow Bar renders it.

## UI acceptance checks

- Settings opens from the menu and Command-Comma as one native window.
- Native traffic lights remain attached to the title bar in light and dark appearance.
- Resizing and larger text do not clip controls.
- Sidebar selection, focus, hover, and keyboard navigation are system behavior.
- There are no custom traffic lights, custom switches, fake dropdowns, hero cards, or global font overrides.
- Flow Bar states remain readable when Reduce Motion is enabled.
- UI tests use a mock coordinator and never require a microphone or real global event tap.
