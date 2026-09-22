# Phase 8 — draggable snap pill (top / bottom slots, indicators, haptic, setting) — PLAN

Status: WRITTEN + EXECUTED same turn (2026-09-22) — user ordered
"plan … then implement" explicitly.

## 0. What the user asked, decoded

- "below the notch or center upper part or the current location" → TWO
  slots: **Top** (top-center of the target display's visible frame, 12pt
  below the menu-bar/notch line — `visibleFrame` already excludes both, so
  this is exact on notch and non-notch Macs) and **Bottom** (today's
  bottom-center, 28pt margin — unchanged default).
- "on release … drag and snap" → press-drag the pill with the mouse; while
  dragging, ghost **fill indicators** appear at both slots; on mouse-up the
  pill animates into the nearest slot.
- "fill indicators … will snap … haptic feedback" → slot ghosts highlight
  nearest-live; drop plays `NSHapticFeedbackManager .alignment` (no-op on
  hardware without haptics — safe by API contract).
- "change the location on setting" → General → Flow Bar → Top/Bottom
  segmented picker (same `app.Oto.*` key pattern as the catcher switch);
  drag-drops write the same key, so gesture and setting never disagree.

Non-goals: free placement (slots only — the pinned-display positioning
chain stays intact), label icon changes, multi-display memory (setting is
global; indicators live on the pinned screen).

## 1. Exact changes

1. NEW `Oto/UI/FlowBar/FlowBarPosition.swift`
   - `enum FlowBarPosition: String { case top, bottom }`, key
     `app.Oto.flowBarPosition`, `current(defaults:) → .bottom` when absent,
     `save(_:defaults:)`.
   - Pure geometry (nonisolated, headless-tested): `topMargin = 12`,
     `bottomMargin = 28` (moved off the panel), `frame(width:on:position:)`
     (same clamp/center math as today), `nearest(dropCenterY:on:)` (mid split).
2. `FlowBarPanel.swift`
   - `show(...position:)`, `resize`/`setFrame` slot-aware (controller passes
     `FlowBarPosition.current()` per poll → setting flips apply live).
   - `PillDragDelegate`: began → capture start slot, show ghosts (fade
     0.15), `orderFront` pill; moved → move frame (no animation), live
     highlight; ended(moved:) → hide ghosts, animate to nearest 0.15,
     save-if-changed + haptic on moved drops.
   - `isDragging` flag; `SnapIndicatorView` (rounded ghost, fill+stroke,
     `highlighted`); ghost panels ignore mouse, nonactivating, join spaces.
3. `PillLayers.swift` — `mouseDown/Dragged/Up` → delegate with screen-space
   origin (grab-offset corrected); `acceptsFirstMouse → true` (non-key
   window); click-without-move = plain drop (no haptic, no write).
4. `FlowBarController.swift` — pass position; while `isDragging`: render
   content (bars stay live under the finger) but skip show/resize; vanish
   branch cancels pending hide instead of scheduling; hide-task closure
   re-checks dragging (skips that cycle, clears task so the next poll
   reschedules — never stuck visible).
5. `GeneralPane.swift` — "Flow Bar" section, segmented Top/Bottom
   `@AppStorage`, one-line caption.
6. NEW `OtoTests/FlowBar/FlowBarPositionTests.swift` — slot math, split
   (incl. boundary), setting round-trip on scratch defaults, absent→bottom,
   raw-value stability.

## 2. SDK 27.0 (verified by build)

`NSHapticFeedbackManager.defaultPerformer.perform(.alignment,
performanceTime: .default)` — AppKit, long-stable; `NSAnimationContext`
completion for ghost fade-out; no new entitlements (haptics need none).

## 3. Risks / mitigations

- Drag vs poll fight → `isDragging` gates (render continues, geometry frozen).
- Vanish mid-drag → cancel-on-sight + closure re-check (no stuck states).
- Silent-edit flakiness seen in v7 → python-applied edits + full grep-audit
  before build (this turn's rule, not optional).
- Nonactivating click-through → `acceptsFirstMouse`; pill has no buttons,
  so every press-drag is a move (no gesture disambiguation needed).

## 4. Verification

Build clean + suite green (~225); grep gates (NULs, dead refs); device
matrix (user): drag during recording — ghosts at top/bottom, nearest glows,
drop ticks + lands; setting flips move next show; restart persists.
