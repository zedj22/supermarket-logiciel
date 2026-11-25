"use client";

import { useSearchParams } from "next/navigation";
import { Suspense, useCallback, useState } from "react";

import { DataTable, type Column } from "@/components/table";
import {
  Alert,
  Badge,
  Button,
  Card,
  CardHeader,
  CopyButton,
  DefinitionList,
  Dialog,
  EmptyState,
  ErrorState,
  Field,
  LoadingRows,
  PageHeader,
  SearchInput,
  Section,
  StatusBadge,
  Textarea,
} from "@/components/ui";
import { errorMessage } from "@/lib/api";
import { formatDateTime, shortHash, titleCase } from "@/lib/format";
import { useSession } from "@/lib/session";
import { useDebounced, useResource } from "@/lib/use-resource";
import type { CodeResponse, LicenseSummary, ReissueResponse } from "@/lib/types";

const STATUS_OPTIONS = [
  { value: "", label: "All statuses" },
  { value: "active", label: "Active" },
  { value: "superseded", label: "Superseded" },
  { value: "revoked", label: "Revoked" },
];

export default function LicensesPage() {
  return (
    <Suspense fallback={<LicensesLoading />}>
      <LicensesView />
    </Suspense>
  );
}

function LicensesLoading() {
  return (
    <Section>
      <PageHeader
        eyebrow="Records"
        title="Licenses"
        description="Every lifetime license ever signed, including superseded and revoked records."
      />
      <Card>
        <LoadingRows rows={6} columns={5} />
      </Card>
    </Section>
  );
}

