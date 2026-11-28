"use client";

import { useState } from "react";

interface FaqItem {
  question: string;
  answer: string;
}

const FAQ_ITEMS: FaqItem[] = [
  {
    question: "Does it work offline?",
    answer:
      "Yes. Once a language model is downloaded in Settings, dictation runs completely offline with Apple Speech.",
  },
  {
    question: "Does my voice ever leave my Mac?",
    answer:
      "Never. Both speech transcription and optional AI cleanup run locally on your Mac—no cloud fallback, no accounts, no telemetry.",
  },
  {
    question: "Is there a subscription?",
    answer:
      "No. Everything runs on your own Apple Silicon hardware, so there are no cloud API fees or monthly plans.",
  },
  {
    question: "What Macs are supported?",
    answer:
      "Any Mac running macOS with Apple Speech support. Apple Silicon (M1 or newer) is recommended for optional on-device AI cleanup.",
  },
  {
    question: "What if I speak without clicking a text field?",
    answer:
      "Your words are never dropped. A small recovery card appears with your transcript and a one-click Copy button.",
  },
  {
    question: "Can I customize cleanup per app?",
    answer:
      "Yes. Choose Off, Light, Medium, or a custom prompt globally—and override individual apps like Mail, Slack, or Terminal.",
  },
  {
    question: "Does it support multiple languages?",
    answer:
      "Yes. Install any language supported by Apple Speech in Settings and switch directly from the menu bar.",
  },
];

export function FaqSection() {
  const [openIndex, setOpenIndex] = useState<number | null>(null);

  return (
    <section
      id="faq"
      className="w-full border-t border-[#F1F1F3] bg-gradient-to-b from-[#FAFAFB] to-white px-5 py-20 sm:px-6 sm:py-24"
    >
      <div className="mx-auto max-w-[660px]">
        <h2 className="text-center text-[30px] font-semibold leading-[1.12] tracking-[-0.025em] text-[#111111] sm:text-[38px]">
          Frequently
          <br />
          Asked Questions
        </h2>

        <div className="mt-10 overflow-hidden rounded-2xl border border-[#EAEAEA] bg-white shadow-[0_1px_2px_rgba(0,0,0,0.02)] sm:mt-12">
          <div className="divide-y divide-[#F0F0F0]">
            {FAQ_ITEMS.map((item, idx) => {
              const isOpen = openIndex === idx;
              return (
                <div key={item.question}>
                  <button
                    type="button"
                    aria-expanded={isOpen}
                    onClick={() => setOpenIndex(isOpen ? null : idx)}
                    className="flex w-full items-center justify-between gap-4 px-5 py-4 text-left transition-colors hover:bg-[#FAFAFB] sm:px-6"
                  >
                    <span className="text-[14px] font-medium leading-[1.45] text-[#111111] sm:text-[15px]">
                      {item.question}
                    </span>
                    <svg
                      width="15"
                      height="15"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.75"
                      strokeLinecap="round"
                      aria-hidden="true"
                      className={`shrink-0 text-[#9CA3AF] transition-transform duration-200 motion-reduce:transition-none ${
                        isOpen ? "rotate-45 text-[#111111]" : "rotate-0"
                      }`}
                    >
                      <path d="M12 5v14M5 12h14" />
                    </svg>
                  </button>
                  {isOpen && (
                    <p className="px-5 pb-4.5 pr-12 text-[13.5px] leading-[1.6] text-[#6B7280] sm:px-6 sm:text-[14px]">
                      {item.answer}
                    </p>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
