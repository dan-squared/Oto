# Plan: Oto Landing Page v2 Revamp (`site/`)

## Goal

Revamp the landing page in `site/` to match the clean, airy, centered aesthetic of the user's new reference image while honoring every explicit constraint:
- **No traditional navbar** — only the Oto SVG logo (left) and a single `Download` button (right) at the top, hiding smoothly on scroll down and reappearing on scroll up.
- **Full-viewport centered Hero** (`min-h-[calc(100svh-24px)]`) with an Oto-native cool sky-blue / pearl atmospheric mesh gradient (ignoring the reference's peach/orange palette, harmonizing with `OtoLogo.svg`'s `#9BCBFF → #F3F8FF` gradient).
- **Centered MacBook bezel mockup** rising from the bottom edge of the hero canvas, controlled live by a **3-tab segmented pill switcher** (`Dictate` | `Auto Cleanup` | `Recovery & Snippets`) directly below the hero.
- **Concise, punchy copy** throughout — short scannable lines, zero filler paragraphs.
- **No personal name anywhere** on the page (removed from footer, mockups, and metadata).
- **Clean `"Under the hood"` 4×2 icon grid** (minimal line icons + 2-line captions, no heavy cards) and a **single rounded grouped FAQ card** with `+` toggles.
- **100% responsive** across mobile (`375px`), tablet, and desktop (`1280px+`) with zero horizontal overflow.

## Spec Sources

- User request & uploaded reference image (`file-ca377dc4d3dbd6e1cedb59808f837c5c.png`)
- `Oto/Assets.xcassets/OtoLogo.imageset/OtoLogo.svg` (exact vector path + sky-blue gradient)
- `README.md` & `Docs/START_HERE_PRODUCT.md` (verified Oto capabilities)
- `site/public/appcast.xml` (preserved untouched)

## Facts Verified Against Workspace

