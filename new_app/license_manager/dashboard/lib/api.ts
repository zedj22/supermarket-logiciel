/**
 * The only way the dashboard talks to the License API.
 *
 * * every protected call carries the administrator's Firebase ID token and,
 *   when this build has one, a Firebase App Check token in
 *   `X-Firebase-AppCheck`. The token is only transported here: the License API
 *   verifies it server-side (Firebase Admin SDK) and this module never treats
 *   the presence of a token as proof of anything;
 * * responses are never cached (`cache: "no-store"`) because activation codes
 *   are bearer material;
 * * errors are normalised into `ApiError` with the API's stable `code`, and the
 *   message shown to the administrator never contains an activation code or a
 *   provider message;
 * * nothing here logs, so a code cannot end up in a console or a bug report.
 */

import type {
  ApiErrorEnvelope,
  AuditListResponse,
  CodeResponse,
  CustomerDetailResponse,
  CustomerListResponse,
  DeviceListResponse,
  DeviceResponse,
  HealthResponse,
  IssueResponse,
  LicenseListResponse,
  ParseResponse,
  ReissueResponse,
  RevokeResponse,
  OverviewResponse,
} from "./types";

const STATUS_MESSAGES: Record<number, string> = {
  0: "Cannot reach the License API. Check that it is running and that LICENSE_API_BASE_URL is correct.",
  400: "The License API rejected the request.",
  401: "Your session has expired. Please sign in again.",
  403: "This account is not an administrator for the License Manager.",
  404: "The requested record does not exist.",
  409: "That change is not allowed for this record's current state.",
  413: "The request was too large for the License API.",
  422: "Please check the values you entered.",
  429: "Too many requests. Wait a moment and try again.",
  500: "The License API could not complete the request.",
  503: "The License API is temporarily unavailable (Firestore or the signing key). Try again shortly.",
};

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details: Record<string, unknown>;

  constructor(
    message: string,
    status: number,
    code: string,
    details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }

  get isUnauthorized(): boolean {
    return this.status === 401;
  }

  get isForbidden(): boolean {
    return this.status === 403;
  }

  get isNetworkError(): boolean {
    return this.status === 0;
  }
}

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error && error.message) return error.message;
  return "Something went wrong. Please try again.";
}

export type QueryValue = string | number | boolean | undefined | null;

function withQuery(path: string, params: Record<string, QueryValue> = {}): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null || value === "") continue;
    search.set(key, String(value));
  }
  const query = search.toString();
  return query ? `${path}?${query}` : path;
}

export interface ApiClient {
  readonly baseUrl: string;
  health(): Promise<HealthResponse>;
  overview(): Promise<OverviewResponse>;
  parseRequest(requestCode: string): Promise<ParseResponse>;
  issueLicense(body: {
    request_code?: string;
    hw_hash?: string;
    features?: string[];
    customer_id?: string;
    customer?: {
      name: string;
      email?: string | null;
      phone?: string | null;
      notes?: string | null;
    };
  }): Promise<IssueResponse>;
  getDevice(hwHash: string): Promise<DeviceResponse>;
  listDevices(params?: { query?: string; limit?: number }): Promise<DeviceListResponse>;
  listLicenses(params?: {
    query?: string;
    status?: string;
    limit?: number;
  }): Promise<LicenseListResponse>;
  getLicenseCode(licenseId: string): Promise<CodeResponse>;
  reissueLicense(
    licenseId: string,
    body: { reason: string; confirm: boolean },
  ): Promise<ReissueResponse>;
  revokeLicense(licenseId: string, body: { reason: string }): Promise<RevokeResponse>;
  listCustomers(params?: { query?: string; limit?: number }): Promise<CustomerListResponse>;
  getCustomer(customerId: string): Promise<CustomerDetailResponse>;
  listAudit(params?: { query?: string; limit?: number }): Promise<AuditListResponse>;
}

export interface ApiClientOptions {
  baseUrl: string;
  /** Returns the current administrator ID token (or null when signed out). */
  getToken?: () => Promise<string | null> | string | null;
  /**
   * Returns the current App Check token (or null when App Check is not
   * configured). Never an assertion of validity — the API verifies it.
   */
  getAppCheckToken?: () => Promise<string | null> | string | null;
}

