import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Boundary between the dashboard and the Firebase SDK: Google is the only
 * provider, the account chooser is always shown, the ID token comes from
 * `getIdToken` and sign-out really ends the Firebase session.
 */
const sdk = vi.hoisted(() => ({
  signInWithPopup: vi.fn(),
  signOut: vi.fn(),
  onIdTokenChanged: vi.fn(() => () => undefined),
  getAuth: vi.fn(),
  connectAuthEmulator: vi.fn(),
}));

vi.mock("firebase/app", () => ({
  getApps: () => [],
  getApp: () => ({}),
  initializeApp: () => ({}),
}));

vi.mock("firebase/auth", () => ({
  GoogleAuthProvider: class {
    customParameters: Record<string, string> | undefined;
    constructor() {
      // Every instance records its own parameters for the assertions below.
    }
    setCustomParameters(parameters: Record<string, string>) {
      this.customParameters = parameters;
      return this;
    }
  },
  signInWithPopup: sdk.signInWithPopup,
  signOut: sdk.signOut,
  onIdTokenChanged: sdk.onIdTokenChanged,
  getAuth: sdk.getAuth,
  connectAuthEmulator: sdk.connectAuthEmulator,
}));

type FirebaseModule = typeof import("@/lib/firebase");
let flags: FirebaseModule;

const user = {
  uid: "admin-uid-1",
  email: "admin@example.com",
  getIdToken: vi.fn(async () => "id-token"),
};

beforeAll(async () => {
  // The module reads its public config at import time (Next inlines it).
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_API_KEY", "public-web-key");
  vi.stubEnv(
    "NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN",
    "klickpos-license-manager.firebaseapp.com",
  );
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_PROJECT_ID", "klickpos-license-manager");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_APP_ID", "1:123:web:abc");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST", "");
  vi.resetModules();
  flags = await import("@/lib/firebase");
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
  user.getIdToken.mockClear();
});

beforeEach(() => {
  sdk.signInWithPopup.mockReset();
  sdk.signInWithPopup.mockResolvedValue({ user });
  sdk.signOut.mockReset();
  sdk.getAuth.mockReset();
  sdk.getAuth.mockReturnValue({ currentUser: user, emulatorConfig: null });
  sdk.connectAuthEmulator.mockReset();
  sdk.onIdTokenChanged.mockReset();
  sdk.onIdTokenChanged.mockReturnValue(() => undefined);
});

describe("Google sign-in", () => {
  it("uses the Google provider with the account chooser always shown", () => {
    const provider = flags.googleAuthProvider() as unknown as {
      customParameters?: Record<string, string>;
    };
    expect(provider.customParameters).toEqual({ prompt: "select_account" });
  });

  it("opens the popup and returns the signed-in user", async () => {
    const result = await flags.signInWithGoogle();

    expect(sdk.signInWithPopup).toHaveBeenCalledTimes(1);
    const [auth, provider] = sdk.signInWithPopup.mock.calls[0]!;
    expect(auth).toBe(flags.firebaseAuth());
    expect(provider.customParameters).toEqual({ prompt: "select_account" });
    expect(result).toBe(user);
  });

  it("propagates popup errors so the UI can explain them", async () => {
    sdk.signInWithPopup.mockRejectedValueOnce({ code: "auth/popup-blocked" });
    await expect(flags.signInWithGoogle()).rejects.toMatchObject({
      code: "auth/popup-blocked",
    });
  });
});

describe("session boundaries", () => {
  it("returns the current ID token, optionally force-refreshed", async () => {
    await expect(flags.currentIdToken()).resolves.toBe("id-token");
    expect(user.getIdToken).toHaveBeenLastCalledWith(false);

    await flags.currentIdToken(true);
    expect(user.getIdToken).toHaveBeenLastCalledWith(true);
  });

  it("returns no token when nobody is signed in", async () => {
    sdk.getAuth.mockReturnValue({ currentUser: null, emulatorConfig: null });
    // A new module instance picks up the fresh auth stub.
    vi.resetModules();
    const reloaded = await import("@/lib/firebase");
    await expect(reloaded.currentIdToken()).resolves.toBeNull();
  });

  it("signs out through the SDK", async () => {
    await flags.signOutAdmin();
    expect(sdk.signOut).toHaveBeenCalled();
  });

  it("does not touch the Auth emulator unless a host is configured", () => {
    flags.firebaseAuth();
    expect(sdk.connectAuthEmulator).not.toHaveBeenCalled();
  });

  it("subscribes to Firebase auth state changes", () => {
    flags.subscribeToAuth(vi.fn());
    expect(sdk.onIdTokenChanged).toHaveBeenCalled();
  });

  it("treats the real web config as configured", () => {
    expect(flags.isFirebaseConfigured).toBe(true);
    expect(flags.firebaseConfig.projectId).toBe("klickpos-license-manager");
  });
});
