import type { Metadata } from "next";

import { ThemeProvider } from "@/components/theme-provider";
import { SessionProvider } from "@/lib/session";

import "./globals.css";

export const metadata: Metadata = {
  title: "KlickPOS License Manager",
  description: "Private administrator dashboard for KlickPOS lifetime licenses.",
  robots: { index: false, follow: false },
};

/** Applies the stored theme before paint so there is no flash. */
const THEME_SCRIPT = `(function(){try{var t=localStorage.getItem('klickpos.theme');var d=window.matchMedia('(prefers-color-scheme: dark)').matches;if(t==='dark'||(!t&&d)){document.documentElement.classList.add('dark');document.documentElement.style.colorScheme='dark';}}catch(e){}})();`;

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body>
        <ThemeProvider>
          <SessionProvider>{children}</SessionProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
