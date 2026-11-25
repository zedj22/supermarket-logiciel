/**
 * Container health for the combined Render image (Phase 8.5).
 *
 * Render probes one path and admits the instance only when it answers 200.
 * In this image the dashboard is useful only if the License API beside it is
 * up, so `/healthz` is a *composite* check: it asks the API's own `/healthz`
 * (loopback, unauthenticated, credential-free) and reports healthy only when
 * that answers `{"status":"ok"}`.
 *
 * It is deliberately not a page and not cached: it returns two possible bodies,
 * both free of configuration, tokens and secrets.
 */

import { resolveApiOrigin } from "../../lib/api-origin";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const NO_STORE = { "cache-control": "no-store", "content-type": "application/json" };

function answer(status: 200 | 503, body: { status: "ok" | "degraded" }): Response {
  return new Response(JSON.stringify(body), { status, headers: NO_STORE });
}

export async function GET(): Promise<Response> {
  const resolved = resolveApiOrigin();
  if (!resolved.ok) {
    // A malformed target is a deployment problem, never "healthy".
    return answer(503, { status: "degraded" });
  }

  try {
    const response = await fetch(`${resolved.origin}/healthz`, {
      cache: "no-store",
      signal: AbortSignal.timeout(2000),
    });
    const payload = (await response.json().catch(() => null)) as {
      status?: unknown;
    } | null;
    if (response.ok && payload?.status === "ok") {
      return answer(200, { status: "ok" });
    }
  } catch {
    // Unreachable API: fall through to the degraded answer.
  }
  return answer(503, { status: "degraded" });
}
