"use client";

import { useCallback, useState } from "react";

import { DataTable, type Column } from "@/components/table";
import {
  Button,
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
import { formatDateTime, relativeTime, shortHash } from "@/lib/format";
import { useSession } from "@/lib/session";
import { useDebounced, useResource } from "@/lib/use-resource";
import type { DeviceListItem, DeviceResponse } from "@/lib/types";

const columns: Column<DeviceListItem>[] = [
  {
    key: "device",
    header: "Device",
    cell: (row) => (
      <div className="min-w-0">
        <p className="font-mono text-[13px] text-ink">{shortHash(row.device.hw_hash, 12)}</p>
        <p className="text-[11px] text-muted">
          {row.device.fingerprint_display_code ?? "no display code"}
        </p>
      </div>
    ),
  },
  {
    key: "install",
    header: "Install ID",
    cell: (row) => (
      <span className="font-mono text-[12px] text-muted">{row.device.install_id ?? "—"}</span>
    ),
  },
  {
    key: "customer",
    header: "Customer",
    cell: (row) => <span className="text-muted">{row.device.customer_id ?? "—"}</span>,
  },
  {
    key: "license",
    header: "Current license",
    cell: (row) =>
      row.current_license ? (
        <div className="flex items-center gap-2">
          <StatusBadge status={row.current_license.status} />
        </div>
      ) : (
        <span className="text-xs text-muted">none</span>
      ),
  },
  {
    key: "last_seen",
    header: "Last seen",
    cell: (row) => (
      <span className="text-muted" title={formatDateTime(row.device.last_seen_at)}>
        {relativeTime(row.device.last_seen_at)}
      </span>
    ),
  },
];

export default function DevicesPage() {
  const { client } = useSession();
  const [query, setQuery] = useState("");
  const debounced = useDebounced(query);
  const load = useCallback(
    (api: typeof client) => api.listDevices({ query: debounced, limit: 100 }),
    [debounced],
  );
  const { data, error, loading, reload } = useResource(load, [debounced]);

  const [selected, setSelected] = useState<DeviceListItem | null>(null);
  const [detail, setDetail] = useState<DeviceResponse | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);

  async function openDevice(row: DeviceListItem) {
    setSelected(row);
    setDetail(null);
    setDetailError(null);
    setDetailLoading(true);
    try {
      setDetail(await client.getDevice(row.device.hw_hash));
    } catch (cause) {
      setDetailError(errorMessage(cause));
    } finally {
      setDetailLoading(false);
    }
  }

  function close() {
    setSelected(null);
    setDetail(null);
    setDetailError(null);
  }

  return (
    <Section>
      <PageHeader
        eyebrow="Inventory"
        title="Devices"
        description="Every hardware fingerprint that requested a license, with its current license and full history."
        actions={<SearchInput value={query} onChange={setQuery} placeholder="Search hash, install id, customer" />}
      />

      <Card>
        <CardHeader
          title={data ? `${data.total} device${data.total === 1 ? "" : "s"}` : "Devices"}
          description={
            query
              ? `Filtered by “${query}” — the API scans up to 500 recent devices.`
              : "Newest activity first."
          }
          actions={
            <Button variant="ghost" size="sm" onClick={reload} disabled={loading}>
              Reload
            </Button>
          }
        />
        {loading ? (
          <LoadingRows rows={5} columns={5} />
        ) : error ? (
          <ErrorState message={error} onRetry={reload} />
        ) : data && data.items.length > 0 ? (
          <DataTable
            caption="Devices"
            columns={columns}
            rows={data.items}
            rowKey={(row) => row.device.hw_hash}
            onRowClick={openDevice}
            rowLabel={(row) => `Open device ${shortHash(row.device.hw_hash, 12)}`}
          />
        ) : (
          <EmptyState
            title={query ? "No device matches that search" : "No devices recorded yet"}
            description={
              query
                ? "Try a shorter fragment of the hardware hash, the install id or the customer id."
                : "A device appears here after its first request code is parsed or a license is issued."
            }
          />
        )}
      </Card>

      <Dialog
        open={selected !== null}
        onClose={close}
        width="lg"
        title="Device detail"
        description={selected ? shortHash(selected.device.hw_hash, 18) : undefined}
      >
        {detailLoading ? (
          <LoadingRows rows={3} columns={3} />
        ) : detailError ? (
          <ErrorState message={detailError} title="Could not load this device" />
        ) : detail ? (
          <div className="space-y-5">
            <DefinitionList
              items={[
                { term: "Hardware hash", value: detail.device.hw_hash, mono: true },
                {
                  term: "Display code",
                  value: detail.device.fingerprint_display_code ?? "—",
                  mono: true,
                },
                { term: "Install ID", value: detail.device.install_id ?? "—", mono: true },
                { term: "Customer", value: detail.device.customer_id ?? "—" },
                { term: "First seen", value: formatDateTime(detail.device.first_seen_at) },
                { term: "Last seen", value: formatDateTime(detail.device.last_seen_at) },
              ]}
            />
            <div className="flex flex-wrap gap-2">
              <CopyButton value={detail.device.hw_hash} label="Copy hash" size="sm" />
            </div>

            {detail.notices.length > 0 ? (
              <div className="space-y-2">
                {detail.notices.map((notice) => (
                  <p
                    key={notice}
                    className="rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-xs leading-relaxed text-warning"
                  >
                    {notice}
                  </p>
                ))}
              </div>
            ) : null}

            <div>
              <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
                License history
              </h3>
              {detail.licenses.length === 0 ? (
                <p className="text-sm text-muted">No license exists for this device.</p>
              ) : (
                <ul className="divide-y divide-line rounded-lg border border-line">
                  {detail.licenses.map((license) => (
                    <li key={license.license_id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5">
                      <div className="min-w-0">
                        <p className="font-mono text-[12px] text-ink">
                          {shortHash(license.license_id, 16)}
                        </p>
                        <p className="text-[11px] text-muted">
                          {formatDateTime(license.issued_at)} · key {license.key_id}
                        </p>
                      </div>
                      <div className="flex items-center gap-2">
                        <StatusBadge status={license.status} />
                        <CopyButton
                          value={license.license_id}
                          label="Copy"
                          size="sm"
                          variant="ghost"
                        />
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
            <p className="text-xs text-muted">
              Activation codes are not listed here. Retrieve one from the Licenses page —
              that call is audited and recorded against your account.
            </p>
          </div>
        ) : null}
      </Dialog>
    </Section>
  );
}
