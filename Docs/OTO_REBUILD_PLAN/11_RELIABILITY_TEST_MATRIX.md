# Oto reliability test matrix

> **Rebuild edition:** These checks are the parity gate for the new coordinator/services. They are not evidence that the current implementation is production-ready; run them against the replacement boundaries and a packaged signed app.

This is the release-gate checklist for system integration. The unit tests cover
the deterministic parts of shortcut state, cancellation-adjacent reset, and
clipboard preservation. The application-level rows must be run on a signed
macOS build with Microphone and Accessibility permissions granted.

## Automated coverage

The test target verifies:

- Hold-to-talk accepts one key-down, ignores repeats, and emits one release.
- Hands-free emits one toggle per key press and ignores the matching key-up.
- Restarting the event monitor cannot leave the shortcut in a pressed state.
- Clipboard snapshots preserve every pasteboard representation and item order.
- Accessibility failures produce an actionable recovery message.
- Voice activity startup grace, hysteresis, trailing silence, and reset.
- Transcript cancellation paths do not save blank or canceled text.

Run the deterministic suite with:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/oto-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/oto-swift-cache \
swift test --disable-sandbox
```

## Manual release matrix

For every row, verify: press and release behavior, hands-free toggle behavior,
partial/final insertion, Escape/cancel, paste-last-transcript, and clipboard
restoration. Record the macOS version, app version, input device, Apple Speech
language, and
whether the target field is protected.

| Target | Text field | Expected insertion | Important checks |
| --- | --- | --- | --- |
| Safari | Address bar, rich text page field | Text appears at cursor | App reactivation, page focus, clipboard restored |
| Slack | Message composer | Text appears once | Electron focus and repeated shortcut events |
| Electron app | Plain and rich text fields | Text appears once | App switch during finalization |
| VS Code | Editor and integrated terminal | Text appears at cursor | Modifier handling and multiline text |
| Terminal | Shell prompt | Text appears without executing early | Paste event must not send Return |
| Secure field | Password/login field where permitted | Clear failure or insertion according to field policy | Accessibility denial must be actionable; never claim success |

## Lifecycle matrix

1. Start hold-to-talk, release normally, and confirm one final insertion.
2. Start recording, press Escape/cancel, and confirm no insertion or history
   entry is created.
3. Switch applications while recording, then finish. Text must return to the
   application that owned the cursor at start time.
4. Switch applications while finalizing. The original target must still be
   used; if it is unavailable, Oto must show a failure rather than paste into
   the newly focused app.
5. Sleep and wake during recording. Oto must stop cleanly, release the audio
   tap, and allow a new session without restarting the app.
6. Disconnect the selected microphone during recording. Oto must stop cleanly,
   explain the failure, and recover after the device is reconnected or changed.
7. Deny Accessibility access, attempt insertion, and use the recovery action
   to open the correct System Settings page.
8. Put non-text content (rich text, an image, or a copied file) on the
   clipboard, dictate text, then confirm the original clipboard contents are
   restored after the paste transaction.
9. Trigger the shortcut repeatedly, hold it long enough for key-repeat events,
   and confirm only one session starts.
10. Restart Oto while a shortcut is held, then release and press again. A new
    press must work; no stuck recording may remain.

## Pass criteria

- No duplicate insertion.
- No insertion into the wrong application after an app switch.
- No lost clipboard contents after a successful or failed insertion.
- Cancel never inserts, saves history, or leaves the Flow Bar recording.
- Permission and device failures are visible and recoverable.
- A new session works after every tested interruption without relaunching Oto.

Failures should be filed with the exact target application version, macOS
version, permissions state, Apple Speech language, and the last Flow Bar state. Do not
mark an integration row complete from a simulator or a headless test run.
