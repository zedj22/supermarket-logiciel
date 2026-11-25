/**
 * The License API address the dashboard's own server proxies to (Phase 8.3.2).
 *
 * Why this lives in `lib/` and not in the Route Handler: a `route.ts` may only
 * export HTTP verbs and its own config, and these helpers are also unit-tested
 * directly.
 *
 * Rules this module exists to enforce:
 *
 * * `LICENSE_API_BASE_URL` is the target. It has **no** `NEXT_PUBLIC_` prefix,
 *   so Next.js does not inline it into a browser bundle and the same image can
 *   be pointed at a different API by changing runtime configuration.
 * * `NEXT_PUBLIC_API_BASE_URL` is a build-time compatibility fallback for the
 *   Phase 6 Cloud Run deployment (where it is inlined at build). It cannot act
 *   as a runtime setting, and new deployments should not use it.
 * * Only `http(s)` origins are accepted. A relative value (which would make the
 *   handler call itself), another scheme (`javascript:`, `file:`, `data:`),
 *   embedded credentials, a query string or a fragment is refused.
 * * Plain `http` is allowed only for loopback, because the API answers with
 *   activation codes and the combined container reaches it on `127.0.0.1`.
 */

/** Server-only proxy target. Never prefixed `NEXT_PUBLIC_`, never inlined. */
export const SERVER_API_BASE_ENV = "LICENSE_API_BASE_URL";

/** Build-time compatibility fallback for the Phase 6 Cloud Run deployment. */
export const LEGACY_API_BASE_ENV = "NEXT_PUBLIC_API_BASE_URL";

/**
 * Used when neither variable is set: the combined container serves FastAPI on
 * loopback, so a local/combined run needs no configuration at all.
 */
export const DEFAULT_API_BASE_URL = "http://127.0.0.1:8000";

/** Shown to the administrator; never contains the configured value. */
const GENERIC_CONFIGURATION_ERROR =
  "The License API address is not configured for this deployment.";

export type ApiOriginResult = { ok: true; origin: string } | { ok: false; reason: string };

function isLoopbackHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  return (
    host === "localhost" || host === "::1" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)
  );
}

function parseApiBaseUrl(value: string): ApiOriginResult {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return { ok: false, reason: GENERIC_CONFIGURATION_ERROR };
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return { ok: false, reason: GENERIC_CONFIGURATION_ERROR };
  }
  if (url.username || url.password || url.search || url.hash) {
    return { ok: false, reason: GENERIC_CONFIGURATION_ERROR };
  }
  if (url.protocol === "http:" && !isLoopbackHost(url.hostname)) {
    return { ok: false, reason: GENERIC_CONFIGURATION_ERROR };
  }
  const path = url.pathname.replace(/\/+$/, "");
  return { ok: true, origin: `${url.origin}${path === "/" ? "" : path}` };
}

/**
 * The proxy target: server-only variable first, then the legacy public one.
 *
 * Exported so the proxy tests can pin the precedence and the validation rules
 * without inventing a second implementation.
 */
export function resolveApiOrigin(
  env: Record<string, string | undefined> = process.env,
): ApiOriginResult {
  const serverOnly = (env[SERVER_API_BASE_ENV] ?? "").trim();
  if (serverOnly) return parseApiBaseUrl(serverOnly);
  const legacy = (env[LEGACY_API_BASE_ENV] ?? "").trim();
  if (legacy) return parseApiBaseUrl(legacy);
  return { ok: true, origin: DEFAULT_API_BASE_URL };
}
