"use client";

import { useState } from "react";

type TabId = "dictate" | "cleanup" | "recovery";

const TABS: { id: TabId; label: string }[] = [
  { id: "dictate", label: "Dictate" },
  { id: "cleanup", label: "Auto Cleanup" },
  { id: "recovery", label: "Recovery & Snippets" },
];

const WAVE_HEIGHTS = [34, 54, 78, 96, 100, 94, 78, 58, 42, 30];

export function FeatureTabsCard() {
  const [activeTab, setActiveTab] = useState<TabId>("dictate");

  return (
    <section
      aria-label="Feature preview"
      className="mx-auto w-full max-w-[780px] px-5 pt-6 pb-8 sm:px-6 sm:pt-10"
    >
      {/* Clean standalone showcase card */}
      <div className="flex min-h-[270px] flex-col items-center justify-center rounded-[24px] border border-[#ECECEF] bg-[#F7F8FA] p-5 sm:min-h-[310px] sm:p-10">
        {activeTab === "dictate" && (
          <div className="flex w-full max-w-[500px] flex-col items-center gap-6">
            <div className="w-full rounded-2xl border border-[#E7E9EE] bg-white p-5 text-left shadow-[0_2px_12px_rgba(17,17,17,0.03)] sm:p-6">
              <div className="mb-3 flex items-center justify-between text-[12px] text-[#888888]">
                <span className="font-medium text-[#111111]">Notes</span>
                <span>Active cursor</span>
              </div>
              <p className="text-[14.5px] leading-[1.6] text-[#111111] sm:text-[15.5px]">
                The build is green and ready for review. Let’s walk through the
                checklist after lunch and ship before five.
                <span className="ml-0.5 inline-block h-[1em] w-[1.5px] translate-y-[2px] bg-[#111111]" />
              </p>
            </div>

            <div className="flex flex-col items-center gap-2">
              <div className="inline-flex h-8 items-center gap-[3.5px] rounded-full bg-[#111111] px-4 shadow-[0_8px_22px_rgba(17,17,17,0.16),inset_0_1px_0_rgba(255,255,255,0.16)]">
                {WAVE_HEIGHTS.map((pct, i) => (
                  <span
                    key={i}
                    className="oto-bar w-[2.5px] rounded-full bg-white"
                    style={{
                      height: `${Math.round((pct / 100) * 14)}px`,
                      animationDelay: `${i * 0.08}s`,
                    }}
                  />
                ))}
              </div>
              <span className="text-[12px] text-[#888888]">
                Hold Right ⌥ to speak · Double-tap for hands-free
              </span>
            </div>
          </div>
        )}

        {activeTab === "cleanup" && (
          <div className="flex w-full max-w-[560px] flex-col items-center gap-6">
            <div className="grid w-full grid-cols-1 gap-3.5 text-left sm:grid-cols-2">
              <div className="rounded-2xl border border-[#E7E9EE] bg-white/80 p-4 sm:p-5">
                <div className="mb-2 text-[11.5px] font-medium text-[#888888]">
                  Spoken
                </div>
                <p className="text-[13.5px] leading-[1.55] text-[#6B7280] sm:text-[14px]">
                  “So <span className="line-through opacity-55">um</span> let’s{" "}
                  <span className="line-through opacity-55">like</span> move the
                  release to Thursday,{" "}
                  <span className="line-through opacity-55">actually</span>{" "}
                  Friday morning.”
                </p>
              </div>

              <div className="rounded-2xl border border-[#111111]/12 bg-white p-4 shadow-[0_2px_12px_rgba(17,17,17,0.04)] sm:p-5">
                <div className="mb-2 flex items-center justify-between gap-2">
                  <span className="text-[11.5px] font-medium text-[#111111]">
                    Cleaned locally
                  </span>
                  <span className="rounded-full bg-[#F3F4F6] px-2 py-0.5 text-[10.5px] font-medium text-[#111111]">
                    Mail · Medium
                  </span>
                </div>
                <p className="text-[13.5px] leading-[1.55] text-[#111111] sm:text-[14px]">
                  “Let’s move the release to Friday morning.”
                </p>
              </div>
            </div>

            <div className="flex flex-wrap items-center justify-center gap-2 text-[12px]">
              {["Off", "Light", "Medium", "Custom prompt"].map((mode, idx) => (
                <span
                  key={mode}
                  className={`rounded-full px-3 py-1 font-medium ${
                    idx === 2
                      ? "bg-[#111111] text-white"
                      : "border border-[#E5E7EB] bg-white text-[#6B7280]"
                  }`}
                >
                  {mode}
                </span>
              ))}
            </div>
          </div>
        )}

        {activeTab === "recovery" && (
          <div className="flex w-full max-w-[560px] flex-col items-center gap-5">
            <div className="grid w-full grid-cols-1 gap-3.5 text-left sm:grid-cols-2">
              <div className="rounded-2xl border border-[#E7E9EE] bg-white p-4 shadow-[0_2px_10px_rgba(17,17,17,0.03)] sm:p-5">
                <div className="mb-2 flex items-center justify-between">
                  <span className="text-[11.5px] font-medium text-[#111111]">
                    No field focused
                  </span>
                  <span className="text-[11px] text-[#888888]">Kept safely</span>
                </div>
                <p className="text-[13px] leading-[1.55] text-[#444444]">
                  “Ship the signed build once the checks are green.”
                </p>
                <div className="mt-3.5 flex justify-end">
                  <span className="rounded-full bg-[#111111] px-3.5 py-1 text-[11.5px] font-medium text-white">
                    Copy
                  </span>
                </div>
              </div>

              <div className="rounded-2xl border border-[#E7E9EE] bg-white p-4 shadow-[0_2px_10px_rgba(17,17,17,0.03)] sm:p-5">
                <div className="mb-2.5 text-[11.5px] font-medium text-[#111111]">
                  Snippets &amp; dictionary
                </div>
                <div className="space-y-2 text-[12px]">
                  <div className="flex items-center justify-between gap-2 rounded-lg bg-[#F7F8FA] px-2.5 py-1.5">
                    <span className="font-medium text-[#111111]">“booking link”</span>
                    <span className="truncate text-[#888888]">cal.com/team/30m</span>
                  </div>
                  <div className="flex flex-wrap gap-1.5 pt-1">
                    {["PostgreSQL", "Kubernetes", "SwiftUI"].map((term) => (
                      <span
                        key={term}
                        className="rounded-full border border-[#E5E7EB] bg-[#FAFAFB] px-2.5 py-0.5 text-[11px] text-[#111111]"
                      >
                        {term}
                      </span>
                    ))}
                  </div>
                </div>
              </div>
            </div>

            <span className="text-[12px] text-[#888888]">
              Spoken words are never lost · Exact spellings stay locked
            </span>
          </div>
        )}
      </div>

      {/* Centered 3-Tab Pill Switcher */}
      <div className="mt-5 flex justify-center sm:mt-6">
        <div
          role="tablist"
          aria-label="Preview modes"
          className="inline-flex max-w-full flex-wrap items-center justify-center gap-1 rounded-full border border-[#ECECEF] bg-[#F5F5F7] p-1"
        >
          {TABS.map((tab) => {
            const isActive = activeTab === tab.id;
            return (
              <button
                key={tab.id}
                type="button"
                role="tab"
                aria-selected={isActive}
                onClick={() => setActiveTab(tab.id)}
                className={`rounded-full px-3.5 py-1.5 text-[12.5px] font-medium transition-all sm:px-4 sm:text-[13px] ${
                  isActive
                    ? "bg-white text-[#111111] shadow-[0_1px_3px_rgba(0,0,0,0.08)]"
                    : "text-[#6B7280] hover:text-[#111111]"
                }`}
              >
                {tab.label}
              </button>
            );
          })}
        </div>
      </div>
    </section>
  );
}
