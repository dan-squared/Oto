# Phase 7h: pill verbs, card cleanup, exact-hug pill width

> Follow-up to 7g from live testing with the pill screenshot (`Polish` +
> spinner floating mid-pill with dead space right): (1) pill labels become
> verbs — Cleaning / Polishing / Shortening / Formalizing (user picked via
> "continue" on recommendations), (2) hey-joey examples + checkmark removed
> from Auto Cleanup cards, (3) min-width clamp removed so the pill always
> hugs content exactly (the clamp was the dead space; the pill is
> non-interactive so the minimum served nothing).

## Exact file changes

1. `TransformPreset`: new `pillVerb` (polish→Polishing, concise→Shortening,
   professional→Formalizing). `displayName` stays for Settings rows.
2. `workPillText`: `.cleaningUp` → `"Cleaning"`, presets → `pillVerb`.
3. `IntelligencePane`: card examples deleted (title + detail only);
   checkmark block deleted (selection still reads via ink border + wash +
   VoiceOver traits — no control removed, only decoration).
4. `VisualizerMath`: delete `workMinWidth`; width = min(max,
   ceil + slack + chrome), unclamped below. Chrome unchanged.
5. Tests: pill-text pins, width pins (exact-hug + slack + max clamp;
   longest label now `Formalizing`), pill frame test (spinner snug,
   no dead space beyond padding), factory/gate tests untouched
   (display names unchanged).

## Verification

- [ ] Build green; full unit green (UI smoke excluded — proven
  pre-existing failure).
- [ ] Matrix (user, fresh Xcode Run): pill shows `Cleaning`/`Polishing`/
  `Shortening`/`Formalizing`, spinner snug right, zero dead space; cards
  show title + one-line description only, selected = ink border.

## Risks

- None material: widths only shrink toward content; no behavior change.
