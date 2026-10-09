"""FactureData view-model + builder (Phase 7 — facturation A4 documents).

Direction: ``InvoiceDocumentResponse`` (the Phase 5 detail payload) + the
Phase 6 seller identity → ``FactureData`` → ``templates/facture_a4.py``.
The split mirrors ``document_data.py`` (G8): the builder computes EVERY
derived value once — the localized document title, the column/row gating
of the five ``show_*`` flags, the formatted money / quantity / percent
text and the identity lines that skip blanks (legacy ``_id``) — and the
template only lays out what it receives. No DB, no settings read.

Contracts this module must never break
---------------------------------------
* **Money is never recomputed.** Totals and the amount-in-words sentence
  ride on the Phase 1 ``calculate_document_result`` payload (the ONE
  path, Phase 5) — this module formats, it does not calculate.
* **The stored date prints.** ``document.document_date`` formatted with
  ``format_date``; legacy ``pdf_invoice.dart:187`` printed
  ``DateTime.today()`` — a defect, not parity.
* **Amount in words is ALWAYS French** (Phase 1 authority), whatever PDF
  locale the endpoint was called with.
* **Display flags are presentation only** (Phase 5: they never change a
  number): ``show_discount`` / ``show_tva`` gate a column and the
  ``Total TVA`` row, ``show_timbre`` gates the timbre row (also gated by
  ``timbre > 0`` — legacy ``opt('show_timbre') && timbre > 0``),
  ``show_amount_words`` / ``show_payment_method`` gate their lines.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from app.printing.labels import is_rtl, label
from app.printing.text import format_date, format_money, format_qty
from app.schemas.facturation import (
    InvoiceClientRefResponse,
    InvoiceDocumentResponse,
)

#: doc_type → localized title key (legacy ``_titles``, translated for SP).
DOC_TITLE_KEYS: dict[str, str] = {
    "FAC": "doc_facture",
    "DEV": "doc_devis",
    "PRO": "doc_proforma",
    "BC": "doc_bon_commande",
    "BL": "doc_bon_livraison",
}

#: payment_method → localized label key (legacy ``_payLabels``).
PAYMENT_KEYS: dict[str, str] = {
    "cash": "label_cash",
    "transfer": "label_transfer",
    "cheque": "label_cheque",
}


@dataclass(frozen=True)
class CompanyIdentity:
    """Raw seller identity for rendering (Phase 6 read view, field-for-field).

    The print service maps ``FacturationCompanySettings`` onto this — the
    printing layer never imports a service and never reads settings.
    Values arrive exactly as stored (``""`` when unset) so blank lines can
    be dropped here the way the legacy ``_id`` helper does.
    """

    name: str
    address: str = ""
    wilaya: str = ""
    phone: str = ""
    email: str = ""
    nif: str = ""
    nis: str = ""
    rc: str = ""
    ai: str = ""
    rib: str = ""


@dataclass(frozen=True)
class IdentityBlock:
    """One party's printed identity: heading + name + pre-formatted lines.

    ``lines`` are already-composed strings (bare address/wilaya, or
    ``"{label} : {value}"`` for contact/fiscal ids) with blanks dropped,
    so the template draws exactly the lines it receives and tests can
    assert a fiscal line verbatim.
    """

    heading: str | None
    name: str
    lines: tuple[str, ...] = ()


@dataclass(frozen=True)
class FactureLineRow:
    """One item row, already formatted (legacy table cells)."""

    index: str
    description: str
    qty: str
    unit_price: str
    #: ``None`` when ``show_discount`` is off → the template drops the column.
    discount: str | None
    #: ``None`` when ``show_tva`` is off → the template drops the column.
    tva_rate: str | None
    total_ht: str


@dataclass(frozen=True)
class FactureTotals:
    """Totals block; ``None`` rows are simply not drawn (never recalculated)."""

    total_ht: str
    total_tva: str | None
    total_ttc: str
    timbre: str | None
    net_a_payer: str


@dataclass(frozen=True)
class FactureData:
    locale: str
    title: str
    number: str
    document_date: str
    company: IdentityBlock
    client: IdentityBlock | None
    show_discount: bool
    show_tva: bool
    lines: tuple[FactureLineRow, ...]
    totals: FactureTotals
    amount_in_words: str | None
    payment_method: str | None
    notes: str | None

    @property
    def rtl(self) -> bool:
        return is_rtl(self.locale)


def _present(value: object) -> str | None:
    """Trimmed text, or None when unset/blank — lines skip None."""
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _id_line(key: str, value: object, locale: str) -> str | None:
    """Legacy ``_id``: ``"{label} : {value}"``, or None when the value is blank."""
    text = _present(value)
    if text is None:
        return None
    return f"{label(key, locale)} : {text}"


def _company_lines(company: CompanyIdentity, locale: str) -> tuple[str, ...]:
    """Seller block in legacy order: bare address/wilaya, then labeled ids."""
    lines: list[str] = []
    for value in (company.address, company.wilaya):
        text = _present(value)
        if text is not None:
            lines.append(text)
    for key, value in (
        ("phone", company.phone),
        ("fiscal_email", company.email),
        ("fiscal_rc", company.rc),
        ("fiscal_nif", company.nif),
        ("fiscal_ai", company.ai),
        ("fiscal_nis", company.nis),
        ("fiscal_rib", company.rib),
    ):
        line = _id_line(key, value, locale)
        if line is not None:
            lines.append(line)
    return tuple(lines)


def _client_block(
    client: InvoiceClientRefResponse | None, locale: str
) -> IdentityBlock | None:
    """Client box in legacy order: bare address/wilaya, then Tél/RC/NIF/AI/NIS."""
    if client is None:
        return None
    lines: list[str] = []
    for value in (client.address, client.wilaya):
        text = _present(value)
        if text is not None:
            lines.append(text)
    for key, value in (
        ("phone", client.phone),
        ("fiscal_rc", client.rc),
        ("fiscal_nif", client.nif),
        ("fiscal_ai", client.ai),
        ("fiscal_nis", client.nis),
    ):
        line = _id_line(key, value, locale)
        if line is not None:
            lines.append(line)
    name = _present(client.name)
    return IdentityBlock(
        heading=label("customer", locale),
        name=name if name is not None else "",
        lines=tuple(lines),
    )


def _percent(value: Decimal | float | int | str) -> str:
    """Cell text for a rate: header carries the ``%``, cell stays a number.

    Legacy ``fmtQty(tva_rate)`` prints ``19`` / ``12.5`` — never
    ``format_percent``'s fixed ``19.00%``.
    """
    return format_qty(value)


def build_facture_document(
    document: InvoiceDocumentResponse,
    company: CompanyIdentity,
    *,
    locale: str,
) -> FactureData:
    """Payload → presentation model. Pure: no DB, no calculation, no I/O."""
    title_key = DOC_TITLE_KEYS.get(document.doc_type)
    title = label(title_key, locale) if title_key is not None else document.doc_type

    rows = tuple(
        FactureLineRow(
            index=str(index),
            description=line.description,
            qty=format_qty(line.quantity),
            unit_price=format_money(line.unit_price_ht),
            discount=_percent(line.discount_pct) if document.show_discount else None,
            tva_rate=_percent(line.tva_rate) if document.show_tva else None,
            total_ht=format_money(line.total_ht),
        )
        for index, line in enumerate(document.lines, start=1)
    )

    totals = document.totals
    timbre = None
    if document.show_timbre and totals.timbre > 0:
        timbre = format_money(totals.timbre)

    payment_method = None
    if document.show_payment_method:
        payment_key = PAYMENT_KEYS.get(document.payment_method)
        payment_method = (
            label(payment_key, locale)
            if payment_key is not None
            else document.payment_method
        )

    notes = _present(document.notes)
    name = _present(company.name)

    return FactureData(
        locale=locale,
        title=title,
        number=document.number,
        document_date=format_date(document.document_date),
        company=IdentityBlock(
            heading=None,
            name=name if name is not None else "",
            lines=_company_lines(company, locale),
        ),
        client=_client_block(document.client, locale),
        show_discount=document.show_discount,
        show_tva=document.show_tva,
        lines=rows,
        totals=FactureTotals(
            total_ht=format_money(totals.total_ht),
            total_tva=format_money(totals.total_tva) if document.show_tva else None,
            total_ttc=format_money(totals.total_ttc),
            timbre=timbre,
            net_a_payer=format_money(totals.net_a_payer),
        ),
        amount_in_words=document.amount_in_words if document.show_amount_words else None,
        payment_method=payment_method,
        notes=notes,
    )
