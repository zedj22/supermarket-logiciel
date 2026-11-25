import { afterEach, describe, expect, it, vi } from "vitest";

/**
 * The Firebase web-app config comes from the environment (public values), and
 * there is no development sign-in fallback any more: a dashboard without a
 * configured project simply cannot sign anyone in.
 */
async function loadWith(env: Record<string, string>) {
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
  vi.resetModules();
  return import("@/lib/firebase");
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("Firebase web configuration", () => {
  it("reads the public web-app values from the environment", async () => {
    const flags = await loadWith({
      NEXT_PUBLIC_FIREBASE_API_KEY: "public-key",
      NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "klickpos-license-manager.firebaseapp.com",
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "klickpos-license-manager",
      NEXT_PUBLIC_FIREBASE_APP_ID: "1:123:web:abc",
      NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID: "123",
    });

    expect(flags.isFirebaseConfigured).toBe(true);
    expect(flags.firebaseConfig.projectId).toBe("klickpos-license-manager");
    expect(flags.firebaseConfig.authDomain).toBe(
      "klickpos-license-manager.firebaseapp.com",
    );
    expect(flags.firebaseConfig.appId).toBe("1:123:web:abc");
  });

  it("is not configured without an API key, auth domain or project id", async () => {
    const noKey = await loadWith({
      NEXT_PUBLIC_FIREBASE_API_KEY: "",
      NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "demo.firebaseapp.com",
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "demo",
    });
    expect(noKey.isFirebaseConfigured).toBe(false);

    const noDomain = await loadWith({
      NEXT_PUBLIC_FIREBASE_API_KEY: "key",
      NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "",
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "demo",
    });
    expect(noDomain.isFirebaseConfigured).toBe(false);

    const noProject = await loadWith({
      NEXT_PUBLIC_FIREBASE_API_KEY: "key",
      NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "demo.firebaseapp.com",
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "",
    });
    expect(noProject.isFirebaseConfigured).toBe(false);
  });

  it("exports no development-token helpers, so nothing can mint a dev session", async () => {
    const flags = (await loadWith({
      NODE_ENV: "development",
      NEXT_PUBLIC_DEV_AUTH_UID: "admin-1",
      NEXT_PUBLIC_FIREBASE_API_KEY: "",
    })) as unknown as Record<string, unknown>;

    for (const name of [
      "isDevelopmentAuth",
      "devAuthUid",
      "developmentToken",
      "readDevToken",
      "storeDevToken",
      "clearDevToken",
      "DEV_TOKEN_STORAGE_KEY",
    ]) {
      expect(flags[name]).toBeUndefined();
    }
  });

  it("returns null from firebaseAuth when the project is not configured", async () => {
    const flags = await loadWith({
      NEXT_PUBLIC_FIREBASE_API_KEY: "",
      NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN: "",
      NEXT_PUBLIC_FIREBASE_PROJECT_ID: "",
    });

    expect(flags.firebaseAuth()).toBeNull();
    await expect(flags.signInWithGoogle()).rejects.toThrow(/not configured/i);
  });
});
