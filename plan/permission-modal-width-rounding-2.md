# Permission card: visible words + rounder corners — plan

## Goal

Fix two things in `PermissionCardView` (`Oto/UI/FlowBar/PermissionModal.swift`):
1. Title truncates on the user's machine ("Microphone Permission Requir…", see `.context/attachments/5K4xNE/image.png`) despite `titleClipped()==false` passing locally.
2. Corners read as flat — user wants a more rounded card + button pair computed with Apple's concentric-corner formula.

## Spec sources

- Screenshot `.context/attachments/5K4xNE/image.png`: 60pt dark card, 18pt red icon, 12.5pt semibold title truncated with ellipsis, cream "Grant Permission" button intact, outer radius visibly small (~18 on 60 height vs pill's full `h/2`).
- Mockup `.context/attachments/RnFwOd/image.png` (original): same layout, full words, ~16 radius.
- `Docs/START_HERE_PRODUCT.md` canonical on conflict; prior plan `plan/permission-denied-modal.md`.
- Current code: `maxWidth=415`, `cardRadius=18`, `buttonRadius=max(4,18-12)=6`, fitted width = `11+18+7+titleW+9+buttonW+11` where `buttonW = button.intrinsicContentSize.width + 30`.

## Facts verified against the local SDK (from files, not memory)

- `PermissionCardView.relayout` (`PermissionModal.swift:137-180`): width is content-fitted then clamped to 415; when clamped, `didClampTitle=true` and the label (`.byTruncatingTail`) ellipsizes. The test `widthFitsTheWords` asserts no clamp locally — so the user's truncation means real metrics there exceed 415 (button `intrinsicContentSize` for a borderless `NSButton` with attributed title carries bezel padding that varies by OS/font rendering; title `intrinsicContentSize` on `NSTextField` likewise includes field padding).
- Pill precedent (`PillLayers.swift:163-167`): silhouette radius = `h/2` (full capsule, 16 on the 32pt pill). Card at 18 on 60 height is far from capsule — room to round up without looking wrong.
- Concentric-corner formula (Apple HIG continuous corners): `inner = outer − gap` with uniform inset. Current gap = `(60−36)/2 = 12`, so `buttonRadius = cardRadius − 12`. Correct formula, just applied to a flat outer value.
- Panel recipe (`FlowBarPanel.makePanel:49-71`): depth from window shadow only, clear layer-backed container, one `CAShapeLayer` — the square-stroke fix from the pill's two passes. No change needed here; radius change is path-only.
- Slot math (`FlowBarPosition.frame:47-64`): height-aware since `906257b` — width increase does not reintroduce the menu-bar clipping; frame clamps to `visible.width − 16`.

## Assumptions questioned

- "Just increase width": yes for the ceiling, but the deeper fix is deterministic measuring. `NSButton.intrinsicContentSize` is the unstable input — replacing it with attributed-string measurement (`"Grant Permission"` at 12.5 semibold → `boundingRect` + fixed 30 hPad) removes the machine-dependent padding that pushes the user over 415.
- New ceiling: **460** (was 415). Estimate: title ~215 + button ~150 + chrome 56 ≈ 421 — fits with ~39 headroom; still far below `visible.width − 16` on any Mac, Top/Bottom slots unaffected.
- New radii: **card 24, button 12** (`24 − 12`, same formula, same 12 inset). 24 reads clearly rounder than 18 without going full capsule (30); button 12 stays concentric. Pill stays `h/2` — untouched.
- Type stays 12.5 semibold / 18 icon: already reduced per the earlier note; width fix removes the need to shrink further.
- Vertical centering (`titleH` block at `midY`, `PermissionModal.swift:170-174`) is already correct — kept as-is, covered by a new centering assertion.

## Exact file changes

1. **`Oto/UI/FlowBar/PermissionModal.swift`**
   - `maxWidth`: 415 → 460.
   - `cardRadius`: 18 → 24 (`buttonRadius` follows automatically to 12 via the existing formula — no formula change).
   - `relayout()`: measure the button from its attributed title string (`NSAttributedString("Grant Permission", 12.5 semibold).boundingRect`) + `buttonHPad*2` instead of `button.intrinsicContentSize`; measure the title from its string with the same font instead of `title.intrinsicContentSize` (removes NSTextField/NSButton bezel variance). Keep clamp-to-max + `didClampTitle` fallback logic unchanged.
2. **`OtoTests/FlowBar/PermissionModalTests.swift`**
   - Update pins: `maxWidth == 460`, `buttonRadius == 12`.
   - Keep `widthFitsTheWords` (no truncation, width ≤ ceiling) + add `titleVerticallyCenteredOnIcon` (title midY == icon midY within 0.5pt) so the earlier centering fix can't regress.
3. No changes to `FlowBarPanel`, `FlowBarPosition`, controller show/hide/timeout (5s), or deep links.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` clean.
- `xcodebuild test -scheme Oto -destination 'platform=macOS'` full suite green (224 + updated pins).
- Grep gates: no new force unwraps; URL strings only in `MicSettingsLink`.
- Relaunch packaged app; user matrix: deny mic → dictate at Top → full words, no outline, rounder corners; Bottom slot + light mode for completeness; Grant button → Settings.

## Risks / deferred

- If the user's metrics still exceed 460 (unlikely — ~39 headroom), the fallback is still graceful truncation with `didClampTitle` test catching it locally first.
- Catcher appearance-aware rework stays deferred post-merge per user call.

## Open questions

- None blocking. If 24 still reads flat to the user, the next step up the capsule scale is 26–28 (button 14–16, same formula) — one-line change.
