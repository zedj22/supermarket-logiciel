/**
 * The same-origin `/api/license/*` proxy (Phase 6).
 *
 * Pins the two-credential contract: the administrator's Firebase token is
 * forwarded untouched, the dashboard's Cloud Run identity is added server-side,
 * a browser cannot inject a service header, and nothing is cached.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { GET, POST } from "../app/api/license/[...path]/route";
import { resolveApiOrigin } from "@/lib/api-origin";
import { resetServiceIdentityCache } from "@/lib/server-identity";

function base64url(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fabricatedToken(): string {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(
    JSON.stringify({ aud: "https://api.example", exp: Math.floor(Date.now() / 1000) + 3600 }),
  );
  return `${header}.${payload}.not-a-real-signature`;
}

function context(path: string[]) {
  return { params: Promise.resolve({ path }) };
}

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

beforeEach(() => {
  resetServiceIdentityCache();
  delete process.env.LICENSE_API_BASE_URL;
  process.env.NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:8100/";
  delete process.env.LICENSE_DASHBOARD_API_AUDIENCE;
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.LICENSE_DASHBOARD_API_AUDIENCE;
  delete process.env.LICENSE_API_BASE_URL;
});

describe("license API proxy", () => {
  it("forwards the path, query and the administrator's Firebase token", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ items: [], total: 0 }));
    vi.stubGlobal("fetch", fetchMock);

    const response = await GET(
      new Request("http://localhost:3000/api/license/v1/licenses?query=abc&limit=25", {
        headers: { Authorization: "Bearer firebase-id-token", Accept: "application/json" },
      }),
      context(["v1", "licenses"]),
    );

    expect(response.status).toBe(200);
    const [url, init] = fetchMock.mock.calls[0] as [URL, RequestInit];
    expect(String(url)).toBe("http://127.0.0.1:8100/v1/licenses?query=abc&limit=25");
    const headers = new Headers(init.headers);
    expect(headers.get("authorization")).toBe("Bearer firebase-id-token");
    // No service identity configured here: no Cloud Run headers at all.
    expect(headers.get("x-klickpos-service-authorization")).toBeNull();
    expect(headers.get("x-serverless-authorization")).toBeNull();
    expect(init.cache).toBe("no-store");
  });

  it("adds the dashboard's service identity when the audience is configured", async () => {
    process.env.LICENSE_DASHBOARD_API_AUDIENCE = "https://api.example";
    const token = fabricatedToken();
    const fetchMock = vi.fn(async (...args: [RequestInfo | URL, RequestInit?]) => {
      const url = String(args[0]);
      if (url.includes("metadata.google.internal")) {
        return new Response(token, { status: 200 });
      }
      return jsonResponse({ counts: {}, recent_licenses: [], recent_events: [] });
    });
    vi.stubGlobal("fetch", fetchMock);

    await GET(
      new Request("http://localhost:3000/api/license/v1/overview", {
        headers: { Authorization: "Bearer firebase-id-token" },
      }),
      context(["v1", "overview"]),
    );

    const upstream = fetchMock.mock.calls.find(
      ([input]) => !String(input).includes("metadata.google.internal"),
    )!;
    const headers = new Headers((upstream[1] as RequestInit).headers);
    expect(headers.get("x-klickpos-service-authorization")).toBe(`Bearer ${token}`);
    expect(headers.get("x-serverless-authorization")).toBe(`Bearer ${token}`);
    expect(headers.get("authorization")).toBe("Bearer firebase-id-token");
  });

  it("ignores a service identity header sent by the browser", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ status: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await GET(
      new Request("http://localhost:3000/api/license/healthz", {
        headers: {
          Authorization: "Bearer firebase-id-token",
          "x-klickpos-service-authorization": "Bearer forged-by-browser",
          "x-serverless-authorization": "Bearer forged-by-browser",
        },
      }),
      context(["healthz"]),
    );

    const headers = new Headers((fetchMock.mock.calls[0]![1] as RequestInit).headers);
    expect(headers.get("x-klickpos-service-authorization")).toBeNull();
    expect(headers.get("x-serverless-authorization")).toBeNull();
  });

  it("refuses to call the API when its identity cannot be obtained", async () => {
    process.env.LICENSE_DASHBOARD_API_AUDIENCE = "https://api.example";
    const fetchMock = vi.fn().mockRejectedValue(new Error("no metadata server"));
    vi.stubGlobal("fetch", fetchMock);

    const response = await GET(
      new Request("http://localhost:3000/api/license/v1/overview", {
        headers: { Authorization: "Bearer firebase-id-token" },
      }),
      context(["v1", "overview"]),
    );

    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("service_identity_unavailable");
    // The API was never contacted.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("forwards a JSON body and the method for issuance", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ created: true }, 201));
    vi.stubGlobal("fetch", fetchMock);

    const response = await POST(
      new Request("http://localhost:3000/api/license/v1/licenses", {
        method: "POST",
        headers: {
          Authorization: "Bearer firebase-id-token",
          "Content-Type": "application/json",
          "X-Firebase-AppCheck": "app-check-token",
        },
        body: JSON.stringify({ hw_hash: "a".repeat(64) }),
      }),
      context(["v1", "licenses"]),
    );

    expect(response.status).toBe(201);
    const [, init] = fetchMock.mock.calls[0] as [URL, RequestInit];
    expect(init.method).toBe("POST");
    expect(new Headers(init.headers).get("x-firebase-appcheck")).toBe("app-check-token");
    expect(new TextDecoder().decode(init.body as ArrayBuffer)).toContain('"hw_hash"');
  });

  it("never caches and passes the API's error envelope through unchanged", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        jsonResponse(
          { error: { code: "admin_not_allowlisted", message: "no", details: {} } },
          403,
        ),
      ),
    );

    const response = await GET(
      new Request("http://localhost:3000/api/license/v1/overview", {
        headers: { Authorization: "Bearer firebase-id-token" },
      }),
      context(["v1", "overview"]),
    );

    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("admin_not_allowlisted");
  });

  it("reports an unreachable API as a controlled 502", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new TypeError("Failed to fetch")));

    const response = await GET(
      new Request("http://localhost:3000/api/license/v1/overview", {
        headers: { Authorization: "Bearer firebase-id-token" },
      }),
      context(["v1", "overview"]),
    );

    expect(response.status).toBe(502);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("api_unreachable");
  });

  it("refuses a relative base URL instead of proxying to itself", async () => {
    process.env.NEXT_PUBLIC_API_BASE_URL = "/api/license";
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await GET(
      new Request("http://localhost:3000/api/license/v1/overview"),
      context(["v1", "overview"]),
    );

    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("api_not_configured");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  // ----------------------------------------------------------------------- #
  // Server-only proxy target (Phase 8.3.2)
  // ----------------------------------------------------------------------- #

  it("prefers the server-only LICENSE_API_BASE_URL", async () => {
    process.env.LICENSE_API_BASE_URL = "http://127.0.0.1:8200/";
    process.env.NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:8100/";
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ status: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await GET(
      new Request("http://localhost:3000/api/license/healthz"),
      context(["healthz"]),
    );

    expect(String(fetchMock.mock.calls[0]![0])).toBe("http://127.0.0.1:8200/healthz");
  });

  it("accepts an https target with a path prefix", async () => {
    process.env.LICENSE_API_BASE_URL = "https://api.example/licenses/";
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ status: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await GET(
      new Request("http://localhost:3000/api/license/v1/overview?limit=1"),
      context(["v1", "overview"]),
    );

    expect(String(fetchMock.mock.calls[0]![0])).toBe(
      "https://api.example/licenses/v1/overview?limit=1",
    );
  });

  it("falls back to the loopback default when nothing is configured", async () => {
    delete process.env.NEXT_PUBLIC_API_BASE_URL;
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ status: "ok" }));
    vi.stubGlobal("fetch", fetchMock);

    await GET(
      new Request("http://localhost:3000/api/license/healthz"),
      context(["healthz"]),
    );

    expect(String(fetchMock.mock.calls[0]![0])).toBe("http://127.0.0.1:8000/healthz");
  });

  it.each([
    ["javascript:alert(1)"],
    ["file:///etc/passwd"],
    ["data:text/plain,hello"],
    ["http://api.example.com:8000"],
    ["http://user:password@127.0.0.1:8000"],
    ["https://api.example/#fragment"],
    ["https://api.example/?query=1"],
    ["api.example.com"],
  ])("refuses the unsafe or malformed target %s", async (value) => {
    process.env.LICENSE_API_BASE_URL = value;
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await GET(
      new Request("http://localhost:3000/api/license/v1/overview"),
      context(["v1", "overview"]),
    );

    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("api_not_configured");
    // The configured value is never echoed back to the caller.
    expect(body.error.message).not.toContain(value);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("resolves the server-only variable without a public prefix", () => {
    const resolved = resolveApiOrigin({
      LICENSE_API_BASE_URL: "http://127.0.0.1:8300",
      NEXT_PUBLIC_API_BASE_URL: "http://127.0.0.1:8100",
    });
    expect(resolved).toEqual({ ok: true, origin: "http://127.0.0.1:8300" });
  });
});
