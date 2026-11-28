"use client";

import { useEffect, useRef, useState } from "react";
import { SITE } from "@/lib/links";
import { OtoLogo } from "./OtoLogo";

export function TopBar() {
  const [visible, setVisible] = useState(true);
  const [scrolled, setScrolled] = useState(false);
  const lastYRef = useRef(0);
  const tickingRef = useRef(false);

  useEffect(() => {
    lastYRef.current = window.scrollY;

    const update = () => {
      const currentY = Math.max(0, window.scrollY);
      const prevY = lastYRef.current;
      const delta = currentY - prevY;

      setScrolled(currentY > 24);

      if (currentY <= 16) {
        setVisible(true);
        lastYRef.current = currentY;
      } else if (delta > 6 && currentY > 56) {
        setVisible(false);
        lastYRef.current = currentY;
      } else if (delta < -6) {
        setVisible(true);
        lastYRef.current = currentY;
      }

      tickingRef.current = false;
    };

    const onScroll = () => {
      if (!tickingRef.current) {
        tickingRef.current = true;
        window.requestAnimationFrame(update);
      }
    };

    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      data-visible={visible ? "true" : "false"}
      className={`fixed inset-x-0 top-0 z-50 transition-transform duration-200 ease-out motion-reduce:transition-none ${
        visible ? "translate-y-0" : "-translate-y-full pointer-events-none"
      }`}
    >
      <div
        className={`mx-auto flex h-16 max-w-6xl items-center justify-between px-6 sm:px-9 transition-colors duration-200 ${
          scrolled
            ? "bg-white/80 backdrop-blur-md"
            : "bg-transparent"
        }`}
      >
        <a
          href="#top"
          aria-label="Oto home"
          className="inline-flex items-center gap-2 text-[15px] font-medium text-[#111111] transition-opacity hover:opacity-80"
        >
          <OtoLogo size={26} />
          <span>{SITE.name}</span>
        </a>

        <a
          href={SITE.downloadUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex h-8.5 items-center justify-center rounded-full bg-[#111111] px-4 text-[13px] font-medium text-white shadow-[0_1px_2px_rgba(0,0,0,0.12),inset_0_1px_0_rgba(255,255,255,0.12)] transition-colors hover:bg-[#262626]"
        >
          Download
        </a>
      </div>
    </header>
  );
}
