# Oto — agent rules

Read `Docs/START_HERE_PRODUCT.md` first. It defines the product boundary,
settings IA, and phased working order. Numbered plans live in
`Docs/OTO_REBUILD_PLAN/`. `Docs/START_HERE_PRODUCT.md` is canonical on
conflict (the copy under `OTO_REBUILD_PLAN/` is a duplicate).

## Apple documentation is source of truth

Use Apple docs for all platform behavior (SwiftUI scenes, Speech,
shortcuts, TCC). Key references:

- https://developer.apple.com/swiftui/get-started/
- https://developer.apple.com/swift/get-started/
- https://developer.apple.com/documentation/SwiftUI#Overview
- https://developer.apple.com/macos/resources/
- https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
- https://developer.apple.com/documentation/swiftui/settings
- https://developer.apple.com/documentation/swiftui/settingslink
- https://developer.apple.com/documentation/swiftui/navigationsplitview
- https://developer.apple.com/documentation/swiftui/form
- https://developer.apple.com/documentation/swiftui/menubarextra
- https://developer.apple.com/documentation/speech/speechanalyzer
- https://developer.apple.com/documentation/speech/assetinventory
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel

Fetching `developer.apple.com` over HTTP returns page titles only (JS
site), so prefer local SDK truth on this Mac:

- SDK path: `xcrun --sdk macosx --show-sdk-path`
  (currently `MacOSX27.0.sdk`, deployment target 27.0)
- Obj-C headers, e.g. Speech:
  `$SDK/System/Library/Frameworks/Speech.framework/Headers/`
- Swift APIs (`Speech`, `FoundationModels`, SwiftUI): inspect via
  `$SDK/.../*.swiftmodule` / `.swiftinterface`, or jump-to-definition in
  Xcode. Never guess availability — confirm with headers and `#available`.
- `~/Library/Developer/Xcode/DocumentationCache/` is a Spotlight index,
  not greppable text. Use Xcode's Documentation window
  (Window → Developer Documentation) to read it.

## Working agreement — plan before execute

- `Docs/` is the prior project's research brain. Never delete, move, or
  rewrite it without an explicit user instruction.
- For every change, write a plan first under `plan/` (one file per
  phase/task): goal, spec sources, facts verified against the local SDK
  (never from memory), assumptions questioned, exact file changes,
  verification steps, risks/deferred decisions, and open questions.
- Report "planning finished" and wait. Implement only after the user
  says "execute". The user reviews the plan, then approves.

## Stay current — research before deciding

Oto tracks the latest Apple platform. Never implement from memory alone
when a newer API may exist:

- Before adopting any framework API, check what is new: the latest
  Xcode release notes, the "What's new" pages for the relevant
  framework, and the API's availability in the local SDK
  (`MacOSX27.0.sdk`, deployment target 27.0). Prefer current APIs over
  deprecated ones; confirm with headers/`.swiftinterface`, not memory.
- For third-party packages, use the `context7` MCP tools to pull current
  documentation before choosing versions or patterns
  (prompt with `use context7`). Do not pin a dependency until its
  release, license, package identity, and on-device behavior are
  verified (per `Docs/START_HERE_PRODUCT.md` engineering rules).
- Record consequential choices (API picked, alternatives rejected, SDK
  version checked) briefly in the commit message or the relevant plan
  doc, so later agents inherit the reasoning instead of re-researching.
- If the local Xcode/SDK is older than what the docs describe, say so
  explicitly and stop — do not code against APIs you cannot compile.

- Xcode 27.0 is installed. Build with:
  `xcodebuild -scheme Oto -destination 'platform=macOS' build`
- Run tests with `xcodebuild test -scheme Oto -destination 'platform=macOS'`.
- TCC permissions and global shortcuts are only valid in the packaged,
  signed `.app` — never validate them from a raw executable.
- If Xcode's official MCP bridge is configured for this workspace
  (`xcrun mcpbridge`, enabled under Xcode Settings → Intelligence →
  Model Context Protocol), prefer its tools — they act on the project
  open in Xcode. The project must be open in Xcode first.

## Engineering constraints (from rebuild plan)

- One `DictationCoordinator` owns session state; views never start audio
  or insert text. Finish/cancel are idempotent and mutually exclusive;
  every async result is checked against the active session ID.
- Apple Speech is the only transcription path. No cloud fallback, no
  asset downloads on shortcut press, no third-party model runtimes.
- Target app/screen is captured at session start, never inferred at
  insertion. Never claim success from a paste event alone — keep the
  transcript recoverable.
- One native `Settings` scene + `MenuBarExtra`. No custom traffic lights,
  toggles, or second settings window. Flow Bar is the only custom surface.
