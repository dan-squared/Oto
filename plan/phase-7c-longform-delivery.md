# Phase 7c: Length-gated delivery (auto-swap for short, notify-when-ready for long)

> Why this exists: a fixed time window cannot cover a 1,000-word dictation,
> and widening it just moves the absurdity. Delivery matches expectation by
> length instead: short text cleans itself invisibly; long text taps you when
> ready. No clocks as the mechanism, no hunting, no surprise rewrites.
> Product first; unbreakable engineering underneath (resource section below).

## Goal

Every dictation length gets exactly one predictable behavior, understandable
by a non-technical user with zero configuration:
- **Short** (≤ long-text threshold): today's swap race — raw lands instantly,
  polish swaps in fast while untouched, raw stands otherwise.
- **Long** (> threshold): raw lands instantly; polish runs detached to
  completion with NO window; a quiet notification delivers it one tap later.
- **Over-context**: fail open silently (raw stands); Manual remains.
- **Off/unavailable**: today's app exactly (unchanged).

## Spec sources

- `Docs/START_HERE_PRODUCT.md` Phase 7 rules (canonical).
- `plan/phase-7b-tuneup-and-upgrade.md` (tune-up + Slice B — this extends it).
- Local SDK truth (this session, `MacOSX27.0.sdk` — never memory):
  `GenerationError` cases exactly: `assetsUnavailable, concurrentRequests,
  decodingFailure, exceededContextWindowSize, guardrailViolation,
  rateLimited, refusal, unsupportedGuide, unsupportedLanguageOrLocale`.
  No pre-checkable context budget exists — over-context arrives as the
  catchable `exceededContextWindowSize` error, so the design catches it
  instead of guessing a size.

## Delivery rules (the whole product in one table)

