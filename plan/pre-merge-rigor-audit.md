# Pre-merge rigor audit — abu-dhabi → main (pill v3→v8b arc)

## Goal

Rigorously verify the full `abu-dhabi` diff vs `origin/main` is solid before merging:
no conflicting, badly-implemented, or outdated code; SDK + Swift currency confirmed
against the local toolchain (never from memory); propose solidifying changes if needed.

User ask (transcript tail): "before merging make sure all we did on these changes
were solid and rigorously analyse the changes and check nothing is conflicting bad
implemented outdated implemented verify the sdk and latest swift 6.4 and propose
plans if changes and solidifying is needed."

## Spec sources

- `Docs/START_HERE_PRODUCT.md` (canonical on conflict): Apple Speech only, one
  `DictationCoordinator`, Flow Bar is the only custom surface, native Settings.
- Attached transcripts: pill v5 (GPU chase, masksToBounds), v6 (no stagnant dots),
  v7 (errors off pill, waves from frame one), Phase 8 (snap-drag), 8b (haptics).
- Raw sweep attachment (2026-09-22, 51 files): force-unwrap / sleep / unsafe census.
- `plan/phase-8-pill-snap-drag.md`, `plan/phase-8b-snap-haptics.md` (intent record).

## Facts verified against the local SDK (this session, not memory)