function LicensesView() {
  // The Issue page links here as /licenses?query=<license id>, so the search
  // box starts from the URL instead of showing the whole list.
  const searchParams = useSearchParams();
  const { client } = useSession();
  const [query, setQuery] = useState(() => searchParams?.get("query") ?? "");
  const [status, setStatus] = useState("");
  const debounced = useDebounced(query);

  const load = useCallback(
    (api: typeof client) => api.listLicenses({ query: debounced, status, limit: 100 }),
    [debounced, status],
  );
  const { data, error, loading, reload } = useResource(load, [debounced, status]);

  const [detail, setDetail] = useState<LicenseSummary | null>(null);

  // -- original activation code (audited) ---------------------------------- //
  const [codeTarget, setCodeTarget] = useState<LicenseSummary | null>(null);
  const [revealed, setRevealed] = useState<CodeResponse | null>(null);
  const [codeError, setCodeError] = useState<string | null>(null);
  const [codeLoading, setCodeLoading] = useState(false);

  function openCode(license: LicenseSummary) {
    setCodeTarget(license);
    setRevealed(null);
    setCodeError(null);
  }

  async function revealCode() {
    if (!codeTarget) return;
    setCodeLoading(true);
    setCodeError(null);
    try {
      setRevealed(await client.getLicenseCode(codeTarget.license_id));
    } catch (cause) {
      setCodeError(errorMessage(cause));
    } finally {
      setCodeLoading(false);
    }
  }

  // -- reissue ------------------------------------------------------------- //
  const [reissueTarget, setReissueTarget] = useState<LicenseSummary | null>(null);
  const [reissueReason, setReissueReason] = useState("");
  const [reissueConfirmed, setReissueConfirmed] = useState(false);
  const [reissueBusy, setReissueBusy] = useState(false);
  const [reissueError, setReissueError] = useState<string | null>(null);
  const [reissueResult, setReissueResult] = useState<ReissueResponse | null>(null);

  function openReissue(license: LicenseSummary) {
    setReissueTarget(license);
    setReissueReason("");
    setReissueConfirmed(false);
    setReissueError(null);
    setReissueResult(null);
  }

  async function submitReissue() {
    if (!reissueTarget) return;
    setReissueBusy(true);
    setReissueError(null);
    try {
      const result = await client.reissueLicense(reissueTarget.license_id, {
        reason: reissueReason.trim(),
        confirm: true,
      });
      setReissueResult(result);
      reload();
    } catch (cause) {
      setReissueError(errorMessage(cause));
    } finally {
      setReissueBusy(false);
    }
  }

  // -- revoke -------------------------------------------------------------- //
  const [revokeTarget, setRevokeTarget] = useState<LicenseSummary | null>(null);
  const [revokeReason, setRevokeReason] = useState("");
  const [revokeConfirmed, setRevokeConfirmed] = useState(false);
  const [revokeBusy, setRevokeBusy] = useState(false);
  const [revokeError, setRevokeError] = useState<string | null>(null);
  const [revokeNotice, setRevokeNotice] = useState<string | null>(null);

  function openRevoke(license: LicenseSummary) {
    setRevokeTarget(license);
    setRevokeReason("");
    setRevokeConfirmed(false);
    setRevokeError(null);
    setRevokeNotice(null);
  }

  async function submitRevoke() {
    if (!revokeTarget) return;
    setRevokeBusy(true);
    setRevokeError(null);
    try {
      const result = await client.revokeLicense(revokeTarget.license_id, {
        reason: revokeReason.trim(),
      });
      setRevokeNotice(result.notice);
      reload();
    } catch (cause) {
      setRevokeError(errorMessage(cause));
    } finally {
      setRevokeBusy(false);
    }
  }

  const columns: Column<LicenseSummary>[] = [
    {
      key: "license",
      header: "License",
      cell: (row) => (
        <div className="min-w-0">
          <p className="font-mono text-[13px] text-ink">{shortHash(row.license_id, 12)}</p>
          <p className="text-[11px] text-muted">{row.kind}</p>
        </div>
      ),
    },
    {
      key: "device",
      header: "Device",
      cell: (row) => (
        <span className="font-mono text-[12px] text-muted">{shortHash(row.hw_hash, 8)}</span>
      ),
    },
    {
      key: "customer",
      header: "Customer",
      cell: (row) => <span className="text-muted">{row.customer_id ?? "—"}</span>,
    },
    {
      key: "created",
      header: "Issued",
      cell: (row) => (
        <span className="text-muted" title={formatDateTime(row.created_at)}>
          {formatDateTime(row.issued_at)}
        </span>
      ),
    },
    { key: "status", header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
    {
      key: "actions",
      header: "Actions",
      headerClassName: "text-right",
      className: "text-right",
      cell: (row) => (
        <div className="flex flex-wrap items-center justify-end gap-1">
          <Button
            size="sm"
            variant="ghost"
            onClick={(event) => {
              event.stopPropagation();
              openCode(row);
            }}
          >
            Code
          </Button>
          <Button
            size="sm"
            variant="ghost"
            disabled={row.status !== "active"}
            onClick={(event) => {
              event.stopPropagation();
              openReissue(row);
            }}
          >
            Reissue
          </Button>
          <Button
            size="sm"
            variant="ghost"
            className="text-danger hover:bg-danger/10"
            disabled={row.status !== "active"}
            onClick={(event) => {
              event.stopPropagation();
              openRevoke(row);
            }}
          >
            Revoke
          </Button>
        </div>
      ),
    },
  ];

  return (
    <Section>
      <PageHeader
        eyebrow="Records"
        title="Licenses"
        description="Every lifetime license ever signed, including superseded and revoked records. Activation codes are retrieved one at a time and logged. Search matches up to the 500 most recent records."
      />

      <Card>
        <CardHeader
          title={data ? `${data.total} license${data.total === 1 ? "" : "s"}` : "Licenses"}
          description={query || status ? "Filtered view." : "Newest first."}
          actions={
            <div className="flex flex-wrap items-center gap-2">
              <SearchInput
                value={query}
                onChange={setQuery}
                placeholder="Search id, hash, customer, key"
                label="Search licenses"
              />
              <select
                aria-label="Filter by status"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
                className="field h-10 w-auto pr-8"
              >
                {STATUS_OPTIONS.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            </div>
          }
        />

        {loading ? (
          <LoadingRows rows={6} columns={5} />
        ) : error ? (
          <ErrorState message={error} onRetry={reload} />
        ) : data && data.items.length > 0 ? (
          <DataTable
            caption="Licenses"
            columns={columns}
            rows={data.items}
            rowKey={(row) => row.license_id}
            onRowClick={(row) => setDetail(row)}
            rowLabel={(row) => `Open license ${shortHash(row.license_id, 12)}`}
          />
        ) : (
          <EmptyState
            title={query || status ? "No license matches these filters" : "No licenses yet"}
            description={
              query || status
                ? "Clear the search or choose a different status."
                : "Issue the first license from the Issue license page."
            }
          />
        )}
      </Card>

      {/* Detail ------------------------------------------------------------ */}
      <Dialog
        open={detail !== null}
        onClose={() => setDetail(null)}
        width="lg"
        title="License detail"
        description={detail ? detail.license_id : undefined}
      >
        {detail ? (
          <div className="space-y-5">
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status={detail.status} />
              <Badge tone="neutral">{titleCase(detail.kind)}</Badge>
              {detail.features.map((feature) => (
                <Badge key={feature} tone="accent">
                  {feature}
                </Badge>
              ))}
            </div>
            <DefinitionList
              items={[
                { term: "License ID", value: detail.license_id, mono: true },
                { term: "Hardware hash", value: detail.hw_hash, mono: true },
                { term: "Customer", value: detail.customer_id ?? "—" },
                { term: "Install ID", value: detail.install_id ?? "—", mono: true },
                { term: "Signing key", value: detail.key_id, mono: true },
                { term: "Issued", value: formatDateTime(detail.issued_at) },
                { term: "Created by", value: detail.created_by, mono: true },
                { term: "Superseded by", value: detail.superseded_by ?? "—", mono: true },
                { term: "Reissued from", value: detail.reissued_from ?? "—", mono: true },
                {
                  term: "Revoked",
                  value: detail.revoked_at
                    ? `${formatDateTime(detail.revoked_at)} — ${detail.revoked_reason ?? "no reason"}`
                    : "—",
                },
              ]}
            />
            <div className="flex flex-wrap gap-2 border-t border-line pt-4">
              <Button size="sm" variant="secondary" onClick={() => setDetail(null)}>
                Close
              </Button>
              <Button
                size="sm"
                onClick={() => {
                  const target = detail;
                  setDetail(null);
                  openCode(target);
                }}
              >
                Show activation code
              </Button>
            </div>
          </div>
        ) : null}
      </Dialog>

      {/* Original code (requires explicit confirmation) -------------------- */}
      <Dialog
        open={codeTarget !== null}
        onClose={() => setCodeTarget(null)}
        title="Reveal the original activation code"
        description={
          codeTarget ? `License ${shortHash(codeTarget.license_id, 16)}` : undefined
        }
      >
        {codeTarget ? (
          <div className="space-y-4">
            <Alert tone="warning" title="This read is recorded">
              The API writes an <code className="font-mono">activation_code_viewed</code>{" "}
              audit event with your administrator identity and the time. The code is not
              stored in this browser beyond this dialog.
            </Alert>

            {revealed ? (
              <div className="rounded-xl border border-line bg-elevated/60 p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-muted">
                  Activation code
                </p>
                <code className="mt-2 block break-all font-mono text-sm text-ink">
                  {revealed.activation_code}
                </code>
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <CopyButton value={revealed.activation_code} label="Copy code" />
                  <span className="flex items-center gap-1.5 text-xs text-muted">
                    Status: <StatusBadge status={revealed.status} />
                  </span>
                </div>
                {revealed.warning ? (
                  <p className="mt-3 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-xs leading-relaxed text-warning">
                    {revealed.warning}
                  </p>
                ) : null}
              </div>
            ) : (
              <div className="space-y-3">
                <p className="text-sm text-muted">
                  The code is fetched from the audited{" "}
                  <code className="font-mono text-xs">/v1/licenses/…/code</code> endpoint.
                </p>
                {codeError ? <Alert tone="danger">{codeError}</Alert> : null}
                <div className="flex justify-end gap-2">
                  <Button variant="secondary" size="sm" onClick={() => setCodeTarget(null)}>
                    Cancel
                  </Button>
                  <Button size="sm" loading={codeLoading} onClick={revealCode}>
                    Reveal code
                  </Button>
                </div>
              </div>
            )}
          </div>
        ) : null}
      </Dialog>

      {/* Reissue ---------------------------------------------------------- */}
      <Dialog
        open={reissueTarget !== null}
        onClose={() => setReissueTarget(null)}
        title="Reissue this license"
        description="A new license document is signed; the original is kept and marked superseded."
      >
        {reissueTarget ? (
          reissueResult ? (
            <div className="space-y-4">
              <Alert tone="success" title="Replacement license issued">
                {reissueResult.notice}
              </Alert>
              <div className="rounded-xl border border-line bg-elevated/60 p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-muted">
                  New activation code
                </p>
                <code className="mt-2 block break-all font-mono text-sm text-ink">
                  {reissueResult.license.activation_code}
                </code>
                <div className="mt-3">
                  <CopyButton value={reissueResult.license.activation_code} label="Copy code" />
                </div>
              </div>
              <DefinitionList
                items={[
                  { term: "New license", value: reissueResult.license.license_id, mono: true },
                  { term: "Previous license", value: reissueResult.previous.license_id, mono: true },
                  { term: "Previous status", value: titleCase(reissueResult.previous.status) },
                ]}
              />
              <div className="flex justify-end">
                <Button size="sm" onClick={() => setReissueTarget(null)}>
                  Done
                </Button>
              </div>
            </div>
          ) : (
            <div className="space-y-4">
              <Alert tone="warning" title="The customer must activate the new code">
                KlickPOS keeps whichever code it last activated. The old record stays in the
                database as <strong>superseded</strong>; nothing is deleted.
              </Alert>
              <Field
                label="Reason (required, at least 4 characters)"
                htmlFor="reissue-reason"
                hint="Stored in the audit log with your administrator identity."
              >
                <Textarea
                  id="reissue-reason"
                  value={reissueReason}
                  onChange={(event) => setReissueReason(event.target.value)}
                  placeholder="Customer reinstalled Windows and regenerated the fingerprint…"
                />
              </Field>
              <label className="flex items-start gap-2 text-sm text-ink">
                <input
                  type="checkbox"
                  checked={reissueConfirmed}
                  onChange={(event) => setReissueConfirmed(event.target.checked)}
                  className="mt-1 h-4 w-4 rounded border-line text-accent"
                />
                <span>
                  I understand this creates a second license record and the old code will stop
                  being the current one.
                </span>
              </label>
              {reissueError ? <Alert tone="danger">{reissueError}</Alert> : null}
              <div className="flex justify-end gap-2">
                <Button variant="secondary" size="sm" onClick={() => setReissueTarget(null)}>
                  Cancel
                </Button>
                <Button
                  size="sm"
                  loading={reissueBusy}
                  disabled={!reissueConfirmed || reissueReason.trim().length < 4}
                  onClick={submitReissue}
                >
                  Reissue license
                </Button>
              </div>
            </div>
          )
        ) : null}
      </Dialog>

      {/* Revoke ----------------------------------------------------------- */}
      <Dialog
        open={revokeTarget !== null}
        onClose={() => setRevokeTarget(null)}
        title="Revoke this license"
        description="Records an administrative revocation. It does not disable an offline installation."
      >
        {revokeTarget ? (
          revokeNotice ? (
            <div className="space-y-4">
              <Alert tone="warning" title="Revocation recorded">
                {revokeNotice}
              </Alert>
              <div className="flex justify-end">
                <Button size="sm" onClick={() => setRevokeTarget(null)}>
                  Close
                </Button>
              </div>
            </div>
          ) : (
            <div className="space-y-4">
              <Alert tone="danger" title="This is not a kill switch">
                A KlickPOS lifetime license is verified offline on the customer&apos;s machine.
                Revocation marks the record and blocks the license as a current entitlement, but
                <strong> the point of sale keeps running</strong> until its license file is replaced
                or removed. Use reissue to hand the customer a replacement code.
              </Alert>
              <Field
                label="Reason (required, at least 4 characters)"
                htmlFor="revoke-reason"
                hint="Stored with the revocation record and the audit log."
              >
                <Textarea
                  id="revoke-reason"
                  value={revokeReason}
                  onChange={(event) => setRevokeReason(event.target.value)}
                  placeholder="Refund issued / chargeback / account closed…"
                />
              </Field>
              <label className="flex items-start gap-2 text-sm text-ink">
                <input
                  type="checkbox"
                  checked={revokeConfirmed}
                  onChange={(event) => setRevokeConfirmed(event.target.checked)}
                  className="mt-1 h-4 w-4 rounded border-line text-danger"
                />
                <span>
                  I understand revocation cannot remotely deactivate this license and is recorded
                  against my administrator account.
                </span>
              </label>
              {revokeError ? <Alert tone="danger">{revokeError}</Alert> : null}
              <div className="flex justify-end gap-2">
                <Button variant="secondary" size="sm" onClick={() => setRevokeTarget(null)}>
                  Cancel
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  loading={revokeBusy}
                  disabled={!revokeConfirmed || revokeReason.trim().length < 4}
                  onClick={submitRevoke}
                >
                  Revoke license
                </Button>
              </div>
            </div>
          )
        ) : null}
      </Dialog>
    </Section>
  );
}
