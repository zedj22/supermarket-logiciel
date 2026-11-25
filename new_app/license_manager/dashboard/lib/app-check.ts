/**
 * Firebase **App Check** for the administrator dashboard.
 *
 * App Check is the second, request-level gate on the License API: the
 * administrator's Firebase ID token proves *who* is calling, and a verified
 * App Check token additionally proves the call came from this dashboard build
 * running in a real browser. A stolen ID token replayed from a script is not
 * enough on its own once the API enables enforcement.
 *
 * Rules this file exists to enforce:
 *
 * * the browser only ever supplies a **token**; the decision to accept it is
 *   made on the server with the Firebase Admin SDK (`app_check.verify_token`),
 *   never here. Nothing in this file can mark a request as verified;
 * * the provider is reCAPTCHA Enterprise, the supported web provider for a
 *   dashboard served from Cloud Run. The site key is a *public* value (like the
 *   Firebase web config) — it is not a secret and cannot mint tokens alone;
 * * when no site key is configured (local development, emulator) no token is
 *   produced and none is sent. The API stays the authority: with enforcement
 *   off it works as before, with enforcement on it answers `app_check_failed`;
 * * a token that cannot be obtained is reported as "no token", never as a
 *   fabricated or cached-success value;
 * * no App Check token is ever logged, and none is stored anywhere.
 *
 * Local development uses the App Check **debug provider**: set
 * `NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN` (a UUID registered in the Firebase
 * Console) and the SDK registers that debug token instead of calling reCAPTCHA.
 */

import {
  ReCaptchaEnterpriseProvider,
  getToken as readAppCheckToken,
  initializeAppCheck,
  type AppCheck,
} from "firebase/app-check";

import { firebaseApp } from "./firebase";

/** Public reCAPTCHA Enterprise site key (Firebase Console → App Check → Apps). */
const siteKey = (process.env.NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY ?? "").trim();

/**
 * Optional development-only debug token. `true` makes the SDK print a fresh
 * debug token to the console instead of using a fixed one.
 */
const debugToken = (process.env.NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN ?? "").trim();

/** True when this build can mint App Check tokens at all. */
export const isAppCheckConfigured = Boolean(siteKey || debugToken);

let cached: AppCheck | null = null;
let unavailable = false;

/**
 * The App Check instance, or null when this build cannot use it.
 *
 * App Check needs a browser (reCAPTCHA) and the public Firebase web config, so
 * a server render, an unconfigured build and a failed initialization all return
 * `null` instead of throwing during render.
 */
export function firebaseAppCheck(): AppCheck | null {
  if (cached) return cached;
  if (unavailable) return null;
  if (typeof window === "undefined") return null;

  const app = firebaseApp();
  if (!app) {
    unavailable = true;
    return null;
  }

  try {
    if (debugToken) {
      (window as unknown as { FIREBASE_APPCHECK_DEBUG_TOKEN?: string | boolean })
        .FIREBASE_APPCHECK_DEBUG_TOKEN = debugToken === "true" ? true : debugToken;
    }
    if (!siteKey) {
      // Debug token alone: the SDK still needs a provider argument in some
      // versions, but without a site key it cannot be initialized safely.
      unavailable = true;
      return null;
    }
    cached = initializeAppCheck(app, {
      provider: new ReCaptchaEnterpriseProvider(siteKey),
      // Refresh in the background; `currentAppCheckToken` also forces a fresh
      // token when the API rejects one.
      isTokenAutoRefreshEnabled: true,
    });
  } catch {
    // Misconfiguration (bad site key, blocked script) must not break the page.
    unavailable = true;
    return null;
  }
  return cached;
}

/**
 * A fresh App Check token for the next API call, or `null`.
 *
 * `forceRefresh` is used after a rejected call so an expired/rotated token is
 * exchanged once before the administrator sees an error.
 *
 * Failure is deliberately silent: the License API decides whether a missing
 * token is fatal (enforcement on) or irrelevant (enforcement off), and this
 * function must never invent success.
 */
export async function currentAppCheckToken(forceRefresh = false): Promise<string | null> {
  const appCheck = firebaseAppCheck();
  if (!appCheck) return null;
  try {
    const result = await readAppCheckToken(appCheck, forceRefresh);
    return result.token || null;
  } catch {
    return null;
  }
}
