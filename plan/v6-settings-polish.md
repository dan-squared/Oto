# Settings polish round: icon verdict, hoisted state, mono selection, dictionary footer

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

Joins the uncommitted batch (WindowGroup experiment, native sidebar,
icon asset, image-only label, dictionary toggle) — one commit after
the matrix go, per the standing rule.

## 0. Black-background verdict (report-back)

New evidence killed the last code theory: the running build already
uses the image-only template label, and the box persists. Dead list:
combined title+image label (dead — current build is image-only),
duplicate instances (`ps` shows exactly one Oto, PID 35997's
successor), appearance overrides (repo-wide grep: zero),
non-template symbol (SF `waveform` is template by construction).

Leading theory now: **Tahoe's open-menu highlight chip**. For it:
rounded padded chip (rendering bugs don't make pretty rounded
rects), triggers coincide exactly with menu-open moments
(click-to-open; opening the menu to reach Settings), and both
screenshots are tight crops that would hide an open dropdown below
the bar. Against it: nothing — persistence was never established
separate from an open menu.

ONE decisive user test (10 seconds, no code): click the WiFi icon —
does the same dark chip appear behind it while open? Esc — does
Oto's clear with the menu?
- Neighbors do it → OS behavior, case closed forever, zero code.
- Oto-only + persistent → fallback: AppKit-owned `NSStatusItem`
  (template `NSImage(systemSymbolName:)`, highlight-managed by us)
  with the SwiftUI menu hosted in a transient `NSPopover`. Specced
  only as fallback — do NOT build unless the test says Oto-only.

Runtime introspection was attempted and abandoned honestly: Xcode
bridge `po` hangs on trivial expressions in this process (even
`process interrupt` + count), process resumed safely. No conclusions
drawn from it.

## 1. Mic flash: hoist pane state (root cause + fix)

Root cause (`DictationPane.swift:180-192` + `PrivacyHistoryPane`
equivalent): every rail visit destroys/recreates the pane, and
`.task` resets ALL statuses to "Checking…", re-enumerates HAL
devices, and re-probes speech (`preparer.status()` — async, slowest,
hundreds of ms). The flash is the reset-then-refill, every visit.

Fix — new `Oto/Settings/SettingsUIState.swift` (`@Observable`,
owned `@State` by `SettingsRoot`, passed to both panes):
- Holds: readiness/language/feedback/preparing, mic/AX/speech
  texts, devices/default UID — plus today's refresh funcs and tone
  helpers moved verbatim (micTone/speechTone/micDeniedGuidance/
  speechReady/currentInputName, `DictationPane.swift:227-256`).
- `ensureLoaded()` runs once per window open (today's full refresh:
  permissions sync + devices + speech async).
- Pane appear runs `refreshPermissions()` ONLY (synchronous, keeps
  the grant-in-System-Settings-then-return flow live with no flash).
- Panes delete their duplicated @States/refreshers; the 500ms
  calibration poll stays per-pane (equal-value assigns don't
  re-render — harmless).
- Tests: initial-state + tone-mapping on synthetic strings (pure;
  no live hardware reads).

## 2. Sidebar lag (same root cause)

"Laggy open/close" = first-render workload, not animation: every
open/visit re-fired HAL + speech probe + full content rebuild.
The §1 hoist makes re-renders cheap; first open builds views once
(unavoidable, one-time). No animation flags added — matrix judges;
if lag survives, profile before touching motion.

## 3. Monochrome selection, no bold

Sidebar `List` gets `.tint(.primary)` + labels `.fontWeight(.regular)`
14pt. Primary-as-accent = black selection/white text in light,
white selection/black text in dark — the ask, via one modifier.
Risk recorded: if selection ignores tint (verify in matrix
screenshot both schemes), fallback = native `List` kept, selected
row painted via `listRowBackground` wash/ground pill (native
scrolling/selection/AX retained, only the fill customized).

## 4. Dictionary footer (meticulous removal)

Footer becomes `Add rule | Spacer | Clear` — Clear trailing aligns
under the row Delete column at the same 14pt inset. Delete dead:
`showImporter/showExporter/exportDocument/importReport` states,
`.fileImporter/.fileExporter` modifiers, `runExport/runImport`,
`DictionaryExportDocument`, `import UniformTypeIdentifiers` (grep
confirms all UTType uses are transfer-only,
`WritingPane.swift:15,18,27,97-102,194-226`). Clear's
confirmationDialog stays. Snippets footer untouched. Behavior
delta: JSON transfer gone (user: not important) — no other path
reads those states (grep-gated at execute).

## 5. Verification

Build green; suite green twice (flake protocol stands). Matrix:
icon test answer (§0), revisit Dictation 3× (no flash), cold open
smoothness, selection screenshot both schemes, footer alignment
screenshot, full shortcut/catcher/device rounds (shared model
touches two panes — trust but verify).

## 6. Risks

- §1 changes refresh timing: speech/devices refresh per window
  open, not per visit (stale-device edge if USB mic plugs in
  mid-session — menu shows it only after reopen; acceptable, stated;
  permissions stay live per §1).
- §3 tint fallback may be needed (matrix decides, no re-plan).
- §4 is a one-way door for JSON transfer (restore = revert commit).
