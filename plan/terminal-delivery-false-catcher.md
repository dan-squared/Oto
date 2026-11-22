# Terminal dictation: stop the false "not delivered" catcher

Status: PLANNED. Awaiting "execute".

## Goal

Dictating into Ghostty (and the other terminals that behave the same way)
pastes the text correctly but then opens the failure catcher:

```
focus ... role=AXTextArea sel=true
posted HID Cmd-V
delivery=notLanded elapsed=315ms
failed insertion, transcript preserved ... The text did not appear in the target app
```

Make known caret-opaque terminal apps report `delivery=unverifiable` instead of
`notLanded`, so the pre-v7 "posted, assume it landed" behaviour stands and the
catcher can never fire on a paste the terminal actually took.

This is a false-positive fix, not a weakening of delivery truth: apps that
publish a real caret (TextEdit, Notes, native fields, most Electron editors)
keep the v7 proof and still fail honestly.

## Facts verified

### Oto's current path

- `RealTextInsertion.postPlacedText` captures a `DeliveryProbe` before posting
  (`Oto/Services/RealTextInsertion.swift:532`), posts once, then
  `verifyDelivery` polls for `CaretSample` changes.
- `InsertionTimings` gives a 300 ms base budget, +15 ms/KB, 1.5 s cap, 15 ms
  poll (`RealTextInsertion.swift:80-83`).
- `DeliveryVerification.verify` returns `.notLanded` when the same element
  reports an identical sample after the budget (`DeliveryVerification.swift:112-129`).
- `.notLanded` becomes `.recoverableFailure` with the catcher copy
  (`RealTextInsertion.swift:576-578`, `notDeliveredReason` at `:773-782`).
- `.unverifiable` is already the pre-v7 path: assume the post worked, keep the
  transcript, no catcher (`DeliveryVerification.swift:52-53`, `:94`).

### Why Ghostty cannot answer the v7 question

Verified in the cloned Ghostty 1.4.0 source (`.context/ghostty`, installed
`/Applications/Ghostty.app`, bundle `com.mitchellh.ghostty`):

- `accessibilitySelectedTextRange()` returns the **selection** range, not the
  insertion caret (`macos/Sources/Features/Terminal/SurfaceView_AppKit.swift:2374`).
  With no selection it stays `(0,0)` before and after a paste.
- `accessibilityNumberOfCharacters()` reads `cachedScreenContents`, refreshed
  on a 500 ms cache (`SurfaceView_AppKit.swift:245`, `:254`, `:2395`). That is
  longer than Oto's 300 ms budget, so the count is stale for the whole poll.
- The AX element is a normal `AXTextArea`, exactly as the log shows. Role and
  subrole cannot distinguish a terminal from a native text view.

Result: identical sample → `.notLanded` → false catcher, even though the paste
landed. The 315 ms elapsed in the log is the 300 ms budget plus poll overhead.

### Installed / canonical IDs

| App | Bundle ID | Status |
|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | installed 1.4.0; AX shape proven above |
| Apple Terminal | `com.apple.Terminal` | installed; same terminal-grid class, must be probed before inclusion |

Other terminals (iTerm2 `com.googlecode.iterm2`, kitty `net.kovidgoyal.kitty`,
Alacritty `org.alacritty`, WezTerm `com.github.wez.wezterm`, Warp
`dev.warp.Warp-Stable`, Hyper `co.zeit.hyper`) are **not installed on this
Mac**. Their IDs are vendor-canonical but their AX behaviour is unverified, so
they are not added by this plan.

## Decision

Add a pure, evidence-backed classification:

```swift
/// Apps whose AX caret is not a document-true insertion point: they draw a
/// text grid and publish either a selection-only range or a cached character
/// count. Post-paste proof cannot be trusted there, so the v7 check is
/// skipped and the pre-v7 "posted" result stands. Exact bundle-ID matches
/// only; every row needs evidence in the table above.
enum CaretOpaqueApps {
    nonisolated static let bundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal", // keep only if the pre-merge AX probe confirms
    ]

    nonisolated static func isOpaque(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(
            bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}
```

Wire it at the two places that build a probe:

1. **Main insertion path** (`insert`, `replaceLast`, `replaceSelection`):
   compute `CaretOpaqueApps.isOpaque(target.bundleIdentifier)` and pass it
   through `postPlacedText(..., caretOpaque:)`.
2. **Retry path** (`retryPostToFrontmost`): compute from
   `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`.

When opaque:

```swift
let probe: DeliveryProbe = caretOpaque ? .unavailable : deliveryCheck.probe(for: pid)
```

`.unavailable` returns `.unverifiable` immediately, so there is no 300 ms
poll and no failure path. Log the reason distinctly from "app published no
signal":

