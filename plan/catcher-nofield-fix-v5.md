# Catcher no-focus fix v5 — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Scope: the divert ONLY (one verdict mapping + logging). Everything
downstream is proven — §2. Merge waits for green + matrix, unchanged.

## 1. Goal

Make the void divert fire when NOTHING has keyboard focus
(desktop/Finder void sessions), while keeping every other behavior
byte-identical. Plus the logging that makes the next device trail
decisive instead of circumstantial.

## 2. Catcher path analysis (stage-by-stage verdict)

Traced end-to-end against the tree + the 7-session Xcode-console
trail (all void sessions → `.completed`/`.inserted`, zero diverts):

| Stage | File:line | Verdict |
|---|---|---|
| Divert (focus check) | `EditableFocusCheck.swift` `syncCheck`, sited `RealTextInsertion.swift` pre-clipboard | BROKEN for genuine no-focus (this plan). Correct for rename/search-field focus (device-proven: the `.txt` rename paste). |
| Coordinator mapping (`.noEditableField` → kept + `.failed(.noTextField)`) | `DictationCoordinator.swift` insert-`switch` | SOLID (unit-tested, suite green). |
| Router match (`.noTextField` → catcher/auto-copy) | `FlowBarState.swift:160` | SOLID (unit-tested both settings). |
| Modal show + pill morph + fallback | `NoTargetModal.swift`, `FlowBarController.swift` route | SOLID in code (units green); DEVICE-UNPROVEN — the trigger never fired on device, so the v4 UI/morph has never been seen live. The matrix (§5) covers it for the first time. |
| Retention, Copy, kill-switch, menu parity, summary copy | unchanged files | SOLID (prior greens + confirmations). |
| Screen source (`.failed` → target screen) | `FlowBarController.swift:347` | SOLID (nil-safe, shared chain). |

Root cause restated (unchanged from diagnosis): `kAXErrorNoValue`
("the specified attribute does not have a value" — `AXUIElement.h`,
re-verified today) is the shape genuine no-focus takes, and the
code maps it to `.unknown` → legacy proceed. The void case
disguises itself as uncertainty. Second defect: proceed paths log
nothing, so trails can't distinguish universal AX failure from
per-app no-value.

## 3. SDK re-verification (today: Xcode 27.0, MacOSX27.0.sdk, Swift 6.4)

- `kAXFocusedUIElementAttribute` (`AXAttributeConstants.h`),
  `kAXRoleAttribute`, `kAXTextFieldRole`/`kAXTextAreaRole`
  (`AXRoleConstants.h`), `AXUIElementCopyAttributeValue`
  (`AXUIElement.h:148`): present, current, no deprecation.
- `kAXErrorNoValue` semantics documented in-header (no-value ≠
  failure). No newer focus-detection API exists in the SDK for
  this purpose (nothing to adopt; stated so it isn't re-asked).
- No entitlement, Info.plist, or TCC change: read-only AX behind
  the existing trust gate (untrusted still fails closed first).

## 4. Exact file changes (minimal by design — 2 files + tests)

1. EDIT `Oto/Services/EditableFocusCheck.swift` —
   a. Pure, unit-testable error mapping (the whole fix):
      `nonisolated static func verdictForFocusError(_ err: AXError)
      -> EditableFocus` — `kAXErrorNoValue` → `.noField`
      (nothing focused IS nowhere to paste); everything else →
      `.unknown` (proceed, today's behavior). `syncCheck` calls it
      on the focused-element read; role-missing (`classify(nil)`)
      stays `.unknown` (an existing element with no role is
      ambiguity, not void — bias preserved).
   b. Verdict logging: `LiveFocusCheck` owns a `Logger(focus)` and
      logs EVERY verdict at info (`verdict=` + pid), plus the raw
      `AXError` code on non-success paths. This is the entire
      observability repair: the next trail names the verdict per
      session, so universal-denial vs per-app-no-value is
      decidable in one matrix run.
   c. Timeout (300 ms), role mapping, call site, and sequel all
      UNTOUCHED.
2. Tests (`RealTextInsertionTests.swift` + existing divert tests
   untouched): `verdictForFocusError` units (noValue→noField;
   failure/invalid/apidDisabled→unknown), divert test asserts the
   new log-independent behavior only (verdict path already pinned).
   No AX in tests (unchanged rule).
3. Contingency (GATED, NOT built): if the matrix shows universal
   `.unknown` with denial-class AXErrors (sandbox refuses reads),
   the AX approach is dead — fall back to reverting the check
   (void returns to known-limitation status, documented) rather
   than heuristics (bundle lists, app-name matching — rejected in
   advance: fragile, permission-hungry, yearly breakage). Device
   evidence triggers this, not speculation.

## 5. Verification steps

- Build clean zero warnings; new tests green; full suite green
  TWICE; gates (no force casts — the ID-gate + `unsafeDowncast`
  precedent stands — banned primitives, coordinator diff empty).
- Device (packaged `.app`, one matrix run, verdicts read live):
  Finder/desktop void → `noField` divert → catcher grows from
  pill (v4 UI/morph seen live for the first time — full v4 matrix:
  morph feel, both schemes, ✕ retains, Copy→⌘V, survival,
  Escape); rename-field/search-field focus → `editable` →
  visible paste (re-confirms the `.txt` verdict); text editors →
  `editable` → insert; any universal-`.unknown` row triggers §4.3
  contingency, not a second guess-fix.
- Then merge (green twice + this matrix).

## 6. Risks

- `kAXErrorNoValue` ALSO covering a case that should proceed
  (attribute transiently unreadable): bounded — the matrix's
  editor rows would show false diverts immediately, and the
  mapping is a one-line revert. Asymmetric stakes favor this
  direction (false catcher = Copy click; false void = text gone).
- New log volume: one line per insertion — negligible, same
  channel as existing insertion lines.
- `AXError` `==` against `kAXErrorNoValue` in Swift: compiles per
  precedent (`== .success` already ships); build proves.

## 7. Open questions — none. `execute` builds §4.
