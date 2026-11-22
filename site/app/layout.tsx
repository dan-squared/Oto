import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Oto",
  description: "Dictation that lands where you were working.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
