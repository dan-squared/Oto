# Engineering wisdom from the Oto build

This document records mistakes, false starts, and durable rules from the Oto work so a future agent does not repeat them. It is deliberately blunt. The goal is a small, reliable, native app—not a collection of impressive-looking partial systems.

## The biggest strategic mistake: building before freezing the boundary

The project initially moved between local model catalogs, Whisper/MLX/FluidAudio, Apple Speech, Apple Intelligence, and a YAP-like Apple Speech-only product. That created unnecessary adapters, download plans, settings controls, and UI states before the core dictation loop was proven.

**Rule:** freeze the first release as:

```text
Apple SpeechAnalyzer
  + global shortcut
  + capture-first audio
  + deterministic dictionary/snippets
  + target-aware insertion
  + local final-only history
  + native Settings
```

Everything else is a later phase behind a documented protocol. Never add a settings control for a runtime that is not installed, tested, and offline-safe.

## Mistakes made during the initial project structure

### 1. UI and backend were changed together

Settings redesign, Flow Bar styling, hotkeys, audio capture, and speech runtime changes were repeatedly mixed. That made it impossible to know whether a failure came from window lifecycle, TCC identity, shortcut delivery, audio format, or transcription.

**Do instead:** work in vertical boundaries:

1. coordinator/state machine;
2. audio and SpeechAnalyzer;
3. global input;
4. target capture and insertion;
5. storage;
6. native Settings;
7. Flow Bar polish.

Each boundary needs a fake, focused tests, and a packaged-app check before the next one is layered on.

### 2. A custom Settings window was treated as a visual problem

The first Settings implementations used custom `NSWindow` controllers, transparent title bars, hand-built sidebar rows, cards, and fake traffic-light assumptions. The result looked unlike a native macOS window and made “Open Settings” unreliable.

**Do instead:** use one SwiftUI `Settings` scene, `SettingsLink`, native title bar, the rebuild's chosen `NavigationSplitView`/`List`, and `Form`. A native `TabView` is a documented alternative only if a future decision log explicitly changes the choice. Never draw traffic lights, manually move them, or create a second Settings window controller.

### 3. The raw Swift executable was used as if it were the app

Launching a SwiftPM executable directly caused misleading failures:

```text
missing bundle identifier
TCC/Accessibility cannot be trusted
LaunchServices cannot resolve the app
global event tap is unavailable
```

**Do instead:** always build and test `Oto.app`. A packaged, stably identified, signed app is a different runtime identity from `.build/.../Oto`.

```sh
./scripts/build-app.sh
open .build/Oto.app
```

If LaunchServices is unavailable in an automation environment, report that limitation; do not “fix” the application by adding more window hacks.

### 4. A local shortcut recorder was mistaken for a global shortcut

A SwiftUI key recorder can display a key while the HID event tap still fails because Accessibility is missing, the tap timed out, macOS consumed F5, or the app was not packaged.

**Do instead:** record the physical key-down/key-up and then prove it through the same global backend used in production. Treat “saved” and “globally verified” as different states.

### 5. F5/function-row events were routed through the ordinary shortcut path

Carbon/AppKit/third-party shortcut libraries are useful for ordinary modifier shortcuts but are not sufficient for function-row and Dictation keys that macOS may consume first.

**Do instead:** keep two input backends converging on one transition state machine:

```text
ordinary modifier shortcut → shortcut backend → shared key events
F5 / Dictation key        → CGEvent HID tap → shared key events
shared key events          → coordinator
```

Never start audio, await, or mutate SwiftUI inside the HID callback. It only decides whether to consume the event and dispatches a lightweight event.

### 6. Apple Speech asset failure was collapsed into one message

“Apple Speech setup needed” can mean unsupported OS, unsupported locale, missing asset, asset preparation in progress, microphone denial, or an engine failure. One generic banner wastes debugging time and makes users think permissions are broken.

**Do instead:** model each readiness state and keep asset installation explicit in Settings. The shortcut path checks readiness; it never downloads or installs assets.

### 7. Stop/cancel had too many owners

Key-up, Escape, Flow Bar Stop, voice activity, engine failure, and app shutdown can all happen together. Letting each path tear down audio and UI caused duplicate finalization and Flow Bar dismissal races.

**Do instead:** one coordinator owns idempotent `finish(sessionID:)` and `cancel(sessionID:)`. Invalidate the session before cancellation teardown. Check the session ID after every `await`.

### 8. UI animation was allowed to outlive its panel

Autonomous `TimelineView`/timer work and animated Flow Bar dismissal can continue after the AppKit panel is gone. That previously contributed to stop-time crashes.

