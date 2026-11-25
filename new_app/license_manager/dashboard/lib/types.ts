/**
 * Response shapes of the KlickPOS License API.
 *
 * These mirror `service/api.py` exactly. Nothing here is guessed: every field
 * below comes from a Pydantic model in that module, and nothing here can carry
 * signing material (only an activation code, and only from the audited code
 * endpoint).
 */

export type LicenseStatus = "active" | "superseded" | "revoked";

export interface LicenseSummary {
  license_id: string;
  hw_hash: string;
  status: LicenseStatus | string;
  kind: string;
  key_id: string;
  issued_at: string;
  created_at: string;
  created_by: string;
  features: string[];
  customer_id: string | null;
  install_id: string | null;
  reissued_from: string | null;
  superseded_by: string | null;
  revoked_at: string | null;
  revoked_reason: string | null;
}

export interface LicenseDetail extends LicenseSummary {
  activation_code: string;
}

export interface DeviceSummary {
  hw_hash: string;
  fingerprint_display_code: string | null;
  install_id: string | null;
  request_code: string | null;
  customer_id: string | null;
  current_license_id: string | null;
  first_seen_at: string | null;
  last_seen_at: string | null;
}

export interface ParseResponse {
  hw_hash: string;
  install_id: string;
  requested_at: string;
  fingerprint_display_code: string;
  existing_license: LicenseSummary | null;
  device: DeviceSummary | null;
}

export interface IssueResponse {
  created: boolean;
  license: LicenseDetail;
  notice: string | null;
}

export interface DeviceResponse {
  device: DeviceSummary;
  licenses: LicenseSummary[];
  notices: string[];
}

export interface CodeResponse {
  license_id: string;
  hw_hash: string;
  status: string;
  activation_code: string;
  warning: string | null;
}

export interface ReissueResponse {
  previous: LicenseSummary;
  license: LicenseDetail;
  notice: string;
}

export interface RevokeResponse {
  license: LicenseSummary;
  notice: string;
}

export interface AuditEntry {
  event_id: string;
  at: string;
  action: string;
  actor_uid: string;
  actor_email: string | null;
  license_id: string | null;
  hw_hash: string | null;
  client_ip: string | null;
  details: Record<string, unknown>;
}

export interface OverviewCounts {
  customers: number;
  devices: number;
  active_licenses: number;
  revoked_licenses: number;
  superseded_licenses: number;
}

export interface OverviewResponse {
  counts: OverviewCounts;
  recent_licenses: LicenseSummary[];
  recent_events: AuditEntry[];
}

export interface DeviceListItem {
  device: DeviceSummary;
  current_license: LicenseSummary | null;
}

export interface DeviceListResponse {
  items: DeviceListItem[];
  total: number;
}

export interface LicenseListResponse {
  items: LicenseSummary[];
  total: number;
}

export interface CustomerSummary {
  customer_id: string;
  name: string | null;
  email: string | null;
  phone: string | null;
  notes: string | null;
  updated_at: string | null;
}

export interface CustomerListResponse {
  items: CustomerSummary[];
  total: number;
}

export interface CustomerDetailResponse {
  customer: CustomerSummary;
  devices: DeviceSummary[];
  licenses: LicenseSummary[];
}

export interface AuditListResponse {
  items: AuditEntry[];
  total: number;
}

export interface HealthResponse {
  status: "ok";
  environment: string;
}

/** Body of the API's stable error envelope. */
export interface ApiErrorEnvelope {
  error: {
    code: string;
    message: string;
    details: Record<string, unknown>;
  };
}