| Input | Behavior | User sees |
|---|---|---|
| Short, fast polish, untouched | Swap in place | Clean text, nothing else |
| Short, slow/refused/error | Raw stands | Nothing (today's app) |
| Long, polish completes | Notification → one-tap card | "Cleanup ready" → Copy/Dismiss |
| Long, polish fails/errors | Raw stands | Nothing |
| Over-context | Raw stands | Nothing (Manual remains) |
| Off/unavailable/denied-notifications | Raw stands (+ menu fallback for denied case) | Nothing, or menu row |

- **Length gate** `longTextWords` (starting value 150 ≈ a minute of speech;
  matrix-tunes): `wordCount(clean) <= threshold` ⇒ swap race, else notify path.
- **Notification content carries ZERO transcript** (lock-screen privacy):
  title "Cleanup ready", body "Your polished dictation is ready to copy."
  Pinned by test with adversarial input.
- **Denied notifications fallback:** polished waits behind a menu row
  ("Copy polished version") — the only place the friction idea survives, as
  a fallback, never the primary path.
- **Permission timing:** requested once, at the first long polish start
  (in-context, Apple HIG). Never re-prompted; denial is permanent-fallback.
- **The 2s window survives ONLY as the short-path backstop.** The 2-vs-5
  debate is over: short polish reliably fits when warm; long has no window.

## Resource discipline (unbreakable part)

- **Always-warm, cheaply:** prewarm at app launch (only if enabled AND
  available — both are sync property reads) AND at every record start
  (the model warms while the user speaks). Hints only — residency is
  OS-owned; our steady-state footprint is one session + strings.
- **Single-flight generation:** one polish at a time; a new run cancels the
  previous (user-initiated wins; dictation is serial anyway). Bounds CPU,
  battery, and memory by construction — no queues, no piles.
- **Cancel paths everywhere:** new session begin cancels a running long
  polish (its context is stale); toggle-off cancels; sheet/card dismiss
  cancels (existing `.task` death); app quit cancels automatically
  (structured tasks, no orphans).
- **Bounded memory:** drafts are strings (10k words ≈ 60KB); single-slot
  session invalidated per use (existing); output capped (existing scaled
  cap); no caches, no histories, no growth.
- **No new timers or polls:** completion is event-driven (stream end ⇒
  notify/swap/drop). The 150ms Flow Bar poll is untouched.
- **Prompts never stored** (existing rule, extended): history file,
  notification content, logs (debug line carries counts only — already true),
  and drafts outside the live sheet/card all stay clean. Pinned by test.
- **Error mapping (SDK-pinned, all fail-open):** `refusal /
  guardrailViolation` ⇒ raw stands silently (a declining model is normal,
  not an error surface); `rateLimited / concurrentRequests` ⇒ back off
  silently (single-flight prevents the latter); `decodingFailure /
  assetsUnavailable` ⇒ raw stands; `exceededContextWindowSize` ⇒ raw stands
  + Manual remains (no auto retry — pointless + wasteful).

## Exact file changes

1. `WritingPolishService.swift`: `longTextWords` constant (150, matrix-tunes);
   single-flight (new run cancels previous); `exceededContextWindowSize`
   mapped to silent raw-stands (never surfaced).
2. `DictationCoordinator`: post-insert routing by length — short ⇒ existing
   race; long ⇒ detached polish-to-completion (no window; still guarded by
   enabled/mode/availability) then notify via scheduler; cancel running
   polish on `begin()`; prewarm on `begin()` when enabled (any mode —
   Manual benefits too).
3. New `PolishedNotifier` seam (`NotificationScheduling` protocol + live
   `UNUserNotificationCenter` + fake recording titles/bodies): permission
   request-once at first long start; lock-screen-safe body (pinned);
   tap response opens the delivery card (delegate via existing app delegate).
4. Delivery card: `NSPanel`-family controller reusing the `PolishSheet`
   view with a completed-draft parameter (no second streaming path);
   Copy polished / Dismiss. No auto-dismiss (user asked for it — it waits).
5. `OtoApp.swift`: construct scheduler + card controller, wire delegate,
   launch prewarm (gated on enabled+available).
6. `OtoMenuBarView`: denied-notifications fallback row only (no other change).
7. `IntelligencePane`: one status line for the notify path state? NO new
   controls — the existing status card covers availability; long-delivery
   needs no setting. (If a toggle proves necessary, matrix says so.)

## Tests (all real)

- Routing: short text ⇒ race path (existing tests); long text ⇒ notify path
  (fake scheduler receives exactly one request, clipboard/history untouched);
  over-threshold-but-off ⇒ nothing scheduled, nothing streamed.
- Notification body never contains transcript (adversarial 10k-word input,
  assert title/body constants only).
- Permission denied ⇒ fallback row path taken, no re-request.
- Cancel-on-begin: long polish parked at gate + new session ⇒ stream task
  ends, nothing scheduled, nothing swapped.
- Single-flight: second run cancels first (first stream's task cancelled,
  only second completes).
- `exceededContextWindowSize` (scripted via fake error) ⇒ raw stands, no
  notify, no retry loop.
- No-persistence extended: long draft completes ⇒ history file byte-identical.
- Prewarm call sites: launch-gated (unavailable ⇒ no prewarm), begin-gated.

## Verification

- [ ] Build green; grep gates (PCC 0, `fm` 0, transcript content in
  notification strings 0, no new timers/polls)
- [ ] Unit green isolated + full `xcodebuild test` calm
- [ ] Matrix L (user): short swaps land (timings from Manual captions);
  long dictation (2+ min speech) ⇒ notification arrives once ⇒ tap ⇒ card
  ⇒ Copy works; denied-notifications machine ⇒ menu fallback works;
  threshold feel (does 150 words split right?); battery impression over a
  day; over-context only if reachable
- [ ] Matrix L-eyes: notification never shows content on lock screen; card
  Copy/Dismiss; Revert still works for short swaps; Off mode = today's app

## Risks

- Notification permission adds a one-time system prompt: requested once,
  in-context, never again. If it proves annoying in matrix, fallback is
  History-badge instead (recorded alternative, not built).
- Threshold 150 is a starting value, not a truth — matrix tunes it.
- Long polish holds memory for its duration (one 60KB string + one session):
  negligible, but the cancel paths above keep it bounded by construction.

## Open questions

1. Threshold 150 words — confirm, raise, or lower after living with it?
   (Recommendation: ship 150, tune from feel, not theory.)
2. Notification sound: silent (alert only) or subtle sound?
   (Recommendation: silent — it can wait.)
3. If denied-notifications fallback goes unused in matrix, delete the menu
   row or keep it? (Recommendation: keep — one row, zero cost, real fallback.)
