# Yap reference — freshness assessment (2026-09-19)

Clone: `/private/tmp/yap-reference` at `6596874` ("Bump version to 0.1.12",
2026-09-14 — 5 days old). Verdict: CURRENT, safe to reference for
backend boundaries with the rules below.

## What is modern (matches Oto's target path)

- Speech stack is `SpeechAnalyzer` + `SpeechTranscriber` +
  `AssetInventory` (`Sources/Services/TranscriptionService.swift`) —
  the exact Apple-only offline path Oto's spec mandates. Not legacy cloud.
- Apple Silicon only (`ARCHS: arm64`), macOS 26+ deployment target,
  signed/notarized releases, no account/cloud/audio-exfil model.
- Architecture mirrors our plan: `Coordinator/RecordingCoordinator`,
  `Services/` (audio capture, relay, transcription, hotkeys, injector,
  history), `Models/`, `Support/`. Borrow boundary decisions, not code.
- Exactly ONE third-party dependency: `KeyboardShortcuts` 2.0+
  (sindresorhus). Confirms our docs' stance that the modifier-shortcut
  backend is the single external dependency question.

## What to treat as dated or verify-before-use

- Targets macOS 26 SDK; Oto builds on macOS 27 SDK (Xcode 27). Every
  borrowed API must be re-verified in the local SDK — newer variants or
  deprecations may exist.
- Swift language mode is 5.0 with minimal strict concurrency
  (`project.yml`), despite the Swift 6 badge (toolchain, not mode).
  Oto follows its own concurrency rules (coordinator actor,
  snapshot-before-await); do not copy Yap's concurrency style blindly.
- `PermissionsManager.swift` uses `SFSpeechRecognizer` authorization
  APIs for speech permission state. Confirm against the macOS 27 SDK
  whether that remains correct for the `SpeechAnalyzer` path before
  reusing — this is a Phase 2 verification item.
- `KeyboardShortcuts` package: our spec already requires proving key-up
  behavior in the packaged app before pinning. Yap's usage is evidence
  of the pattern, not proof for our build.
- Build system is XcodeGen (`project.yml`, ad-hoc dev signing).
  Oto keeps its hand-managed `.xcodeproj` (Xcode MCP edits it directly).
  Do NOT adopt XcodeGen.

## Usage rules (all agents)

1. Reference for contracts and failure modes; reimplement in Oto-owned
   code. Never copy files wholesale; never add Yap as a dependency.
2. Attribute deliberately if any expression is copied (MIT license).
3. Check this file's date: if older than ~2 weeks vs Yap upstream,
   refresh the clone and re-verify the "dated" list above.
