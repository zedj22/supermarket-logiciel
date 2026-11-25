"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";

import { cx } from "@/lib/cx";
import { initials } from "@/lib/format";
import { useSession } from "@/lib/session";
import {
  IconAudit,
  IconClose,
  IconCustomers,
  IconDevice,
  IconIssue,
  IconKey,
  IconLogout,
  IconMenu,
  IconMoon,
  IconOverview,
  IconShield,
  IconSun,
} from "./icons";
import { useTheme } from "./theme-provider";
import { Button } from "./ui";

const NAV = [
  { href: "/overview", label: "Overview", icon: IconOverview },
  { href: "/issue", label: "Issue license", icon: IconIssue },
  { href: "/devices", label: "Devices", icon: IconDevice },
  { href: "/licenses", label: "Licenses", icon: IconKey },
  { href: "/customers", label: "Customers", icon: IconCustomers },
  { href: "/audit", label: "Audit log", icon: IconAudit },
] as const;

function Brand() {
  return (
    <div className="flex items-center gap-3">
      <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-accent text-sm font-bold text-white dark:text-canvas">
        KP
      </span>
      <span className="leading-tight">
        <span className="block text-sm font-semibold tracking-tight text-ink">KlickPOS</span>
        <span className="block text-[11px] text-muted">License Manager</span>
      </span>
    </div>
  );
}

function NavLinks({ onNavigate }: { onNavigate?: () => void }) {
  const pathname = usePathname();
  return (
    <nav aria-label="Main" className="flex flex-col gap-1">
      {NAV.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        const Icon = item.icon;
        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            aria-current={active ? "page" : undefined}
            className={cx(
              "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
              active
                ? "bg-accent-soft text-accent-ink"
                : "text-muted hover:bg-elevated hover:text-ink",
            )}
          >
            <Icon size={18} />
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}

function ThemeToggle() {
  const { theme, toggle } = useTheme();
  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
      className="rounded-lg border border-line bg-panel p-2 text-muted transition-colors hover:text-ink"
    >
      {theme === "dark" ? <IconSun size={17} /> : <IconMoon size={17} />}
    </button>
  );
}

function AccountMenu() {
  const { admin, signOut } = useSession();
  const router = useRouter();
  const [busy, setBusy] = useState(false);

  async function handleSignOut() {
    setBusy(true);
    try {
      await signOut();
      router.replace("/login");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex items-center gap-2 sm:gap-3">
      <div className="hidden text-right sm:block">
        <p className="max-w-[180px] truncate text-xs font-medium text-ink">
          {admin?.email ?? admin?.uid ?? "Administrator"}
        </p>
        <p className="text-[11px] text-muted">Signed in with Google</p>
      </div>
      <span
        aria-hidden="true"
        className="flex h-8 w-8 items-center justify-center rounded-full bg-accent-soft text-xs font-semibold text-accent-ink"
      >
        {initials(admin?.email ?? admin?.uid ?? "A")}
      </span>
      <Button
        variant="ghost"
        size="sm"
        onClick={handleSignOut}
        loading={busy}
        aria-label="Sign out"
        title="Sign out"
      >
        <IconLogout size={16} />
        <span className="hidden sm:inline">Sign out</span>
      </Button>
    </div>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const [mobileOpen, setMobileOpen] = useState(false);
  const pathname = usePathname();

  useEffect(() => {
    setMobileOpen(false);
  }, [pathname]);

  const title = NAV.find(
    (item) => pathname === item.href || pathname.startsWith(`${item.href}/`),
  )?.label ?? "License Manager";

  return (
    <div className="min-h-dvh bg-canvas">
      {/* Desktop sidebar */}
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-64 flex-col border-r border-line bg-panel px-4 py-5 lg:flex">
        <Brand />
        <div className="mt-8 flex-1">
          <NavLinks />
        </div>
        <div className="rounded-lg border border-line bg-elevated/60 p-3">
          <p className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted">
            <IconShield size={13} /> Private tool
          </p>
          <p className="mt-1 text-[11px] leading-relaxed text-muted">
            License data is read from the License API only. No signing key or
            service credential ever reaches this browser.
          </p>
        </div>
      </aside>

      {/* Mobile header */}
      <div className="sticky top-0 z-30 flex items-center justify-between gap-3 border-b border-line bg-panel/95 px-4 py-3 backdrop-blur lg:hidden">
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setMobileOpen(true)}
            aria-label="Open navigation"
            aria-expanded={mobileOpen}
            className="rounded-lg border border-line bg-panel p-2 text-muted hover:text-ink"
          >
            <IconMenu size={18} />
          </button>
          <Brand />
        </div>
        <ThemeToggle />
      </div>

      {/* Mobile navigation sheet */}
      {mobileOpen ? (
        <div className="fixed inset-0 z-40 lg:hidden">
          <div
            className="absolute inset-0 bg-black/50"
            aria-hidden="true"
            onClick={() => setMobileOpen(false)}
          />
          <div
            role="dialog"
            aria-modal="true"
            aria-label="Navigation"
            className="relative z-10 flex h-full w-72 max-w-[85vw] flex-col border-r border-line bg-panel px-4 py-5"
          >
            <div className="flex items-center justify-between">
              <Brand />
              <button
                type="button"
                onClick={() => setMobileOpen(false)}
                aria-label="Close navigation"
                className="rounded-md p-1 text-muted hover:text-ink"
              >
                <IconClose size={18} />
              </button>
            </div>
            <div className="mt-6 flex-1">
              <NavLinks onNavigate={() => setMobileOpen(false)} />
            </div>
            <div className="flex items-center justify-between border-t border-line pt-3">
              <AccountMenu />
            </div>
          </div>
        </div>
      ) : null}

      <div className="lg:pl-64">
        {/* Desktop top bar */}
        <div className="sticky top-0 z-20 hidden items-center justify-between gap-4 border-b border-line bg-canvas/85 px-6 py-3 backdrop-blur lg:flex">
          <p className="text-sm font-medium text-muted">{title}</p>
          <div className="flex items-center gap-3">
            <ThemeToggle />
            <AccountMenu />
          </div>
        </div>

        <main className="mx-auto w-full max-w-[1200px] px-4 py-6 sm:px-6 sm:py-8">
          {children}
        </main>
      </div>
    </div>
  );
}
