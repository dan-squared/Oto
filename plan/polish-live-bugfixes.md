# Plan: Fix Live Download Diagnostics, Cancel `×` Hang, and Message Pill Truncation

## Goal

Fix three live bugs reproduced on macOS 27.2 in the packaged `Oto.app`:
1. **Language model download appears stuck with no feedback** — diagnose & surface macOS Low Data Mode / offline / stalled `mobileassetd` state honestly while preparing.
2. **Cancel (`×`) button in `OtoProgressStatus` does nothing** — clicking `×` must exit the preparing UI immediately and re-enable the Language picker even when Apple's `AssetInstallationRequest.downloadAndInstall()` ignores `progress.cancel()`.
3. **`"Speech unavailable"` Flow Bar pill is still clipped (`"Speech unavaila..."`)** — eliminate AppKit `NSTextFieldCell` truncation on all centered message notices and pin it with a real AppKit truncation test.

## Spec Sources

- `AGENTS.md` (Apple SDK truth, `downloadAndInstall()` confined to `SpeechAssetPreparer.swift`, native `Settings` + `MenuBarExtra`, Flow Bar as only custom surface)
- `plan/productivity-pack-polish.md` (prior polish pass that introduced `OtoProgressStatus`, `cancelPrepare()`, and `messagePadding`)

## Facts Verified Against Local SDK & Live Runtime (`MacOSX27.2.sdk`, macOS 27.2)

1. **Bug #1 — Why Bengali (`bn-IN`) download stalled (`mobileassetd` + `NWPathMonitor`):**
   - `Speech.AssetInventory.assetInstallationRequest(supporting:)` succeeded and `mobileassetd` completed the Pallas catalog lookup with HTTP `200`, queuing `com.apple.speech.asr.transcription.mul-IN^3100.52005.81607.13.303715,0`.
   - `NWPathMonitor` on this Mac reports `status=satisfied, isExpensive=false, isConstrained=true` on `en0(wifi)` (**Low Data Mode** is enabled on Wi-Fi).
   - `com.apple.MobileAsset.DownloadService.Builtin` logged `[Progress]: Stalled` every 30s for 18+ minutes on `BackgroundDownloadTask` because Low Data Mode constrains macOS background asset downloads.
   - `SpeechAssetPreparer` checked neither offline nor constrained network status, so `OtoProgressStatus` spun `"Preparing…"` indefinitely with zero user-facing explanation.
   - Confirmed in `Speech.swiftmodule/arm64e-apple-macos.swiftinterface`: `AssetInventory` exposes `reservedLocales`, `reserve(locale:)`, `release(reservedLocale:)`, `status(forModules:)`, and `assetInstallationRequest(supporting:)`; `AssetInstallationRequest` exposes `progress: Progress` and `downloadAndInstall() async throws`. There is no API to override `mobileassetd`'s Low Data Mode policy.

2. **Bug #2 — Why clicking `×` did not cancel the UI (live Swift probe):**
   - Live probe against `Speech.AssetInventory.assetInstallationRequest(supporting:)` proved that calling `request.progress.cancel()` sets `request.progress.isCancelled == true`, **but `try await request.downloadAndInstall()` never returns** while `mobileassetd` is stalled.
   - In `Oto/Settings/SettingsUIState.swift`, `runPrepare()` executes `await task.value` before setting `isPreparing = false`, and `cancelPrepare()` only calls `prepareTask?.cancel()` without resetting `isPreparing`. Therefore `isPreparing` stays `true` forever, keeping `OtoProgressStatus` on screen and the Language picker disabled.

3. **Bug #3 — Why `"Speech unavailable"` still rendered as `"Speech unavaila..."` (live AppKit probe + screenshot measurement):**
   - Pixel measurement of user screenshot (`394×150` @2x): rendered capsule is ~`139.75 pt` wide while rendered text `"Speech unavaila..."` is `200 px` (`100.0 pt`), with large empty margins on both sides.
   - Live AppKit probe on macOS 27.2 proved why:
     - `VisualizerMath.measureWorkText("Speech unavailable")` = `109.0 pt` (`ceil` of `108.996`).
     - Left-aligned `NSTextField(labelWithString:)` has `fittingSize.width = 113.0 pt` (`+4 pt`).
     - **Centered** (`alignment = .center`) `NSTextField(labelWithString:)` has `fittingSize.width = 117.0 pt` (`cellSize = 116.996`, `expansionFrame = 117.996`, **`+8 pt`** over raw `NSString.size`!).
     - `VisualizerMath.messagePillWidth` used `workTextSlack = 6`, giving `139.75 pt` pill width → `maxLabelW = 139.75 - 24.75 = 115.0 pt < 117.0 pt`.
     - Every single failure notice (`"Microphone error"`, `"Speech unavailable"`, `"Target app closed"`, `"No text field"`, `"Couldn't paste — kept"`) had `cell.expansionFrame != .zero` (truncated) at `slack = 6`, and **zero** are truncated at `slack = 12` (while `"Copied"` still floors cleanly at `dictationWidth = 80.85 pt`).
   - `PillLayersTests.messagePillFitsAllFailureNoticesWithoutTruncation` missed this because it only asserted `frame.width >= ceil(measured) + workTextSlack` (`115 >= 115`) instead of checking AppKit's `NSTextFieldCell.expansionFrame(withFrame:in:) == .zero`.

