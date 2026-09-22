# Pill v3 — CALayer renderer + mini geometry — PLAN ONLY

Status: PLANNING ONLY (2026-09-22). Nothing implemented. Awaiting `go`.
Supersedes the renderer + geometry of 6B (projection, controller
ownership, analyzer, modal routing all stand).

## 1. Diagnosis from the screenshot (evidence, not guesses)

The frame shows four defects, three with identified root causes:

- **D1. Square frame, root cause FOUND.** The hairline rect = the panel
  bounds exactly → `NSHostingView` is drawing a backdrop. Why the layer
  fix failed: the SwiftUI root (`FlowBarView`) never declares
  `.background(Color.clear)` — in a panel context the hosting view paints
  the default window background behind our pill. Layer-clear treats the
  symptom one level down; the paint happens one level up. Cure options:
  (a) add the one-line clear (patch), (b) remove SwiftUI from the pill
  entirely (cure). This plan takes (b) — see §3 — because D4 below
  independently demands it. The modal keeps its hosting view (opaque
  card by design = correct there) + gets the explicit clear line.
- **D2. Spinner center dot.** `drawDots(spinner:true)` draws all 9 dots
  AND the spinner; the middle dot sits under the spinner hub. Custom
  spokes + hub dot ≠ macOS spinner. Cure: native `NSProgressIndicator`
  (spinning, small) + dots row shortened to clear it.
- **D3. Ring + dot size.** The hands-free ring reads as a second element
  at small sizes; dot at 10px still heavy. Cure: dot 8px, ring deleted
  (hands-free already distinguishable by behavior; no replacement mark).
- **D4. Lag, root cause FOUND (two contributors).** (i) The width guard
  fixed hierarchy rebuilds, but every analyzer publish still diffs a
  SwiftUI hierarchy on the MainActor at 30 Hz inside a transparent
  floating panel — transparen
...[truncated 4477 chars]