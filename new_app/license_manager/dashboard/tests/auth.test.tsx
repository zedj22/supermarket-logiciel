import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { renderWithSession } from "./helpers";

const nav = vi.hoisted(() => ({ replace: vi.fn(), push: vi.fn() }));
const firebase = vi.hoisted(() => ({ isFirebaseConfigured: false }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ replace: nav.replace, push: nav.push, refresh: vi.fn() }),
  usePathname: () => "/login",
  useSearchParams: () => new URLSearchParams(),
}));

vi.mock("@/lib/firebase", () => ({
  get isFirebaseConfigured() {
    return firebase.isFirebaseConfigured;
  },
  firebaseConfig: { apiKey: "", authDomain: "", projectId: "", appId: "" },
  signInWithGoogle: vi.fn(async () => ({ uid: "admin-1", email: "admin@example.com" })),
  signOutAdmin: vi.fn(),
  subscribeToAuth: vi.fn(() => () => undefined),
  currentIdToken: vi.fn(async () => "token"),
}));

import LoginPage from "@/app/login/page";

beforeEach(() => {
  firebase.isFirebaseConfigured = false;
  nav.replace.mockClear();
});

describe("authentication screen", () => {
  it("explains the missing Firebase configuration and offers no development fallback", () => {
    renderWithSession(<LoginPage />, { status: "unauthenticated" });

    expect(screen.getByText("Not configured")).toBeInTheDocument();
    expect(screen.getByText(/NEXT_PUBLIC_FIREBASE_\*/)).toBeInTheDocument();
    expect(screen.getByText(/no development sign-in fallback/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Enter dashboard/i })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
  });

  it("offers Google as the only sign-in method when Firebase is configured", () => {
    firebase.isFirebaseConfigured = true;
    renderWithSession(<LoginPage />, { status: "unauthenticated" });

    expect(screen.getByRole("button", { name: /Sign in with Google/i })).toBeInTheDocument();
    expect(screen.queryByLabelText("Email")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
  });

  it("signs in with Google and redirects to the dashboard", async () => {
    firebase.isFirebaseConfigured = true;
    const { signInWithGoogle } = await import("@/lib/firebase");
    const user = userEvent.setup();

    renderWithSession(<LoginPage />, { status: "unauthenticated" });
    await user.click(screen.getByRole("button", { name: /Sign in with Google/i }));

    await waitFor(() => expect(signInWithGoogle).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(nav.replace).toHaveBeenCalledWith("/overview"));
  });

  it("explains a blocked popup instead of navigating", async () => {
    firebase.isFirebaseConfigured = true;
    const { signInWithGoogle } = await import("@/lib/firebase");
    vi.mocked(signInWithGoogle).mockRejectedValueOnce({ code: "auth/popup-blocked" });
    const user = userEvent.setup();

    renderWithSession(<LoginPage />, { status: "unauthenticated" });
    await user.click(screen.getByRole("button", { name: /Sign in with Google/i }));

    expect(await screen.findByText(/blocked the sign-in popup/i)).toBeInTheDocument();
    expect(nav.replace).not.toHaveBeenCalled();
  });

  it("treats a closed popup as a cancellation", async () => {
    firebase.isFirebaseConfigured = true;
    const { signInWithGoogle } = await import("@/lib/firebase");
    vi.mocked(signInWithGoogle).mockRejectedValueOnce({
      code: "auth/popup-closed-by-user",
    });
    const user = userEvent.setup();

    renderWithSession(<LoginPage />, { status: "unauthenticated" });
    await user.click(screen.getByRole("button", { name: /Sign in with Google/i }));

    expect(await screen.findByText("Sign-in cancelled.")).toBeInTheDocument();
    expect(nav.replace).not.toHaveBeenCalled();
  });

  it("names the authorized-domains setting when the origin is rejected", async () => {
    firebase.isFirebaseConfigured = true;
    const { signInWithGoogle } = await import("@/lib/firebase");
    vi.mocked(signInWithGoogle).mockRejectedValueOnce({
      code: "auth/unauthorized-domain",
    });
    const user = userEvent.setup();

    renderWithSession(<LoginPage />, { status: "unauthenticated" });
    await user.click(screen.getByRole("button", { name: /Sign in with Google/i }));

    expect(await screen.findByText(/Authorized domains/i)).toBeInTheDocument();
    expect(nav.replace).not.toHaveBeenCalled();
  });
});
