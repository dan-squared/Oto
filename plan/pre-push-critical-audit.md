# Pre-push critical audit — 4 local commits since `origin/main`

Scope: `origin/main...HEAD` (28 files, +1015/−68). Commits: Phase 12
Items 2–5, speech-allow crash fix, Phase 9 custom transform, Dia probe
fix. Method: full diff read + SDK/header verification
(`MacOSX27.0.sdk`, Xcode 27.0 toolchain Swift 6.4, language mode 6.0).
No code changed for this audit.

Verdict: **do not push as-is — 3 ship-blockers** (§1). Everything else
is shippable with recorded judgment calls (§3) or small follow-ups (§2).

Resolved 2026-10-09 (commit pending, unpushed): §1.1 (both Fill buttons
removed with rationale comments), §1.2 (single `KeptRecovery` value;
`recoveryTranscript`/`recoveryExpectedBundleID` kept as derived
pass-throughs so reads cannot drift), §1.3 (frontmost re-read after the
confirm), §2.1 (bundleID passed at both log sites), §2.2 (guidance uses
the live chip label), §2.3 (onboarding `permissionRow` gains a guidance
slot; speech passes `speechDeniedGuidance`), §2.4 (`speechAllowed`
removed + tests updated). Accepted without code: §2.5 (test-time
announcements harmless — no listener in CI; gating would make tests lie
about the production path), §2.6 (per-row process snapshot is cheap at
page sizes; caching without invalidation would risk stale names).

## 1. Ship-blockers (fix before release)

### 1.1 "Use frontmost app" Fill captures Oto itself — broken by design
`DictionaryPane.swift`, `SnippetsPane.swift` (new buttons). The project
sets **no `LSUIElement`** and never calls `setActivationPolicy` (verified
in `project.pbxproj` + `Oto/App/OtoApp.swift`): Oto runs under the
regular activation policy, so clicking anything in Settings makes Oto
frontmost. Pressing Fill therefore reads `frontmostApplication == Oto`
and writes `app.Oto` as the rule scope — ~always. The rule then never
matches, and the user concludes scoping is broken. This is not a
tuning issue; no in-Settings button can ever observe another app as
frontmost at click time. Options: (a) remove both buttons until a real
capture UX exists (e.g. capture-while-in-target via the existing global
shortcut layer); (b) keep the button but exclude self and say what it
did — still wrong whenever the target isn't second-frontmost.
Recommend (a). Note the tests can't cover this (frontmost isn't
injectable) — another reason to delete rather than keep-and-hope.

### 1.2 `recoveryExpectedBundleID` desyncs by construction
`DictationCoordinator.swift:29`. The transcript and its expected app are
two parallel optionals kept in sync across 4 sites by discipline. The
first future keep-site that sets one without the other (or a refactor
that moves one) produces a confirm dialog **naming the wrong app** —
the user then pastes into the wrong place *because* we told them it
was verified. Confirm dialogs must never misinform. Fix shape (small,
mechanical): one value — `recovery: (transcript: Transcript,
expectedBundleID: String?)?` — set/cleared atomically. Until then,
every reviewer must check all four sites per diff.

### 1.3 Retry names the wrong app across the confirm dialog (TOCTOU)
`OtoMenuBarView.swift`: `front` is read before the `NSAlert`, but the
post goes to frontmost-at-post while the success copy names
frontmost-at-click. Accept the dialog, Cmd-Tab during its dismissal,
and the feedback names an app the text didn't go to. Fix shape: re-read
`frontmostApplication` after the Paste confirmation and use that one
binding for both the post context and the copy.

## 2. Should-fix (real, lower blast radius)

- **2.1 The verdict-log bundle ID is dead.** `logVerdict` gained a
  `bundleID:` parameter (`EditableFocusCheck.swift:244`) but neither
  call site (`:282`, `:304`) passes it — every line prints `app=?`,
  exactly the diagnosis aid the Dia fix was supposed to buy. One-line
  follow-up (`bundleID(for: pid)` exists at both sites).
- **2.2 Custom guidance hardcodes ⌘4** (`IntelligencePane.swift`).
  Re-record custom to Ctrl+4 and the empty-state copy still says ⌘4.
  Use the live chip label (`transformShortcutLabel(kind:)`) instead.
- **2.3 Onboarding denied-speech is a dead end.** The row shows
  "Not allowed" with no button and no Settings pointer (the row
  component has no guidance slot). Settings got guidance; onboarding
  didn't. Users who deny during onboarding get silence.
- **2.4 `speechAllowed` is dead API.** Added for the buttons, then the
  single-slot redesign left it referenced only by tests. Remove it or
  keep it deliberately — currently neither.
- **2.5 Announcements fire during unit tests.** `copy(pasteboard:)`
  posts a real VoiceOver announcement even for scratch-board test
  copies. Harmless (no VO in CI), but a `NSApp` post from a test
  bundle is noise by construction; gate it or record acceptance.
- **2.6 History names re-snapshot the process list per row per render.**
  `AppNames.displayName` calls
  `runningApplications(withBundleIdentifier:)` inside the row body —
  correct, but uncached across re-renders. Cheap today (page-sized
  slices); revisit only with a large-history profile.

## 3. Patches, recorded (shippable as-is, don't gold-plate)

- **3.1 `displayName` reads live UserDefaults** (`WritingPolishService`).
  The audit/refusal copy says the user's custom name — nice — at the
  cost of an impure display function. Tests stay deterministic via
  stash/restore helpers (`TransformTests`). Accepted pattern, but every
  future `displayName` test must seed; document that in the helper
  (done) and don't "simplify" it later.
