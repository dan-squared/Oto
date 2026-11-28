import { useId } from "react";

interface OtoLogoProps {
  size?: number;
  className?: string;
}

/**
 * Renders the exact vector mark from Oto/Assets.xcassets/OtoLogo.imageset/OtoLogo.svg
 * inside a crisp dark squircle so the sky-blue gradient stays sharp on #FFFFFF.
 */
export function OtoLogo({ size = 24, className = "" }: OtoLogoProps) {
  const gradId = useId();
  const radius = Math.round(size * 0.25);

  return (
    <span
      className={`inline-flex shrink-0 items-center justify-center bg-[#111111] shadow-[inset_0_1px_0_rgba(255,255,255,0.14)] ${className}`}
      style={{ width: size, height: size, borderRadius: radius }}
      aria-hidden="true"
    >
      <svg
        width={Math.round(size * 0.66)}
        height={Math.round(size * 0.66)}
        viewBox="0 0 702 702"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M350.685 0C405.661 0.000952214 451.135 40.6507 458.708 93.5322C501.409 62.1841 561.76 65.8209 600.373 104.433C638.222 142.285 642.45 201.014 613.073 243.54C663.378 253.27 701.37 297.538 701.37 350.685C701.37 404.595 662.279 449.369 610.899 458.226C642.638 500.955 639.134 561.616 600.373 600.377C561.613 639.137 500.955 642.643 458.226 610.907C449.366 662.284 404.592 701.369 350.685 701.37C297.539 701.37 253.271 663.381 243.54 613.077C201.014 642.457 142.281 638.227 104.429 600.377C65.8151 561.763 62.1801 501.41 93.5322 458.708C40.6493 451.136 0 405.662 0 350.685C0 296.467 39.5347 251.489 91.3494 242.994C62.384 200.512 66.7402 142.123 104.429 104.433C142.118 66.7449 200.508 62.3855 242.99 91.3494C251.485 39.5354 296.467 0 350.685 0ZM349.282 561.096C466.264 561.096 561.096 466.264 561.096 349.282C561.096 232.301 466.264 137.468 349.282 137.468C232.301 137.468 137.468 232.301 137.468 349.282C137.468 466.264 232.301 561.096 349.282 561.096Z"
          fill={`url(#${gradId})`}
        />
        <defs>
          <linearGradient
            id={gradId}
            x1="350.685"
            y1="0"
            x2="350.685"
            y2="701.37"
            gradientUnits="userSpaceOnUse"
          >
            <stop stopColor="#9BCBFF" />
            <stop offset="1" stopColor="#F3F8FF" />
          </linearGradient>
        </defs>
      </svg>
    </span>
  );
}
