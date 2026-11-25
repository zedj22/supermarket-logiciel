import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { ApiError } from "@/lib/api";
import type { ParseResponse } from "@/lib/types";

import IssuePage from "@/app/(app)/issue/page";
import { fakeClient, licenseSummary, renderWithSession } from "./helpers";

const parsed: ParseResponse = {
  hw_hash: "b".repeat(64),
  install_id: "install-0002",
  requested_at: "2026-02-28T09:30:00Z",
  fingerprint_display_code: "DDDD-EEEE-FFFF",
  existing_license: null,
  device: null,
};

const issued = {
  created: true,
  license: {
    ...licenseSummary,
    hw_hash: parsed.hw_hash,
    license_id: "lic_new_0001",
    activation_code: "SMP1.fresh.activation.code",
  },
  notice: null,
};

describe("issue license workflow", () => {
  it("parses the request code and shows the fingerprint", async () => {
    const client = fakeClient({ parseRequest: vi.fn(async () => parsed) });
    const user = userEvent.setup();
    renderWithSession(<IssuePage />, { client });

    await user.type(screen.getByLabelText("SMPr1 request code"), "SMPr1.demo.request");
    await user.click(screen.getByRole("button", { name: "Parse request" }));

    expect(await screen.findByText("No license exists for this fingerprint")).toBeInTheDocument();
    expect(screen.getByText(parsed.hw_hash)).toBeInTheDocument();
    expect(screen.getByText("DDDD-EEEE-FFFF")).toBeInTheDocument();
    expect(client.parseRequest).toHaveBeenCalledWith("SMPr1.demo.request");
  });

  it("issues the license and shows a copyable activation code", async () => {
    const client = fakeClient({
      parseRequest: vi.fn(async () => parsed),
      issueLicense: vi.fn(async () => issued),
    });
    const user = userEvent.setup();
    renderWithSession(<IssuePage />, { client });

    await user.type(screen.getByLabelText("SMPr1 request code"), "SMPr1.demo.request");
    await user.click(screen.getByRole("button", { name: "Parse request" }));
    await screen.findByText("No license exists for this fingerprint");

    await user.click(screen.getByRole("button", { name: "Issue lifetime license" }));

    expect(await screen.findByText(/License issued/)).toBeInTheDocument();
    expect(screen.getByText("SMP1.fresh.activation.code")).toBeInTheDocument();
    expect(client.issueLicense).toHaveBeenCalledWith({ request_code: "SMPr1.demo.request" });

    await user.click(screen.getByRole("button", { name: "Copy code" }));
    await waitFor(async () =>
      expect(await navigator.clipboard.readText()).toBe("SMP1.fresh.activation.code"),
    );
  });

  it("sends optional customer details when supplied", async () => {
    const client = fakeClient({
      parseRequest: vi.fn(async () => parsed),
      issueLicense: vi.fn(async () => issued),
    });
    const user = userEvent.setup();
    renderWithSession(<IssuePage />, { client });

    await user.type(screen.getByLabelText("SMPr1 request code"), "SMPr1.demo.request");
    await user.click(screen.getByRole("button", { name: "Parse request" }));
    await screen.findByText("No license exists for this fingerprint");

    await user.click(screen.getByRole("button", { name: "Add customer details" }));
    await user.type(screen.getByLabelText("Customer name"), "Epicerie Al Noor");
    await user.click(screen.getByRole("button", { name: "Issue lifetime license" }));

    await waitFor(() =>
      expect(client.issueLicense).toHaveBeenCalledWith({
        request_code: "SMPr1.demo.request",
        customer: {
          name: "Epicerie Al Noor",
          email: null,
          phone: null,
          notes: null,
        },
      }),
    );
  });

  it("reports an existing license instead of issuing a second one", async () => {
    const client = fakeClient({
      parseRequest: vi.fn(async () => ({ ...parsed, existing_license: licenseSummary })),
    });
    const user = userEvent.setup();
    renderWithSession(<IssuePage />, { client });

    await user.type(screen.getByLabelText("SMPr1 request code"), "SMPr1.demo.request");
    await user.click(screen.getByRole("button", { name: "Parse request" }));

    expect(await screen.findByText("This device already has a license")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Issue lifetime license" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Open this license" })).toBeInTheDocument();
    expect(client.issueLicense).not.toHaveBeenCalled();
  });

  it("shows the API's parse error without leaking internals", async () => {
    const client = fakeClient({
      parseRequest: vi.fn(async () => {
        throw new ApiError("the request code is not a valid SMPr1 request", 422, "request_format_invalid");
      }),
    });
    const user = userEvent.setup();
    renderWithSession(<IssuePage />, { client });

    await user.type(screen.getByLabelText("SMPr1 request code"), "not-a-code");
    await user.click(screen.getByRole("button", { name: "Parse request" }));

    expect(
      await screen.findByText("the request code is not a valid SMPr1 request"),
    ).toBeInTheDocument();
  });

  it("explains a missing published signing key when issuance fails", async () => {
    const client = fakeClient({
      parseRequest: vi.fn(async () => parsed),
      issueLicense: vi.fn(async () => {
        throw new ApiError("the signing key is not published", 503, "signing_key_not_published");
      }),
    });
    const user = userEvent.setup();
    renderWithSession(<IssuePage />, { client });

    await user.type(screen.getByLabelText("SMPr1 request code"), "SMPr1.demo.request");
    await user.click(screen.getByRole("button", { name: "Parse request" }));
    await screen.findByText("No license exists for this fingerprint");
    await user.click(screen.getByRole("button", { name: "Issue lifetime license" }));

    expect(await screen.findByText(/verification_keys\.json/)).toBeInTheDocument();
  });
});
