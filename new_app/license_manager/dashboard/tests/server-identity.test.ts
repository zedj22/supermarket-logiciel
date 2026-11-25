/**
 * The Cloud Run service identity the Dashboard server presents to the API.
 *
 * These tests pin: correct audience, metadata-server discovery, in-memory
 * caching, refresh before expiry, and fail-closed behaviour. No real metadata
 * server and no real Google token is involved — the token below is a
 * fabricated three-part string that is never sent anywhere.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  ServiceIdentityError,
  apiAudience,
  getServiceIdentityToken,
  resetServiceIdentityCache,
  tokenExpiryMs,
} from "@/lib/server-identity";

function base64url(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fabricatedToken(expSeconds: number): string {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ aud: "https://api.example", exp: expSeconds }));
  return `${header}.${payload}.not-a-real-signature`;
}

function metadataResponse(token: string): Response {
  return new Response(token, { status: 200, headers: { "Content-Type": "text/plain" } });
}

beforeEach(() => {
  resetServiceIdentityCache();
  delete process.env.LICENSE_DASHBOARD_API_AUDIENCE;
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.LICENSE_DASHBOARD_API_AUDIENCE;
});

describe("service identity", () => {
  it("is disabled when no audience is configured (local development)", async () => {
    const fetchImpl = vi.fn();
    expect(apiAudience({})).toBe("");
    await expect(getServiceIdentityToken({ audience: "", fetchImpl })).resolves.toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("asks the metadata server for a token whose audience is the API service", async () => {
    const token = fabricatedToken(Math.floor(Date.now() / 1000) + 3600);
    const fetchImpl = vi.fn().mockResolvedValue(metadataResponse(token));

    const result = await getServiceIdentityToken({
      audience: "https://klickpos-license-api-staging-abc.a.run.app",
      fetchImpl,
    });

    expect(result).toBe(token);
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("http://metadata.google.internal/computeMetadata/v1/");
    expect(url).toContain(
      "audience=https%3A%2F%2Fklickpos-license-api-staging-abc.a.run.app",
    );
    expect(new Headers(init.headers).get("Metadata-Flavor")).toBe("Google");
  });

  it("normalises a trailing slash off the configured audience", () => {
    expect(apiAudience({ LICENSE_DASHBOARD_API_AUDIENCE: "https://api.example/" })).toBe(
      "https://api.example",
    );
  });

  it("caches the token instead of calling the metadata server per request", async () => {
    const token = fabricatedToken(Math.floor(Date.now() / 1000) + 3600);
    const fetchImpl = vi.fn().mockResolvedValue(metadataResponse(token));

    await getServiceIdentityToken({ audience: "https://api.example", fetchImpl });
    await getServiceIdentityToken({ audience: "https://api.example", fetchImpl });

    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("refreshes shortly before the token expires", async () => {
    const now = 1_800_000_000_000;
    const expiring = fabricatedToken(now / 1000 + 60); // 60s left: inside the margin
    const fresh = fabricatedToken(now / 1000 + 3600);
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(metadataResponse(expiring))
      .mockResolvedValueOnce(metadataResponse(fresh));

    const first = await getServiceIdentityToken({
      audience: "https://api.example",
      fetchImpl,
      now: () => now,
    });
    const second = await getServiceIdentityToken({
      audience: "https://api.example",
      fetchImpl,
      now: () => now,
    });

    expect(first).toBe(expiring);
    expect(second).toBe(fresh);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("fails closed when the metadata server is unreachable", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("getaddrinfo ENOTFOUND"));
    await expect(
      getServiceIdentityToken({ audience: "https://api.example", fetchImpl }),
    ).rejects.toBeInstanceOf(ServiceIdentityError);
  });

  it("fails closed when the metadata server answers with an error", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("denied", { status: 403 }));
    await expect(
      getServiceIdentityToken({ audience: "https://api.example", fetchImpl }),
    ).rejects.toBeInstanceOf(ServiceIdentityError);
  });

  it("rejects a non-JWT body rather than forwarding it as a token", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("<html>oops</html>"));
    await expect(
      getServiceIdentityToken({ audience: "https://api.example", fetchImpl }),
    ).rejects.toBeInstanceOf(ServiceIdentityError);
  });

  it("reads exp from the token payload", () => {
    expect(tokenExpiryMs(fabricatedToken(1_900_000_000))).toBe(1_900_000_000_000);
    expect(tokenExpiryMs("not-a-jwt")).toBeNull();
  });
});
