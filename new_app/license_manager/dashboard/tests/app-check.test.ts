/**
 * Firebase App Check on the dashboard (Phase 6.9).
 *
 * The browser only *transports* a token: these tests pin that it never invents
 * one, never treats App Check as a substitute for the ID token, and degrades to
 * "no token" (leaving the decision to the API) when initialization or token
 * retrieval fails.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const sdk = vi.hoisted(() => ({
  initializeAppCheck: vi.fn(),
  getToken: vi.fn(),
  ReCaptchaEnterpriseProvider: vi.fn(function (
    this: { siteKey: string },
    siteKey: string,
  ) {
    this.siteKey = siteKey;
  }),
}));

vi.mock("firebase/app-check", () => sdk);
vi.mock("@/lib/firebase", () => ({ firebaseApp: () => ({ name: "test-app" }) }));

type AppCheckModule = typeof import("@/lib/app-check");

async function loadWith(env: Record<string, string>): Promise<AppCheckModule> {
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
  vi.resetModules();
  return import("@/lib/app-check");
}

beforeEach(() => {
  sdk.initializeAppCheck.mockReset();
  sdk.getToken.mockReset();
  sdk.ReCaptchaEnterpriseProvider.mockClear();
  sdk.initializeAppCheck.mockImplementation(() => ({ name: "app-check" }));
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
  delete (window as unknown as { FIREBASE_APPCHECK_DEBUG_TOKEN?: string }).FIREBASE_APPCHECK_DEBUG_TOKEN;
});

describe("App Check client", () => {
  it("is inactive when no site key is configured (local development)", async () => {
    const appCheck = await loadWith({
      NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY: "",
      NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN: "",
    });

    expect(appCheck.isAppCheckConfigured).toBe(false);
    expect(appCheck.firebaseAppCheck()).toBeNull();
    expect(await appCheck.currentAppCheckToken()).toBeNull();
    expect(sdk.initializeAppCheck).not.toHaveBeenCalled();
    expect(sdk.ReCaptchaEnterpriseProvider).not.toHaveBeenCalled();
  });

  it("initializes reCAPTCHA Enterprise with the public site key", async () => {
    const appCheck = await loadWith({
      NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY: "site-key-123",
    });

    const instance = appCheck.firebaseAppCheck();

    expect(instance).not.toBeNull();
    expect(sdk.ReCaptchaEnterpriseProvider).toHaveBeenCalledWith("site-key-123");
    const [app, options] = sdk.initializeAppCheck.mock.calls[0] as [
      { name: string },
      { provider: unknown; isTokenAutoRefreshEnabled: boolean },
    ];
    expect(app.name).toBe("test-app");
    expect(options.provider).toBeInstanceOf(sdk.ReCaptchaEnterpriseProvider);
    expect(options.isTokenAutoRefreshEnabled).toBe(true);
    // Initialized once, even across calls.
    appCheck.firebaseAppCheck();
    expect(sdk.initializeAppCheck).toHaveBeenCalledTimes(1);
  });

  it("returns the SDK token for the next API call", async () => {
    sdk.getToken.mockResolvedValue({ token: "app-check-jwt" });
    const appCheck = await loadWith({
      NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY: "site-key-123",
    });

    await expect(appCheck.currentAppCheckToken()).resolves.toBe("app-check-jwt");
    // No forced refresh unless asked.
    expect(sdk.getToken.mock.calls[0]![1]).toBe(false);
    await appCheck.currentAppCheckToken(true);
    expect(sdk.getToken.mock.calls[1]![1]).toBe(true);
  });

  it("reports no token instead of a fabricated one when retrieval fails", async () => {
    sdk.getToken.mockRejectedValue(new Error("reCAPTCHA blocked"));
    const appCheck = await loadWith({
      NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY: "site-key-123",
    });

    await expect(appCheck.currentAppCheckToken()).resolves.toBeNull();
  });

  it("reports no token when initialization throws", async () => {
    sdk.initializeAppCheck.mockImplementation(() => {
      throw new Error("bad site key");
    });
    const appCheck = await loadWith({
      NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY: "site-key-123",
    });

    expect(appCheck.firebaseAppCheck()).toBeNull();
    await expect(appCheck.currentAppCheckToken()).resolves.toBeNull();
  });

  it("registers the development debug token before initializing", async () => {
    sdk.getToken.mockResolvedValue({ token: "debug-token" });
    const appCheck = await loadWith({
      NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY: "site-key-123",
      NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN: "11111111-2222-3333-4444-555555555555",
    });

    appCheck.firebaseAppCheck();

    expect(
      (window as unknown as { FIREBASE_APPCHECK_DEBUG_TOKEN?: string })
        .FIREBASE_APPCHECK_DEBUG_TOKEN,
    ).toBe("11111111-2222-3333-4444-555555555555");
  });
});