interface RequestOptions {
  method?: "GET" | "POST";
  body?: unknown;
  /** Skip the token lookup (used only for /healthz). */
  anonymous?: boolean;
  signal?: AbortSignal;
}

export function createApiClient({
  baseUrl,
  getToken,
  getAppCheckToken,
}: ApiClientOptions): ApiClient {
  const root = baseUrl.replace(/\/+$/, "");

  async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
    const headers = new Headers({ Accept: "application/json" });
    if (options.body !== undefined) headers.set("Content-Type", "application/json");

    if (!options.anonymous) {
      const token = await getToken?.();
      if (token) headers.set("Authorization", `Bearer ${token}`);

      // App Check is additive: the ID token above is never replaced by it, and
      // a failure to obtain one is not turned into a fake success.
      let appCheckToken: string | null = null;
      try {
        appCheckToken = (await getAppCheckToken?.()) || null;
      } catch {
        appCheckToken = null;
      }
      if (appCheckToken) headers.set("X-Firebase-AppCheck", appCheckToken);
    }

    let response: Response;
    try {
      response = await fetch(`${root}${path}`, {
        method: options.method ?? "GET",
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        cache: "no-store",
        credentials: "omit",
        signal: options.signal,
      });
    } catch (cause) {
      if (cause instanceof DOMException && cause.name === "AbortError") throw cause;
      throw new ApiError(STATUS_MESSAGES[0]!, 0, "network_error");
    }

    const text = await response.text();
    let payload: unknown = null;
    if (text) {
      try {
        payload = JSON.parse(text) as unknown;
      } catch {
        payload = null;
      }
    }

    if (!response.ok) {
      const envelope = payload as ApiErrorEnvelope | null;
      const error = envelope?.error;
      const code = error?.code ?? `http_${response.status}`;
      const message =
        error?.message?.trim() ||
        STATUS_MESSAGES[response.status] ||
        "The request failed.";
      throw new ApiError(message, response.status, code, error?.details ?? {});
    }

    return payload as T;
  }

  return {
    baseUrl: root,
    health: () => request<HealthResponse>("/healthz", { anonymous: true }),
    overview: () => request<OverviewResponse>("/v1/overview"),
    parseRequest: (requestCode) =>
      request<ParseResponse>("/v1/requests/parse", {
        method: "POST",
        body: { request_code: requestCode },
      }),
    issueLicense: (body) =>
      request<IssueResponse>("/v1/licenses", { method: "POST", body }),
    getDevice: (hwHash) =>
      request<DeviceResponse>(`/v1/devices/${encodeURIComponent(hwHash)}`),
    listDevices: (params) =>
      request<DeviceListResponse>(
        withQuery("/v1/devices", { query: params?.query, limit: params?.limit }),
      ),
    listLicenses: (params) =>
      request<LicenseListResponse>(
        withQuery("/v1/licenses", {
          query: params?.query,
          status: params?.status,
          limit: params?.limit,
        }),
      ),
    getLicenseCode: (licenseId) =>
      request<CodeResponse>(`/v1/licenses/${encodeURIComponent(licenseId)}/code`),
    reissueLicense: (licenseId, body) =>
      request<ReissueResponse>(
        `/v1/licenses/${encodeURIComponent(licenseId)}/reissue`,
        { method: "POST", body },
      ),
    revokeLicense: (licenseId, body) =>
      request<RevokeResponse>(`/v1/licenses/${encodeURIComponent(licenseId)}/revoke`, {
        method: "POST",
        body,
      }),
    listCustomers: (params) =>
      request<CustomerListResponse>(
        withQuery("/v1/customers", { query: params?.query, limit: params?.limit }),
      ),
    getCustomer: (customerId) =>
      request<CustomerDetailResponse>(`/v1/customers/${encodeURIComponent(customerId)}`),
    listAudit: (params) =>
      request<AuditListResponse>(
        withQuery("/v1/audit", { query: params?.query, limit: params?.limit }),
      ),
  };
}

/**
 * Same-origin path that Next proxies to the License API (see next.config.ts).
 *
 * Calling the API directly from the browser would need CORS on the Python
 * service, which is deliberately not enabled; the proxy keeps requests
 * same-origin and forwards the Authorization header unchanged.
 */
export function defaultApiBaseUrl(): string {
  return "/api/license";
}
