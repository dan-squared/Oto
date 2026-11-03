# Mic TCC rows: why they duplicate, and the card's 5 s cap

Date: 2026-11-03
Trigger: user report — three "Oto" rows in System Settings → Privacy &
Security → Microphone (two dead, one live); `tccutil reset Microphone
app.Oto` does not make Oto appear; the red mic-permission card should last
5 s at most.

## Root cause (found 2026-11-03 10:20, from the tccd log)

The app had `ENABLE_HARDENED_RUNTIME = YES` but no Audio Input entitlement.
Every mic request was therefore refused *before* any dialog could be shown:

```
Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires
entitlement com.apple.security.device.audio-input but it is missing for
requesting={TCCDProcess: identifier=app.Oto, ...}
Policy disallows prompt for Sub:{app.Oto}Resp:{app.Oto};
access to kTCCServiceMicrophone denied
```

Consequences, all observed:

- `AVAudioApplication.requestRecordPermission` returned `false` instantly, so
  `PermissionsManager.microphoneStatus()` read `.denied`;
- the Settings row and the red card therefore offered "Open Settings" and
  opened System Settings — the native dialog could never appear;
- TCC never created a Microphone row for `app.Oto`, so Oto was absent from
  the list no matter how many times the button was pressed.

Fix: add `com.apple.security.device.audio-input` to `Oto/Oto.entitlements`
(the hardened-runtime "Audio Input" capability). The existing request path
(`requestRecordPermission` for `.notDetermined`) then produces the system
modal — no `tccutil` call is needed from the app.

Also confirmed by the same log: the user ran a service-wide
`tccutil reset Microphone` at 10:17:59; tccd published `Delete` events for
both dead path records (`…/Oto-fatehj…/Build/Products/Debug/Oto` and
`…/wan-fatehj…/Build/Products/Debug/Oto`) and for every bundle row. The two
dead rows are therefore already gone.

## Verified facts (this Mac, macOS 27.2 / build 26B123)

- Bundle id is `app.Oto` (`Oto.xcodeproj/project.pbxproj`), team
  `78458476CJ`, Apple Development signing, hardened runtime on.
- `NSMicrophoneUsageDescription` = "Microphone required for dictation."
  (both configurations) — so the app is eligible for the mic TCC row.
- Designated requirement is team-based, not cdhash-based:
  `identifier "app.Oto" and anchor apple generic and certificate
  leaf[subject.CN] = "Apple Development: danielgirma819@gmail.com (XS3DT92WJH)" ...`
  → a rebuild in place does not change the app's TCC identity.
- No `/Applications/Oto.app` or `~/Applications/Oto.app`; the app runs from
  `~/Library/Developer/Xcode/DerivedData/Oto-*/Build/Products/Debug/Oto.app`.
- Two DerivedData copies exist (`Oto-abqxt…`, `Oto-fuorv…`), both
  registered with LaunchServices; the live process is the `fuorv` copy.