- `site/` runs Next.js `16.4.6`, React `19.3.1`, Tailwind CSS v4 (`4.3.5`), and dev server is live on `http://localhost:3000`.
- `next/font/google` supports both `Inter` (primary geometric sans) and `Caveat` (optional subtle handwritten accent for the two tiny eyebrows matching the reference's `"YOUR SMART NOTCH"` / `"AND MORE"`).
- `OtoLogo.svg` uses `#9BCBFF → #F3F8FF`, which pairs naturally with a luminous sky-blue / ice-silver / soft-mist hero mesh gradient (`#D6E8FF`, `#E8F2FF`, `#F5F8FD`, `#C3DCFF`) + subtle noise texture.

## Assumptions Questioned

- **Should the top header keep any nav links (`Features`, `Cleanup`, `FAQ`)?**
  No — user explicitly requested *"no nav bar needed like only the download aat the right and logo in the left"*.
- **Should we mention any personal/author name in the footer or mockups?**
  No — user explicitly requested *"don't mention name"*. Footer uses only `© 2026` + Oto SVG mark + `GitHub` / `Releases` / `Privacy`, and mockups use neutral examples (`cal.com/team/30m`, `Thanks, team`).
- **Should the MacBook screen mockup be interactive?**
  Yes — wiring the 3 centered pill tabs (`Dictate`, `Auto Cleanup`, `Snippets & Recovery`) below the hero directly to the MacBook viewport inside the hero gives an immediate, tactile product demo without extra page bloat.

## Exact File Changes

1. **[site/app/layout.tsx](file:///Users/dan_cubed/oto/site/app/layout.tsx)**
   - Load `Inter` (`400/500/600`) and `Caveat` (`500`, used solely for the two small handwritten eyebrows) via `next/font/google`.
   - Clean metadata with no personal name.

2. **[site/app/globals.css](file:///Users/dan_cubed/oto/site/app/globals.css)**
   - Bind `--font-sans` to `Inter` and `--font-hand` to `Caveat`.
   - Add `.oto-hero-mesh` (cool sky-blue / pearl / mist layered radial gradients + subtle SVG noise overlay) and keep the smooth `.oto-bar` waveform animation (honoring `prefers-reduced-motion`).

3. **[site/components/TopBar.tsx](file:///Users/dan_cubed/oto/site/components/TopBar.tsx)** (`"use client"`, replaces `Navbar.tsx`)
   - Minimal floating top row with **only** `OtoLogo` on the left and a crisp `Download` pill button on the right (no nav links, no bar border at top; hides smoothly on scroll down, reappears on scroll up).

4. **[site/components/HeroShowcase.tsx](file:///Users/dan_cubed/oto/site/components/HeroShowcase.tsx)** (`"use client"`, replaces `ShowcaseCarousel.tsx`)
   - Full-viewport (`min-h-[calc(100svh-24px)]`) rounded atmospheric hero frame (`m-2 sm:m-3 rounded-[24px] sm:rounded-[28px] overflow-hidden`) centered cleanly:
     - Tiny eyebrow: `OFFLINE MAC DICTATION`
     - Concise centered headline: `Dictates, cleans up, and` / `lands text anywhere on Mac`
     - Crisp centered white pill button `Download for macOS` (with Apple glyph) + subtle quiet caption underneath (`Free · 100% on-device · Apple Silicon · v1.0`)
     - Bottom-anchored sleek MacBook bezel frame (`border-x-[4px] border-t-[4px] border-[#111111] rounded-t-[20px]`) displaying Oto's live floating Flow Bar pill + active scene for the selected tab.
   - Directly below the hero frame: centered 3-pill segmented tab switcher (`Dictate` | `Auto Cleanup` | `Snippets & Recovery`) that switches the MacBook screen preview live.

5. **[site/components/FaqSection.tsx](file:///Users/dan_cubed/oto/site/components/FaqSection.tsx)** (`"use client"`)
   - Centered heading `Frequently` / `Asked Questions` above a single rounded bordered card (`max-w-[680px] rounded-2xl border border-[#ECECEC] bg-white divide-y divide-[#F0F0F0]`).
   - Crisp `+` toggle icons that rotate `45deg` into `×` on expand, with concise 1–2 sentence Oto answers and zero personal names.

6. **[site/app/page.tsx](file:///Users/dan_cubed/oto/site/app/page.tsx)**
   - Assembles the streamlined 4-part layout matching the reference rhythm:
     1. `TopBar` (Logo left, Download right)
     2. `HeroShowcase` (Full-viewport centered hero + interactive MacBook preview + 3-tab switcher)
     3. `"And more"` / `"Under the hood"` centered **4×2 minimal icon grid** (8 concise Oto highlights: Privacy / Works offline / Hold or hands-free / 3× faster / Auto cleanup / Never loses words / Audio ducking / Multi-language)
     4. Centered `FaqSection` card
     5. Minimal centered footer (`© 2026` · Oto SVG logo · `Oto` + `GitHub` · `Releases`, zero personal names).

7. **Cleanup unused components**
   - Remove superseded `site/components/Navbar.tsx` and `site/components/ShowcaseCarousel.tsx` so `site/` stays spotless.

## Verification Steps

1. Run `npx tsc --noEmit && npm run build` in `site/` — expect 0 errors, 0 warnings.
2. Verify live on `http://localhost:3000` in browser preview at desktop (`1280×800`) and mobile (`390×844`):
   - Hero fits cleanly centered in the viewport with MacBook preview visible above the fold.
   - Only Logo (left) and Download (right) in the top bar; scroll down hides it, scroll up reveals it.
   - Clicking the 3 showcase tabs updates the hero screen preview cleanly.
   - Zero horizontal overflow (`scrollWidth <= innerWidth`), zero personal names anywhere in DOM text, and `site/public/appcast.xml` untouched.

## Risks / Deferred Decisions

- None — pure frontend layout revamp inside `site/`.

## Open Questions

- None blocking. Ready for approval to execute.
