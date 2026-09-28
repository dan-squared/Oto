# Catcher history + timeout decision — PLAN (decision record)

Status: DECISION + one comment fix. No behavior change shipped.
Bridge connected (`workspace-99ZB93q2hu`) for follow-up log pulls.

## 1. History: already implemented — you weren't missing code

Verified in-tree today (no memory):

- `DictationCoordinator.swift:395` records EVERY final BEFORE the
  liveness check and insertion attempt — inserted, `targetGone`,
  `insertionFailed`, AND `noTextField` all flow through it. Catcher
  transcripts are recorded by construction, not by special case.
- Deliberately NOT recorded (no transcript exists to keep):
  silent-skip, empty finals, cancels, mic-denied/prep failures.
- Pollution guards (`HistoryStore.swift`): opt-in, OFF by default
  (`historyEnabled`, absent = off); final-text + timestamp +
  bundleID ONLY (never audio, partials, clipboard, target
  contents); blank rejected; 5000-char cap; newest-100 cap;
  30-day eviction; trim + atomic persist on every write.
- Drift fixed here: an in-code comment said "newest-200", the
  constant is 100 — comment aligned to code (behavior untouched).

So if catcher dictations aren't in History: flip **Settings →
Privacy/History → History ON**. That toggle is the entire fix —
no code owed. (If ON and still missing, that's a bug report with
a different shape: reproduce + console pull.)

## 2. Catcher timeout: analyzed — recommendation is NO timer

The ask: auto-hide after ~10s (default), user-customizable.

Against (decisive):
- The catcher is a TO-DO, not a notification. Notifications
  expire; to-dos don't. It holds the ONLY copy of that text once
  the next `begin` clears menu recovery — with History OFF
  (default), a timed-out modal is designed data loss: user looks
  away 10s, text exists nowhere.
- ✕ is already the one-click deliberate dismiss (user SAW it).
  A timer dismisses without seeing — strictly worse safety for
  zero functional gain.
- Customizability cost is real: new Settings surface + defaults
  key + tests + matrix, inviting misconfiguration (10s punishes
  "dictate, get coffee, copy"). A knob for a non-problem.
- Staleness (the apparent motive) doesn't exist: once-per-key
  routing replaces old failure text on each new failure — modals
  never stack, and a surviving modal is current work, not noise.

For (recorded, rejected): tidiness across sessions. Rejected
because tidiness here is purchased with loss risk, and the
retention rule (6C1 Q3) was a deliberate safety call, not an
oversight — overturning it needs loss-proofing a timer can't give
(menu recovery clears on begin; History is opt-in).

Better-targeted alternative IF tidiness ever bites: hide ONLY on
next SUCCESSFUL insertion of a NEW session is equally lossy (old
text ≠ new text) — so also rejected. No follow-up owed.

Verdict: no timeout, no setting, no code. The ✕ stays the
dismissal. Revisit only with loss-proof retention elsewhere
(e.g., History ON by default — a separate product call, not made
here).

## 3. Open questions — none. Nothing to execute.
