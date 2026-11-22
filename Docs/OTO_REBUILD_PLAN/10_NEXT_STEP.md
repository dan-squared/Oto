# Oto — next-step execution brief

> **Rebuild edition:** This handoff is for the new backend track. Do not resume unrelated UI/model work until the phase gates in [`README.md`](README.md) are met.

This is the current handoff after reading:

- [Product design and execution plan](09_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md)
- [Engineering playbook](08_ENGINEERING_PLAYBOOK.md)
- [Apple Speech implementation plan](07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md)
- [Yap backend audit](14_YAP_BACKEND_AUDIT.md)
- [Reliability test matrix](11_RELIABILITY_TEST_MATRIX.md)
- [Locked rebuild decisions](16_REBUILD_DECISIONS.md)

## Decision

The next milestone is **the packaged-app integration gate for core Apple Speech dictation**.

Do not start Foundation Models, local-model runtimes, spoken snippet triggers, or visual polish yet. The highest remaining risk is not model quality; it is whether one real shortcut reliably starts one session, captures the right target, finishes safely, and inserts text into the right app after permissions, device changes, and cancellation.

## What is already specified or available as reference

- Apple Speech is the only release transcription path.
- Dictation does not silently download or use a cloud fallback.
- Ordinary modifier shortcuts have a documented dependency boundary; pin a verified release only after the new packaged build proves key-up behavior.
- F5/Dictation keys remain on the HID event-tap path.
- Session IDs reject late results after cancellation or replacement.
- Audio delivery is bounded and startup audio is retained while SpeechAnalyzer prepares.
- Audio-engine route changes rebuild a fresh engine.
- The original target application bundle ID is carried through final processing.
- System Events paste and synthetic Command-V fallback are layered.
- Clipboard restoration is marker/change-count guarded.
- Settings uses the native `SettingsLink` route, with the AppKit bridge retained only for the non-activating Flow Bar.
- Settings recovery also uses SwiftUI's `openSettings` action when the menu content is available, so the Flow Bar and Settings rows share one destination.
- Settings follows the reviewed Typa lessons through a native `Settings` scene, a resizable window, padded grouped `Form` content, and no custom traffic-light or titlebar layer. Oto's selected navigation is `NavigationSplitView` with a native sidebar; Typa's `TabView` is reference material, not a second architecture.
- Shortcut calibration now has a native AppKit recorder, suspends global registration while listening, preserves the old value on invalid input, and treats Escape as cancel.
- Hold-to-talk release during Apple Speech preparation is queued as a finish rather than being mistaken for cancellation.
- Audio capture taps the selected input's hardware format, avoiding the 48 kHz device / 44.1 kHz client mismatch seen on some Macs.
- The Flow Bar captures the target screen at session start, keeps its content width-bounded, and classifies speech setup, microphone, accessibility, and generic failures separately.
- The current repository has a signed build and deterministic tests, but those results belong to the old implementation until the replacement passes the same gates.

These are reference capabilities and existing evidence, not proof that the from-scratch replacement is complete. They are not evidence that TCC permissions, F5 interception, Apple Speech assets, or cross-application insertion work on a real Mac.

## Next work, in order

### 1. Make Settings opening and shortcut readiness unambiguous

Code work:

- Validate the native `Settings` scene/`SettingsLink` path in the packaged app; keep the string-based bridge only as a compatibility fallback for non-SwiftUI callers.
- Keep one shared Settings destination for the menu item, Command-Comma, and every permission-recovery action.
- Add a native Dictation settings row for **Test shortcut** once real-device calibration can observe the registered global route.
- The recorder now captures the desired key locally; the acceptance test must still exercise the actual registered global route, not only the recorder.
- Show one of: `Ready`, `Conflicts with another shortcut`, `Not received globally`, or `Requires Accessibility`.
- Keep hold-to-talk and hands-free as separate tested interaction modes; do not treat release as a third mode.

Acceptance:

- Settings opens from the menu bar, Command-Comma, and Flow Bar recovery action in the packaged app.
- A saved shortcut is never labelled ready until a real down/hold/repeat/up sequence succeeds.
- Re-registering a shortcut cannot leave an old callback active.

