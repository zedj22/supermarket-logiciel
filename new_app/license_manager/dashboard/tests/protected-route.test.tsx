import { screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { ThemeProvider } from "@/components/theme-provider";

import { renderWithSession } from "./helpers";

const nav = vi.hoisted(() => ({ replace: vi.fn(), pathname: "/overview" }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ replace: nav.replace, push: vi.fn(), refresh: vi.fn() }),
  usePathname: () => nav.pathname,
  useSearchParams: () => new URLSearchParams(),
}));

import PrivateLayout from "@/app/(app)/layout";

beforeEach(() => {
  nav.replace.mockClear();
});

describe("protected area", () => {
  it("redirects an anonymous visitor to the sign-in page", async () => {
    renderWithSession(
      <ThemeProvider>
        <PrivateLayout>
          <p>License secrets</p>
        </PrivateLayout>
      </ThemeProvider>,
      { status: "unauthenticated", admin: null },
    );

    expect(screen.getByText(/Redirecting to sign in/)).toBeInTheDocument();
    expect(screen.queryByText("License secrets")).not.toBeInTheDocument();
    await waitFor(() => expect(nav.replace).toHaveBeenCalledWith("/login"));
  });

  it("shows a session check instead of the page while loading", () => {
    renderWithSession(
      <ThemeProvider>
        <PrivateLayout>
          <p>License secrets</p>
        </PrivateLayout>
      </ThemeProvider>,
      { status: "loading", admin: null },
    );

    expect(screen.getByText(/Checking your session/)).toBeInTheDocument();
    expect(screen.queryByText("License secrets")).not.toBeInTheDocument();
  });

  it("renders the dashboard shell for an authenticated administrator", () => {
    renderWithSession(
      <ThemeProvider>
        <PrivateLayout>
          <p>License secrets</p>
        </PrivateLayout>
      </ThemeProvider>,
    );

    expect(screen.getByText("License secrets")).toBeInTheDocument();
    expect(screen.getAllByRole("navigation", { name: "Main" }).length).toBeGreaterThan(0);
    expect(screen.getByRole("button", { name: "Sign out" })).toBeInTheDocument();
    expect(nav.replace).not.toHaveBeenCalled();
  });
});
