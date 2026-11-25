"use client";

import { useCallback, useState } from "react";

import { DataTable, type Column } from "@/components/table";
import {
  Badge,
  Card,
  CardHeader,
  CopyButton,
  Dialog,
  EmptyState,
  ErrorState,
  LoadingRows,
  PageHeader,
  SearchInput,
  Section,
} from "@/components/ui";
import type { ApiClient } from "@/lib/api";
import { formatDateTime, shortHash, titleCase } from "@/lib/format";
import { useDebounced, useResource } from "@/lib/use-resource";
import type { AuditEntry } from "@/lib/types";

const columns: Column<AuditEntry>[] = [
  {
    key: "at",
    header: "When",
    cell: (row) => (
      <div>
        <p className="text-ink">{formatDateTime(row.at)}</p>
        <p className="text-[11px] text-muted">{row.client_ip ?? "no client ip"}</p>
      </div>
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
      <div className="min-w-0">
        <p className="text-ink">{row.actor_email ?? "—"}</p>
        <p className="font-mono text-[11px] text-muted">{row.actor_uid}</p>
      </div>
    ),
  },
  {
    key: "license",
    header: "License",
    cell: (row) => (
      <span className="font-mono text-[12px] text-muted">
        {row.license_id ? shortHash(row.license_id, 14) : "—"}
      </span>
    ),
  },
  {
    key: "device",
    header: "Hardware hash",
    cell: (row) => (
      <span className="font-mono text-[12px] text-muted">
        {row.hw_hash ? shortHash(row.hw_hash, 12) : "—"}
      </span>
    ),
  },
];

export default function AuditPage() {
  const [query, setQuery] = useState("");
  const debounced = useDebounced(query);
  const load = useCallback(
    (api: ApiClient) => api.listAudit({ query: debounced, limit: 200 }),
    [debounced],
  );
  const { data, error, loading, reload } = useResource(load, [debounced]);
  const [detail, setDetail] = useState<AuditEntry | null>(null);

  return (
    <Section>
      <PageHeader
        eyebrow="Accountability"
        title="Audit log"
        description="Every administrative action the API recorded. Activation codes are never written to the log — only the fact that one was viewed."
        actions={
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="Search action, administrator, license, device"
            label="Search audit log"
          />
        }
      />

      <Card>
        <CardHeader
          title={data ? `${data.total} event${data.total === 1 ? "" : "s"}` : "Events"}
          description="Newest first, up to 200 entries from the most recent 500."
        />
        {loading ? (
          <LoadingRows rows={6} columns={5} />
        ) : error ? (
          <ErrorState message={error} onRetry={reload} />
        ) : data && data.items.length > 0 ? (
          <DataTable
            caption="Audit events"
            columns={columns}
            rows={data.items}
            rowKey={(row) => row.event_id}
            onRowClick={(row) => setDetail(row)}
            rowLabel={(row) => `Open audit event ${titleCase(row.action)}`}
          />
        ) : (
          <EmptyState
            title={query ? "No audit event matches that search" : "No audit events yet"}
            description={
              query
                ? "Search matches the action name, administrator, license id and hardware hash."
                : "Parse requests, issue licenses, view codes, reissues and revocations will appear here."
            }
          />
        )}
      </Card>

      <Dialog
        open={detail !== null}
        onClose={() => setDetail(null)}
        title={detail ? titleCase(detail.action) : "Audit event"}
        description={detail ? formatDateTime(detail.at) : undefined}
      >
        {detail ? (
          <div className="space-y-4">
            <dl className="grid gap-3 text-sm sm:grid-cols-2">
              {[
                ["Event ID", detail.event_id],
                ["Administrator", detail.actor_email ?? detail.actor_uid],
                ["Administrator UID", detail.actor_uid],
                ["License ID", detail.license_id ?? "—"],
                ["Hardware hash", detail.hw_hash ?? "—"],
                ["Client IP", detail.client_ip ?? "—"],
              ].map(([term, value]) => (
                <div key={term} className="min-w-0">
                  <dt className="text-xs font-medium uppercase tracking-wide text-muted">
                    {term}
                  </dt>
                  <dd className="mt-0.5 break-words font-mono text-[12px] text-ink">{value}</dd>
                </div>
              ))}
            </dl>

            <div>
              <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
                Details
              </h3>
              {Object.keys(detail.details).length === 0 ? (
                <p className="text-sm text-muted">No extra detail was recorded.</p>
              ) : (
                <ul className="divide-y divide-line rounded-lg border border-line text-sm">
                  {Object.entries(detail.details).map(([key, value]) => (
                    <li key={key} className="flex flex-wrap gap-2 px-3 py-2">
                      <span className="min-w-[120px] font-medium text-muted">{titleCase(key)}</span>
                      <span className="break-words text-ink">
                        {typeof value === "string" || typeof value === "number"
                          ? String(value)
                          : JSON.stringify(value)}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            {detail.license_id ? (
              <CopyButton value={detail.license_id} label="Copy license id" size="sm" />
            ) : null}
          </div>
        ) : null}
      </Dialog>
    </Section>
  );
}
