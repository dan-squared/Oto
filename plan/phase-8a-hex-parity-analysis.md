# Phase 8a (analysis): text-field detection Hex-parity — what it costs

> Analysis only — nothing implemented, nothing changed. Answers: "make it
> work everywhere like Hex — what will it cost us?" Sources are the local
> Hex checkout (`/Users/dan_cubed/conductor/repos/hex`, 2.1.18; `hex-v1`
> is byte-identical — one codebase) read line-by-line this session, plus
> Oto's own insertion path re-read against it.

## Goal

Decide how far Oto's insertion path moves toward Hex's "posts everywhere"
model, with priced options (code size + test churn + matrix + product risk)
instead of vibes.

## Spec sources

- Hex (canonical): `src/paste.rs` (956 lines — full read of `paste_text`,
  `commit_prepared_paste`, `complete_paste`, clipboard capture/restore),
  `src/keyboard.rs` (`post_key_code`, `shortcut_event_specs`,
  `KeyboardEvent`), `src/accessibility.rs` (203 lines — window title +
  selected-text reads ONLY, never gates), `src/parakeet.rs` (worker wiring,
  `commit` = cancellation only), `docs/` (no paste-limitation notes found).
- Oto (current): `Oto/Services/RealTextInsertion.swift` (readyPID +
  postPlacedText + retry), `EditableFocusCheck.swift` (AX verdicts),
  `TranscriptPipeline` (untouched), `Oto/UI/FlowBar/*catcher*` +
  `OtoMenuBarView` (recovery surfaces), `Docs/START_HERE_PRODUCT.md`
  (recoverability + honesty rules — canonical).
- Local SDK truth: unchanged from 7d (CGEvent/HID/AX APIs as used).

## Findings — Hex's actual model (not the myth)

1. **No target capture.** Pastes to whatever is frontmost at paste time.
   App-switch mid-dictation pastes into the NEW app, silently.
2. **No field detection at all.** `paste.rs` contains zero AX reads —
   no focus check, no role check, no secure-field check, no void divert.
   `accessibility.rs` reads focused-window title + selected text for
   app-context only, never to permit/refuse a paste.
3. **No trust gating.** No `AXIsProcessTrusted` check anywhere in the
   paste path (only a test-ignore note about trusted processes).
4. **No pre-post guards.** No modifier drain, no reactivation, no
   frontmost re-check, no write-verify poll, no clipboard marker.
5. **Keystroke** (`keyboard.rs:296-344`): full Command-down / V-down-up /
   Command-up to the HID tap, ZERO inter-event sleeps, NULL (default)
   event source, synthetic marker in `EVENT_SOURCE_USER_DATA`, layout-aware
   `v` keycode via UCKeyTranslate. Notably MISSING vs Oto: the
   `NX_DEVICELCMDKEYMASK` device bit Oto sets for Qt/Java apps.