| Fact | Evidence |
|---|---|
| Xcode 27.0 (27A266a) | `xcodebuild -version` |
| Swift 6.4 (swiftlang-6.4.0.34.1) | `swift -version`, `xcrun swift -version` |
| SDK MacOSX27.0.sdk | `xcrun --sdk macosx --show-sdk-path` |
| Deployment target 27.0, SWIFT_VERSION 6.0 (Effective 6), default isolation MainActor, bundle `app.Oto` | `-showBuildSettings` + `project.pbxproj` |
| Build clean | `xcodebuild -scheme Oto build` → **BUILD SUCCEEDED** (this session) |
| Tests | Full `xcodebuild test`: **224 passed, 0 failed, exit 0** (this session; transcript's 225 was off by one — 224 `Test case … passed` lines, no failures) |
| `vDSP_create/destroy_fftsetup` NOT deprecated | `vDSP.h:367,372` — no deprecation attribute, plain `extern` |
| Old `installTapOnBus:bufferSize:format:block:` IS deprecated in 27.0 | `AVAudioNode.h:117` `API_DEPRECATED_WITH_REPLACEMENT("installTapOnBus:bufferSize:format:error:block", …macos(10.10, 27.0))` — and the diff correctly does NOT use it |
| Audio uses modern tap | `AppleAudioCapture.swift:151` `input.installAudioTap(onBus: 0, bufferSize: 4096, format: nil)` (S5 modernization intact) |
| Haptics API current | `NSHapticFeedback.h:15-31` — `.alignment` / `.levelChange`, `.default` (=DrawCompleted) / `.now`; code matches exactly (`FlowBarPanel.swift:251-253, 326-328`) |
| Speech path current | `AppleSpeechService.swift:154-172` uses `SpeechTranscriber` + `AssetInventory` + `SpeechAnalyzer`; `SFSpeechRecognizer` (not deprecated in this SDK, but unused) correctly avoided |
| Leftover gates hold | `successFlash`/`flashLayers`/`spinnerAngle` → 0 hits; `Timer(` → 0; `print(`/`NSLog(` code calls → 0 |
| Force unwraps triaged | 6× `baseAddress!` (all `AudioSpectrumAnalyzer` DSP closures on non-empty arrays, synchronous — safe); 1× `noticeDeadline!` (`FlowBarController.swift:242`, nil-guarded 2 lines above — safe); 4× ghost unwraps (`FlowBarPanel.swift:230`, set-just-above — safe). No `as!`/`try!`; one `fatalError` is the standard unavailable-`init(coder:)` nib trap |

## Area verdicts (all read in full this session)

1. **Pill renderer** (`PillLayers.swift`): infinite CAAnimations on render server with
   `motionVisual` re-entry guard; `masksToBounds` + `clipsToBounds` two-level clip;
   shrink transitions skip fade-out (F1b); sway evicted before voice transforms land.
   Solid. No conflicts.
2. **Vanish flow** (`FlowBarController.swift`): generation-guarded melt, drag owns frame
   (no schedule/no fire mid-drag, no stuck task), 150 ms poll, recovery-before-analyzer
   ordering. Solid.
3. **Errors off the pill** (`FlowBarState.swift` + controller): failures project hidden,
   `RecoveryRouter` pure + once-per-key, menu status owns copy. `retryPostToFrontmost`
   still live via `OtoMenuBarView.swift:63` — NOT dead code. Solid.
4. **Snap-drag + haptics** (`FlowBarPosition.swift` + panel): one `snapDuration` constant
   drives glide AND land tick (can't drift); `SnapTickGate` 100 ms refractory; entry tick
   `.levelChange/.default` synced to highlight frame, land tick `.alignment/.now` on
   arrival; both performer calls on MainActor. `.levelChange`-as-detent is off-label per
   the header ("Used by NSMultiLevelAcceleratorButtons") but a deliberated choice
   recorded in `plan/phase-8b-snap-haptics.md`. Solid.
5. **Analyzer** (`AudioSpectrumAnalyzer.swift`): fork feed (`relay.receive` + `box.offer`
   in `OtoApp.swift` — relay/speech untouched), NSLock latest-slot, actor drain ≤30 Hz,
   awaited `stop()` → guaranteed silence. Real-FFT even/odd packing is the standard
   vDSP pattern. Solid; conversion-under-lock on the audio thread is precedent-accepted
   (non-merge-blocking, noted).
6. **Catcher modal** (`NoTargetModal.swift`): prewarmed nonactivating panel, kill-switch
   defaults ON, literal key test-pinned to `NoTargetModalSettings.key`. Copy's 1.5 s
   unstructured `Task` captures a app-lifetime-owned controller — fine.
7. **Settings** (`GeneralPane`/`DictationPane`/`PrivacyHistoryPane`/`SettingsRoot`):
   `@AppStorage` over `FlowBarPosition` (String-RawRepresentable — supported);
   Reinsert removal is clean (menu Retry path intact); setting flip moves a live pill
   via the next 150 ms poll (`show()` → `resize()` with slot position). Solid, no dup
   controls (follows product IA: Flow Bar lives under General).

## Assumptions questioned

- Trackpad-only haptics is Apple-by-design (header: trackpads suppress without touch;
  mice perform nothing) — documented, not a bug. Accepted.
- `visibleFrame` excludes the menu strip (notch lives inside it) → Top slot truly sits
  below the notch on every Mac. Holds.
- Ghost width frozen at grab time: width cannot change mid-drag (controller `!dragging`
  guard on `show()`), so stale-size ghosts are impossible. Holds.
- Midpoint drop belongs to Top ("reads as up there"). Judgment call, tested, kept.

## Proposed solidifying changes (none merge-blocking)

- **S1 (cosmetic):** `FlowBarController.swift:242` `noticeDeadline!` → `if let` binding.
- **S2 (cosmetic):** `FlowBarPanel.swift:230` ghost tuple force unwraps → `guard let`.
- **S3 (deliberately NOT proposed):** sharing the 0.15 s bg-path morph constant with
  `snapDuration` — same value, different semantics (chrome morph vs window glide);
  sharing would couple unrelated motion. Keep duplicated-with-comment.
- Merge order per transcript discussion: merge this arc first, then catcher eyes-on
  verification, then media-mute spike / Phase 7.

## Verification steps

- [x] `xcodebuild -scheme Oto build` → SUCCEEDED (this session)
- [x] `xcodebuild test -scheme Oto` full suite: 224 passed, 0 failed, exit 0 (this session)
- [x] Grep gates: leftovers 0, `Timer(` 0, logging 0, unwraps triaged
- [ ] Manual matrix on trackpad: cold dictate (waves frame one) → stop (loader melts
      straight out) → deny-mic (no pill, menu names it) → drag pill (mid-crossing thunk
      + settle tick) → quit/relaunch (slot persists) → Settings flip (live pill moves)
      → catcher on/off paths

## Risks / deferred

- Tooling dropped/truncated edits twice in this arc's history (caught via build+suite);
  the full test re-run + grep gates above are the backstop — do not merge on stale counts.
- Catcher desktop-dictate eyes-on verification deferred twice — first task after merge.
- Media auto-mute 30-min sandbox probe still unproven — unchanged.

## Open questions

1. Cosmetic S1+S2 before or after merge? (Recommendation: fold into the merge — 4 lines,
   zero behavior change.)
2. Confirm merge target/timing, or hold for catcher verification first?
