import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-inter",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Oto — Offline dictation for macOS",
  description:
    "Hold a key, speak naturally, and land clean text anywhere on Mac. 100% on-device Apple Speech with optional local AI cleanup.",
  openGraph: {
    title: "Oto — Offline dictation for macOS",
    description:
      "Hold a key, speak naturally, and land clean text anywhere on Mac. 100% on-device Apple Speech with optional local AI cleanup.",
    type: "website",
  },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={inter.variable}>
      <body className="font-sans bg-white text-[#111111] antialiased selection:bg-[#111111] selection:text-white">
        {children}
      </body>
    </html>
  );
}
