import { afterEach, describe, expect, it, vi } from "vitest";

import { ApiError, createApiClient, defaultApiBaseUrl, errorMessage } from "@/lib/api";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function captureFetch(): ReturnType<typeof vi.fn> {
  const spy = vi.fn();
  vi.stubGlobal("fetch", spy);
  return spy;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("api client", () => {
  it("defaults to the same-origin proxy path instead of a cross-origin API", () => {
    // Direct browser calls would be blocked by CORS; Next proxies /api/license.
    expect(defaultApiBaseUrl()).toBe("/api/license");
  });

  it("calls the configured base URL and sends the administrator token", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(jsonResponse({ status: "ok", environment: "testing" }));
    const client = createApiClient({
      baseUrl: "http://127.0.0.1:8100/",
      getToken: async () => "id-token-123",
    });

    await client.health();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://127.0.0.1:8100/healthz");
    // health is the only anonymous call
    expect(new Headers(init.headers).get("Authorization")).toBeNull();
    expect(init.cache).toBe("no-store");
  });

  it("adds a bearer token to protected calls and never caches", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(jsonResponse({ items: [], total: 0 }));
    const client = createApiClient({
      baseUrl: "http://api.test",
      getToken: () => "id-token-123",
    });

    await client.listLicenses({ query: "abc", status: "active", limit: 25 });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://api.test/v1/licenses?query=abc&status=active&limit=25");
    const headers = new Headers(init.headers);
    expect(headers.get("Authorization")).toBe("Bearer id-token-123");
    expect(headers.get("Accept")).toBe("application/json");
    expect(init.cache).toBe("no-store");
    expect(init.credentials).toBe("omit");
  });

  it("reads the activation code from the audited endpoint without caching", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        license_id: "lic_1",
        hw_hash: "a".repeat(64),
        status: "active",
        activation_code: "SMP1.abc.def",
        warning: null,
      }),
    );
    const client = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });

    const result = await client.getLicenseCode("lic_1");

    expect(result.activation_code).toBe("SMP1.abc.def");
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://api.test/v1/licenses/lic_1/code");
    expect(init.cache).toBe("no-store");
  });

  it("maps the API error envelope and keeps its stable code", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(
      jsonResponse(
        {
          error: {
            code: "admin_not_allowlisted",
            message: "this account is not on the License Manager administrator allowlist",
            details: {},
          },
        },
        403,
      ),
    );
    const client = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });

    const failure = await client.overview().catch((error: unknown) => error);

    expect(failure).toBeInstanceOf(ApiError);
    expect((failure as ApiError).status).toBe(403);
    expect((failure as ApiError).code).toBe("admin_not_allowlisted");
    expect((failure as ApiError).isForbidden).toBe(true);
  });

  it.each([
    [401, "unauthorized"],
    [404, "license_not_found"],
    [409, "license_conflict"],
    [422, "validation_error"],
    [503, "store_unavailable"],
  ])("surfaces a %s response with its code", async (status, code) => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: { code, message: "nope", details: {} } }, status));
    const client = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });

    const failure = (await client.listDevices().catch((error: unknown) => error)) as ApiError;

    expect(failure.status).toBe(status);
    expect(failure.code).toBe(code);
    expect(errorMessage(failure)).toBe("nope");
  });

  it("reports an unreachable API as a network error, without throwing raw fetch errors", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    const client = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });

    const failure = (await client.overview().catch((error: unknown) => error)) as ApiError;

    expect(failure).toBeInstanceOf(ApiError);
    expect(failure.isNetworkError).toBe(true);
    expect(failure.message).toMatch(/Cannot reach the License API/);
  });

  it("sends reissue confirmation and the mandatory reason", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ previous: {}, license: {}, notice: "ok" }),
    );
    const client = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });

    await client.reissueLicense("lic_1", { reason: "hardware replaced", confirm: true });

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://api.test/v1/licenses/lic_1/reissue");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({
      reason: "hardware replaced",
      confirm: true,
    });
  });

  it("sends a Firebase App Check token alongside the ID token", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(jsonResponse({ items: [], total: 0 }));
    const client = createApiClient({
      baseUrl: "http://api.test",
      getToken: () => "id-token-123",
      getAppCheckToken: async () => "app-check-token",
    });

    await client.listDevices();

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const headers = new Headers(init.headers);
    expect(headers.get("X-Firebase-AppCheck")).toBe("app-check-token");
    // App Check is additive: the identity token is untouched.
    expect(headers.get("Authorization")).toBe("Bearer id-token-123");
  });

  it("omits the App Check header when this build has no token", async () => {
    const fetchMock = captureFetch();
    // A fresh Response per call: a body can only be read once.
    fetchMock.mockImplementation(async () => jsonResponse({ items: [], total: 0 }));
    const noToken = createApiClient({
      baseUrl: "http://api.test",
      getToken: () => "id-token-123",
      getAppCheckToken: async () => null,
    });
    await noToken.listDevices();
    expect(
      new Headers((fetchMock.mock.calls[0]![1] as RequestInit).headers).get(
        "X-Firebase-AppCheck",
      ),
    ).toBeNull();

    // A build with no App Check wiring at all behaves the same way.
    const unwired = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });
    await unwired.listDevices();
    expect(
      new Headers((fetchMock.mock.calls[1]![1] as RequestInit).headers).get(
        "X-Firebase-AppCheck",
      ),
    ).toBeNull();
  });

  it("still calls the API when the App Check token cannot be obtained", async () => {
    // The API decides whether a missing token is fatal (enforcement on) or
    // irrelevant (enforcement off); the client never fabricates one and never
    // downgrades the ID token either.
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(jsonResponse({ items: [], total: 0 }));
    const client = createApiClient({
      baseUrl: "http://api.test",
      getToken: () => "id-token-123",
      getAppCheckToken: () => {
        throw new Error("reCAPTCHA blocked");
      },
    });

    await client.listDevices();

    const headers = new Headers((fetchMock.mock.calls[0]![1] as RequestInit).headers);
    expect(headers.get("X-Firebase-AppCheck")).toBeNull();
    expect(headers.get("Authorization")).toBe("Bearer id-token-123");
  });

  it("never sends App Check on the anonymous health probe", async () => {
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(jsonResponse({ status: "ok", environment: "testing" }));
    const appCheck = vi.fn(async () => "app-check-token");
    const client = createApiClient({
      baseUrl: "http://api.test",
      getToken: () => "id-token-123",
      getAppCheckToken: appCheck,
    });

    await client.health();

    const headers = new Headers((fetchMock.mock.calls[0]![1] as RequestInit).headers);
    expect(headers.get("X-Firebase-AppCheck")).toBeNull();
    expect(appCheck).not.toHaveBeenCalled();
  });

  it("never logs the activation code", async () => {
    const consoleSpies = (["log", "info", "warn", "error", "debug"] as const).map((name) =>
      vi.spyOn(console, name).mockImplementation(() => undefined),
    );
    const fetchMock = captureFetch();
    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        license_id: "lic_1",
        hw_hash: "a".repeat(64),
        status: "active",
        activation_code: "SMP1.secret.material",
        warning: null,
      }),
    );
    const client = createApiClient({ baseUrl: "http://api.test", getToken: () => "t" });

    await client.getLicenseCode("lic_1");

    const logged = consoleSpies
      .flatMap((spy) => spy.mock.calls)
      .flat()
      .map((value) => String(value))
      .join(" ");
    expect(logged).not.toContain("SMP1.secret.material");
  });
});
