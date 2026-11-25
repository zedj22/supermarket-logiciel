/**
 * Firebase **Authentication** only: Google sign-in for administrators.
 *
 * The web SDK is used for exactly two things: opening the Google account
 * chooser, and minting a fresh ID token for the License API. Firestore is never
 * opened from the browser — every license and customer record comes from the
 * API, which verifies the token server-side (with revocation checking) and its
 * own administrator allowlist. No service-account material, signing key or AES
 * key is ever present in this bundle; only the public web-app config below.
 *
 * There is no development sign-in path: the dashboard always authenticates
 * against the Firebase project configured here. The only non-production
 * allowance is the Firebase **Auth emulator**, which is used only when
 * `NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST` is set explicitly.
 */

import { getApp, getApps, initializeApp, type FirebaseApp } from "firebase/app";
import {
  GoogleAuthProvider,
  connectAuthEmulator,
  getAuth,
  onIdTokenChanged,
  signInWithPopup,
  signOut,
  type Auth,
  type User,
} from "firebase/auth";

/**
 * Public web-app configuration (Firebase Console → Project settings → Your
 * apps → Web app). These values are shipped to the browser by design and are
 * not secrets; the signing/AES material lives only on the License API.
 *
 * Each value is read with a static `process.env.NEXT_PUBLIC_…` member access so
 * Next.js inlines it at build time.
 */
export const firebaseConfig = {
  apiKey: (process.env.NEXT_PUBLIC_FIREBASE_API_KEY ?? "").trim(),
  authDomain: (process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN ?? "").trim(),
  projectId: (process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID ?? "").trim(),
  appId: (process.env.NEXT_PUBLIC_FIREBASE_APP_ID ?? "").trim(),
  messagingSenderId: (process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID ?? "").trim(),
  storageBucket: (process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET ?? "").trim(),
};

export const isFirebaseConfigured = Boolean(
  firebaseConfig.apiKey && firebaseConfig.authDomain && firebaseConfig.projectId,
);

const authEmulatorUrl = (process.env.NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST ?? "").trim();

let cachedApp: FirebaseApp | null = null;
let cachedAuth: Auth | null = null;

/**
 * The single Firebase app, or null when the public config is incomplete.
 *
 * App Check (see `lib/app-check.ts`) attaches to the same app instance, so it
 * is created here once rather than twice.
 */
export function firebaseApp(): FirebaseApp | null {
  if (!isFirebaseConfigured) return null;
  if (!cachedApp) {
    cachedApp = getApps().length > 0 ? getApp() : initializeApp(firebaseConfig);
  }
  return cachedApp;
}

/** The single Firebase Auth instance, or null when the app is not configured. */
export function firebaseAuth(): Auth | null {
  const app = firebaseApp();
  if (!app) return null;
  if (cachedAuth) return cachedAuth;

  const auth = getAuth(app);

  if (authEmulatorUrl && !auth.emulatorConfig) {
    connectAuthEmulator(auth, `http://${authEmulatorUrl}`, { disableWarnings: true });
  }

  cachedAuth = auth;
  return auth;
}

/**
 * Google is the only administrator provider. `prompt=select_account` always
 * shows the account chooser, so a shared machine cannot silently reuse whoever
 * signed in last.
 */
export function googleAuthProvider(): GoogleAuthProvider {
  const provider = new GoogleAuthProvider();
  provider.setCustomParameters({ prompt: "select_account" });
  return provider;
}

/** Google popup sign-in. The caller decides how to report SDK errors. */
export async function signInWithGoogle(): Promise<User> {
  const auth = firebaseAuth();
  if (!auth) {
    throw new Error("Firebase is not configured for this deployment.");
  }
  const credential = await signInWithPopup(auth, googleAuthProvider());
  return credential.user;
}

export async function signOutAdmin(): Promise<void> {
  const auth = firebaseAuth();
  if (auth) await signOut(auth);
}

/**
 * Fires on sign-in, sign-out and token refresh. The session provider trusts
 * Firebase as the single source of truth for "is there an administrator?".
 */
export function subscribeToAuth(handler: (user: User | null) => void): () => void {
  const auth = firebaseAuth();
  if (!auth) {
    handler(null);
    return () => undefined;
  }
  return onIdTokenChanged(auth, handler);
}

/**
 * A fresh ID token for the next API call.
 *
 * `forceRefresh` is used after a 401 so a rotated/rejected token is exchanged
 * once before the administrator is asked to sign in again.
 */
export async function currentIdToken(forceRefresh = false): Promise<string | null> {
  const auth = firebaseAuth();
  if (!auth?.currentUser) return null;
  return auth.currentUser.getIdToken(forceRefresh);
}
