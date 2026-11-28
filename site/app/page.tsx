import { FaqSection } from "@/components/FaqSection";
import { FeatureTabsCard } from "@/components/FeatureTabsCard";
import { HeroShowcase } from "@/components/HeroShowcase";
import { OtoLogo } from "@/components/OtoLogo";
import { TopBar } from "@/components/TopBar";
import { SITE } from "@/lib/links";

interface Highlight {
  title: string;
  subtitle: string;
  icon: React.ReactNode;
}

const HIGHLIGHTS: Highlight[] = [
  {
    title: "Local-first",
    subtitle: "100% private",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <rect x="5" y="11" width="14" height="9" rx="2" />
        <path d="M8 11V7a4 4 0 0 1 8 0v4" />
      </svg>
    ),
  },
  {
    title: "Works offline",
    subtitle: "No cloud ever",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M2 2l20 20" />
        <path d="M8.5 16.5a5 5 0 0 1 7 0" />
        <path d="M5 12.85a10 10 0 0 1 5.17-2.69" />
        <path d="M10.71 5.05A16 16 0 0 1 22.58 9" />
        <path d="M1.42 9a15.9 15.9 0 0 1 4.7-2.88" />
        <circle cx="12" cy="19.5" r="0.8" fill="currentColor" stroke="none" />
      </svg>
    ),
  },
  {
    title: "One shortcut",
    subtitle: "Hold or hands-free",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <rect x="3" y="6" width="18" height="12" rx="3" />
        <path d="M7 10h2m3 0h2m3 0h0M8 14h8" />
      </svg>
    ),
  },
  {
    title: "Talk 3× faster",
    subtitle: "Than typing",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M4 12v0m4-5v10m4-13v16m4-11v6m4-3v0" />
      </svg>
    ),
  },
  {
    title: "Auto cleanup",
    subtitle: "Per-app rules",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9L12 3Z" />
        <path d="M19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8L19 16Z" />
      </svg>
    ),
  },
  {
    title: "Never loses words",
    subtitle: "Recovery card",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <rect x="4" y="4" width="16" height="16" rx="3" />
        <path d="M8.5 12.2l2.3 2.3 4.7-5" />
      </svg>
    ),
  },
  {
    title: "Audio ducking",
    subtitle: "Lowers music",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M11 5L6 9H3v6h3l5 4V5Z" />
        <path d="M15.5 9.5a3.5 3.5 0 0 1 0 5" />
      </svg>
    ),
  },
  {
    title: "Multi-language",
    subtitle: "Apple Speech",
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <circle cx="12" cy="12" r="9" />
        <path d="M3.5 9h17M3.5 15h17M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18" />
      </svg>
    ),
  },
];

export default function Home() {
  return (
    <div id="top" className="min-h-screen bg-white text-[#111111]">
      <TopBar />

      <main>
        {/* Full-viewport centered hero with live typewriter dictation & cleanup */}
        <HeroShowcase />

        {/* Dedicated 3-tab interactive feature card */}
        <FeatureTabsCard />

        {/* Minimal 4x2 "Under the hood" icon grid */}
        <section className="mx-auto max-w-[760px] px-5 py-20 sm:px-6 sm:py-28">
          <div className="text-center">
            <p className="text-[12px] font-medium tracking-[0.12em] uppercase text-[#888888]">
              And more
            </p>
            <h2 className="mt-2.5 text-[30px] font-semibold leading-[1.15] tracking-[-0.025em] text-[#111111] sm:text-[36px]">
              Under the hood
            </h2>
          </div>

          <div className="mt-12 grid grid-cols-2 gap-x-6 gap-y-10 sm:mt-16 sm:grid-cols-4 sm:gap-y-12">
            {HIGHLIGHTS.map((item) => (
              <div
                key={item.title}
                className="flex flex-col items-center text-center"
              >
                <div className="mb-3 flex size-10 items-center justify-center text-[#111111]">
                  {item.icon}
                </div>
                <div className="text-[13.5px] font-medium leading-[1.35] text-[#111111]">
                  {item.title}
                </div>
                <div className="mt-0.5 text-[13px] leading-[1.35] text-[#6B7280]">
                  {item.subtitle}
                </div>
              </div>
            ))}
          </div>
        </section>

        {/* Centered single-card FAQ */}
        <FaqSection />
      </main>

      {/* Ultra-minimal centered footer (no personal name) */}
      <footer className="px-5 pt-4 pb-14 text-center sm:pb-16">
        <div className="inline-flex items-center justify-center gap-2 text-[12px] text-[#9CA3AF]">
          <span>© 2026</span>
          <a
            href="#top"
            aria-label="Back to top"
            className="inline-flex items-center gap-1.5 font-medium text-[#111111] transition-opacity hover:opacity-80"
          >
            <OtoLogo size={18} />
            <span>{SITE.name}</span>
          </a>
        </div>
        <div className="mt-2.5 flex items-center justify-center gap-4 text-[11px] tracking-[0.08em] uppercase text-[#9CA3AF]">
          <a
            href={SITE.githubUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="transition-colors hover:text-[#111111]"
          >
            GitHub
          </a>
          <a
            href={SITE.releasesUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="transition-colors hover:text-[#111111]"
          >
            Releases
          </a>
          <a
            href={SITE.issuesUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="transition-colors hover:text-[#111111]"
          >
            Feedback
          </a>
        </div>
      </footer>
    </div>
  );
}
