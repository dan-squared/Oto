# Slice 6B Flow Bar — SDK 27.0 + Swift 6.4 re-plan — PLAN ONLY

Status: PLANNING ONLY (2026-09-22). Nothing implemented. Awaiting `execute`.
Slice 6B spec in `plan/phase-6-flowbar-writing-history.md` (§5E + §6 items
10–16) STANDS. This file records only what today's re-check against the
connected Xcode changed: two citation corrections, line-drift updates, one
new device-check, and the Swift 6.4 decision. No behavior change.

## 1. Goal

Build the Flow Bar (pill panel + projection model + visualizer + analyzer +
controller) exactly per §5E, with every framework citation re-proven today
against Xcode 27.0 (`27A266a`), `MacOSX27.0.sdk`, Apple Swift 6.4 compiler,
deployment target 27.0.

## 2. Method (how this re-plan was produced)

- Connected via Xcode bridge: `Oto.xcodeproj` open (`workspace-RMRkmepW10`,
  scheme Oto, destination My Mac). Stays open for the build.
- SDK truth: header + `.swiftinterface` grep on the local 27.0 SDK
  (full table in this plan's §3 — delegated to a clean-room grep pass, all
  hits quoted with file:line).
- Docs truth: Xcode `DocumentationSearch` (local, current releases) for
  `NSPanel` configuring-panels, `Canvas` renderer + `animation(_:value:)`,
  `AVAudioConverter` sample-rate conversion, Swift concurrency build
  settings (`SWIFT_STRICT_CONCURRENCY`, `SWIFT_APPROACHABLE_CONCURRENCY`).
- Source truth: current `Oto/` seams re-read today (paths drifted since v2 —
  corrected below).

## 3. Facts verified today

### 3a. Project settings (via `xcodebuild -showBuildSettings`, bridge target Oto)