**Do instead:** the Flow Bar controller owns its task/token, stops it before dismissal, and has a reduced-motion/static path. Add repeated stop/cancel stress tests before adding motion polish.

### 9. Audio work was too close to the main actor

Scheduling a main-actor task per audio buffer creates queue pressure, latency, and cancellation lag.

**Do instead:** the audio tap performs only bounded copying/signaling. A dedicated consumer converts and feeds SpeechAnalyzer. Meter/spectrum samples are coalesced to a modest rate such as 30 Hz.

### 10. The target app was queried too late

Using the frontmost app when transcription finished can paste into the wrong app after a focus change or after Oto presented UI.

**Do instead:** capture application, process, screen, and available window identity before showing Oto UI. Never fall back to whichever app is frontmost at finalization.

### 11. Clipboard restoration used timing instead of ownership

A fixed delay alone is not safe: Electron may read later, or the user may copy something new during the delay.

**Do instead:** use a unique session marker plus pasteboard change count. Restore only if Oto still owns the exact write. Otherwise leave the final text available for recovery.

### 12. Documentation drift hid the real product decision

The docs simultaneously described local model downloads, Apple Intelligence, Inter typography, native system fonts, and Apple Speech-only release scope. Future agents could follow the wrong section.

**Do instead:** keep one active rebuild README with reading order and phase gates. Mark deferred capabilities explicitly. When a decision changes, update the active copies inside `OTO_REBUILD_PLAN/` and link back to the historical audit.

## Repository structure that scales without ceremony

Use the canonical ownership-oriented folders below, not layers invented for their names. This is the same layout used by `05_CURRENT_TO_REBUILD_MAP.md` and the product plan; do not introduce a competing `Core/`, `Dictation/`, or `Writing/` top-level layout.

```text
Sources/Oto/
├── App/            # scenes, dependency composition, lifecycle
├── Coordinator/    # one recording coordinator and session state
├── Services/       # audio, SpeechAnalyzer, permissions, input, insertion
├── Models/         # small Sendable values and session/persistence schemas
├── Storage/        # history, dictionary, snippets, migrations
├── Support/        # diagnostics, launch-at-login, app capability checks
└── UI/
    ├── Settings/   # native Settings scene and panes
    ├── FlowBar/    # only custom visual surface
    └── Scratchpad/ # optional recovery/editing window

Tests/OtoTests/
├── Coordinator/
├── Services/
├── Storage/
└── UI/
```

Rules:

- One owner per side effect. A view does not start audio; an audio service does not insert text.
- Protocols exist at system boundaries, not for every tiny value type.
- Keep state values `Sendable`, equatable where practical, and independent from SwiftUI.
- Keep persistence schemas versioned and domain-specific.
- Mirror source boundaries in tests so a future agent can find proof next to behavior.
- Do not add a package merely because it shortens a demo. Pin versions, review licenses, and keep it behind a narrow boundary.
- Keep web/React tooling out of the native Swift target. Inspect ElevenLabs components in a temporary workspace; recreate behavior in SwiftUI.

## Swift and SwiftUI mistakes to avoid

- Do not store injected changing values as `@State`.
- Do not put `@StateObject`/`ObservableObject` ownership in multiple views for one coordinator.
- Do not capture `self` strongly in long-lived audio, hotkey, or notification callbacks.
- Do not assume an actor remains exclusive across `await`.
- Do not hold a lock across `await` or AppKit calls.
- Do not use `.indices` as identity in dynamic `ForEach`.
- Do not build a settings window with fixed canvas dimensions.
- Do not use a custom control when `Form`, `List`, `Picker`, `Toggle`, `Button`, `SettingsLink`, or a native file importer already expresses the behavior.
- Do not make an animation essential to understanding state.
- Do not claim device reliability from unit tests or simulator screenshots.

## Dependency and command hygiene

- Do not use floating `main`, `latest`, or unverified binary URLs in a release path.
- If a dependency cannot be fetched or verified, document the boundary and keep the adapter unimplemented rather than inventing a fake integration.
- Run networked generators such as `pnpm dlx ...` only in a disposable reference workspace, never inside the Swift package.
- Prefer `apply_patch` for source/document edits so diffs are reviewable.
- Avoid destructive Git or filesystem commands unless the target is explicit and the user asked for them.
- Keep build artifacts out of source review; inspect `.build/Oto.app` separately from `Sources`.

## Evidence discipline

Every future handoff must state:

1. What changed for the user.
2. Which files changed and why.
3. Which automated tests ran.
4. Which signed-build or real-device checks remain.
5. Which assumptions, OS requirements, permissions, and risks remain.

The most trustworthy product claim is often “implemented, unit-tested, and awaiting real-device validation.” Do not replace that with a confident sentence that the environment cannot prove.
