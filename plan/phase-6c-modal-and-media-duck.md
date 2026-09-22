# No-target modal + media auto-mute — PLAN ONLY

Status: PLANNING COMPLETE (2026-09-22, §7 answered — all recommended).
Nothing implemented. Awaiting `execute` (builds 6B pill + 6C1 modal; mute
stays Phase 7). Two features, different phases: the modal is 6C-now, the
mute is Phase-7-later.

## 1. Image analysis (the two modal references, deeply)

Both frames show the SAME surface (two transcripts, one design) — the
"you dictated with nowhere to paste" catcher:

- Dark rounded card (~440–480pt wide, ~150–180pt tall), near-black fill.
- Top row: small white waveform mark left, centered dim hint
  **"Select a textbox first, then dictate"**, circular ✕ right.
- Body: single large light-gray transcript line ("Open ChatGPT" /
  "Hey how are you doing?") — display, not a text field (no caret,
  no selection chrome in either frame).
- Bottom-right: gray rounded **Copy** button. No Retry, no edit, no
  second button.
- Read: a display-only catcher, not an editor. The hint teaches the
  flow (click a textbox → paste); Copy executes it. Minimal on purpose.

## 2. Feature A — no-target modal (NOW, as 6C1)

### Routing rule (decided 2026-09-22 — the whole feature in one line)

Session with a valid target → text goes **into the field** (existing
insertion path, zero new UI). Session with nowhere to paste
(`targetGone` / `insertionFailed`) → **catcher modal**, unless disabled
in Settings → **auto-copy** (today's menu-copy made automatic).
No gradient anywhere; success needs no celebration.

### Modal ON (default) vs OFF

- Setting: Dictation pane toggle "Show catcher when there's nowhere to
  paste", `@AppStorage("app.Oto.noTargetModal")`, default **ON** (the
  modal is the discovery path for the #1 new-user dead end).
- OFF → auto-copy path: on `targetGone`/`insertionFailed`, the kept
  transcript is written to the general pasteboard immediately
  (clipboard discipline: explicit user session just ended, transcript is
  theirs — same primitive as manual Copy, one step earlier) with pill
  feedback "Copied — paste with ⌘V." No modal, no extra click. Menu
  recovery + history retention unchanged underneath.

### Why now, not later

Today a no-target dictate ends in the failure panel / menu recovery —
functional but undiscoverable. The modal turns the #1 new-user dead end
("I dictated into the void") into a guided recovery. It reuses the 6B
pill pipeline (state observation, target screen) and the 6C window work,
so building it with 6C is cheaper than a separate phase. The full
editable scratchpad (TextEditor, key-capable window) stays 6C2/optional —
the images ask for display-only, and display-only ships the value.

### Trigger matrix (exact)

Modal shows when a session produces a kept transcript but NO paste
happened, i.e. coordinator reaches `.failed(_, .targetGone)` or
`.failed(_, .insertionFailed)` (`DictationCoordinator.swift:170–171`,
`:306–307`, `:323–324` — verified today; both set `recoveryTranscript`
before failing) **AND** `app.Oto.noTargetModal` is ON. Pill hides, modal
appears on the session's target screen (falls back through the same
4-step chain). If the setting is OFF → auto-copy path (§2) instead of
the modal. The modal does NOT show for
micDenied/speechPrep/audioCapture/noAudio (nothing to recover — failure
panel copy stays) and never for success/cancel (success = text in the
field, §2 routing rule).

### Layout (match the images)

- `NSPanel`, borderless, **nonactivating** (see §4 — the load-bearing
  decision), floating level, same collection behavior as the pill.
  ~464×168pt. Top row: waveform mark (reuse BarVisualizer static mark)
  + hint "Select a textbox first, then dictate" + circular ✕.
  Transcript (2-line limit, truncation tail), Copy bottom-right.
- Transition from pill: fade + scale 0.94→1 `.snappy(0.3)`, centered on
  the pill's screen — reads as the pill "opening up". Close reverses.
- Copy: pasteboard write + "Copied — paste with ⌘V." feedback inline;
  modal STAYS open after copy (user may need to click a textbox first).
- ✕: closes the view only. Text survives in `recoveryTranscript` +
  history (if enabled) until next `begin` (`:196` clears it) — honest,
  no silent loss.
- Retention (Q3): modal holds its OWN text copy at show time, survives
  the next session, closes only via ✕ or Copy-then-✕. Rationale: killing
  it on next `begin` would destroy the text the user hasn't pasted yet.
- Buttons (Q2): Copy + ✕ exactly like the images. Retry stays in the
  menu (visible, test-pinned); adding a third button contradicts both
  reference frames.

### Files (6C1)

1. NEW `Oto/UI/Scratchpad/NoTargetModal.swift` — SwiftUI content
   (layout above, pure `init(text:)`; Copy via pasteboard).
2. NEW `Oto/UI/Scratchpad/NoTargetModalController.swift` — `@MainActor`
   owner: observes coordinator state (poll already owned by
   FlowBarController — SHARE it, no second poller), shows on the two
   failure cases with session-ID check, owns panel lifecycle
   (show/hide/orderOut, same cancel-before-orderOut invariant).
3. EDIT `OtoApp.swift` — app-scope owner wiring (same pattern as
   FlowBarController in §5F item 18).