- `MACOSX_DEPLOYMENT_TARGET = 27.0`, `SDKROOT = …/MacOSX27.0.sdk`.
- `SWIFT_VERSION = 6.0` (language mode), compiler Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`).
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Consequence: strict concurrency is complete (errors, not warnings);
  every new 6B type follows the proven shapes — `Sendable` + explicit
  `nonisolated` pure helpers + `@MainActor` model. No new 6.4 feature is
  required; the re-plan deliberately uses nothing version-gated beyond
  what §3b proves present.

### 3b. SDK citations — all PRESENT, two citation corrections (behavior-neutral)

- `NSWindowStyleMaskNonactivatingPanel = 1 << 7` — `NSWindow.h:66` EXACT
  (v2's `:66` still exact, no drift).
- `collectionBehavior` bits (`CanJoinAllSpaces :130`, `FullScreenAuxiliary
  :141`), levels (`NSFloatingWindowLevel :194`), `orderFront :423` /
  `orderOut :425`, `hidesOnDeactivate :416`, `animationBehavior` (`:162–167`,
  `:540`) — all present, no deprecation.
- `NSPanel.h:15–17`: `floatingPanel` (getter `isFloatingPanel`) /
  `becomesKeyOnlyIfNeeded` / `worksWhenModal`. Rest of file is deprecated
  C alert functions — untouched.
- `NSScreen.h:30–31` screens/mainScreen; `:72–73` `CGDirectDisplayID`
  `API_AVAILABLE(macos(26.0))` — fine at deployment 27.0.
- `NSEvent.h:527` `+mouseLocation`. `CGDirectDisplay.h:20`
  `uint32_t CGDirectDisplayID`.
- `Canvas` = `SwiftUICore` struct (2 decls, `:22244`/`:22270`, one struct
  under `#if` branches, `@_originallyDefinedIn(module: "SwiftUI",
  macOS 15.0)`); `import SwiftUI` re-exports — citation only.
- `accessibilityReduceMotion :23466` + `accessibilityReduceTransparency
  :23459` in SwiftUICore `EnvironmentValues` — v2 stood, re-confirmed.
- `NSPanel` count = 0 in both SwiftUI + SwiftUICore swiftinterfaces —
  panels stay AppKit-bridged, unchanged.
- vDSP FFT (`create_fftsetup :367`, `fft_zrip :840` family) `API_AVAILABLE`,
  no deprecation on the cited path (nearby `fft3/fft5` deprecated —
  untouched).
- `AVAudioConverter :162` + `convertToBuffer:fromBuffer:error: :287` /
  `convertToBuffer:error:withInputFromBlock: :303`; `AVAudioPCMBuffer`,
  `AVAudioFormat` present, no deprecation.
- ★ CORRECTION 1: `keyboardShortcut` / `KeyboardShortcut.defaultAction`
  (`:27399`) / `.cancelAction` (`:27400`) / `KeyEquivalent` live in the
  **SwiftUI** module (`SwiftUI…swiftinterface:27359–27430`), zero hits in
  SwiftUICore. Usage `.keyboardShortcut(.defaultAction)` /
  `.keyboardShortcut(.cancelAction)` is valid — cite SwiftUI.
- ★ CORRECTION 2: `NSHostingView` has NO AppKit header (zero hits in
  AppKit); it is `SwiftUI.NSHostingView` (`SwiftUI…:12074`,
  `@MainActor`-isolated `open class`). The bridge file imports SwiftUI
  (which re-exports AppKit types on macOS) — cite SwiftUI, not AppKit.
- Deprecation sweep: NONE on any cited API.

### 3c. Source seams re-pinned (line drift since v2 — behavior identical)

- `DictationState` now `Oto/Models/DictationState.swift:117` (was
  `DictationState.swift`): `recording(SessionContext)` — NO level/partial
  payload. `onPartial =` has ZERO hits in `Oto/` (property exists
  `AppleSpeechService.swift:116`, invoked `:259/261`, but nobody wires it).
  Payload-free projection stands verbatim.
- `coordinator.state`: `DictationCoordinator.swift:23` `private(set) var` —
  controller poll reads across isolation, no coordinator edits, unchanged.
- Relay: `AudioBufferRelay.swift:42` single `sink`; `attach` OVERWRITES it
  (`:72`). Fork stays at `OtoApp.swift:49–51` (`bufferHandler` closure:
  `relay.receive` + analyzer `offer`). v2's `:72`/`:42–44` refs drifted;
  mechanism identical.
- Target display: `RealTargetCapture.swift:47/73` same `deviceDescription
  ["NSScreenNumber"]` technique; `TargetApplication.displayID` +
  `SessionContext.targetScreen` already plumbed (`DictationState.swift`
  :40/:81) — Flow Bar positioning step 1 reuses them, no new capture.
- Tap: `format: nil` (`AppleAudioCapture.swift:151`) → hardware format,
  variable rate/channels. Precedent: speech path converts via its OWN
  converter; analyzer gets its OWN instance too (never shared). A
  `BufferConverter.convertBuffer(_:to:)` (`BufferConverter.swift:31`,
  `nonisolated`) already exists — analyzer owns a private instance of the
  same shape (reuse type, not instance).

### 3d. Docs deltas with teeth (one new device-check)

- `NSPanel` docs (current): nonactivating panels become key ONLY if the
  hit view opts in via `needsPanelToBecomeKey`. Consequence: Stop/Cancel
  CLICKS are the guaranteed path; whether Return/Escape key equivalents
  fire in a never-key panel is UNPROVEN — recorded as device-check D1
  (primary finish is key-up anyway; shortcuts are backup, idempotent via
  `cancel(sessionID)` either way). No spec change.
- `Canvas` renderer + `animation(_:value:)` current; `AVAudioConverter`
  conversion path current; TimelineView ban stands (policy per 09 §2.2,
  not availability).

## 4. Assumptions questioned (and settled)

- "Ship state-only first (6B2 analyzer later)?" — NO, same as Q2: WITH
  analyzer, state-only fallback stays pre-approved on profiling flake.
  vDSP + converter + ≤30 Hz publish are all proven present today.
- "New Swift 6.4 concurrency feature (e.g. approachable-concurrency
  inference) to simplify shapes?" — NO: flag is ON but existing explicit
  shapes build clean with zero warnings; new code copies the proven
  shapes. Predictability beats novelty in a realtime-adjacent slice.
- "AsyncStream broadcast now instead of poll?" — NO: v2 recorded it as
  future-only; poll ownership (100–250 ms, cancel-before-orderOut) stays.
- "`retryPostToFrontmost` for failure-panel Retry?" — YES, unchanged: the
  history-Reinsert removal (68cf975) touched the history pane only; the
  Flow Bar failure panel's Copy/Retry/Scratchpad row per §5E stands.
- "Keyboard shortcuts need key status — switch to activ
...[truncated 2086 chars]