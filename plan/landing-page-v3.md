# Plan: Oto Landing Page v3 — Full-Screen Centered Hero + Live Typewriter Dictation & Cleanup (`site/`)

## Goal

Refine the landing page hero and typography to match the user's latest direction:
- **Full-screen edge-to-edge hero gradient** (`min-h-[100svh] w-full`, no outer margins or rounded container box), smoothly fading into pure `#FFFFFF` at the bottom edge.
- **Remove the MacBook bezel frame and 3-tab bar** completely.
- **Remove the handwritten font (`Caveat`) everywhere** — 100% pure, cohesive `Inter` across the entire page.
- **Center everything in the viewport** with generous breathing room and zero layout shift.
- **Live typewriter description + morphing Oto Flow Bar pill** demonstrating the real dictation → on-device Auto Cleanup → clean landed text lifecycle right inside the hero description.

## Spec Sources

- User request: full-screen hero gradient, remove MacBook mockup, center everything, remove handwritten font, live typewriter description showing dictation indicator and on-device cleanup, well-crafted feel.
- Prior verified constraints: logo left + Download right only (no nav links, hides on scroll down / shows on scroll up), exact codebase `OtoLogo.svg`, zero personal names anywhere, responsive across all viewports.

## Facts Verified Against Workspace

- `site/` runs Next.js `16.4.6` + Tailwind CSS v4 (`4.3.5`), live at `http://localhost:3000`.
- Real Oto Flow Bar visual states (`Oto/UI/FlowBar/PillLayers.swift`):
  - Recording: compact dark frosted capsule with 10 animated white waveform bars.
  - Cleaning: expanding dark capsule with horizontal shimmering `"Cleaning"` label + spinner.
  - Landed: subtle clean confirmation before resetting.

## Exact File Changes

1. **[site/app/layout.tsx](file:///Users/dan_cubed/oto/site/app/layout.tsx)**
   - Remove `Caveat` import and CSS variable; keep only `Inter` (`400 / 500 / 600`).

2. **[site/app/globals.css](file:///Users/dan_cubed/oto/site/app/globals.css)**
   - Remove `--font-hand`.
   - Refine `.oto-hero-mesh` for full-bleed edge-to-edge coverage with a soft fade into `#FFFFFF` along the bottom edge so the transition into `"Under the hood"` feels seamless.
   - Add smooth `@keyframes oto-shimmer` (horizontal text shine matching Oto's real `.work` shimmer) and `@keyframes oto-caret` (blinking insertion cursor), both disabled cleanly under `prefers-reduced-motion: reduce`.

3. **[site/components/HeroShowcase.tsx](file:///Users/dan_cubed/oto/site/components/HeroShowcase.tsx)** (`"use client"`)
   - Full-screen centered layout (`min-h-[100svh] w-full flex flex-col items-center justify-center px-5 sm:px-6 text-center`).
   - Clean `Inter` eyebrow (`Offline dictation for macOS`) + centered 2-line headline (`Speak naturally.` / `Land clean text anywhere.`).
   - **Live Typewriter + Morphing Flow Bar Showcase** directly in the hero description slot:
     - Fixed `min-h` container so buttons below never shift vertically.
     - Cycles through 3 concise real Oto descriptions:
       1. **Dictating phase:** Flow Bar shows the 10 animated white waveform bars while raw spoken text (including realistic filler words like `"um,"`, `"like,"`, `"uh,"`) types out smoothly with a blinking caret.
       2. **Cleaning phase:** Flow Bar morphs smoothly into the shimmering `"Cleaning"` + spinner pill while filler words dim/strike softly.
       3. **Cleaned phase:** Filler words vanish, the description settles into crisp final copy, and the pill shows a subtle `"Cleaned locally"` check state before cycling cleanly to the next line.
     - Honors `prefers-reduced-motion` by displaying the clean description and static pill immediately without timers.
   - Primary `#111111` pill CTA (`Download for macOS` with Apple icon) + quiet meta line (`Free · 100% offline · Apple Silicon · v1.0`).

4. **[site/app/page.tsx](file:///Users/dan_cubed/oto/site/app/page.tsx)**
   - Replace the handwritten `"AND MORE"` eyebrow above `"Under the hood"` with clean `Inter` (`text-[12px] font-medium tracking-[0.12em] uppercase text-[#888888]`).
   - Keep `TopBar`, `"Under the hood"` 4×2 icon grid, single-card `FaqSection`, and minimal name-free footer intact.

## Verification Steps

1. Run `npx tsc --noEmit && npm run build` in `site/` — 0 errors.
2. Verify live on `http://localhost:3000` at desktop (`1280×800`) and mobile (`390×844`):
   - Hero gradient fills 100% of the viewport edge-to-edge with everything centered cleanly and zero MacBook frame.
   - Only `Inter` font is loaded/computed across the entire DOM (zero `Caveat`).
   - Typewriter animation cycles cleanly through `dictating` → `cleaning` → `cleaned` with zero layout shift.
   - Zero horizontal overflow, scroll-down hides top bar / scroll-up shows it, zero personal names.

## Risks / Deferred Decisions

- None — pure frontend refinement inside `site/`.

## Open Questions

- None. Ready for approval to execute.
