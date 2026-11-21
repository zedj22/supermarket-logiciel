"""DocumentData view-models + builders (Phase 15 §4.5, §8.5, G8).

Direction: response payloads → `DocumentData` → template (zero business
logic in templates). All derived values (line kinds, base quantities,
discount sums, localized labels, formatted money) are computed ONCE here
and unit-tested here. Builders never touch the DB — optional display
names come in as parameters (G19 additive payload fields on sales).

Customer-facing policy (Phase 17 §15.7)
---------------------------------------
`build_sale_document` is the ONLY customer-facing builder.  It marks the
result `customer_facing=True` and strips presentation-only fields that a
shopper has no business seeing, while every underlying store/API/audit
value stays untouched:

* ``LineItem.sku`` / ``LineItem.barcode``  → identifiers, never printed;
* ``HeaderBlock.device_id``                → LAN/idempotency identity;
* ``DocumentData.cashier_name``            → kept in the sale + audit log;
* ``DocumentData.customer``                → ``None`` for an anonymous cash
  sale (no localized "Cash customer" placeholder posing as a person); a
  REAL attached customer keeps their name;
* ``HeaderBlock.occurred_date``/``_time``  → one authoritative timestamp
  (`sale.sale_date`) split for display, never a second source.

Returns, purchases and reports keep the identifiers, the cashier line and
the device id — they are internal/supplier documents, not receipts.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Literal

from app.core.config import settings
from app.printing.labels import label
from app.printing.text import (
    format_date,
    format_datetime,
    format_money,
    format_qty,
    format_receipt_stamp,
    format_time,
)
from app.schemas.purchase import PurchaseResponse
from app.schemas.returns import ReturnResponse
from app.schemas.sale import SaleResponse

LineKind = Literal["product", "pack_summary", "pack_component"]

_PAYMENT_KEYS = ("cash", "card", "partial", "credit")


def _dec(value: object) -> Decimal:
    if isinstance(value, Decimal):
        return value
    if value is None:
        return Decimal("0")
    return Decimal(str(value))


def _status_label(status: str, locale: str) -> str:
    key = f"status_{status}"
    if status in ("draft", "received", "cancelled"):
        key = f"purchase_status_{status}"
    text = label(key, locale)
    return text if text != key else status


def _method_label(method: str, locale: str) -> str:
    if method in _PAYMENT_KEYS:
        return label(f"label_{method}", locale)
    return method


def _present(value: object) -> str | None:
    """Trimmed, or None when the field is unset — templates test for None."""
    if value is None:
        return None
    text = str(value).strip()
    return text or None


@dataclass
class StoreBlock:
    name: str
    #: Receipt contact block (Phase 17 §17.6, Phase 15 G19/Q3).  Optional so
    #: an install that has never opened Settings renders byte-identically.
    phone: str | None = None
    address: str | None = None
    #: Printed under the totals — the configured invoice footer text.
    footer: str | None = None


@dataclass
class HeaderBlock:
    document_number: str
    document_title: str
    occurred_at: str
    status_label: str | None
    #: Split view of the SAME timestamp as `occurred_at` (§15.7).  Only the
    #: customer sale builder fills them; every other document keeps the
    #: single combined `occurred_at` row it has always printed.
    occurred_date: str | None = None
    occurred_time: str | None = None
    is_void: bool = False
    voided_at: str | None = None
    void_reason: str | None = None
    device_id: str | None = None
    source_invoice: str | None = None
    supplier_name: str | None = None


@dataclass
class PartyBlock:
    label_key: str
    name: str | None


@dataclass
class LineItem:
    """Normalized receipt line (Phase 17 item contract).

    Every sale/return/purchase line is flattened into this shape before any
    template sees it, so all renderers show the same fields in the same
    order: ``name`` (never optional), ``sku``/``barcode`` metadata,
    ``qty`` + ``unit_label``, ``unit_price``, ``line_total``.  Missing
    optional fields only remove their own row — they never shift the
    columns another field sits in.
    """

    kind: LineKind
    name: str
    unit_label: str
    qty: str
    unit_price: str
    line_total: str
    variant: str | None = None
    sku: str | None = None
    barcode: str | None = None
    base_qty: str | None = None
    line_discount: str | None = None
    show_money: bool = True


@dataclass
class TotalsBlock:
    subtotal: str
    total: str
    line_discounts_sum: str | None = None
    invoice_discount: str | None = None
    paid: str | None = None
    change: str | None = None
    debt: str | None = None
    payment_method: str | None = None
    # Phase E loyalty (additive; None = pre-loyalty / facturation sale —
    # the renderer drops None rows, so their row set is untouched).
    loyalty_redeemed: str | None = None
    amount_due: str | None = None
    loyalty_points_earned: str | None = None
    loyalty_cashback_earned: str | None = None


@dataclass
class PaymentLine:
    method_label: str
    amount: str


@dataclass
class ReceiptSummary:
    """Thermal-receipt header/summary values (80mm customer sale only).

    A dedicated block instead of new ``HeaderBlock``/``TotalsBlock`` fields:
    those two are shared with the A4 invoice and with internal return /
    purchase documents, and their output must not move.  Populated ONLY by
    `build_sale_document`, so its presence is what routes a document to the
    redesigned thermal receipt (``data.receipt is not None``).

    Every value is a display string already produced by the formatting
    helpers — zero business logic downstream.  ``total_discount`` is the
    SUM of the line discounts and the invoice discount, formatted once, so
    a receipt can never charge the same discount twice.  ``cash_payment    ``records whether any money arrived in cash; a card-only sale must not
    print a cash ``Change`` row.  ``total_qty`` counts physical pieces,
    including pack components (never the pack summary row itself).
    """

    stamp: str | None = None
    cashier: str | None = None
    article_count: int = 0
    total_qty: str | None = None
    qty_unit: str | None = None
    total_discount: str | None = None
    cash_payment: bool = True
    reference: str | None = None


@dataclass
class MetaBlock:
    locale: str
    generated_at: str
    note: str | None = None


@dataclass
class DocumentData:
    store: StoreBlock
    header: HeaderBlock
    customer: PartyBlock | None
    supplier: PartyBlock | None
    cashier_name: str | None
    lines: list[LineItem] = field(default_factory=list)
    totals: TotalsBlock | None = None
    payments: list[PaymentLine] = field(default_factory=list)
    meta: MetaBlock | None = None
    #: True only for the customer sale receipt/invoice.  Templates key
    #: presentation-only omissions (SKU column, identifier rows) off this;
    #: return/purchase/report documents stay internal and keep them.
    customer_facing: bool = False
    #: Thermal-receipt block — set by `build_sale_document` only.
    receipt: ReceiptSummary | None = None

    @property
    def rtl(self) -> bool:
        return self.meta is not None and self.meta.locale == "ar"


@dataclass
class DocumentNames:
    """Display names not carried by the payload (returns/purchases)."""

    customer: str | None = None
    cashier: str | None = None


def _line_kind(line) -> LineKind:  # noqa: ANN001 - sale/return line schema
    if line.pack_id is None:
        return "product"
    if line.product_id is None:
        return "pack_summary"
    return "pack_component"


def _base_qty(line) -> str | None:
    if line.selling_unit_multiplier is None:
        return None
    return format_qty(_dec(line.quantity) * _dec(line.selling_unit_multiplier))


def _unit_label(line) -> str:
    if line.selling_unit_name:
        return line.selling_unit_name
    return line.product_unit


def _line_name(line, *, with_marker: bool = False, locale: str = "") -> str:
    name = line.product_name
    # Purchase lines snapshot the variant id but not its name.
    variant = getattr(line, "variant_name", None)
    if variant:
        name = f"{name} ({variant})"
    if with_marker:
        name = f"{name} {label('pack_marker', locale)}"
    return name


def _customer_block(
    customer_id,
    customer_name,
    locale,
    *,
    anonymous_placeholder: bool = True,
) -> PartyBlock | None:
    """Party block for a document; `None` means "print no customer row".

    `anonymous_placeholder` exists only for INTERNAL documents: returns and
    reports keep printing the localized "Cash customer" line so their row
    set does not change.  The customer sale invoice passes
    `anonymous_placeholder=False` (§15.7 A3) — an anonymous cash sale must
    not invent a person on the shopper's receipt.  A REAL attached customer
    keeps their name either way.
    """
    if customer_id is None:
        if not anonymous_placeholder:
            return None
        return PartyBlock(label_key="customer", name=label("cash_customer", locale))
    if customer_name:
        return PartyBlock(label_key="customer", name=customer_name)
    return None  # known id, unknown name → omit (§7.2 step 3)


def _store_field(source: object, key: str) -> object:
    """Read one identity field from a schema model or its dict form."""
    if isinstance(source, dict):
        return source.get(key)
    return getattr(source, key, None)


def _store_block(payload_store=None) -> StoreBlock:
    if payload_store is None:
        return StoreBlock(name=settings.STORE_NAME)
    return StoreBlock(
        name=_present(_store_field(payload_store, "name")) or settings.STORE_NAME,
        phone=_present(_store_field(payload_store, "phone")),
        address=_present(_store_field(payload_store, "address")),
        footer=_present(_store_field(payload_store, "footer")),
    )


def _meta(locale: str, note: str | None, generated_at: datetime | None) -> MetaBlock:
    stamp = generated_at or datetime.utcnow()
    return MetaBlock(locale=locale, generated_at=format_datetime(stamp), note=note)


def build_sale_document(
    sale: SaleResponse,
    *,
    locale: str,
    generated_at: datetime | None = None,
) -> DocumentData:
    """Customer-facing sale receipt/invoice (§15.7).

    Presentation-only stripping — the sale row itself, the API payload and
    the audit trail all keep their SKU, barcode, device id and cashier:
    a receipt shows WHAT was bought, not which till scanned it.
    """
    lines = [
        LineItem(
            kind=kind,
            name=_line_name(line, with_marker=kind == "pack_summary", locale=locale),
            variant=line.variant_name,
            sku=None,  # A1 — identifiers are never printed on a customer receipt
            barcode=None,  # A2
            unit_label=_unit_label(line),
            qty=format_qty(line.quantity),
            base_qty=_base_qty(line),
            unit_price=format_money(line.unit_price),
            line_discount=format_money(line.line_discount)
            if _dec(line.line_discount) != 0
            else None,
            line_total=format_money(line.line_total),
            show_money=kind != "pack_component",
        )
        for line in sale.lines
        for kind in [_line_kind(line)]
    ]

    discount_sum = sum((_dec(ln.line_discount) for ln in sale.lines), Decimal("0"))
    invoice_discount = _dec(sale.discount)
    # Phase E loyalty summary — every value comes from the sale response
    # (server-computed); a missing/zero field renders no row at all.
    redeemed_value = getattr(sale, "loyalty_redeemed_value", None)
    amount_due = getattr(sale, "amount_due", None)
    points_earned = getattr(sale, "loyalty_points_earned", None)
    cashback_earned = getattr(sale, "loyalty_cashback_earned", None)
    totals = TotalsBlock(
        subtotal=format_money(sale.subtotal),
        total=format_money(sale.total),
        line_discounts_sum=format_money(discount_sum) if discount_sum != 0 else None,
        invoice_discount=format_money(invoice_discount) if invoice_discount != 0 else None,
        paid=format_money(sale.paid),
        change=format_money(sale.change),
        debt=format_money(sale.debt) if _dec(sale.debt) > 0 else None,
        payment_method=_method_label(sale.payment_method, locale),
        loyalty_redeemed=format_money(_dec(redeemed_value))
        if redeemed_value is not None and _dec(redeemed_value) != 0
        else None,
        amount_due=format_money(_dec(amount_due)) if amount_due is not None else None,
        loyalty_points_earned=format_qty(_dec(points_earned))
        if points_earned is not None and _dec(points_earned) != 0
        else None,
        loyalty_cashback_earned=format_money(_dec(cashback_earned))
        if cashback_earned is not None and _dec(cashback_earned) != 0
        else None,
    )

    payments = [
        PaymentLine(method_label=_method_label(p.method, locale), amount=format_money(p.amount))
        for p in sale.payments
    ]

    # Receipt summary (80mm thermal layout).  Pure display aggregation of
    # values the sale response already carries: no total is recomputed from
    # rounded text, and discounts are added up exactly once.
    top_level = [line for line in sale.lines if _line_kind(line) != "pack_component"]
    article_count = len({line.product_name for line in top_level})
    # Physical pieces: every regular line contributes its sold quantity
    # (× its selling-unit multiplier), and every pack COMPONENT line its
    # own quantity — the component rows already store `per_pack × packs`.
    # The pack summary line is skipped: counting it as well would charge
    # the pack itself on top of its components.
    pieces = Decimal("0")
    for line in sale.lines:
        if _line_kind(line) == "pack_summary":
            continue
        multiplier = line.selling_unit_multiplier
        pieces += _dec(line.quantity) * (
            _dec(multiplier) if multiplier is not None else Decimal("1")
        )
    discount_total = discount_sum + invoice_discount
    # Any cash tendered means a change row is meaningful; a card-only or
    # credit sale must never display cash change.
    cash_payment = any(p.method == "cash" for p in sale.payments) or (
        not sale.payments and sale.payment_method == "cash"
    )
    receipt = ReceiptSummary(
        stamp=format_receipt_stamp(sale.sale_date),
        # §15.7 A4 keeps `cashier_name` off the A4 invoice; the thermal
        # receipt names the operator who took the money (same sale field).
        cashier=getattr(sale, "cashier_name", None),
        article_count=article_count,
        total_qty=format_qty(pieces) if pieces != 0 else None,
        qty_unit=label("receipt_units_pcs", locale),
        total_discount=format_money(discount_total) if discount_total != 0 else None,
        cash_payment=cash_payment,
        reference=sale.invoice_number,
    )

    is_void = sale.status == "void"
    header = HeaderBlock(
        document_number=sale.invoice_number,
        document_title=label("doc_invoice", locale),
        occurred_at=format_datetime(sale.sale_date),
        # A6 — one authoritative timestamp (sale.sale_date), split for
        # display only; EN/FR/AR share the app's existing YYYY-MM-DD / HH:MM.
        occurred_date=format_date(sale.sale_date),
        occurred_time=format_time(sale.sale_date),
        status_label=_status_label(sale.status, locale),
        is_void=is_void,
        voided_at=format_datetime(sale.voided_at) if is_void and sale.voided_at else None,
        void_reason=sale.void_reason if is_void else None,
        device_id=None,  # A5 — LAN/idempotency identity, never printed
    )

    return DocumentData(
        store=_store_block(getattr(sale, "store", None)),
        header=header,
        # A3 — no localized "Cash customer" placeholder on a receipt; a real
        # attached customer keeps their name.
        customer=_customer_block(
            sale.customer_id,
            getattr(sale, "customer_name", None),
            locale,
            anonymous_placeholder=False,
        ),
        supplier=None,
        cashier_name=None,  # A4 — audit only, never printed on the receipt
        lines=lines,
        totals=totals,
        payments=payments,
        meta=_meta(locale, sale.note, generated_at),
        customer_facing=True,
        receipt=receipt,
    )


def build_return_document(
    ret: ReturnResponse,
    *,
    locale: str,
    names: DocumentNames | None = None,
    generated_at: datetime | None = None,
) -> DocumentData:
    names = names or DocumentNames()
    lines = [
        LineItem(
            kind=kind,
            name=_line_name(line, with_marker=kind == "pack_summary", locale=locale),
            variant=line.variant_name,
            sku=line.product_sku,
            barcode=line.product_barcode,
            unit_label=_unit_label(line),
            qty=format_qty(line.quantity),
            base_qty=_base_qty(line),
            unit_price=format_money(line.unit_price),
            line_discount=format_money(line.line_discount)
            if _dec(line.line_discount) != 0
            else None,
            line_total=format_money(line.line_total),
            show_money=kind != "pack_component",
        )
        for line in ret.lines
        for kind in [_line_kind(line)]
    ]

    discount_sum = sum((_dec(ln.line_discount) for ln in ret.lines), Decimal("0"))
    invoice_discount = _dec(ret.discount)
    totals = TotalsBlock(
        subtotal=format_money(ret.subtotal),
        total=format_money(ret.total),
        line_discounts_sum=format_money(discount_sum) if discount_sum != 0 else None,
        invoice_discount=format_money(invoice_discount) if invoice_discount != 0 else None,
    )

    header = HeaderBlock(
        document_number=ret.return_number,
        document_title=label("doc_return", locale),
        occurred_at=format_datetime(ret.return_date),
        status_label=None,
        void_reason=ret.reason,
        device_id=ret.device_id,
        source_invoice=ret.invoice_number,
    )

    return DocumentData(
        store=_store_block(None),
        header=header,
        customer=_customer_block(ret.customer_id, names.customer, locale),
        supplier=None,
        cashier_name=names.cashier,
        lines=lines,
        totals=totals,
        payments=[],
        meta=_meta(locale, ret.note, generated_at),
    )


def build_purchase_document(
    purchase: PurchaseResponse,
    *,
    locale: str,
    names: DocumentNames | None = None,
    generated_at: datetime | None = None,
) -> DocumentData:
    names = names or DocumentNames()
    lines = [
        LineItem(
            kind="product",
            name=_line_name(line, locale=locale),
            variant=None,
            sku=line.product_sku,
            barcode=line.product_barcode,
            unit_label=line.purchase_unit_name or line.product_unit,
            qty=format_qty(line.quantity),
            base_qty=format_qty(line.base_qty_equivalent)
            if line.base_qty_equivalent is not None
            else None,
            unit_price=format_money(line.unit_cost),
            line_discount=None,
            line_total=format_money(line.line_total),
            show_money=True,
        )
        for line in purchase.lines
    ]

    discount = _dec(purchase.discount)
    totals = TotalsBlock(
        subtotal=format_money(purchase.subtotal),
        total=format_money(purchase.total),
        invoice_discount=format_money(discount) if discount != 0 else None,
        paid=format_money(purchase.paid),
    )

    header = HeaderBlock(
        document_number=purchase.invoice_number,
        document_title=label("doc_purchase", locale),
        occurred_at=format_datetime(purchase.purchase_date),
        status_label=_status_label(purchase.status, locale),
        device_id=purchase.device_id,
        supplier_name=purchase.supplier_name,
    )

    return DocumentData(
        store=_store_block(None),
        header=header,
        customer=None,
        supplier=PartyBlock(label_key="supplier", name=purchase.supplier_name),
        cashier_name=names.cashier,
        lines=lines,
        totals=totals,
        payments=[],
        meta=_meta(locale, purchase.note, generated_at),
    )


def line_discounts_consistency(data: DocumentData, sale: SaleResponse) -> bool:
    """`Σ line_discount == subtotal − invoice_discount − total` (§19.1)."""
    derived = sum((_dec(ln.line_discount) for ln in sale.lines), Decimal("0"))
    expected = _dec(sale.subtotal) - _dec(sale.discount) - _dec(sale.total)
    return derived == expected


def document_entity_id(value: uuid.UUID) -> str:
    return str(value)
