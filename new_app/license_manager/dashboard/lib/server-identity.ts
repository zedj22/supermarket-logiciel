/**
 * The Dashboard server's own Cloud Run identity (Phase 6).
 *
 * On Cloud Run, the API refuses any request that does not come from this
 * service's **runtime service account**.  Cloud Run IAM checks a Google-signed
 * OIDC token at the edge; this module mints that token from the metadata server
 * and hands it to the proxy, which also sends it to the API so the API can
 * verify it a second time in-process.
 *
 * Rules this file exists to enforce:
 *
 * * the token's audience is the **API service URL**, never "any Google API";
 * * the token is a *service* credential and is never confused with the
 *   administrator's Firebase ID token — they travel in different headers;
 * * nothing here is imported by a client component: the token must never reach
 *   a browser bundle.  `getServiceIdentityToken` is server-only;
 * * the token is cached in memory until shortly before it expires, so a page
 *   with several API calls does not hit the metadata server each time.
 *
 * Locally (no Cloud Run, no attached identity) the audience is unset and this
 * module returns `null`; the proxy then sends no service token and the API —
 * which has the invoker gate off outside Cloud Run — answers normally.
 */

/** Header the API reads for the service identity token (not `Authorization`). */
export const SERVICE_IDENTITY_HEADER = "x-klickpos-service-authorization";

const METADATA_URL = "http://metadata.google.internal";
const REFRESH_MARGIN_MS = 5 * 60 * 1000;
const DEFAULT_LIFETIME_MS = 10 * 60 * 1000;

export class ServiceIdentityError extends Error {
  constructor(message = "the dashboard could not obtain its Cloud Run service identity") {
    super(message);
    this.name = "ServiceIdentityError";
  }
}

/**
 * The API's Cloud Run URL, used as the OIDC audience.
 *
 * Read at request time (not build time) so the same image can be promoted
 * between staging and production by changing the service configuration.
 */
export function apiAudience(env: Record<string, string | undefined> = process.env): string {
  return (env.LICENSE_DASHBOARD_API_AUDIENCE ?? "").trim().replace(/\/+$/, "");
}

export interface ServiceIdentityOptions {
  audience?: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

interface CachedToken {
  token: string;
  expiresAt: number;
}

let cached: CachedToken | null = null;
let inflight: Promise<CachedToken> | null = null;

/** Test seam: drop the in-process cache. */
export function resetServiceIdentityCache(): void {
  cached = null;
  inflight = null;
}

/**
 * The service identity token, or `null` when this deployment has none
 * (local development).  Throws `ServiceIdentityError` when an audience *is*
 * configured but the token cannot be obtained — the proxy turns that into a
 * controlled 503 rather than silently calling the API unauthenticated.
 */
export async function getServiceIdentityToken(
  options: ServiceIdentityOptions = {},
): Promise<string | null> {
  const audience = (options.audience ?? apiAudience()).trim().replace(/\/+$/, "");
  if (!audience) return null;

  const now = options.now ?? (() => Date.now());
  if (cached && now() < cached.expiresAt - REFRESH_MARGIN_MS) {
    return cached.token;
  }
  if (inflight) {
    return (await inflight).token;
  }

  const fetchImpl = options.fetchImpl ?? fetch;
  inflight = fetchIdentityToken(audience, fetchImpl, now);
  try {
    const fresh = await inflight;
    cached = fresh;
    return fresh.token;
  } finally {
    inflight = null;
  }
}

async function fetchIdentityToken(
  audience: string,
  fetchImpl: typeof fetch,
  now: () => number,
): Promise<CachedToken> {
  const url =
    `${METADATA_URL}/computeMetadata/v1/instance/service-accounts/default/identity` +
    `?audience=${encodeURIComponent(audience)}&format=full`;

  let response: Response;
  try {
    response = await fetchImpl(url, {
      headers: { "Metadata-Flavor": "Google" },
      cache: "no-store",
    });
  } catch {
    throw new ServiceIdentityError();
  }
  if (!response.ok) {
    throw new ServiceIdentityError();
  }

  const token = (await response.text()).trim();
  if (!token || token.split(".").length !== 3) {
    // Not a JWT: an error page or an empty answer.  Fail closed.
    throw new ServiceIdentityError();
  }

  const expiresAt = tokenExpiryMs(token) ?? now() + DEFAULT_LIFETIME_MS;
  return { token, expiresAt };
}

/** `exp` from a JWT payload, in epoch milliseconds (no signature check needed). */
export function tokenExpiryMs(token: string): number | null {
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const padded = part.replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(padded.padEnd(padded.length + ((4 - (padded.length % 4)) % 4), "="));
    const payload = JSON.parse(json) as { exp?: unknown };
    if (typeof payload.exp !== "number" || !Number.isFinite(payload.exp)) return null;
    return payload.exp * 1000;
  } catch {
    return null;
  }
}