### 2. Finish target-screen and Flow Bar correctness

Code work:

- Capture the target screen together with the target application at session start.
- Give the Flow Bar that screen for the entire session; do not use `NSScreen.main` at finalization time.
- Verify the six terminal/presentation states: idle, recording, processing, success, cancelled, and failure/permission.
- Keep the pill content width-driven with a maximum, never a hard-coded fixed width.
- Preserve the reduced-motion and reduced-transparency behavior already specified.
- Add repeated start/stop/cancel tests so the panel cannot outlive a session.

Acceptance:

- The indicator stays on the display where the dictation began.
- Stop, Escape, cancel, permission failure, and engine failure all return to a usable ready state.
- No Flow Bar state claims insertion succeeded unless the insertion route was dispatched and the transcript remains recoverable on failure.

### 3. Prove Apple Speech setup and offline behavior

Code work:

- Distinguish unsupported OS, unsupported locale, assets not prepared, assets preparing, microphone denial, and engine failure.
- Keep asset preparation explicit in Settings only.
- Make the recovery action open the correct Settings destination and never start a download from the shortcut.
- Verify that the selected locale used for preparation is the locale used for dictation.

Real-Mac validation:

- Prepare the language once while online.
- Disconnect the network.
- Start, cancel, finish, and repeat dictation without a network connection.
- Confirm that missing assets produce a direct recovery message rather than a generic microphone error.

Acceptance:

- A prepared language continues to dictate offline.
- An unprepared language fails clearly without downloading during dictation.
- Core dictation still works when Apple Intelligence is unavailable.

### 4. Run the cross-application and interruption matrix

Use the signed packaged app and record macOS version, hardware, input device, locale, permissions, and target app version.

Required targets:

- Safari address bar and rich text field.
- Slack or another Electron composer.
- VS Code editor and integrated terminal.
- Terminal prompt.
- A secure/password field where macOS permits the test.

Required interruptions:

- Switch apps while recording.
- Switch apps while finalizing.
- Close the original target app.
- Copy new content while Oto is restoring the clipboard.
- Deny Accessibility after setup.
- Disconnect/reconnect the microphone.
- Change Bluetooth input format.
- Sleep/wake during recording.
- Press the shortcut repeatedly and hold through key-repeat.
- Restart Oto while the shortcut is held.

Acceptance:

- Exactly one insertion or a clear recoverable failure.
- Never paste into the app that became frontmost later.
- Never overwrite a newer user clipboard item.
- A new dictation works after every interruption without relaunching Oto.

### 5. Profile before adding more intelligence

Measure release builds rather than guessing:

- shortcut-to-recording feedback latency;
- recording-to-finalization latency;
- analyzer startup and repeated-cancel cleanup;
- audio relay depth and dropped-buffer count;
- memory during a long session;
- Flow Bar redraw frequency;
- insertion latency and clipboard restoration behavior.

Only after the core gate passes should the project begin the optional on-device intelligence phase. Any Foundation Models work must remain a reversible post-transcript draft and must not sit on the microphone path.

## Release gate

Oto is ready to move beyond core reliability only when all of these are true:

- [ ] Settings opens reliably from every supported entry point.
- [ ] Shortcut calibration passes on the real global path for both interaction modes.
- [ ] Offline Apple Speech dictation works after explicit asset preparation.
- [ ] Flow Bar remains stable through every terminal state and repeated cancellation.
- [ ] Safari, Electron, VS Code, Terminal, and secure-field behavior is recorded.
- [ ] App switching, sleep/wake, permission changes, and microphone changes recover cleanly.
- [ ] No P0/P1 issue remains open.
- [ ] Automated tests, packaged build checks, and real-device evidence are documented separately.

## Do not do next

- Do not add Qwen, Nemotron, Cohere, Parakeet, Whisper streaming, or a model catalog to the release path.
- Do not add cloud transcription, Private Cloud Compute, silent asset downloads, or hidden app-content extraction.
- Do not replace native Settings controls with custom cards, pickers, toggles, or titlebar chrome.
- Do not claim success from a keystroke post alone; preserve the raw transcript whenever insertion is uncertain.
