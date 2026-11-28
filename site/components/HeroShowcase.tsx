"use client";

import { useEffect, useState } from "react";
import { SITE } from "@/lib/links";

interface Segment {
  text: string;
  filler?: boolean;
}

const DEMOS: Segment[][] = [
  [
    { text: "Hold a key, " },
    { text: "um, ", filler: true },
    { text: "speak naturally, and " },
    { text: "like, ", filler: true },
    { text: "Oto lands clean text right at your cursor." },
  ],
  [
    { text: "No cloud uploads, " },
    { text: "uh, ", filler: true },
    { text: "no subscriptions — " },
    { text: "wait, ", filler: true },
    { text: "everything runs 100% offline on your Mac." },
  ],
  [
    { text: "Dictate in Mail, Slack, or Notes — " },
    { text: "you know, ", filler: true },
    { text: "with per-app cleanup and " },
    { text: "uh, ", filler: true },
    { text: "voice snippets." },
  ],
];

type Phase = "dictating" | "cleaning" | "cleaned" | "fading";

const WAVE_HEIGHTS = [34, 54, 78, 96, 100, 94, 78, 58, 42, 30];

function AppleIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.81-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M15.97 6.33c.64-.78 1.08-1.86.96-2.94-.93.04-2.06.62-2.72 1.4-.58.68-1.1 1.78-.96 2.84 1.04.08 2.09-.52 2.72-1.3" />
    </svg>
  );
}

function fullLength(segments: Segment[]): number {
  return segments.reduce((sum, seg) => sum + seg.text.length, 0);
}

