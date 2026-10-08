"""Facturation calculation domain (Phase 1 facturation, pure functions).

Authoritative money math for commercial documents (facture / devis /
proforma / bon). This is a faithful port of the WORKING reference
implementation ``factura_simple/backend/calc.py`` plus the validation
rules of ``factura_simple/backend/main.py`` — the source behaviour is
the parity contract and must not be "improved" in this module
(``tests/unit/test_facturation.py`` locks it, including a live parity
sweep against the reference file when it is present).

Scope / isolation (Phase 1 decisions)
-------------------------------------
* Facture line prices are HT (excl. tax); VAT is computed ONLY inside
  this domain. POS / sale totals never reach this module — existing
  sale behaviour (``products.vat_rate`` stays metadata) is untouched.
* Promotions / wholesale / selling-unit pricing are NOT used anywhere
  in facturation: a facture line carries its own snapshot
  ``qty / unit_price_ht / tva_rate / discount_pct`` (``description``
  belongs to the schema layer, not this module).
* No database, HTTP, FastAPI, SQLModel, Pydantic or Flutter imports.

Money rounding (source contract)
--------------------------------
* Every monetary result is ``Decimal`` quantized to ``0.01`` with
  ``ROUND_HALF_UP`` — never binary float, never builtin ``round()``.
  This CENTIME precision is the factura_simple behaviour and
  deliberately differs from the POS money quantum ``0.001``
  (``app/services/sale.py::_money`` / ``valuation.quantize_money``).
* Rounding ORDER is part of the contract. Per line::

      gross     = qty × unit_price_ht
      net_ht    = money(gross × (1 − discount_pct / 100))
      tva       = money(RAW net_ht × tva_rate / 100)   # NOT from the
                                                        # rounded net_ht
* Document totals SUM the already-rounded per-line values
  (``total_ttc = money(Σ net_ht + Σ tva)``) — never re-derive totals
  from unrounded intermediates.

Stamp duty (``stamp_duty``) — source rules, do not invent new ones
-------------------------------------------------------------------
Applied only when ``cash`` and ``apply_timbre`` are both true, where
callers derive ``cash = doc_type == "FAC" and payment_method == "cash"``
(main.py ``document_out`` / ``preview_document``):

* total_ttc <= 300        -> 0
* total_ttc <= 30_000     -> 1 % of total, rounded UP to whole dinars
* total_ttc <= 100_000    -> 1.5 %, rounded UP to whole dinars
* total_ttc > 100_000     -> 2 %, rounded UP to whole dinars
* any duty above the 300 free threshold is at least 5 DA

``apply_timbre`` mirrors the source ``show_timbre`` display option:
when it is False the duty is 0 **and is excluded from ``net_a_payer``**
(same as source ``compute_totals``). The rendering layer later decides
whether the value is SHOWN, but totals semantics stay exactly like
factura_simple.

Amount in words
---------------
French wording (70-79 ``soixante-dix``, 80 ``quatre-vingts``,
``cent`` pluralisation), ``dinars algériens`` / ``centimes``, closed by
the document-type phrase. Deterministic, Flutter-free. Unknown document
types fall back to the FAC phrase exactly like the source.

Validation boundary (here vs the future API/service layer)
----------------------------------------------------------
This module owns the PURE checks (no I/O, no client lookup):

* ``validate_doc_type`` / ``validate_payment_method`` — membership in
  {FAC, DEV, PRO, BC, BL} / {cash, transfer, cheque}.
* ``validate_line`` — qty > 0, unit_price_ht >= 0,
  0 <= discount_pct <= 100, tva_rate in {0, 9, 19}, finite decimals.
* ``validate_document_inputs`` — the above plus at least one line
  (source ``_validate_document_in`` minus the client-existence 404).

Left to the future service/API layer: client existence, number
allocation, persistence, and translating ``FacturationError`` into the
source's Arabic 422 payloads. Like the source (``compute_line`` never
validated; the preview endpoint skips invalid lines itself), the
calculation entry points are permissive — validation is explicit.

Types
-----
Pure dataclasses + ``Decimal`` + module constants. Literal constants
duplicated instead of importing ``app.models`` — same convention as
``promotion.py`` / ``wholesale.py`` (the domain layer never imports
models).
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_CEILING, ROUND_HALF_UP, Decimal, InvalidOperation

from app.domain.unit_conversions import to_decimal

# Centime precision — factura_simple parity (NOT the POS 0.001 quantum).
CENT = Decimal("0.01")
ZERO = Decimal("0")

# Source main.py: DOC_TYPES / PAYMENT_METHODS / TVA_RATES.
DOC_TYPE_FAC = "FAC"
DOC_TYPES: frozenset[str] = frozenset({"FAC", "DEV", "PRO", "BC", "BL"})

PAYMENT_METHOD_CASH = "cash"
PAYMENT_METHODS: frozenset[str] = frozenset({"cash", "transfer", "cheque"})

TVA_RATES: frozenset[Decimal] = frozenset({Decimal(0), Decimal(9), Decimal(19)})

# Source calc.py _DOC_PHRASES — exact wording, used by amount_in_words.
DOCUMENT_PHRASES: Mapping[str, str] = {
    DOC_TYPE_FAC: "la présente facture",
    "DEV": "le présent devis",
    "PRO": "la présente facture proforma",
    "BC": "le présent bon de commande",
    "BL": "le présent bon de livraison",
}


class FacturationError(ValueError):
    """Pure-domain validation error (future API layer maps it to 422)."""


@dataclass(frozen=True)
class FactureLine:
    """One facture line's calculation snapshot.

    ``description`` is deliberately absent: it is document content
    owned by the schema layer, not by money math.
    """

    qty: Decimal | int | float | str
    unit_price_ht: Decimal | int | float | str
    tva_rate: Decimal | int | float | str
    discount_pct: Decimal | int | float | str = ZERO


@dataclass(frozen=True)
class LineTotals:
    """Result of one line calculation.

    ``net_ht`` / ``tva`` are the parity-critical rounded values (same
    as source ``compute_line``). ``gross`` / ``discount_amount`` are
    rounded display values the source never consumed — document
    totals must keep summing ``net_ht`` / ``tva`` only.
    """

    gross: Decimal
    discount_amount: Decimal
    net_ht: Decimal
    tva: Decimal
    total_ttc: Decimal


@dataclass(frozen=True)
class DocumentTotals:
    """Grand totals, source key set of ``compute_totals``."""

    total_ht: Decimal
    total_tva: Decimal
    total_ttc: Decimal
    timbre: Decimal
    net_a_payer: Decimal

    def as_dict(self) -> dict[str, Decimal]:
        """Source ``compute_totals`` dict (key order preserved)."""
        return {
            "total_ht": self.total_ht,
            "total_tva": self.total_tva,
            "total_ttc": self.total_ttc,
            "timbre": self.timbre,
            "net_a_payer": self.net_a_payer,
        }


def money(value: Decimal | int | float | str) -> Decimal:
    """Quantize to centimes with ROUND_HALF_UP (source ``calc.money``)."""
    return to_decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


def calculate_line(line: FactureLine) -> LineTotals:
    """Calculate one facture line (source ``compute_line``, exact port).

    Permissive like the source: inputs are coerced but never validated
    — call ``validate_line`` first (documented validation boundary).

    Rounding order is contractual: ``tva`` derives from the RAW
    (un-rounded) net amount, then each result rounds independently.
    """
    gross_raw = to_decimal(line.qty) * to_decimal(line.unit_price_ht)
    net_raw = gross_raw * (1 - to_decimal(line.discount_pct) / 100)
    tva_raw = net_raw * to_decimal(line.tva_rate) / 100
    net_ht = money(net_raw)
    tva = money(tva_raw)
    return LineTotals(
        gross=money(gross_raw),
        discount_amount=money(gross_raw - net_raw),
        net_ht=net_ht,
        tva=tva,
        total_ttc=net_ht + tva,
    )


def stamp_duty(
    total_ttc: Decimal | int | float | str,
    cash: bool,
) -> Decimal:
    """Algerian stamp duty (source ``calc.stamp_duty``, exact port).

    Thresholds / rounding / minimum are the source rules — see the
    module docstring. ``cash`` is the caller-derived flag
    (FAC + cash payment); duty is 0 otherwise.
    """
    if not cash:
        return ZERO
    total = to_decimal(total_ttc)
    if total <= 300:
        return ZERO
    if total <= 30_000:
        rate = Decimal("1")
    elif total <= 100_000:
        rate = Decimal("1.5")
    else:
        rate = Decimal("2")
    duty = (total * rate / 100).quantize(Decimal("1"), rounding=ROUND_CEILING)
    return max(duty, Decimal("5"))


def calculate_totals(
    lines: Sequence[FactureLine],
    *,
    cash: bool = False,
    apply_timbre: bool = True,
) -> DocumentTotals:
    """Document totals (source ``compute_totals``, exact port).

    Sums the already-rounded per-line ``net_ht`` / ``tva`` values;
    stamp duty only when ``apply_timbre`` (the source ``show_timbre``
    option) and ``cash`` (FAC + cash payment) — both supplied by the
    caller, exactly like the source. Permissive core: empty input yields
    zero totals (source behaviour); use ``validate_document_inputs`` in
    the service layer to require >= 1 line.
    """
    total_ht = ZERO
    total_tva = ZERO
    for line in lines:
        per_line = calculate_line(line)
        total_ht += per_line.net_ht
        total_tva += per_line.tva
    total_ttc = money(total_ht + total_tva)
    timbre = stamp_duty(total_ttc, cash) if apply_timbre else ZERO
    return DocumentTotals(
        total_ht=money(total_ht),
        total_tva=money(total_tva),
        total_ttc=total_ttc,
        timbre=timbre,
        net_a_payer=money(total_ttc + timbre),
    )


def validate_doc_type(doc_type: str) -> str:
    """Reject anything outside the five source document types."""
    if doc_type not in DOC_TYPES:
        raise FacturationError(f"unsupported doc_type: {doc_type!r}")
    return doc_type


def validate_payment_method(payment_method: str) -> str:
    """Reject anything outside the three source payment methods."""
    if payment_method not in PAYMENT_METHODS:
        raise FacturationError(f"unsupported payment_method: {payment_method!r}")
    return payment_method


def validate_line(line: FactureLine) -> FactureLine:
    """Pure numeric validation of one line (source ``_validate_document_in``).

    Checks: all values finite decimals, ``tva_rate`` in {0, 9, 19},
    ``qty > 0``, ``unit_price_ht >= 0``, ``0 <= discount_pct <= 100``.
    Returns the line unchanged when valid.
    """
    try:
        qty = to_decimal(line.qty)
        price = to_decimal(line.unit_price_ht)
        tva = to_decimal(line.tva_rate)
        discount = to_decimal(line.discount_pct)
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise FacturationError(f"line value is not a valid decimal: {exc}") from exc
    if not all(v.is_finite() for v in (qty, price, tva, discount)):
        raise FacturationError("line values must be finite decimals")
    if tva not in TVA_RATES:
        raise FacturationError(f"tva_rate must be one of 0, 9, 19; got {tva}")
    if qty <= 0 or price < 0:
        raise FacturationError(
            f"qty must be > 0 and unit_price_ht >= 0; got qty={qty}, price={price}"
        )
    if not ZERO <= discount <= 100:
        raise FacturationError(f"discount_pct must be within 0..100; got {discount}")
    return line


def validate_document_inputs(
    doc_type: str,
    payment_method: str,
    lines: Sequence[FactureLine],
) -> None:
    """Document-level pure validation (source ``_validate_document_in``).

    Everything here is I/O-free. The source's client-existence 404 and
    the Arabic 422 message mapping belong to the future API/service
    layer — not duplicated here.
    """
    validate_doc_type(doc_type)
    validate_payment_method(payment_method)
    if not lines:
        raise FacturationError("a document needs at least one line")
    for line in lines:
        validate_line(line)


def calculate_document_totals(
    lines: Sequence[FactureLine],
    *,
    doc_type: str,
    payment_method: str,
    show_timbre: bool = True,
) -> DocumentTotals:
    """Validated totals for one facture (service-layer entry point).

    Derives the source cash flag (``FAC`` and ``cash`` payment) and maps
    the ``show_timbre`` display option onto ``apply_timbre`` — the same
    wiring main.py ``document_out`` / ``preview_document`` perform —
    after running the pure validation above.
    """
    validate_document_inputs(doc_type, payment_method, lines)
    cash = doc_type == DOC_TYPE_FAC and payment_method == PAYMENT_METHOD_CASH
    return calculate_totals(lines, cash=cash, apply_timbre=show_timbre)


# ------------------------- French amount in words -------------------------

_UNITS = [
    "zéro",
    "un",
    "deux",
    "trois",
    "quatre",
    "cinq",
    "six",
    "sept",
    "huit",
    "neuf",
    "dix",
    "onze",
    "douze",
    "treize",
    "quatorze",
    "quinze",
    "seize",
]
_TENS = {2: "vingt", 3: "trente", 4: "quarante", 5: "cinquante", 6: "soixante"}


def _below_100(n: int, final: bool = True) -> str:
    if n < 17:
        return _UNITS[n]
    if n < 20:
        return "dix-" + _UNITS[n - 10]
    if n < 70:
        t, u = divmod(n, 10)
        if u == 0:
            return _TENS[t]
        if u == 1:
            return _TENS[t] + " et un"
        return _TENS[t] + "-" + _UNITS[u]
    if n < 80:  # 70..79
        r = n - 60
        if r == 11:
            return "soixante et onze"
        return "soixante-" + _below_100(r)
    r = n - 80  # 80..99
    if r == 0:
        return "quatre-vingts" if final else "quatre-vingt"
    return "quatre-vingt-" + _below_100(r)


def _below_1000(n: int, final: bool = True) -> str:
    h, r = divmod(n, 100)
    if h == 0:
        return _below_100(r, final)
    text = "cent" if h == 1 else _UNITS[h] + " cent"
    if r == 0:
        if h > 1 and final:
            text += "s"
    else:
        text += " " + _below_100(r, final)
    return text


def number_to_words_fr(n: int) -> str:
    """French integer wording (source ``calc.number_to_words_fr``, exact).

    Contract: ``n`` is a non-negative int (amounts are validated >= 0
    upstream, exactly like the source).
    """
    if n == 0:
        return "zéro"
    parts: list[str] = []
    millions, rest = divmod(n, 1_000_000)
    thousands, units = divmod(rest, 1000)
    if millions:
        parts.append(number_to_words_fr(millions) + (" million" if millions == 1 else " millions"))
    if thousands:
        parts.append("mille" if thousands == 1 else _below_1000(thousands, final=False) + " mille")
    if units:
        parts.append(_below_1000(units, final=True))
    return " ".join(parts)


def amount_in_words(
    amount: Decimal | int | float | str,
    doc_type: str = DOC_TYPE_FAC,
) -> str:
    """Closed amount sentence (source ``calc.amount_in_words``, exact).

    Always French — fiscal document content is never localized. An
    unknown ``doc_type`` falls back to the FAC phrase (source
    behaviour; ``validate_doc_type`` rejects it upstream instead).
    """
    total = money(amount)
    dinars = int(total)
    centimes = int((total - dinars) * 100)
    words = number_to_words_fr(dinars)
    text = f"{words} dinar{'s' if dinars > 1 else ''} algérien{'s' if dinars > 1 else ''}"
    if centimes:
        text += f" et {number_to_words_fr(centimes)} centime{'s' if centimes > 1 else ''}"
    text = text[0].upper() + text[1:]
    phrase = DOCUMENT_PHRASES.get(doc_type, DOCUMENT_PHRASES[DOC_TYPE_FAC])
    return f"Arrêté {phrase} à la somme de : {text}."
