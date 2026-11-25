/**
 * Same-origin proxy from the browser to the private License API.
 *
 * Why a Route Handler instead of the `next.config.ts` rewrite used before
 * Phase 6: the API now requires **two** credentials, and a config rewrite can
 * only forward what the browser already sent. This handler adds the second one:
 *
 *   Authorization: Bearer <Firebase ID token>        (from the browser, as-is)
 *   x-klickpos-service-authorization: Bearer <OIDC>   (minted here, server-side)
 *
 * and also presents the OIDC token as `X-Serverless-Authorization` so Cloud Run
 * can consume it at the edge and admit the request. Cloud Run strips those
 * headers before the container sees them; the dedicated one above is what the
 * API verifies in-process.
 *
 * The proxy target is a **server-only** environment variable
 * (`LICENSE_API_BASE_URL`), read on every request.  It deliberately has no
 * `NEXT_PUBLIC_` prefix: Next.js inlines those at build time, so a public name
 * would bake one environment's API URL into the image and make the same build
 * unsafe to promote.  `NEXT_PUBLIC_API_BASE_URL` is still honoured as a
 * build-time compatibility fallback (Cloud Run deployments from Phase 6 set
 * it); new deployments should use the server-only name.
 *
 * Guarantees:
 *   * the browser never learns the API's URL and never needs to reach it;
 *   * a browser-supplied service header is ignored (only this server's token is
 *     ever forwarded), so a caller cannot talk its way past the API's gate;
 *   * nothing is cached: activation codes are bearer material;
 *   * when this deployment has no service identity, the request is refused with
 *     a controlled 503 instead of being sent unauthenticated.
 */

import { resolveApiOrigin } from "../../../../lib/api-origin";
import {
  SERVICE_IDENTITY_HEADER,
  ServiceIdentityError,
  apiAudience,
  getServiceIdentityToken,
} from "../../../../lib/server-identity";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/** Headers worth forwarding from the browser, and nothing else. */
const FORWARDED_REQUEST_HEADERS = [
  "authorization",
  "x-firebase-appcheck",
  "content-type",
  "accept",
  "x-request-id",
] as const;

/** Response headers worth returning; the body is streamed untouched. */
const FORWARDED_RESPONSE_HEADERS = [
  "content-type",
  "retry-after",
  "www-authenticate",
  "x-request-id",
] as const;

type RouteContext = { params: Promise<{ path: string[] }> };

function envelope(code: string, message: string, status: number): Response {
  return new Response(
    JSON.stringify({ error: { code, message, details: {} } }),
    {
      status,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    },
  );
}

async function proxy(request: Request, context: RouteContext): Promise<Response> {
  const resolved = resolveApiOrigin();
  // A malformed, non-http/relative or non-loopback-plain-http target is refused
  // here instead of being forwarded (a relative one would call this handler).
  if (!resolved.ok) {
    return envelope("api_not_configured", resolved.reason, 503);
  }
  const origin = resolved.origin;

  const { path } = await context.params;
  const incoming = new URL(request.url);
  const target = new URL(
    `${origin}/${path.map((segment) => encodeURIComponent(segment)).join("/")}`,
  );
  target.search = incoming.search;

  const headers = new Headers();
  for (const name of FORWARDED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }

  let serviceToken: string | null = null;
  if (apiAudience()) {
    try {
      serviceToken = await getServiceIdentityToken();
    } catch (error) {
      if (error instanceof ServiceIdentityError) {
        return envelope(
          "service_identity_unavailable",
          "The dashboard could not authenticate itself to the License API. Try again shortly.",
          503,
        );
      }
      throw error;
    }
    if (!serviceToken) {
      return envelope(
        "service_identity_unavailable",
        "The dashboard could not authenticate itself to the License API. Try again shortly.",
        503,
      );
    }
  }
  if (serviceToken) {
    headers.set(SERVICE_IDENTITY_HEADER, `Bearer ${serviceToken}`);
    // Cloud Run's own IAM gate consumes this one at the edge.
    headers.set("x-serverless-authorization", `Bearer ${serviceToken}`);
  }

  const method = request.method.toUpperCase();
  const body = method === "GET" || method === "HEAD" ? undefined : await request.arrayBuffer();

  let upstream: Response;
  try {
    upstream = await fetch(target, {
      method,
      headers,
      body,
      redirect: "manual",
      cache: "no-store",
    });
  } catch {
    return envelope(
      "api_unreachable",
      "Cannot reach the License API. Check that it is running and that LICENSE_API_BASE_URL is correct.",
      502,
    );
  }

  const responseHeaders = new Headers({ "cache-control": "no-store" });
  for (const name of FORWARDED_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders.set(name, value);
  }
  if (!responseHeaders.has("content-type")) {
    responseHeaders.set("content-type", "application/json");
  }

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
}

export const GET = proxy;
export const POST = proxy;
export const PUT = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
