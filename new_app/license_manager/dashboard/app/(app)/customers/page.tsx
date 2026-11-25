"use client";

import { useCallback, useState } from "react";

import { DataTable, type Column } from "@/components/table";
import {
  Card,
  CardHeader,
  CopyButton,
  DefinitionList,
  Dialog,
  EmptyState,
  ErrorState,
  LoadingRows,
  PageHeader,
  SearchInput,
  Section,
  StatusBadge,
} from "@/components/ui";
import { errorMessage } from "@/lib/api";
import { formatDateTime, shortHash } from "@/lib/format";
import { useSession } from "@/lib/session";
import { useDebounced, useResource } from "@/lib/use-resource";
import type { CustomerDetailResponse, CustomerSummary } from "@/lib/types";

const columns: Column<CustomerSummary>[] = [
  {
    key: "name",
    header: "Customer",
    cell: (row) => (
      <div className="min-w-0">
        <p className="font-medium text-ink">{row.name ?? "Unnamed customer"}</p>
        <p className="font-mono text-[11px] text-muted">{row.customer_id}</p>
      </div>
    ),
  },
  {
    key: "email",
    header: "Email",
    cell: (row) => <span className="text-muted">{row.email ?? "—"}</span>,
  },
  {
    key: "phone",
    header: "Phone",
    cell: (row) => <span className="text-muted">{row.phone ?? "—"}</span>,
  },
  {
    key: "notes",
    header: "Notes",
    cell: (row) => (
      <span className="block max-w-[220px] truncate text-muted" title={row.notes ?? undefined}>
        {row.notes ?? "—"}
      </span>
    ),
  },
  {
    key: "updated",
    header: "Updated",
    cell: (row) => <span className="text-muted">{formatDateTime(row.updated_at)}</span>,
  },
];

export default function CustomersPage() {
  const { client } = useSession();
  const [query, setQuery] = useState("");
  const debounced = useDebounced(query);
  const load = useCallback(
    (api: typeof client) => api.listCustomers({ query: debounced, limit: 100 }),
    [debounced],
  );
  const { data, error, loading, reload } = useResource(load, [debounced]);

  const [detail, setDetail] = useState<CustomerDetailResponse | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  async function open(customerId: string) {
    setSelectedId(customerId);
    setDetail(null);
    setDetailError(null);
    setDetailLoading(true);
    try {
      setDetail(await client.getCustomer(customerId));
    } catch (cause) {
      setDetailError(errorMessage(cause));
    } finally {
      setDetailLoading(false);
    }
  }

  return (
    <Section>
      <PageHeader
        eyebrow="Relationships"
        title="Customers"
        description="Customer records created alongside a license. Contact details are stored by the License API, not in this browser. Search matches up to the 500 most recent records."
        actions={
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="Search name, id, email, phone"
            label="Search customers"
          />
        }
      />

      <Card>
        <CardHeader
          title={data ? `${data.total} customer${data.total === 1 ? "" : "s"}` : "Customers"}
          description={
            data && data.total === 0
              ? "Add customer details while issuing a license to populate this list."
              : "Select a customer to see its devices and licenses."
          }
        />
        {loading ? (
          <LoadingRows rows={4} columns={4} />
        ) : error ? (
          <ErrorState message={error} onRetry={reload} />
        ) : data && data.items.length > 0 ? (
          <DataTable
            caption="Customers"
            columns={columns}
            rows={data.items}
            rowKey={(row) => row.customer_id}
            onRowClick={(row) => open(row.customer_id)}
            rowLabel={(row) => `Open customer ${row.name ?? row.customer_id}`}
          />
        ) : (
          <EmptyState
            title={query ? "No customer matches that search" : "No customers yet"}
            description={
              query
                ? "Try a different name or identifier fragment."
                : "Customers are created when a license is issued with customer details, or attached to an existing device."
            }
          />
        )}
      </Card>

      <Dialog
        open={selectedId !== null}
        onClose={() => setSelectedId(null)}
        width="lg"
        title="Customer detail"
        description={detail?.customer.name ?? selectedId ?? undefined}
      >
        {detailLoading ? (
          <LoadingRows rows={3} columns={3} />
        ) : detailError ? (
          <ErrorState message={detailError} title="Could not load this customer" />
        ) : detail ? (
          <div className="space-y-5">
            <DefinitionList
              items={[
                { term: "Customer ID", value: detail.customer.customer_id, mono: true },
                { term: "Name", value: detail.customer.name ?? "—" },
                { term: "Email", value: detail.customer.email ?? "—" },
                { term: "Phone", value: detail.customer.phone ?? "—" },
                { term: "Notes", value: detail.customer.notes ?? "—" },
                { term: "Updated", value: formatDateTime(detail.customer.updated_at) },
              ]}
            />
            {detail.customer.customer_id ? (
              <CopyButton value={detail.customer.customer_id} label="Copy customer id" size="sm" />
            ) : null}

            <div>
              <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
                Devices ({detail.devices.length})
              </h3>
              {detail.devices.length === 0 ? (
                <p className="text-sm text-muted">No device is linked to this customer yet.</p>
              ) : (
                <ul className="divide-y divide-line rounded-lg border border-line">
                  {detail.devices.map((device) => (
                    <li
                      key={device.hw_hash}
                      className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5"
                    >
                      <div>
                        <p className="font-mono text-[12px] text-ink">
                          {shortHash(device.hw_hash, 16)}
                        </p>
                        <p className="text-[11px] text-muted">
                          {device.fingerprint_display_code ?? "no display code"} ·{" "}
                          {device.install_id ?? "no install id"}
                        </p>
                      </div>
                      <span className="text-[11px] text-muted">
                        last seen {formatDateTime(device.last_seen_at)}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <div>
              <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
                Licenses ({detail.licenses.length})
              </h3>
              {detail.licenses.length === 0 ? (
                <p className="text-sm text-muted">No license is linked to this customer yet.</p>
              ) : (
                <ul className="divide-y divide-line rounded-lg border border-line">
                  {detail.licenses.map((license) => (
                    <li
                      key={license.license_id}
                      className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5"
                    >
                      <div>
                        <p className="font-mono text-[12px] text-ink">
                          {shortHash(license.license_id, 16)}
                        </p>
                        <p className="text-[11px] text-muted">
                          issued {formatDateTime(license.issued_at)}
                        </p>
                      </div>
                      <StatusBadge status={license.status} />
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </div>
        ) : null}
      </Dialog>
    </Section>
  );
}
