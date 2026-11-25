import { render } from "@testing-library/react";
import type { RenderResult } from "@testing-library/react";
import type { ReactElement } from "react";
import { vi } from "vitest";

import type { ApiClient } from "@/lib/api";
import { createSession, SessionContext, type SessionStatus } from "@/lib/session";
import type {
  AuditListResponse,
  CustomerListResponse,
  DeviceListResponse,
  LicenseListResponse,
  OverviewResponse,
} from "@/lib/types";

export const emptyOverview: OverviewResponse = {
  counts: {
    customers: 0,
    devices: 0,
    active_licenses: 0,
    revoked_licenses: 0,
    superseded_licenses: 0,
  },
  recent_licenses: [],
  recent_events: [],
};

export const licenseSummary = {
  license_id: "lic_0123456789abcdef",
  hw_hash: "a".repeat(64),
  status: "active",
  kind: "lifetime",
  key_id: "test-owner",
  issued_at: "2026-03-01T12:00:00Z",
  created_at: "2026-03-01T12:00:00Z",
  created_by: "admin-1",
  features: ["pos"],
  customer_id: "CUS-1",
  install_id: "install-0001",
  reissued_from: null,
  superseded_by: null,
  revoked_at: null,
  revoked_reason: null,
};

export const deviceSummary = {
  hw_hash: "a".repeat(64),
  fingerprint_display_code: "AAAA-BBBB-CCCC",
  install_id: "install-0001",
  request_code: "SMPr1.demo",
  customer_id: "CUS-1",
  current_license_id: licenseSummary.license_id,
  first_seen_at: "2026-02-01T10:00:00Z",
  last_seen_at: "2026-03-01T12:00:00Z",
};

export function fakeClient(overrides: Partial<ApiClient> = {}): ApiClient {
  const base: ApiClient = {
    baseUrl: "http://api.test",
    health: vi.fn(async () => ({ status: "ok" as const, environment: "testing" })),
    overview: vi.fn(async () => emptyOverview),
    parseRequest: vi.fn(async () => {
      throw new Error("parseRequest not stubbed");
    }),
    issueLicense: vi.fn(async () => {
      throw new Error("issueLicense not stubbed");
    }),
    getDevice: vi.fn(async () => {
      throw new Error("getDevice not stubbed");
    }),
    listDevices: vi.fn(
      async (): Promise<DeviceListResponse> => ({ items: [], total: 0 }),
    ),
    listLicenses: vi.fn(
      async (): Promise<LicenseListResponse> => ({ items: [], total: 0 }),
    ),
    getLicenseCode: vi.fn(async () => {
      throw new Error("getLicenseCode not stubbed");
    }),
    reissueLicense: vi.fn(async () => {
      throw new Error("reissueLicense not stubbed");
    }),
    revokeLicense: vi.fn(async () => {
      throw new Error("revokeLicense not stubbed");
    }),
    listCustomers: vi.fn(
      async (): Promise<CustomerListResponse> => ({ items: [], total: 0 }),
    ),
    getCustomer: vi.fn(async () => {
      throw new Error("getCustomer not stubbed");
    }),
    listAudit: vi.fn(async (): Promise<AuditListResponse> => ({ items: [], total: 0 })),
  };
  return { ...base, ...overrides };
}

export function renderWithSession(
  ui: ReactElement,
  options: {
    client?: ApiClient;
    status?: SessionStatus;
    admin?: { uid: string; email: string | null } | null;
  } = {},
): RenderResult & { client: ApiClient } {
  const client = options.client ?? fakeClient();
  const session = createSession(client, {
    status: options.status ?? "authenticated",
    admin:
      options.admin === undefined
        ? { uid: "admin-1", email: "admin@example.com" }
        : options.admin,
  });
  const result = render(
    <SessionContext.Provider value={session}>{ui}</SessionContext.Provider>,
  );
  return { ...result, client };
}