4. EDIT Dictation-adjacent Settings (toggle per §2: key
   `app.Oto.noTargetModal`, default ON) + auto-copy branch in the
   failure owner (setting OFF → pasteboard write + "Copied — paste with
   ⌘V." feedback; same `NSPasteboard` primitive as history Copy).
5. Tests: trigger-matrix tests (targetGone/insertionFailed + setting
   ON → show; setting OFF → clipboard holds transcript, no show;
   micDenied/noAudio/success/cancel → no show either way), text-ownership
   test (modal keeps text across a synthetic `begin`), no-focus test
   (panel `nonactivatingPanel` style bit asserted).

## 3. Feature B — media auto-mute with resume (LATER, Phase 7)

### Why later, not 6C

It touches system output volume — needs a sandbox spike FIRST (see risk).
6C stays UI-only and shippable; mute rides behind a proven spike, never
blocking the modal.

### Mechanism (SDK-verified today, `MacOSX27.0.sdk`)

- Read/duck/restore the default output device's
  `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (`'vmvc'`,
  `AudioHardwareService.h:49,70`) via `AudioHardwareServiceGetPropertyData`
  (same header — verified present). `kAudioDevicePropertyMute` (`'mute'`,
  `AudioHardware.h:1306`) is the alternative; volume-save/restore is
  gentler than mute-flag (coexists with user pressing mute mid-duck).
- Owner: `MediaDuck` (`@MainActor`, `nonisolated` HAL calls): on
  `.recording` → save current volume → set 0.0; on EVERY terminal state
  (completed/cancelled/failed) → restore saved. Idempotent per session
  ID (double-restore safe: restore clears the saved slot).
- Crash safety: persist `{duckedByOto: true, savedVolume}` in
  UserDefaults at duck time, clear on restore; on launch, if flag set →
  restore + clear. A kill mid-dictation can never leave the user muted.
- Setting (Q5/Q6): Dictation pane toggle "Mute media while dictating",
  `@AppStorage`, default ON (recommended — speaker bleed ruins
  transcripts; resume is automatic and the toggle is one tap away).
- Explicitly REJECTED: MediaRemote/private `MRMediaRemote*` (private API
  — App Store rejection + breaks yearly); per-app pausing (no public
  API — AppleScript-per-app is fragile and permission-hungry);
  `MPNowPlayingInfoCenter` (read-only for other apps' playback).

### Sandbox spike (gate, ~30 min, FIRST task of Phase 7)

`Oto.entitlements` today: `app-sandbox` + `audio-input` ONLY. Volume-set
from sandbox is UNPROVEN — the HID tap has the same open question at
ship. Spike: minimal sandboxed probe sets `'vmvc'` on the default
output; success → build Phase 7 sandboxed; denial → the mute decision
rides the same sandbox verdict as the HID tap (one decision, not two).
No Phase 7 code before the spike result.

### Files (Phase 7, sketched — detailed plan on phase start)

1. NEW `Oto/Services/MediaDuck.swift` + `MediaDuckTests` (save/duck/
   restore, double-restore safe, crash-flag round-trip with fake HAL).
2. EDIT Dictation pane (+ toggle), `FlowBarController` or coordinator
   observation (duck on `.recording`, restore on terminal — owner TBD at
   phase start), `OtoApp` launch-restore.

## 4. Load-bearing decisions (questioned, settled)

- **Modal is nonactivating, never steals focus.** If it took key status,
  the taught flow (click a textbox, ⌘V) would break — the click would
  land in the modal. Buttons still click (same as pill Stop/Cancel).
  This is the single most important line in this plan.
- **Modal is display-only v1.** The images show no editor; editing is
  6C2-if-wanted, not smuggled into 6C1.
- **Mute saves+restores volume, not a mute-flag,** and persists a
  crash-recovery flag. Three paths (terminal restore, idempotent
  re-restore, launch restore) — no silent-muted-user outcome.
- **No private APIs anywhere in either feature.** Stated so nobody
  reaches for MediaRemote later.

## 5. Verification

- 6C1: build zero warnings; trigger-matrix + ownership + style-bit tests
  green; full suite green. Device: dictate with desktop focused (no
  textbox) → pill → processing → modal on same screen; Copy → click
  textbox → ⌘V lands text; ✕ → menu recovery still holds text; frontmost
  app NEVER changes on modal show (focus-steal probe). Setting OFF →
  no modal, transcript already on clipboard, ⌘V pastes; setting back ON
  → modal returns.
- Phase 7: spike result recorded; duck/restore on built-in + Jabra
  (BT device volume quirks); kill -9 mid-dictation → relaunch restores
  volume; toggle OFF → zero HAL calls (assertable).

## 6. Risks / deferred

- Modal width at 464pt on small screens: position-clamp to visible frame
  (same step-4 fallback as pill).
- Long transcripts: 2-line tail-truncate in modal; full text one Copy
  away + history. Full-text scroll is 6C2 territory.
- Jabra/BT output devices sometimes ignore `'vmvc'` (absolute-volume
  headsets): Phase 7 matrix records per-device; degrade = honest
  "couldn't mute" log, never a failure state.
- Deferred: editable scratchpad (6C2), per-app exceptions for mute,
  duck-to-15% instead of mute (Q5 picks).

## 7. Questions — ANSWERED (2026-09-22, all recommended)

- Q1. Modal timing: **6C1 now with 6C** (display-only, exact image match).
- Q2. Modal buttons: **Copy + ✕** (Retry stays in menu).
- Q3. Modal retention: **holds text until closed** (survives next begin).
- Q4. Mute timing: **Phase 7 after 6C**, behind the sandbox spike.
- Q5. Mute depth + default: **full mute, default ON**.
- Q6. Pill-motion Q1–Q6: **all recommended** (locked in
  `phase-6b-pill-motion.md` §7).
- Q7 (new 2026-09-22). Success routing + modal kill-switch: **valid
  target → field (existing path, no UI); no target → modal when
  `app.Oto.noTargetModal` ON (default ON), auto-copy when OFF.**
  Gradient dropped everywhere.
