# Denied-card duration 5s → 10s (mic-denied persistence, scoped)

## Goal

Give the mic-denied card enough screen time to be seen and acted on:
visible window 5 s → 10 s. Explicitly scoped per user direction
(2026-10-06): 10 s is judged enough; the deeper persistence work
(menu badge / sticky status / keyboard path) is deferred, revisit on
beta evidence, not theory.

## Spec sources (canonical first)

- `Oto/UI/FlowBar/PermissionModal.swift:224-294`
  (`PermissionModalController`: `visibleDuration`, generation-guarded
  show/fade, never-key orderFront).
- `OtoTests/FlowBar/PermissionModalTests.swift:32` (pins `== 5.0` —
  must move with the constant).
- Audit P1-35 (`.context/audit-2026-10-05.md`): look-away story,
  no-trace-after-vanish, non-focusable action. This plan answers only
  the duration half; the rest stays deferred below.

## Facts verified against the local SDK (never from memory)

- ACP connected this session: workspace `Oto.xcodeproj`, scheme `Oto`,
  dest `My Mac`. Toolchain Xcode 27.0 / Swift 6.4 / MacOSX27.0.sdk.
- Zero new APIs: one constant + two comments + one test pin. The
  hide machinery (generation guard, `.seconds(Self.visibleDuration)`,
  0.15 s easeIn fade) reads the constant — no logic change.
- The card is macOS-banner persistence class by design intent
  (comment at :227); banners persist ~5 s minimum, Notification Center
  keeps them. 10 s sits inside that idiom, not beyond it.

## Assumptions questioned

1. "10 s fixes look-away." No — it halves the miss rate (coffee run
   still beats it). Accepted explicitly: cheap 80% improvement now,
   persistence later only with evidence.
2. "The 5.0 pin is load-bearing." No — it pins whatever ships; moving
   constant + pin together is the designed workflow (same as every
   pill timing in this repo).

## Exact file changes

1. `Oto/UI/FlowBar/PermissionModal.swift:229` — `5.0` → `10.0`;
   refresh the `:227-228` comment (banner class, 10 s window) and the
   `:267` comment ("full 10 s, never truncated").
2. `OtoTests/FlowBar/PermissionModalTests.swift:32` — pin `== 10.0`.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green.
- `xcodebuild test` green (PermissionModalTests + full bundle).
- Live matrix (packaged app, mic denied): hold → card up, readable +
   actionable for a full 10 s; re-hold mid-window restarts the full
   10 s (generation guard, unchanged); fade + orderOut after.

## Risks / deferred decisions

- Risk ~zero: constant-only change through generation-guarded
  machinery; no new states, no new surfaces.
- Deferred (explicit): persistent affordance after vanish, keyboard /
  VoiceOver path to Grant, 300 ms-vs-1 s Copied comment mismatch
  elsewhere. Revisit only on beta evidence.

## Open questions

- None.