6. **Clipboard**: EAGER capture during dictation (`prepare()`), flavor
   filtering (drops system-translated flavors), change-count abort
   ("clipboard changed while preserving"), generation-guarded restore
   after 500 ms on a spawned thread, 100 ms post settle ("not an
   acknowledgment" — their own comment admits loss is possible).
7. **Failure model**: `Err` + log. No recovery transcript at the paste
   layer, no catcher, no retry UX in this path.

## Gap table — where Oto refuses/diverts and Hex posts

| Situation | Oto today | Hex | Who's right |
|---|---|---|---|
| Normal text field | Posts (guarded) | Posts | Same outcome, Oto slower (~250-400 ms of gates) |
| Exotic AX tree (unknown roles, async Chromium, Java, VMs, games) | Diverts to catcher on persistent void | Posts (usually lands — a caret exists) | Hex, on reach |
| Secure password field | Refuses (subrole gate) | Posts (OS delivers synthetic paste; password managers prove it daily — Oto's own comment admits this) | Hex, on reach |
| Finder/desktop/void (nowhere to paste) | Catcher explains | Keystroke sent, nothing lands, user confused | Oto, on honesty |
| App switched mid-dictation | Fails honest, transcript kept | Pastes into the WRONG app, silently | Oto, on safety |
| Trust revoked mid-flight | Refuses + restores | Posts into whatever (tap may be dead → silent nothing) | Oto |
| Chromium slow clipboard | Write-verify + 100 ms linger | 500 ms linger, no verify | Split (verify vs linger — matrix question) |
| Dvorak/Colemak layout | Hardcoded `kVK_ANSI_V` (wrong key) | UCKeyTranslate resolution | Hex, flat-out bug in Oto |
| Qt/Java apps | Device-bit set deliberately | Plain `1<<20`, no device bit | Oto, on paper |

## Cost breakdown (priced options, not a single quote)

**A. Delete gates (~50 prod lines + ~15 tests die):** focus-check call,
frontmost race guard, reactivation, modifier drain, write-verify. CHEAP in
code, EXPENSIVE in honesty: void-pastes beep nowhere (user blames Oto),
mid-dictation switches mis-paste (silent wrong-app text — the nightmare
case target capture exists to prevent), password behavior becomes
"it just works" (actually a reach WIN — consider independently).
RECOMMENDATION: do not delete as a bundle. Price each gate separately in
matrix instead (see steal-list).

**B. Keystroke convergence (1-line A/Bs + matrix):** null vs private event
source, 10 ms keySteps vs zero, device-bit on/off. Each is a one-line
change with a device-matrix verdict per app class (Chromium, Electron,
Qt/Java, terminals). CHEAP. RECOMMENDATION: run as A/Bs on the user's
actual apps before any gate deletion — half the "everywhere" gap may be
keystroke shape, not policy.

**C. Layout-aware V keycode (~100 lines + tests):** port UCKeyTranslate
resolution for the paste key. Small, no policy impact, fixes Dvorak
outright. RECOMMENDATION: just do it (standalone slice, no matrix needed
beyond one Dvorak check — or even US-only review of the table).

**D. Eager clipboard snapshot at session start (tiny):** capture in
`begin`/`finalize`-start instead of at insert. Saves single-digit ms
(capture is already fast) — nearly free, nearly pointless alone. Only
with a bigger finalization-latency pass. RECOMMENDATION: defer.

**E. Restore linger 100 ms → 500 ms (one constant + matrix re-tune):**
Yap tuned 100 ms against the double-paste window; Hex chose 500 ms for
slow readers. This is an EMPIRICAL question, not a size question — the
cost is matrix time on the user's slowest app, not code.
RECOMMENDATION: A/B with B.

**F. Drop target capture + reactivation (the real price):** Hex's headline
"works everywhere" is 80% "never refuses". Adopting it means deleting the
app-switch guard (silent wrong-app pastes), the void divert (silent
no-ops), and the trust refusal — plus ~15 fail-closed tests and their
whole device-matrix cover, REPLACED by per-app "paste lands" verification
(Finder, 1Password, Terminals, Electron, browsers, VMs, games). The matrix
work DWARFS the code work (days, not hours), and every silent failure
becomes a support ticket instead of a catcher card. RECOMMENDATION: do
not adopt. Oto's recoverability (catcher/auto-copy/menu retry + "never
claim success from a paste") is the product differentiator AND a product-
doc rule — Hex parity here means deleting the product.

## Steal-list (take from Hex regardless — cheap, no policy change)

1. Layout-aware paste keycode (C above) — real bug, do first.
2. A/B null event source + zero-step posting (B above) on the user's apps.
3. Linger A/B 100 vs 500 ms (E above) on the slowest real app.
4. `EVENT_SOURCE_USER_DATA` synthetic marker (one line in
   `postFullCommandV`) — lets device trails distinguish Oto keystrokes
   from hardware in logs. Free observability.
5. Keep: device bit, change-count+marker restore, write-verify,
   catcher/recovery, target capture, secure-field refusal (revisit ONLY
   with explicit product sign-off — it verlangsamts nothing and protects
   the only truly sensitive case).

## Verification (if any slice is approved)

- [ ] Build green; touched-suite unit green; full suite calm.
- [ ] Per-slice matrix on the user's actual apps (named apps, named
  outcomes — "works in X" per app, not "feels fine").
- [ ] No silent behavior change without a matrix row proving it.

## Risks

- The siren call is F (delete the guards). Its cost is measured in
  support tickets and silent mis-pastes, not lines of code. The analysis
  recommends against it explicitly.
- Hex's no-verify + 500 ms linger is itself lossy BY THEIR OWN COMMENT
  ("longer stalls can still lose a paste") — parity is not superiority.
- Dvorak keycode is the one flat-out Oto bug found; everything else is a
  trade, not a fix.

## Open questions

1. Approve the steal-list order (C → B/E A/Bs → marker), F rejected?
   (Recommendation: yes — C first, it's the only outright bug.)
2. Secure-field refusal: keep (my recommendation — the one gate with a
   security story) or product-sign-off to match Hex's post-anywhere?
3. Which 3–5 real apps form the A/B matrix? (Recommendation: the user's
   daily drivers including the slowest Electron app + one terminal +
   Finder-as-void-control.)