- **3.2 Trio fallback silently resets a corrupt custom slot.**
  A new-blob-with-garbage-custom decodes the trio and defaults custom.
  Correct priority (trio > custom), no data class harmed. Fine.
- **3.3 Probe allowlist changes non-Figma canvas apps' fate.**
  Miro/Notion-canvas/Excalidraw-style apps that relied on the
  selection flip now divert to the catcher. That's recoverable
  annoyance replacing silent loss — the codebase's stated bias — but
  it IS a behavior change beyond browsers. Matrix item exists in the
  plan; don't ship without running it.
- **3.4 Reset doesn't clear the custom prompt.** Deliberate (don't nuke
  user writing while resetting shortcuts), but it reads inconsistent
  next to "Reset covers four". One line in the Reset area explaining
  scope would preempt the bug report.
- **3.5 `CustomPrompt.init` sanitizes; `load` double-sanitizes.**
  Idempotent, tested, fine — but the next reader will wonder why both.
  The comment says why; leave it.

## 4. Currency (Swift / SDK / Apple API — verified, not recalled)

- Toolchain is Swift 6.4 (`xcrun swift --version`), project language
  mode is **6.0** (`SWIFT_VERSION`, ACP-verified). Not the latest mode,
  but a deliberate conservative pin with `SWIFT_STRICT_CONCURRENCY`
  complete + MainActor default isolation doing the real work. If "latest
  stack" means language mode 6.4, that's a conscious migration, not a
  finding — record the decision somewhere permanent; right now it lives
  only in build settings.
- `SFSpeechRecognizer.requestAuthorization` is current in the
  `MacOSX27.0.sdk` headers — no deprecation marker near the
  declaration (`SFSpeechRecognizer.h:115`). Correct API, no migration.
- `NSAccessibility.post(element:notification:userInfo:)` +
  `.announcementRequested` + `.announcement` + `.priority` verified
  against `AppKit.apinotes` (lines 7972–7975, 8312) — the header prose
  names a different priority key (`NSAccessibilityAnnouncementPriorityKey`)
  than the actual constant (`NSAccessibilityPriorityKey`); the code uses
  the real one. Good catch preserved — do not "fix" to match the prose.
- `NSRunningApplication.runningApplications(withBundleIdentifier:)` is
  a class method (the original `NSWorkspace.shared` receiver failed at
  build). Correct in tree.
- `NSAlert.runModal()` from a MenuBarExtra `Task`: legal on MainActor,
  but a nested modal session inside menu tracking is the heaviest UI
  primitive in this diff — the live matrix item (mismatch dialog) must
  actually run before release; no test can cover it headless.
- Mic row keeps the old below-status button pattern
  (`PermissionRows.swift:19-34`, pre-existing). The clutter complaint
  that reshaped the speech row applies verbatim here — either reshape
  both or record why mic differs. Currently inconsistent by omission.

## 5. Test / proof gaps

- Privacy invariants (prompt never in History/logs) hold by
  construction + word-count-only logging (verified: `WritingPolishService`
  log lines carry counts, never content) — but no test scans for them.
  The plan's "grep bans" are unenforced. A 10-line source-scan test
  would make the guarantee structural.
- The `NSAlert` confirm, the Fill buttons, and the announcement are
  headless-untestable by nature — all three have matrix items, but if
  the matrix doesn't run, they ship unproven. The Fill buttons additionally
  cannot be proven even live without care (see §1.1).
- `FocusProbeTests` hardcodes Dia's bundle ID (verified on this Mac via
  PlistBuddy — fine, but brittle if they rebrand; prefer a comment
  noting the source).

## 7. Resolutions, §3–§5 (2026-10-09, unpushed)

- §3.4: Reset-scope line added in the Transforms card ("Reset restores
  the four shortcuts; the custom name + instruction stay untouched").
- Mic row reshaped to the single-slot contract (button only while
  notDetermined, else status pill) + onboarding mic/speech rows:
  action only while notDetermined, denied gets guidance (onboarding
  `permissionRow` gained a guidance slot). The clutter complaint now
  holds nowhere.
- §5 privacy: `customPromptNeverReachesLogs` source-scan tripwire added
  (`PolishServiceTests`); verified zero hits in-tree.
- §5 Dia ID: source comment added (PlistBuddy, this Mac, 2026-10-09).
- §4 language mode: Swift 6.4 toolchain pinned at language mode 6.0 is
  deliberate (strict concurrency complete does the work); recorded here
  as the permanent note — revisit only for a named 6.4 feature.
- No-code acceptances stand: §2.5, §2.6, §3.1–3.3, §3.5, live-only
  matrices (retry dialog, speech Allow, Fill removal sanity, Docs
  canvas, non-Figma canvas divert, Dia void card).

## 6. What is solid (don't touch)

- Crash fix shape (`nonisolated` request callbacks) — correct executor
  reasoning, TCC-verified failure mode, mic path hardened too.
- Tolerant `TransformShortcuts.load` + dedicated 3-key test — the
  load-bearing risk, genuinely mitigated.
- `RetryOutcome` over Bool — per-cause copy is test-pinned at both
  updated call sites.
- Exhaustive switches absorbing `.custom` (compiler-enforced; build
  proves zero missed sites).
- Single-slot permission rows, stash/restore test hygiene, verdict-log
  shape (modulo §2.1).