## Assumptions Questioned

- **Did `downloadAndInstall()` fail due to missing entitlements or API call order?**
  No — `Oto.entitlements` is unsandboxed (only `com.apple.security.device.audio-input`), `mobileassetd` accepted the request, fetched the Pallas catalog (HTTP 200), and queued `mul-IN`, then stalled in `DownloadService.Builtin` because Wi-Fi has `isConstrained = true` (Low Data Mode).
- **Can Oto force `mobileassetd` to download over Low Data Mode?**
  No — `Speech.AssetInstallationRequest` has no `allowsConstrainedNetworkAccess` knob; macOS owns the download policy. Oto's job is to detect offline / Low Data Mode honestly, tell the user clearly why macOS may pause it, and ensure `×` cancels immediately.
- **Should `.message` simply switch to `alignment = .left` instead of increasing slack?**
  Keeping `.center` (when `centerText == true`) AND raising `messageTextSlack` to `12 pt` is cleaner and safer: `"Copied"` still fits inside `dictationWidth` (`80.85 pt`) with zero resize, and `"Speech unavailable"` grows only `6 pt` (`139.75` → `145.75 pt`), guaranteeing zero truncation even on Retina rounding or bold-text accessibility variations.

## Exact File Changes

1. **[Oto/Services/SpeechAssetPreparer.swift](file:///Users/dan_cubed/oto/Oto/Services/SpeechAssetPreparer.swift)**
   - Add a lightweight `NetworkPathCondition` helper (`online`, `constrained`, `offline`) using `Network.NWPathMonitor` (one-shot snapshot with a short fallback timeout so it never blocks).
   - Before calling `AssetInventory.assetInstallationRequest(supporting:)`:
     - If `.offline`, return `.failed("No internet connection — connect to download this language.")` immediately.
   - Expose `currentNetworkCondition() async -> NetworkPathCondition` so `SettingsUIState` can display an honest Low Data Mode hint when `isConstrained == true`.
   - Observe both `\.fractionCompleted` and `\.completedUnitCount` on `request.progress` (guarded against post-cancel callbacks) so determinate progress updates are never missed.
   - Keep `downloadAndInstall()` strictly inside `SpeechAssetPreparer.swift` (grep gate unchanged).

2. **[Oto/Settings/SettingsUIState.swift](file:///Users/dan_cubed/oto/Oto/Settings/SettingsUIState.swift)**
   - Add `private var prepareGeneration = 0` and an optional waiter continuation (`prepareContinuation: CheckedContinuation<Void, Never>?`) so `cancelPrepare()` unblocks both the UI AND any caller awaiting `runPrepare()` immediately — even if Apple's `downloadAndInstall()` never returns.
   - Add injectable `prepareHandler` and `networkConditionProvider` (defaulting to `preparer.prepareDefaultWithOutcome` and `preparer.currentNetworkCondition`) so unit tests can deterministically test hung downloads, instant cancellation, late stale completions, and Low Data Mode feedback without hitting Apple servers.
   - In `runPrepare()`:
     - Bump `prepareGeneration` and capture `generation`.
     - If `networkConditionProvider()` returns `.constrained`, set `prepareFeedback = "Low Data Mode is on — macOS may pause speech downloads."` while indeterminate; clear it as soon as `progress > 0` arrives.
     - Start a gentle 15 s stall-hint task (cancelled on progress/finish/cancel): if still preparing with `prepareProgress == nil` and `prepareFeedback == nil`, set `prepareFeedback = "Waiting on macOS to start the download…"` so the user is never left guessing.
     - Run the preparation in `prepareTask`; guard ALL state mutations (`prepareProgress`, `prepareFeedback`, `isPreparing`, `LocaleSnapshotCache.shared.invalidate()`, `refreshSpeech()`) on `self.prepareGeneration == generation`.
   - In `cancelPrepare()`:
     - Bump `prepareGeneration += 1`.
     - Cancel `prepareTask` and stall-hint task (`prepareTask?.cancel()`, `prepareStallTask?.cancel()`).
     - Immediately clear `prepareTask = nil`, `prepareStallTask = nil`, `prepareProgress = nil`, `prepareFeedback = nil`, `isPreparing = false`, and resume any pending `prepareContinuation`.

3. **[Oto/UI/Theme/OtoControls.swift](file:///Users/dan_cubed/oto/Oto/UI/Theme/OtoControls.swift)**
   - Give the `×` cancel button in `OtoProgressStatus` an explicit `18×18` circular hit target (`frame(width: 18, height: 18).contentShape(Circle())`) and subtle hover state so clicking it is effortless.

4. **[Oto/UI/FlowBar/VisualizerMath.swift](file:///Users/dan_cubed/oto/Oto/UI/FlowBar/VisualizerMath.swift)**
   - Add `nonisolated static let messageTextSlack: CGFloat = 12` (covers centered `NSTextFieldCell`'s +8 pt internal padding plus +4 pt headroom).
   - Update `messagePillWidth(textWidth:)` to use `let chrome = messagePadding * 2 + messageTextSlack`.

5. **[Oto/UI/FlowBar/PillLayers.swift](file:///Users/dan_cubed/oto/Oto/UI/FlowBar/PillLayers.swift)**
   - In the `.message` branch of `update(...)`, compute `measured = ceil(VisualizerMath.measureWorkText(label.stringValue)) + VisualizerMath.messageTextSlack` and size `f.size.width = min(max(ceil(label.fittingSize.width) + 2, measured), maxLabelW)`.
   - Add `@MainActor func messageIsTruncated() -> Bool` test hook returning `(label.cell as? NSTextFieldCell)?.expansionFrame(withFrame: label.bounds, in: label) != .zero`.

6. **Tests**
   - **[OtoTests/FlowBar/VisualizerMathTests.swift](file:///Users/dan_cubed/oto/OtoTests/FlowBar/VisualizerMathTests.swift)**: assert `messageTextSlack` in `messagePillWidthGivesAllNoticesSlackAndCapsulePadding()` and confirm `"Copied"` still equals `dictationWidth`.
   - **[OtoTests/FlowBar/PillLayersTests.swift](file:///Users/dan_cubed/oto/OtoTests/FlowBar/PillLayersTests.swift)**: assert `#expect(!pill.messageIsTruncated())` for `"Copied"` and all 5 failure notices (`"Microphone error"`, `"Speech unavailable"`, `"Target app closed"`, `"No text field"`, `"Couldn't paste — kept"`).
   - **[OtoTests/SettingsUIStateTests.swift](file:///Users/dan_cubed/oto/OtoTests/SettingsUIStateTests.swift)**:
     - Test that `cancelPrepare()` flips `isPreparing` to `false`, clears `prepareProgress`/`prepareFeedback`, and unblocks `runPrepare()` **immediately** even when the underlying download never returns after cancellation.
     - Test that a late completion from a cancelled prepare generation does not overwrite state or interfere with a subsequent prepare.
     - Test that `.constrained` network surfaces the Low Data Mode note while indeterminate and clears it once progress > 0 arrives.

## Verification Steps

1. Run unit tests: `xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests` — expect 0 failures, 0 new warnings.
2. Run grep gates:
   - `downloadAndInstall` appears ONLY in `Oto/Services/SpeechAssetPreparer.swift`.
   - `PrivateCloudComputeLanguageModel` appears in 0 code files.
3. Build and relaunch packaged `Oto.app`, then verify:
   - Triggering `"Speech unavailable"` renders the full unclipped text in the Flow Bar pill.
   - Clicking `"Not prepared"` on an uninstalled language shows the Low Data Mode note (when Low Data Mode is on) and clicking `×` exits preparing immediately.

## Risks / Deferred Decisions

- When `cancelPrepare()` exits immediately while Apple's `downloadAndInstall()` is stuck inside `mobileassetd`, the cancelled `Task` may remain parked in the background until `mobileassetd` eventually finishes or errors out. Because `prepareGeneration` gates all state updates and `request.progress.cancel()` has already been called, it cannot mutate UI state or interfere with subsequent downloads.
- macOS Low Data Mode is a system Wi-Fi setting; Oto cannot bypass it programmatically for `mobileassetd`. Turning off **Low Data Mode** in **System Settings → Wi-Fi → Details…** will let Apple's `mobileassetd` immediately resume downloading `bn-IN` and other speech models.

## Open Questions

None — all three root causes are empirically proven on this Mac. Ready for approval to execute.
