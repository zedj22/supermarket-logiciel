"use client";

import Link from "next/link";
import { useCallback } from "react";

import { DataTable, type Column } from "@/components/table";
import {
  Badge,
  Card,
  CardHeader,
  ErrorState,
  LoadingRows,
  PageHeader,
  EmptyState,
  Section,
  StatCard,
  StatusBadge,
  Button,
} from "@/components/ui";
import { IconIssue, IconRefresh } from "@/components/icons";
import { formatDateTime, relativeTime, shortHash, titleCase } from "@/lib/format";
import { useResource } from "@/lib/use-resource";
import type { ApiClient } from "@/lib/api";
import type { AuditEntry, LicenseSummary } from "@/lib/types";

const licenseColumns: Column<LicenseSummary>[] = [
  {
    key: "license",
    header: "License",
    cell: (row) => (
      <span className="font-mono text-[13px] text-ink">{shortHash(row.license_id, 12)}</span>
    ),
  },
  {
    key: "device",
    header: "Device",
    cell: (row) => (
      <span className="font-mono text-[13px] text-muted">{shortHash(row.hw_hash, 8)}</span>
    ),
  },
  {
    key: "customer",
    header: "Customer",
    cell: (row) => (
      <span className="text-muted">{row.customer_id ?? "—"}</span>
    ),
  },
  {
    key: "created",
    header: "Issued",
    cell: (row) => (
      <span className="text-muted" title={formatDateTime(row.created_at)}>
        {relativeTime(row.created_at)}
      </span>
    ),
  },
  {
    key: "status",
    header: "Status",
    cell: (row) => <StatusBadge status={row.status} />,
  },
];

const activityColumns: Column<AuditEntry>[] = [
  {
    key: "at",
    header: "When",
    cell: (row) => (
      <span className="text-muted" title={formatDateTime(row.at)}>
        {relativeTime(row.at)}
      </span>
    ),
  },
  {
    key: "action",
    header: "Action",
    cell: (row) => <Badge tone="accent">{titleCase(row.action)}</Badge>,
  },
  {
    key: "actor",
    header: "Administrator",
    cell: (row) => (
      <span className="text-muted">{row.actor_email ?? row.actor_uid}</span>
    ),
  },
  {
    key: "target",
    header: "Target",
    cell: (row) => (
      <span className="font-mono text-[12px] text-muted">
        {row.license_id ? shortHash(row.license_id, 10) : row.hw_hash ? shortHash(row.hw_hash, 8) : "—"}
      </span>
    ),
  },
];

export default function OverviewPage() {
  const load = useCallback((client: ApiClient) => client.overview(), []);
  const { data, error, loading, reload } = useResource(load, []);

  return (
    <Section>
      <PageHeader
        eyebrow="Fleet"
        title="Overview"
        description="Totals and recent activity from the License API. Counts reflect the live Firestore state."
        actions={
          <>
            <Button variant="secondary" size="sm" onClick={reload} disabled={loading}>
              <IconRefresh size={14} /> Refresh
            </Button>
            <Link
              href="/issue"
              className="inline-flex h-8 items-center gap-1.5 rounded-lg bg-accent px-3 text-xs font-medium text-white hover:bg-accent/90 dark:text-canvas"
            >
              <IconIssue size={14} /> Issue license
            </Link>
          </>
        }
      />

      {error ? (
        <Card>
          <ErrorState message={error} onRetry={reload} />
        </Card>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4">
            {loading && !data ? (
              Array.from({ length: 4 }).map((_, index) => (
                <div key={index} className="card p-5">
                  <div className="h-3 w-20 animate-pulse rounded bg-line/60" />
                  <div className="mt-4 h-8 w-16 animate-pulse rounded bg-line/60" />
                </div>
              ))
            ) : (
              <>
                <StatCard
                  label="Customers"
                  value={data?.counts.customers ?? 0}
                  hint="Customer records with contact details"
                />
                <StatCard
                  label="Devices"
                  value={data?.counts.devices ?? 0}
                  hint="Fingerprints that requested a license"
                />
                <StatCard
                  label="Active licenses"
                  value={data?.counts.active_licenses ?? 0}
                  tone="positive"
                  hint="Currently valid, not replaced"
                />
                <StatCard
                  label="Revoked"
                  value={data?.counts.revoked_licenses ?? 0}
                  tone="danger"
                  hint={`${data?.counts.superseded_licenses ?? 0} superseded by reissue`}
                />
              </>
            )}
          </div>

          <div className="grid gap-4 xl:grid-cols-5">
            <Card className="xl:col-span-3">
              <CardHeader
                title="Recent licenses"
                description="Newest first, including licenses later superseded."
                actions={
                  <Link href="/licenses" className="text-xs font-medium text-accent hover:underline">
                    View all
                  </Link>
                }
              />
              {loading && !data ? (
                <LoadingRows rows={4} columns={4} />
              ) : data && data.recent_licenses.length > 0 ? (
                <DataTable
                  caption="Recent licenses"
                  columns={licenseColumns}
                  rows={data.recent_licenses}
                  rowKey={(row) => row.license_id}
                />
              ) : (
                <EmptyState
                  title="No licenses yet"
                  description="Paste a customer's SMPr1 request code on the Issue license page to create the first lifetime license."
                  action={
                    <Link
                      href="/issue"
                      className="inline-flex h-9 items-center gap-1.5 rounded-lg border border-line bg-panel px-3 text-sm font-medium text-ink hover:bg-elevated"
                    >
                      <IconIssue size={15} /> Issue a license
                    </Link>
                  }
                />
              )}
            </Card>

            <Card className="xl:col-span-2">
              <CardHeader
                title="Recent activity"
                description="Every entry is written by the API's audit trail."
                actions={
                  <Link href="/audit" className="text-xs font-medium text-accent hover:underline">
                    View all
                  </Link>
                }
              />
              {loading && !data ? (
                <LoadingRows rows={4} columns={3} />
              ) : data && data.recent_events.length > 0 ? (
                <DataTable
                  caption="Recent audit activity"
                  columns={activityColumns}
                  rows={data.recent_events}
                  rowKey={(row) => row.event_id}
                />
              ) : (
                <EmptyState
                  compact
                  title="No activity recorded"
                  description="Parsing a request code, issuing, retrieving a code and revoking all appear here."
                />
              )}
            </Card>
          </div>
        </>
      )}
    </Section>
  );
}
