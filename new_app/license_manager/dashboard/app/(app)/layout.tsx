"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import type { ReactNode } from "react";

import { AppShell } from "@/components/shell";
import { Spinner } from "@/components/ui";
import { useSession } from "@/lib/session";

/**
 * Client-side guard for the private area.
 *
 * This is convenience, not security: the License API independently verifies the
 * Firebase ID token and its own administrator allowlist on every request, so a
 * forged route here still gets a 401/403 from the backend.
 */
export default function PrivateLayout({ children }: { children: ReactNode }) {
  const { status } = useSession();
  const router = useRouter();
  const pathname = usePathname();

  useEffect(() => {
    if (status === "unauthenticated") {
      router.replace("/login");
    }
  }, [status, router, pathname]);

  if (status !== "authenticated") {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-canvas">
        <div className="flex items-center gap-3 text-sm text-muted">
          <Spinner size={18} />
          {status === "loading" ? "Checking your session…" : "Redirecting to sign in…"}
        </div>
      </div>
    );
  }

  return <AppShell>{children}</AppShell>;
}
