import type { NextConfig } from "next";

/**
 * The browser never calls the Python License API directly: `/api/license/*`
 * stays same-origin (no CORS on the API, no preflights).
 *
 * Since Phase 6 that path is a Route Handler —
 * `app/api/license/[...path]/route.ts` — and **not** a rewrite. A rewrite can
 * only forward what the browser sent, while the proxy must also attach the
 * Dashboard's Cloud Run identity token next to the administrator's Firebase
 * token.
 *
 * Since Phase 8.3.2 the proxy target is the **server-only** variable
 * `LICENSE_API_BASE_URL`, which the handler reads per request — so one image
 * can be moved between environments without a rebuild. `NEXT_PUBLIC_API_BASE_URL`
 * is kept only as a *build-time* compatibility fallback for the Phase 6 Cloud
 * Run deployment: a `NEXT_PUBLIC_` name is inlined by Next at build time, so it
 * can never be a genuine runtime setting.
 */

// Fail `npm run build` when the public Firebase web configuration is incomplete
// or carries a development-only switch: Next.js inlines `NEXT_PUBLIC_*` at
// build time, so a Docker build that forgets the build arguments would
// otherwise ship an image whose sign-in page always says "Not configured".
// The gate runs from `prebuild` (`scripts/public-build-env.mjs`, with tests)
// and not from this file: Next evaluates the config before it sets
// `process.env.NEXT_PHASE`, so a phase check here could not tell a build from
// `next start`.

/**
 * Minimum hardening for a private console that reveals activation codes:
 *
 * * `X-Frame-Options: DENY` — a framed dashboard could have its destructive
 *   Revoke/Reissue dialogs clickjacked by an attacker's page;
 * * `Referrer-Policy: no-referrer` — license ids travel in `/licenses?query=…`,
 *   and they must not follow a click out to a third-party site;
 * * `nosniff` / `Permissions-Policy` — no content-type guessing, no device APIs.
 *
 * A full CSP is deliberately omitted: Firebase Authentication talks to its own
 * origins at sign-in, and a wrong `connect-src` would break the only way in.
 */
const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "no-referrer" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
];

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  // Slim, self-contained server for the Cloud Run image (`node server.js`).
  output: "standalone",
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