- The user-level TCC db on macOS 27 is now
  `/private/var/containers/Data/ProtectedSystem/<uuid>/Data/Library/Application Support/com.apple.TCC/TCC.db`
  (found via `lsof` on the user's `tccd`). It is TCC-protected: reads from
  this shell fail with `authorization denied` (no Full Disk Access).
- The system TCC db (`/Library/Application Support/com.apple.TCC/TCC.db`,
  readable) lists **path-typed clients** (`client_type = 1`) for Oto, e.g.
  - `/Users/dan_cubed/.../DerivedData/Oto-fatehj…/Build/Products/Debug/Oto`
  - `/Users/dan_cubed/.../DerivedData/wan-fatehj…/Build/Products/Debug/Oto`
  (no `.app` suffix → the raw executable, from earlier raw-binary launches;
  `Docs/START_HERE_PRODUCT.md:217` forbids exactly this). Those directories
  no longer exist.
- `tccutil reset <service> <bundle-id>` resolves the second argument through
  LaunchServices; a filesystem path is rejected
  (`No such bundle identifier "…": OSStatus -10814`). So path-typed rows
  cannot be reset individually with the bundle-id form.
- The mic card is fixed crimson (`PermissionCardView.paletteColor = .crimson`,
  user 2026-11-01) — this is the "red one" the report means.
  `PermissionModalController.visibleDuration` is currently 10.0 s.

## Diagnosis

1. The two grey rows are path-typed TCC records left by earlier launches of
   the raw `Debug/Oto` executable from DerivedData directories that have
   since been deleted. Their app path is gone, so LaunchServices cannot
   resolve an icon → generic square, and no code requirement matches → toggle
   off and inert.
2. `tccutil reset Microphone app.Oto` deletes only the bundle-typed rows
   (`client = app.Oto`). It cannot match path-typed rows, which is why the
   dead two survive every reset.
3. A reset also removes the live row, and macOS only inserts a row when a
   process actually asks for the mic. Oto asks lazily — on the first
   dictation, or when Settings → Privacy → Allow is pressed — never at
   launch (07 §5.1). So right after `tccutil reset … app.Oto` the list shows
   no Oto at all until the next request. That is the "Oto doesn't appear"
   observation.
4. Nothing in the app can remove TCC rows: no public API, the user db needs
   Full Disk Access, and SIP protects the container. The supported path is a
   service-wide reset followed by a single fresh grant.

## Fix

### A. Card timeout: 10 s → 5 s (code)

- `Oto/UI/FlowBar/PermissionModal.swift`
  - `visibleDuration = 5.0`; rewrite the doc comment to record the 5 s cap
    (user, 2026-11-03) and that it supersedes the earlier 10 s hold.
  - Update the "full 10s" comment in `show(displayID:position:)`.
- `OtoTests/FlowBar/PermissionModalTests.swift`
  - Pin `visibleDuration == 5.0`.

### A2. Mic entitlement (the actual bug)

- `Oto/Oto.entitlements` — added `com.apple.security.device.audio-input`.
  Without it hardened runtime answers `denied` and suppresses the prompt.
- Requires a rebuild + relaunch (entitlements are part of the signature).
  The designated requirement is unchanged, so TCC identity is unchanged.

### B. Clean the dead rows — already done at 10:17:59

The tccd log for that moment shows a service-wide reset publishing `Delete`
events for both path records and every bundle row, so the two grey Oto rows
are gone. No further action needed. (The steps below are the record of how to
do it again if a raw-binary launch ever creates a new one.)

Order matters; Oto must be quit so it cannot re-grant mid-reset.

1. Quit Oto (menu-bar item → Quit, or `osascript -e 'quit app "Oto"'`).
2. Remove the superseded DerivedData copy and its LaunchServices record (the
   stale `abqxt…` build; keeps one copy registered):
   - `rm -rf ~/Library/Developer/Xcode/DerivedData/Oto-abqxtojacqasivdizaghodxnmymu`
   - `lsregister -u <that>/Build/Products/Debug/Oto.app`
3. Reset the whole Microphone service (this is the only form that reaches
   path-typed rows):
   - `tccutil reset Microphone`
   - Cost: every app currently in the list re-asks the next time it needs the
     mic (ChatGPT, Claude, Conductor, Dia, Hex, Muse, Screendrop, Shazam,
     Telegram, Wispr Flow). No data is touched.
4. Relaunch Oto from the `.app` (never the raw executable) and grant once:
   - `open ~/Library/Developer/Xcode/DerivedData/Oto-fuorvvqiotpmjthfnaxbiekjscga/Build/Products/Debug/Oto.app`
   - Oto → Settings → Privacy → Microphone row → "Allow", or press the
     dictation shortcut once.
5. Result: exactly one Oto row, real icon, granted.

Note: deleting TCC rows directly (`sudo sqlite3 … TCC.db "delete …"`) is not
offered — the macOS 27 user db lives in a SIP-protected container, and even
root writes there are unsupported and reversible only by another reset.

### C. Prevent recurrence

- Keep running the `.app`; a raw `Contents/MacOS/Oto` launch creates a new
  path-typed row each time the build directory changes. This is already the
  rule in `Docs/START_HERE_PRODUCT.md:217` and `AGENTS.md`; the dead rows are
  the evidence it was violated.
- Keep one DerivedData copy registered (step 2), so LaunchServices never
  resolves "Oto" to a deleted path.

## Verification

- `codesign -d --entitlements` on the built app shows
  `com.apple.security.device.audio-input`; the designated requirement is
  unchanged (same TCC identity).
- After relaunch (10:22:56) tccd logs the mic preflight as
  `AUTHREQ_SUBJECT: subject=app.Oto` with **no** "requires entitlement
  com.apple.security.device.audio-input but it is missing" error — the
  hardened-runtime gate is satisfied.
- `xcodebuild test -scheme Oto -destination 'platform=macOS'` — the pinned
  geometry/timeout test and the rest of `PermissionModalTests` pass.
- Manual: trigger a mic failure (deny the mic, press the shortcut) → the red
  card fades out 5 s after it appears, never longer.
- Manual: after step 4, System Settings → Microphone contains a single Oto
  row with the waveform icon and the toggle on.

## Risks / deferred

- Wiping the service is user-visible (other apps re-prompt). Not reversible
  except by re-approving; it is the only supported way to drop path-typed
  rows. Offered as a user-run step, not executed by the agent.
- Rows made by macOS itself for a deleted app cannot be pruned selectively
  even with Full Disk Access on a protected container; a future `tccutil
  list` (present as dead strings in the macOS 27 binary, entitlement-gated)
  may make this scriptable.