export function HeroShowcase() {
  const [demoIndex, setDemoIndex] = useState(0);
  const [phase, setPhase] = useState<Phase>("dictating");
  const [charCount, setCharCount] = useState(0);
  const [reducedMotion, setReducedMotion] = useState(false);

  const segments = DEMOS[demoIndex];
  const totalChars = fullLength(segments);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    const sync = () => {
      if (mq.matches) {
        setReducedMotion(true);
        setPhase("cleaned");
        setCharCount(fullLength(DEMOS[0]));
      } else {
        setReducedMotion(false);
      }
    };
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  useEffect(() => {
    if (reducedMotion) return;

    if (phase === "dictating") {
      if (charCount < totalChars) {
        const timer = window.setTimeout(() => {
          setCharCount((c) => c + 1);
        }, 32);
        return () => window.clearTimeout(timer);
      }
      const pauseBeforeClean = window.setTimeout(() => {
        setPhase("cleaning");
      }, 420);
      return () => window.clearTimeout(pauseBeforeClean);
    }

    if (phase === "cleaning") {
      const timer = window.setTimeout(() => {
        setPhase("cleaned");
      }, 1150);
      return () => window.clearTimeout(timer);
    }

    if (phase === "cleaned") {
      const timer = window.setTimeout(() => {
        setPhase("fading");
      }, 2800);
      return () => window.clearTimeout(timer);
    }

    if (phase === "fading") {
      const timer = window.setTimeout(() => {
        setDemoIndex((idx) => (idx + 1) % DEMOS.length);
        setCharCount(0);
        setPhase("dictating");
      }, 320);
      return () => window.clearTimeout(timer);
    }
  }, [phase, charCount, totalChars, reducedMotion]);

  // Slice segments up to charCount during dictation/cleaning
  const renderLiveText = () => {
    if (phase === "cleaned" || phase === "fading") {
      return segments
        .filter((s) => !s.filler)
        .map((s) => s.text)
        .join("");
    }

    let remaining = charCount;
    return segments.map((seg, idx) => {
      if (remaining <= 0) return null;
      const slice = seg.text.slice(0, remaining);
      remaining -= seg.text.length;

      if (seg.filler) {
        return (
          <span
            key={idx}
            className={`transition-all duration-300 ${
              phase === "cleaning"
                ? "text-[#111111]/30 line-through decoration-[#111111]/35"
                : "text-[#111111]/55"
            }`}
          >
            {slice}
          </span>
        );
      }

      return <span key={idx}>{slice}</span>;
    });
  };

  return (
    <section
      aria-label="Oto overview"
      className="oto-hero-mesh relative flex min-h-[100svh] w-full flex-col items-center justify-center overflow-hidden px-5 pt-20 pb-16 text-center sm:px-6"
    >
      {/* Subtle film grain overlay */}
      <div
        aria-hidden="true"
        className="oto-hero-grain pointer-events-none absolute inset-0 opacity-[0.055] mix-blend-multiply"
      />

      <div className="relative z-10 mx-auto flex w-full max-w-2xl flex-col items-center">
        {/* Clean Inter eyebrow */}
        <p className="text-[12.5px] font-medium tracking-[0.01em] text-[#111111]/55 sm:text-[13px]">
          Offline dictation for macOS
        </p>

        {/* Centered Headline */}
        <h1 className="mt-3 text-[34px] font-semibold leading-[1.07] tracking-[-0.032em] text-balance text-[#111111] sm:text-[48px] md:text-[54px]">
          Speak naturally.
          <br />
          Land clean text anywhere.
        </h1>

        {/* Live Typewriter Description + Morphing Flow Bar Indicator */}
        <div className="mt-7 flex w-full max-w-[540px] flex-col items-center sm:mt-8">
          {/* Morphing Oto Flow Bar Pill */}
          <div className="flex h-9 items-center justify-center">
            <div
              data-phase={phase}
              aria-live="polite"
              className={`inline-flex h-8 items-center justify-center rounded-full bg-[#111111] text-white shadow-[0_10px_28px_rgba(17,17,17,0.18),inset_0_1px_0_rgba(255,255,255,0.16)] transition-all duration-300 ease-out ${
                phase === "dictating"
                  ? "w-[88px] gap-[3.5px] px-3.5"
                  : phase === "cleaning"
                    ? "w-[116px] gap-2 px-4"
                    : "w-[108px] gap-1.5 px-3.5"
              }`}
            >
              {phase === "dictating" &&
                WAVE_HEIGHTS.map((pct, i) => (
                  <span
                    key={i}
                    className="oto-bar w-[2.5px] rounded-full bg-white"
                    style={{
                      height: `${Math.round((pct / 100) * 14)}px`,
                      animationDelay: `${i * 0.08}s`,
                    }}
                  />
                ))}

              {phase === "cleaning" && (
                <>
                  <span className="oto-shimmer-text text-[12px] font-medium leading-none">
                    Cleaning
                  </span>
                  <span
                    aria-hidden="true"
                    className="size-3 shrink-0 animate-spin rounded-full border-[1.5px] border-white/25 border-t-white"
                  />
                </>
              )}

              {(phase === "cleaned" || phase === "fading") && (
                <>
                  <svg
                    width="13"
                    height="13"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2.4"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    aria-hidden="true"
                    className="text-[#86EFAC]"
                  >
                    <path d="M5 13l4 4L19 7" />
                  </svg>
                  <span className="text-[12px] font-medium leading-none text-white/95">
                    Cleaned
                  </span>
                </>
              )}
            </div>
          </div>

          {/* Fixed-height typewriter description so CTA below never jumps */}
          <div className="mt-4 flex min-h-[78px] w-full items-start justify-center sm:min-h-[62px]">
            <p
              className={`text-[17px] leading-[1.5] text-pretty text-[#111111]/80 transition-opacity duration-300 sm:text-[19px] ${
                phase === "fading" ? "opacity-0" : "opacity-100"
              }`}
            >
              {renderLiveText()}
              {phase === "dictating" && (
                <span
                  aria-hidden="true"
                  className="oto-caret ml-0.5 inline-block h-[1.05em] w-[1.5px] translate-y-[2.5px] rounded-full bg-[#111111]"
                />
              )}
            </p>
          </div>
        </div>

        {/* Primary CTA */}
        <div className="mt-7 flex flex-wrap items-center justify-center gap-3 sm:mt-8">
          <a
            href={SITE.downloadUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex h-11 items-center justify-center gap-2 rounded-full bg-[#111111] px-6 text-[15px] font-medium text-white shadow-[0_8px_24px_rgba(17,17,17,0.16),inset_0_1px_0_rgba(255,255,255,0.14)] transition-all hover:bg-[#242424] hover:shadow-[0_10px_28px_rgba(17,17,17,0.2)]"
          >
            <AppleIcon />
            <span>Download for macOS</span>
          </a>
        </div>

        <p className="mt-3.5 text-[12px] text-[#111111]/50">
          Free · 100% on-device · Apple Silicon ·{" "}
          <a
            href={SITE.releasesUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="underline decoration-[#111111]/25 underline-offset-2 transition-colors hover:text-[#111111]"
          >
            {SITE.version}
          </a>
        </p>
      </div>
    </section>
  );
}
