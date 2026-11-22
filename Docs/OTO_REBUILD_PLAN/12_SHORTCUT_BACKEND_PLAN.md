# Oto shortcut backend boundary

> **Rebuild edition:** Keep ordinary shortcuts and the function-row HID path separate, but converge both into the coordinator state machine described in [`02_RECORDING_WORKFLOWS.md`](02_RECORDING_WORKFLOWS.md). A shortcut recorder is not global verification.

Oto now has one primary shortcut boundary with two physical event sources:

```text
ordinary modifier shortcut  → AppKitShortcutBackend (Carbon package) → HotkeyTransitionState
F5 / Dictation / function row → CGEvent HID tap → HotkeyTransitionState
```

Both paths end at the same transition state machine. The coordinator therefore
does not care whether a key arrived from an AppKit monitor or the HID tap.
Hold-to-talk still starts on the first non-repeat key-down and finishes on the
matching key-up. Hands-free toggles on each non-repeat key-down and ignores
key-up.

## Package boundary (verify before pinning)

The rebuild may use the official `KeyboardShortcuts` package for ordinary
modifier shortcuts, but it must pin an immutable release only after the
packaged build and device tests verify key-up behavior. The package is used
only behind the first-party boundary in
`Sources/Oto/Services/ModifierHotkeyMonitor.swift`; Oto does not expose package types to
preferences, session coordination, or tests. This isolates only the
responsibilities Oto needs today:

- match a recorded key and exact modifier set;
- register ordinary shortcuts through Carbon-backed global events;
- route key-down/key-up and repeat information to the existing state machine;
- leave F5 and function-row keys to the HID event tap.

The package does not own F5/Dictation keys. Those remain on the HID event tap,
and Oto's `HotkeyTransitionState` remains the only source of hold-to-talk and
hands-free transitions. This keeps the package replaceable and prevents it from
becoming a second source of session behavior.

## Package adoption gate

Before release, verify all of the following in a signed macOS build:

1. The selected package release supports the deployment target and Swift toolchain.
2. Normal modifier combinations can be registered, removed, and re-registered without stale callbacks.
3. The package does not claim F5/Dictation ownership; those keys remain on the HID path.
4. The package exposes enough key-up information for hold-to-talk, or Oto keeps the AppKit monitor for that mode.
5. Shortcut changes are persisted by Oto’s `ShortcutConfiguration`, not by two competing stores.
6. Accessibility revocation and wake-from-sleep cause a clear unavailable state and re-registration attempt.
7. The package is license-reviewed and its exact revision is recorded in `THIRD_PARTY_NOTICES.md`.

If any condition fails, keep the first-party AppKit backend. A dependency is
valuable only when it removes tested maintenance without weakening the key-up
and global-path guarantees.

## Non-negotiable limits

- Never route F5 through the ordinary AppKit backend.
- Never start a dictation session from the shortcut backend itself; it emits
  events and the coordinator owns lifecycle transitions.
- Never treat a local recorder as proof that a global shortcut works. Onboarding
  must perform a real global-path calibration.
- Never spawn a per-event unbounded task. AppKit callbacks forward only a tiny
  value event; audio work remains outside this boundary.
