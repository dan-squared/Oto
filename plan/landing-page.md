# Plan: Oto Simple Landing Page (`site/`)

## Goal

Build a clean, fast, high-converting, fully responsive landing page for **Oto** inside the existing Next.js 16 + Tailwind CSS v4 project at `site/`, inspired by the user's Paper layout (`pasted-text.txt` / `pasted-text-2.txt`) while fixing all of its rough edges:
- **Unified typography & color system** strictly derived from the Hero (`Inter`, `#FFFFFF` canvas, `#111111` primary ink, `#888888` muted ink, `#FAFAFA` / `#F0F0F0` surfaces, `#EDEDED` / `#E5E5E5` hairlines) — eliminating the Paper export's mixed `PP Neue Montreal` / `Geist` fonts, inconsistent spacing, and white-on-white FAQ borders.
- **Scroll-direction navbar** — visible at top of page, hides smoothly when scrolling down, and reappears only when scrolling up.
- **Full viewport responsiveness** — fluid layout from `320px` mobile through `1440px+` desktop with zero horizontal overflow (replacing the Paper export's hardcoded `w-362.25` / `h-[4304px]` canvas).
- **Real Oto SVG logo from the codebase** (`Oto/Assets.xcassets/OtoLogo.imageset/OtoLogo.svg`) used across navbar, footer, and favicon.
- **Honest, converting Oto copy** grounded strictly in Oto's actual macOS features (no fabricated stats, no fake testimonials, no dead links).

## Spec Sources

- User request & Paper layout exports (`pasted-text.txt`, `pasted-text-2.txt`)
- `README.md` and `Docs/START_HERE_PRODUCT.md` (verified Oto feature set and privacy guarantees)
- `Oto/Assets.xcassets/OtoLogo.imageset/OtoLogo.svg` (canonical SVG logo geometry and gradient)
- `site/package.json` (`next@16.4.6`, `react@19.3.1`, `tailwindcss@4.3.5`)
- `site/public/appcast.xml` & `Scripts/release.sh` (must preserve `appcast.xml` untouched; GitHub repo `https://github.com/dan-squared/Oto`, version `v1.0`)

## Facts Verified Against Workspace

- `site/` already exists as a minimal Next.js 16 App Router + Tailwind v4 app (`site/app/page.tsx` is intentionally empty for the landing page).
- `node`, `npm`, and `bun` are installed locally (`site/node_modules` is not yet installed; will install dependencies cleanly with `npm install` when executing).
- `OtoLogo.svg` (`viewBox="0 0 702 702"`) uses a light sky-blue gradient (`#9BCBFF → #F3F8FF`). On a `#FFFFFF` background, hosting the exact `OtoLogo.svg` vector inside a `#111111` rounded macOS-icon tile preserves the exact gradient and gives crisp contrast; we also ship `site/public/oto-logo.svg` and `site/app/icon.svg` directly from the codebase SVG.
- `Oto.xcodeproj/project.pbxproj` sets `MARKETING_VERSION = 1.0`.

## Assumptions Questioned

- **Should we include the Paper template's fake tweet/testimonial wall (e.g. `@shadcn`) or fake download counter?**
  No — fake testimonials and fabricated download counts hurt credibility. We keep the clean Paper layout cadence (Hero → Interactive Showcase Carousel → Two 3-column Feature Grids → Two-column Core Pillars → Interactive FAQ → Full-width CTA Band → Minimal Footer) with 100% real Oto product value and interactive UI previews.
- **Should the showcase carousel rely on external `app.paper.design` `.webp` URLs?**
  No — those are Mesurer screenshots hosted on Paper. Instead, we build crisp, lightweight, self-contained macOS UI mockups in React/Tailwind that accurately depict Oto's real Flow Bar pill, on-device Auto Cleanup, No-Target Recovery Catcher, Snippets/Dictionary, and Offline Apple Speech architecture.
- **Where should the primary CTA point?**
  Link `Download for Mac` to `https://github.com/dan-squared/Oto/releases/latest` and secondary CTA `View on GitHub` to `https://github.com/dan-squared/Oto` (matching `Scripts/release.sh` and `site/public/appcast.xml`). Easy to swap to a direct `.dmg`/`.zip` URL once published.

## Exact File Changes

1. **[site/app/layout.tsx](file:///Users/dan_cubed/oto/site/app/layout.tsx)**
   - Load `Inter` via `next/font/google` (`weights: ["400", "500", "600"]`, CSS variable `--font-inter`).
   - Set SEO metadata (`title: "Oto — Fast, private macOS dictation"`, description, OpenGraph).
   - Apply clean `#FFFFFF` background, `#111111` text, `antialiased`, and `scroll-smooth`.

2. **[site/app/globals.css](file:///Users/dan_cubed/oto/site/app/globals.css)**
   - Configure Tailwind v4 `@theme inline` to bind `--font-sans` to `var(--font-inter), system-ui, sans-serif`.
   - Define scrollbar hiding helper for the horizontal snap carousel and subtle wave-bar keyframes for the live Flow Bar pill preview (honoring `@media (prefers-reduced-motion: reduce)`).

3. **[site/app/icon.svg](file:///Users/dan_cubed/oto/site/app/icon.svg)** & **[site/public/oto-logo.svg](file:///Users/dan_cubed/oto/site/public/oto-logo.svg)**
   - Copy/derive directly from `Oto/Assets.xcassets/OtoLogo.imageset/OtoLogo.svg` so favicon and public asset share the exact codebase logo.

4. **[site/components/OtoLogo.tsx](file:///Users/dan_cubed/oto/site/components/OtoLogo.tsx)**
   - Reusable React component rendering the exact SVG path + `#9BCBFF → #F3F8FF` gradient from `OtoLogo.svg` inside a `#111111` squircle mark (with unique gradient IDs via `useId()` so multiple instances on the page never collide).

5. **[site/components/Navbar.tsx](file:///Users/dan_cubed/oto/site/components/Navbar.tsx)** (`"use client"`)
   - Fixed top navigation bar (`max-w-6xl mx-auto px-5 sm:px-6 h-14`).
   - Scroll-direction listener (`requestAnimationFrame`-throttled passive `scroll` event):
     - Visible at top (`scrollY <= 16`).
     - Hides cleanly (`-translate-y-full pointer-events-none`) when scrolling down past `48px`.
     - Reappears smoothly (`translate-y-0`) only when scrolling up (with a `6px` delta deadzone to prevent trackpad bounce flicker).
   - Minimal links (`Features`, `How it works`, `FAQ`) on `md+` + Oto SVG logo/wordmark left + primary `Download` pill right.

6. **[site/components/ShowcaseCarousel.tsx](file:///Users/dan_cubed/oto/site/components/ShowcaseCarousel.tsx)** (`"use client"`)
   - Responsive full-bleed horizontal snap carousel matching Paper's `16:10` centered peek layout (`w-[88vw] sm:w-[76vw] lg:w-[64vw] max-w-[920px]`), working circular Prev/Next buttons (`#EDEDED` border, active/disabled states), dot/caption sync, and keyboard navigation.
   - 5 clean Oto product preview slides with concise two-tone captions (`#111111` verb + `#888888` explanation):
     1. **Dictate.** Hold `Right ⌥`, speak, and land text straight at your cursor.
     2. **Auto Cleanup.** Remove filler words and stumbles with on-device Apple Foundation Models.
     3. **Never Lose Words.** Spoke without a focused field? Oto catches it with one-click Copy.
     4. **Snippets & Dictionary.** Expand spoken triggers instantly and lock in technical spellings.
     5. **100% Offline.** Apple Speech on your Mac—no cloud, no account, no subscription.

7. **[site/components/FaqSection.tsx](file:///Users/dan_cubed/oto/site/components/FaqSection.tsx)** (`"use client"`)
   - Paper's `grid-cols-1 lg:grid-cols-[5fr_7fr]` two-column FAQ layout, unified with Hero typography (`22px` medium `#111111` heading, `16px` medium `#111111` questions, `15px` `#888888` answers, `#EDEDED` bottom dividers, smooth chevron rotation & accessible `button`/`aria-expanded` toggle).

8. **[site/app/page.tsx](file:///Users/dan_cubed/oto/site/app/page.tsx)**
   - Assembles the full landing page with consistent vertical rhythm and strict Hero palette (`#FFFFFF`, `#111111`, `#888888`, `#FAFAFA`, `#F0F0F0`, `#EDEDED`):
     - `Navbar`
     - Hero (`max-w-2xl mx-auto`, `max-w-[460px]` headline/subhead/CTAs/meta)
     - `ShowcaseCarousel`
     - Feature Grid 1 (*"Built to disappear into your workflow"*: Hold or Hands-Free, Floating Flow Bar, Audio Ducking)
     - Feature Grid 2 (*"Private on-device polish, when you want it"*: Per-App Auto Cleanup, Quick Transforms, Local History & Copy Last)
     - 2-Column Core Pillars (*On-device Speech* & *Native macOS*)
     - `FaqSection`
     - `#F0F0F0` Final CTA Band
     - Minimal Footer with `OtoLogo` + honest links

## Verification Steps

1. Install dependencies in `site/` (`npm install`) and run production build & TypeScript check (`npm run build` / `npx tsc --noEmit`) — expect 0 errors, 0 warnings.
2. Start Next.js dev server (`npm run dev`), open in T3's browser preview, and visually verify:
   - Desktop (`1280×800`) and Mobile (`390×844`, iPhone preset) layouts: zero horizontal overflow, clean spacing, single unified `Inter` font, crisp `OtoLogo` SVG, readable FAQ borders.
   - Scroll-down hides the navbar; scroll-up brings it back cleanly.
   - Interactive carousel prev/next buttons and FAQ accordions work smoothly.
3. Confirm `site/public/appcast.xml` is untouched (`git diff site/public/appcast.xml` is empty) and `Oto` macOS Swift files are untouched.

## Risks / Deferred Decisions

- Download links currently point to `https://github.com/dan-squared/Oto/releases/latest`. Once a direct signed zip/DMG URL or custom domain is live, update the single `DOWNLOAD_URL` constant in `site/lib/links.ts` (or top of `page.tsx`).
- Adding `site/node_modules` is already ignored by `site/.gitignore` (verify before finishing).

## Open Questions

- None blocking; if you want a specific download URL, price/free wording, or social link (X/email) in the footer, let me know when approving.
