import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { ApiError } from "@/lib/api";

import LicensesPage from "@/app/(app)/licenses/page";
import { fakeClient, licenseSummary, renderWithSession } from "./helpers";

const nav = vi.hoisted(() => ({ query: "" }));

vi.mock("next/navigation", () => ({
  useSearchParams: () =>
    new URLSearchParams(nav.query ? { query: nav.query } : undefined),
}));

beforeEach(() => {
  nav.query = "";
});

function clientWithLicense(overrides = {}) {
  return fakeClient({
    listLicenses: vi.fn(async () => ({ items: [licenseSummary], total: 1 })),
    ...overrides,
  });
}

describe("licenses", () => {
  it("lists licenses and opens a detail view", async () => {
    const client = clientWithLicense();
    const user = userEvent.setup();
    renderWithSession(<LicensesPage />, { client });

    await screen.findByText("1 license");
    await user.click(screen.getByLabelText(/Open license/));

    const detail = await screen.findByRole("dialog");
    expect(within(detail).getAllByText(licenseSummary.license_id).length).toBeGreaterThan(0);
    expect(within(detail).getByText("Show activation code")).toBeInTheDocument();
  });

  it("retrieves the original code only after an explicit confirmation", async () => {
    const client = clientWithLicense({
      getLicenseCode: vi.fn(async () => ({
        license_id: licenseSummary.license_id,
        hw_hash: licenseSummary.hw_hash,
        status: "active",
        activation_code: "SMP1.original.code",
        warning: null,
      })),
    });
    const user = userEvent.setup();
    renderWithSession(<LicensesPage />, { client });

    await screen.findByText("1 license");
    await user.click(screen.getByRole("button", { name: "Code" }));

    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText(/This read is recorded/)).toBeInTheDocument();
    expect(client.getLicenseCode).not.toHaveBeenCalled();

    await user.click(within(dialog).getByRole("button", { name: "Reveal code" }));

    expect(await screen.findByText("SMP1.original.code")).toBeInTheDocument();
    expect(client.getLicenseCode).toHaveBeenCalledWith(licenseSummary.license_id);

    await user.click(screen.getByRole("button", { name: "Copy code" }));
    await waitFor(async () =>
      expect(await navigator.clipboard.readText()).toBe("SMP1.original.code"),
    );
  });

  it("requires a reason and an explicit confirmation before reissuing", async () => {
    const client = clientWithLicense({
      reissueLicense: vi.fn(async () => ({
        previous: { ...licenseSummary, status: "superseded" },
        license: {
          ...licenseSummary,
          license_id: "lic_replacement",
          activation_code: "SMP1.replacement.code",
        },
        notice: "The previous license is preserved with status 'superseded'.",
      })),
    });
    const user = userEvent.setup();
    renderWithSession(<LicensesPage />, { client });

    await screen.findByText("1 license");
    await user.click(screen.getByRole("button", { name: "Reissue" }));

    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByRole("button", { name: "Reissue license" })).toBeDisabled();

    await user.type(within(dialog).getByLabelText(/Reason/), "hardware replaced");
    expect(within(dialog).getByRole("button", { name: "Reissue license" })).toBeDisabled();

    await user.click(within(dialog).getByRole("checkbox"));
    await user.click(within(dialog).getByRole("button", { name: "Reissue license" }));

    await waitFor(() =>
      expect(client.reissueLicense).toHaveBeenCalledWith(licenseSummary.license_id, {
        reason: "hardware replaced",
        confirm: true,
      }),
    );
    expect(await screen.findByText("SMP1.replacement.code")).toBeInTheDocument();
  });

  it("warns that revocation cannot deactivate an offline license", async () => {
    const client = clientWithLicense({
      revokeLicense: vi.fn(async () => ({
        license: { ...licenseSummary, status: "revoked" },
        notice:
          "Administrative revocation recorded. A KlickPOS lifetime license is verified offline on the customer's own machine.",
      })),
    });
    const user = userEvent.setup();
    renderWithSession(<LicensesPage />, { client });

    await screen.findByText("1 license");
    await user.click(screen.getByRole("button", { name: "Revoke" }));

    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText("This is not a kill switch")).toBeInTheDocument();
    expect(within(dialog).getByText(/the point of sale keeps running/i)).toBeInTheDocument();

    expect(within(dialog).getByRole("button", { name: "Revoke license" })).toBeDisabled();

    await user.type(within(dialog).getByLabelText(/Reason/), "chargeback");
    await user.click(within(dialog).getByRole("checkbox"));
    await user.click(within(dialog).getByRole("button", { name: "Revoke license" }));

    await waitFor(() =>
      expect(client.revokeLicense).toHaveBeenCalledWith(licenseSummary.license_id, {
        reason: "chargeback",
      }),
    );
    expect(await screen.findByText("Revocation recorded")).toBeInTheDocument();
  });

  it("offers recovery when the list request fails", async () => {
    const client = fakeClient({
      listLicenses: vi.fn(async () => {
        throw new ApiError("The License API is temporarily unavailable.", 503, "store_unavailable");
      }),
    });
    const user = userEvent.setup();
    renderWithSession(<LicensesPage />, { client });

    expect(
      await screen.findByText("The License API is temporarily unavailable."),
    ).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /Try again/ }));
    await waitFor(() => expect(client.listLicenses).toHaveBeenCalledTimes(2));
  });

  it("starts from the ?query= deep link used by the Issue page", async () => {
    // `Open in licenses` / `Open this license` link to /licenses?query=<id>.
    nav.query = "lic_0123456789abcdef";
    const client = clientWithLicense();
    renderWithSession(<LicensesPage />, { client });

    const search = (await screen.findByLabelText("Search licenses")) as HTMLInputElement;
    expect(search.value).toBe("lic_0123456789abcdef");
    await waitFor(() =>
      expect(client.listLicenses).toHaveBeenCalledWith(
        expect.objectContaining({ query: "lic_0123456789abcdef" }),
      ),
    );
  });

  it("shows an empty state when nothing matches", async () => {
    const client = fakeClient({
      listLicenses: vi.fn(async () => ({ items: [], total: 0 })),
    });
    const user = userEvent.setup();
    renderWithSession(<LicensesPage />, { client });

    expect(await screen.findByText("No licenses yet")).toBeInTheDocument();
    await user.type(screen.getByLabelText("Search licenses"), "zzz");
    expect(await screen.findByText(/No license matches these filters/)).toBeInTheDocument();
  });
});