```swift
log.info("delivery=\(outcome) elapsed=\(elapsedMs)ms caretOpaque=\(caretOpaque, privacy: .public) target=\(bundleID ?? "?", privacy: .public)")
```

No transcript text is logged.

### Alternatives rejected

- **Raise the delivery budget above 500 ms.** Ghostty's range is selection-only,
  so the caret still never moves; a longer wait only adds latency to every
  terminal paste and still fails.
- **Poll `AXNumberOfCharacters` slower.** Its cache is 500 ms and the check
  has no reliable refresh trigger; reading stale values is not proof.
- **Compare `AXSelectedText`/document content.** Reads user content (privacy)
  and Ghostty returns the selection only anyway.
- **Treat every unchanged caret as `.unverifiable`.** Deletes v7's real
  failure detection and the unchanged-caret test that protects it.
- **Detect terminals by AX role/subrole.** The log proves the role is the same
  `AXTextArea` as native fields.
- **Use `AXIdentifier`/window title heuristics.** Fragile, localisation-
  dependent, and not a stable contract.

## File changes

- **New** `Oto/Services/CaretOpaqueApps.swift` — the classification above,
  with the evidence comment. No AX, no AppKit imports needed.
- `Oto/Services/RealTextInsertion.swift`
  - `insert`, `replaceLast`, `replaceSelection`: pass
    `caretOpaque: CaretOpaqueApps.isOpaque(target.bundleIdentifier)` into
    `postPlacedText`.
  - `postPlacedText`: new `caretOpaque: Bool` parameter; choose
    `.unavailable` instead of probing; add `caretOpaque=` to the delivery log
    line. Keep the existing restore discipline and the `.notLanded` branch
    unchanged for verifiable apps.
  - `retryPostToFrontmost`: same choice from the frontmost bundle ID; log it.
- **New** `OtoTests/CaretOpaqueAppsTests.swift` — pure classifier cases.
- `OtoTests/RealTextInsertionTests.swift`
  - Add a `RecordingDeliveryCheck` (probe counter) next to
    `StubDeliveryCheck`.
  - `opaqueTargetSkipsProbeAndReportsInserted`: target bundle
    `com.mitchellh.ghostty`, scripted probe would say `notLanded`; expect
    `.inserted`, probe count `0`, one HID post, clipboard restored.
  - `opaqueTargetRestoresClipboardOnGrace`: same, with fast timings; assert
    the previous clipboard comes back (the non-landed branch schedules the
    restore rather than restoring immediately).
  - Keep `unchangedCaretFailsRecoverablyAfterOnePost` as the guard that
    verifiable apps still fail honestly.

`DeliveryVerification.swift` and its tests are **not** changed: the decision
core is still "different is the only positive evidence". The new layer only
decides when the question can be asked at all.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'
   -only-testing:OtoTests`
3. **Terminal probe (before merge).** With Accessibility granted to the probe,
   focus Terminal with an empty prompt, read `AXSelectedTextRange` and
   `AXNumberOfCharacters`, paste a word, read again after 100 ms and after
   700 ms. If the range does not include the caret and/or the count is stale
   for 500 ms, keep `com.apple.Terminal`; otherwise remove that row.
4. **Device pass in Ghostty.** Dictate with no selection: text appears, log
   shows `delivery=unverifiable ... caretOpaque=true`, no catcher, clipboard
   restored. Repeat with a selection active.
5. **Regression in a verifiable app.** Dictate into TextEdit/Notes: log still
   shows `delivery=landed`; the unchanged-caret unit test still passes, so the
   catcher still works for a real refusal.
6. **Retry path.** Trigger a retry into Ghostty and confirm it reports
   `posted`, not `notDelivered`.

## Risks / deferred

- **A real failed paste into an opaque terminal now reports inserted.** This is
  exactly the pre-v7 behaviour; the transcript still exists in History, but no
  catcher opens. Logging `caretOpaque=true` keeps the gap observable. A later
  terminal-specific proof (screen text after the 500 ms cache, or terminal
  APIs) can restore verification without guessing.
- **Other terminals still false-catcher** until their rows are evidence-backed.
  Their IDs are listed above; adding them is a one-line set change after a
  probe. This plan deliberately does not guess.
- **Bundle-ID forks** (e.g. nightly builds, renamed distributions) will miss
  the set and keep the old behaviour. That is a missed fix, never a new false
  failure.
- **Helper processes** are not target apps: capture uses the owning app's
  bundle ID, so no helper IDs belong in the set.

## Open questions

- Do you want the other terminals added as a class now (iTerm2, kitty,
  Alacritty, WezTerm, Warp, Hyper), accepting the same "assume posted"
  trade-off without a local probe? Recommendation: no — ship Ghostty +
  Terminal, then add each after its probe.
- Should the catcher copy mention terminals when a verifiable app genuinely
  refuses? Not needed for this fix.
