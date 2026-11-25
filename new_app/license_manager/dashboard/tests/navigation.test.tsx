import { screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { ThemeProvider } from "@/components/theme-provider";
import { AppShell } from "@/components/shell";

import { renderWithSession } from "./helpers";

vi.mock("next/navigation", () => ({
  useRouter: () => ({ replace: vi.fn(), push: vi.fn(), refresh: vi.fn() }),
  usePathname: () => "/overview",
  useSearchParams: () => new URLSearchParams(),
}));

function renderShell() {
  return renderWithSession(
    <ThemeProvider>
      <AppShell>
        <p>Page body</p>
      </AppShell>
    </ThemeProvider>,
  );
}

describe("navigation", () => {
  it("renders every destination in the sidebar", () => {
    renderShell();
    const navs = screen.getAllByRole("navigation", { name: "Main" });
    expect(navs.length).toBeGreaterThan(0);

    for (const label of [
      "Overview",
      "Issue license",
      "Devices",
      "Licenses",
      "Customers",
      "Audit log",
    ]) {
      expect(screen.getAllByRole("link", { name: label }).length).toBeGreaterThan(0);
    }
  });

  it("marks the current page as aria-current", () => {
    renderShell();
    const current = screen
      .getAllByRole("link", { name: "Overview" })
      .find((link) => link.getAttribute("aria-current") === "page");
    expect(current).toBeDefined();
  });

  it("opens and closes the mobile navigation sheet", async () => {
    const user = userEvent.setup();
    renderShell();

    expect(screen.queryByRole("dialog", { name: "Navigation" })).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Open navigation" }));
    const sheet = await screen.findByRole("dialog", { name: "Navigation" });
    expect(sheet).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Close navigation" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Close navigation" }));
    expect(screen.queryByRole("dialog", { name: "Navigation" })).not.toBeInTheDocument();
  });

  it("switches between light and dark themes", async () => {
    const user = userEvent.setup();
    renderShell();

    // jsdom reports prefers-color-scheme: light, so the first click goes dark.
    await user.click(screen.getAllByRole("button", { name: /Switch to .* theme/ })[0]!);
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(window.localStorage.getItem("klickpos.theme")).toBe("dark");

    await user.click(screen.getAllByRole("button", { name: /Switch to .* theme/ })[0]!);
    expect(document.documentElement.classList.contains("dark")).toBe(false);
    expect(window.localStorage.getItem("klickpos.theme")).toBe("light");
  });
});
