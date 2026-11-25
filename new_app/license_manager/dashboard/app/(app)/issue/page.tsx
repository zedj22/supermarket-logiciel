"use client";

import Link from "next/link";
import { useState } from "react";

import { IconAlert, IconCheck, IconShield } from "@/components/icons";
import {
  Alert,
  Button,
  Card,
  CardHeader,
  CopyButton,
  DefinitionList,
  Field,
  Input,
  PageHeader,
  Section,
  StatusBadge,
  Textarea,
} from "@/components/ui";
import { errorMessage, type ApiError } from "@/lib/api";
import { formatDateTime, shortHash } from "@/lib/format";
import { useSession } from "@/lib/session";
import type { IssueResponse, ParseResponse } from "@/lib/types";

interface CustomerForm {
  name: string;
  email: string;
  phone: string;
  notes: string;
}

const EMPTY_CUSTOMER: CustomerForm = { name: "", email: "", phone: "", notes: "" };

export default function IssuePage() {
  const { client } = useSession();

  const [code, setCode] = useState("");
  const [parsed, setParsed] = useState<ParseResponse | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const [parsing, setParsing] = useState(false);

  const [customer, setCustomer] = useState<CustomerForm>(EMPTY_CUSTOMER);
  const [showCustomerForm, setShowCustomerForm] = useState(false);

  const [issued, setIssued] = useState<IssueResponse | null>(null);
  const [issueError, setIssueError] = useState<string | null>(null);
  const [issuing, setIssuing] = useState(false);

  const existing = parsed?.existing_license ?? null;

  function reset() {
    setCode("");
    setParsed(null);
    setParseError(null);
    setIssued(null);
    setIssueError(null);
    setCustomer(EMPTY_CUSTOMER);
    setShowCustomerForm(false);
  }

  async function handleParse(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = code.trim();
    if (!value) {
      setParseError("Paste the customer's SMPr1 request code first.");
      return;
    }
    setParsing(true);
    setParseError(null);
    setIssued(null);
    setIssueError(null);
    try {
      setParsed(await client.parseRequest(value));
    } catch (cause) {
      setParsed(null);
      setParseError(errorMessage(cause));
    } finally {
      setParsing(false);
    }
  }

  async function handleIssue() {
    if (!parsed) return;
    setIssuing(true);
    setIssueError(null);
    try {
      const result = await client.issueLicense({
        request_code: code.trim(),
        ...(showCustomerForm && customer.name.trim()
          ? {
              customer: {
                name: customer.name.trim(),
                email: customer.email.trim() || null,
                phone: customer.phone.trim() || null,
                notes: customer.notes.trim() || null,
              },
            }
          : {}),
      });
      setIssued(result);
      setParsed((current) =>
        current ? { ...current, existing_license: result.license } : current,
      );
    } catch (cause) {
      const apiError = cause as ApiError;
      setIssueError(
        apiError?.code === "signing_key_not_published"
          ? `${errorMessage(cause)} The key id is not in the customer app's verification_keys.json yet.`
          : errorMessage(cause),
      );
    } finally {
      setIssuing(false);
    }
  }

  return (
    <Section>
      <PageHeader
        eyebrow="Workflow"
        title="Issue license"
        description="Parse a customer's SMPr1 request, review the fingerprint, then let the API sign one lifetime license for it."
        actions={
          parsed || issued ? (
            <Button variant="secondary" size="sm" onClick={reset}>
              Start another
            </Button>
          ) : null
        }
      />

      <div className="grid gap-4 lg:grid-cols-5">
        <Card className="lg:col-span-3">
          <CardHeader
            title="1 · Paste the request code"
            description="The SMPr1 code comes from KlickPOS → Settings → License on the customer's machine."
          />
          <form onSubmit={handleParse} className="space-y-4 px-5 py-4">
            <Field
              label="SMPr1 request code"
              htmlFor="request-code"
              hint="Requests are read with the same parser the desktop app uses. Nothing is issued yet."
              error={parseError}
            >
              <Textarea
                id="request-code"
                value={code}
                onChange={(event) => setCode(event.target.value)}
                placeholder="SMPr1.…"
                spellCheck={false}
                autoComplete="off"
                className="font-mono text-[13px]"
                aria-invalid={parseError ? true : undefined}
              />
            </Field>
            <div className="flex items-center gap-2">
              <Button type="submit" loading={parsing}>
                {parsing ? "Parsing…" : "Parse request"}
              </Button>
              <span className="text-xs text-muted">No license is created by parsing.</span>
            </div>
          </form>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader title="What happens next" />
          <ol className="space-y-3 px-5 py-4 text-sm text-muted">
            {[
              "The API verifies the request format and extracts the hardware digest.",
              "If this fingerprint already has a license, that record is shown instead of a new one.",
              "Otherwise the API signs one lifetime license and stores it with an audit event.",
              "Copy the activation code and send it to the customer.",
            ].map((line, index) => (
              <li key={line} className="flex gap-3">
                <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[11px] font-semibold text-accent-ink">
                  {index + 1}
                </span>
                <span className="leading-relaxed">{line}</span>
              </li>
            ))}
          </ol>
          <div className="mx-5 mb-5 rounded-lg border border-line bg-elevated/60 p-3 text-xs leading-relaxed text-muted">
            <span className="flex items-center gap-1.5 font-semibold uppercase tracking-wide">
              <IconShield size={13} /> Signing happens server-side
            </span>
            <p className="mt-1">
              This browser never holds the Ed25519 key or the AES key, and never
              generates an activation code.
            </p>
          </div>
        </Card>
      </div>

      {parsed ? (
        <Card>
          <CardHeader
            title="2 · Parsed request"
            description={`Parsed at ${formatDateTime(new Date().toISOString())}`}
            actions={<StatusBadge status={existing ? existing.status : "ready"} />}
          />
          <div className="space-y-4 px-5 py-4">
            {existing ? (
              <Alert tone="warning" title="This device already has a license">
                <p>
                  The API will not mint a second license for this fingerprint. The
                  existing record is{existing.status === "active" ? "" : ` ${existing.status}`}{" "}
                  and its original activation code can be retrieved from the Licenses page
                  (audited).
                </p>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <Link
                    href={`/licenses?query=${encodeURIComponent(existing.license_id)}`}
                    className="text-xs font-semibold underline underline-offset-2"
                  >
                    Open this license
                  </Link>
                  <span className="text-xs opacity-80">
                    License {shortHash(existing.license_id, 14)}
                  </span>
                </div>
              </Alert>
            ) : (
              <Alert tone="success" title="No license exists for this fingerprint">
                You can issue one lifetime license below.
              </Alert>
            )}

            <DefinitionList
              items={[
                { term: "Hardware hash", value: parsed.hw_hash, mono: true },
                { term: "Fingerprint display code", value: parsed.fingerprint_display_code, mono: true },
                { term: "Install ID", value: parsed.install_id, mono: true },
                { term: "Requested at", value: formatDateTime(parsed.requested_at) },
                {
                  term: "Existing device",
                  value: parsed.device
                    ? `${parsed.device.fingerprint_display_code ?? shortHash(parsed.device.hw_hash, 10)}`
                    : "New device",
                },
                {
                  term: "Device first seen",
                  value: formatDateTime(parsed.device?.first_seen_at ?? null),
                },
              ]}
            />
            <div className="flex flex-wrap items-center gap-2 border-t border-line pt-4">
              <span className="text-xs text-muted">Hardware hash</span>
              <CopyButton value={parsed.hw_hash} label="Copy hash" size="sm" variant="ghost" />
              <CopyButton
                value={parsed.fingerprint_display_code}
                label="Copy display code"
                size="sm"
                variant="ghost"
              />
            </div>
          </div>
        </Card>
      ) : null}

      {parsed && !existing ? (
        <Card>
          <CardHeader
            title="3 · Issue the lifetime license"
            description="Customer details are optional; they are stored with the license for support."
            actions={
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setShowCustomerForm((value) => !value)}
              >
                {showCustomerForm ? "Hide customer details" : "Add customer details"}
              </Button>
            }
          />
          <div className="space-y-4 px-5 py-4">
            {showCustomerForm ? (
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label="Customer name" htmlFor="customer-name">
                  <Input
                    id="customer-name"
                    value={customer.name}
                    onChange={(event) =>
                      setCustomer((current) => ({ ...current, name: event.target.value }))
                    }
                    placeholder="Epicerie Al Noor"
                  />
                </Field>
                <Field label="Email (optional)" htmlFor="customer-email">
                  <Input
                    id="customer-email"
                    type="email"
                    value={customer.email}
                    onChange={(event) =>
                      setCustomer((current) => ({ ...current, email: event.target.value }))
                    }
                    placeholder="owner@example.com"
                  />
                </Field>
                <Field label="Phone (optional)" htmlFor="customer-phone">
                  <Input
                    id="customer-phone"
                    value={customer.phone}
                    onChange={(event) =>
                      setCustomer((current) => ({ ...current, phone: event.target.value }))
                    }
                    placeholder="+212 …"
                  />
                </Field>
                <Field label="Notes (optional)" htmlFor="customer-notes">
                  <Input
                    id="customer-notes"
                    value={customer.notes}
                    onChange={(event) =>
                      setCustomer((current) => ({ ...current, notes: event.target.value }))
                    }
                    placeholder="Shop in Casablanca, 2 tills"
                  />
                </Field>
              </div>
            ) : null}

            {issueError ? (
              <Alert tone="danger" title="Could not issue the license">
                {issueError}
              </Alert>
            ) : null}

            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={handleIssue} loading={issuing}>
                {issuing ? "Signing…" : "Issue lifetime license"}
              </Button>
              <span className="text-xs text-muted">
                One license per fingerprint — repeated submissions return the original.
              </span>
            </div>
          </div>
        </Card>
      ) : null}

      {issued ? (
        <Card className="border-positive/40">
          <CardHeader
            title={issued.created ? "4 · License issued" : "Existing license returned"}
            description={
              issued.created
                ? "Copy this code and send it to the customer."
                : "No second license was created. This is the original code."
            }
            actions={<StatusBadge status={issued.license.status} />}
          />
          <div className="space-y-4 px-5 py-4">
            {issued.notice ? <Alert tone="info">{issued.notice}</Alert> : null}
            <div className="rounded-xl border border-positive/30 bg-positive/5 p-4">
              <p className="text-xs font-semibold uppercase tracking-wide text-positive">
                Activation code
              </p>
              <div className="mt-2 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <code className="break-all font-mono text-sm leading-relaxed text-ink">
                  {issued.license.activation_code}
                </code>
                <CopyButton value={issued.license.activation_code} label="Copy code" />
              </div>
              <p className="mt-2 flex items-center gap-1.5 text-xs text-muted">
                <IconCheck size={13} /> Send this over a channel you trust; it activates
                exactly one device.
              </p>
            </div>

            <DefinitionList
              items={[
                { term: "License ID", value: issued.license.license_id, mono: true },
                { term: "Key ID", value: issued.license.key_id, mono: true },
                { term: "Issued", value: formatDateTime(issued.license.issued_at) },
                { term: "Features", value: issued.license.features.join(", ") },
                { term: "Customer", value: issued.license.customer_id ?? "—" },
                { term: "Install ID", value: issued.license.install_id ?? "—", mono: true },
              ]}
            />

            <div className="flex flex-wrap gap-2 border-t border-line pt-4">
              <Link
                href={`/licenses?query=${encodeURIComponent(issued.license.license_id)}`}
                className="inline-flex h-8 items-center rounded-lg border border-line bg-panel px-3 text-xs font-medium text-ink hover:bg-elevated"
              >
                Open in licenses
              </Link>
              <Button variant="ghost" size="sm" onClick={reset}>
                Issue another
              </Button>
            </div>

            {!issued.created ? (
              <p className="flex items-center gap-1.5 text-xs text-muted">
                <IconAlert size={13} /> A duplicate submission never re-signs material.
              </p>
            ) : null}
          </div>
        </Card>
      ) : null}
    </Section>
  );
}
