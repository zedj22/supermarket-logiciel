"""Product import / export service (Objective 1).

One module owns both directions so an exported file is guaranteed to be
a file this importer understands.

**Export** — CSV (UTF-8 with BOM so Excel opens Arabic correctly) or
XLSX (openpyxl, already a project dependency for report exports). The
scope of the run (``all`` / ``filtered`` / ``selected``) is echoed back
to the caller and recorded in the audit row, so the operator always
knows whether a file holds the whole catalogue or only the filtered
subset. Nothing secret is ever written: no tokens, no password hashes,
no session data — the columns are exactly ``EXPORT_FIELDS``.

**Import** — the same columns, parsed strictly, validated against the
same Pydantic schemas and the same services the API uses
(``ProductCreateRequest`` / ``ProductUpdateRequest`` /
``ProductService``), so an imported file cannot bypass a business rule
or an authorization check. The run is two-staged: a **dry run** plans
every row (parse, validate, match against the database, detect in-file
duplicates) and returns a preview; only an explicit apply call
executes, and even then every row outcome is reported with its row
number. Stock is never touched: ``current_stock`` is exported as
information and *ignored* on import — quantities move exclusively
through the inventory ledger (``POST /api/v1/inventory/adjust``).

File-level failures (unsupported format, macro workbook, bad encoding,
missing required column, size/row caps) raise before any row is
written; row-level failures are reported and do not roll back the rows
that succeeded, because a partial result is always fully reported.
"""

from __future__ import annotations

import codecs
import csv
import io
import json
import re
import unicodedata
import uuid
import zipfile
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

import structlog
from openpyxl import Workbook, load_workbook  # type: ignore[import-untyped]
from pydantic import ValidationError as PydanticValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.exceptions import AppError, ForbiddenError, ValidationError
from app.core.filenames import sanitize_filename
from app.models.audit import AuditLog
from app.models.catalog import Category, Product
from app.models.enums import AuditAction, AuditModule
from app.repositories.catalog import ProductRepository
from app.schemas.catalog import ProductCreateRequest, ProductUpdateRequest
from app.schemas.product_transfer import (
    EXPORT_FIELDS,
    IMPORTABLE_FIELDS,
    INFORMATIONAL_FIELDS,
    MAX_EXPORT_ROWS,
    MAX_IMPORT_BYTES,
    MAX_IMPORT_ROWS,
    MAX_REPORT_ROWS,
    ExportFormat,
    ImportReport,
    ImportRow,
    OnConflict,
    ProductExportRequest,
)
from app.services.base import BaseService
from app.services.catalog import ProductService

logger = structlog.get_logger(__name__)

#: Page size used to walk the catalogue for an export (same idea as the
#: report export walker, but bounded by ``MAX_EXPORT_ROWS``).
_WALK_PAGE_SIZE = 1_000
#: Chunk for ``IN`` lookups — keeps every dialect's bound-parameter limit
#: far away (SQLite's is the smallest one we run on).
_ID_CHUNK = 500

_CSV_MEDIA_TYPE = "text/csv"
_XLSX_MEDIA_TYPE = (
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
)

#: Characters that turn a plain cell into a spreadsheet formula when the
#: file is opened in Excel/LibreOffice. Exported text cells starting
#: with one of them are prefixed with an apostrophe; the importer strips
#: exactly that prefix back, so the round-trip is lossless and no
#: imported/exported formula is ever evaluated (§Objective 5).
_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")

# ---------------------------------------------------------------------------
# Header vocabulary (auto column matching, en / fr / ar)
# ---------------------------------------------------------------------------


def _normalize_key(value: Any) -> str:
    """Fold a header cell to its match key: lower-case, accent-free,
    separators collapsed, Arabic letters preserved (their own script is
    their key — an Arabic header never becomes mojibake here)."""
    text = unicodedata.normalize("NFKD", str(value))
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.strip().lower()
    text = re.sub(r"[^0-9a-z\u0600-\u06ff]+", "_", text)
    return text.strip("_")


#: target field -> accepted header spellings (normalized on lookup).
_FIELD_ALIASES: dict[str, tuple[str, ...]] = {
    "product_id": (
        "product_id", "id", "uuid", "product_uuid", "productid",
        "identifiant", "identifiant_produit",
        "\u0645\u0639\u0631\u0641_\u0627\u0644\u0645\u0646\u062a\u062c",
        "\u0631\u0642\u0645_\u0627\u0644\u0645\u0646\u062a\u062c", "\u0631\u0642\u0645",
    ),
    "name": (
        "name", "nom", "product_name", "produit", "designation",
        "libelle", "libelle_produit", "title",
        "\u0627\u0644\u0627\u0633\u0645", "\u0627\u0633\u0645_\u0627\u0644\u0645\u0646\u062a\u062c",
        "\u0627\u0633\u0645", "\u0627\u0644\u0645\u0646\u062a\u062c", "\u062a\u0633\u0645\u064a\u0629",
    ),
    "barcode": (
        "barcode", "code_barre", "codebarre", "code", "ean", "ean13",
        "upc", "article_code",
        "\u0627\u0644\u0628\u0627\u0631\u0643\u0648\u062f", "\u0628\u0627\u0631\u0643\u0648\u062f",
        "\u0631\u0645\u0632_\u0627\u0644\u0645\u0646\u062a\u062c", "\u0631\u0645\u0632",
        "\u0627\u0644\u0631\u0645\u0632",
    ),
    "sku": (
        "sku", "ref", "reference", "referencia", "supplier_ref",
        "\u0627\u0644\u0645\u0631\u062c\u0639", "\u0645\u0631\u062c\u0639", "\u0645\u0631\u062c\u0639\u064a",
    ),
    "category": (
        "category", "categorie", "cat", "famille", "family",
        "product_category",
        "\u0627\u0644\u0641\u0626\u0629", "\u0627\u0644\u062a\u0635\u0646\u064a\u0641",
        "\u0641\u0626\u0629", "\u062a\u0635\u0646\u064a\u0641",
    ),
    "unit": (
        "unit", "unite", "unit_type", "uom", "measure",
        "\u0627\u0644\u0648\u062d\u062f\u0629", "\u0648\u062d\u062f\u0629",
        "\u0648\u062d\u062f\u0629_\u0627\u0644\u0642\u064a\u0627\u0633",
    ),
    "sale_price": (
        "sale_price", "price", "prix", "prix_vente", "selling_price",
        "prix_de_vente", "retail_price",
        "\u0633\u0639\u0631_\u0627\u0644\u0628\u064a\u0639", "\u0627\u0644\u0633\u0639\u0631",
        "\u0633\u0639\u0631", "\u0633\u0639\u0631_\u0627\u0644\u062a\u062c\u0632\u064a\u0629",
    ),
    "purchase_price": (
        "purchase_price", "cost", "prix_achat", "buying_price",
        "prix_d_achat", "achat",
        "\u0633\u0639\u0631_\u0627\u0644\u0634\u0631\u0627\u0621",
        "\u0627\u0644\u062a\u0643\u0644\u0641\u0629", "\u062a\u0643\u0644\u0641\u0629",
    ),
    "wholesale_price": (
        "wholesale_price", "prix_gros", "wholesale", "gross_price",
        "\u0633\u0639\u0631_\u0627\u0644\u062c\u0645\u0644\u0629",
        "\u0627\u0644\u062c\u0645\u0644\u0629", "\u0633\u0639\u0631_\u0628\u0627\u0644\u062c\u0645\u0644\u0629",
    ),
    "wholesale_min_qty": (
        "wholesale_min_qty", "min_wholesale_qty", "qty_min_gros",
        "wholesale_threshold",
        "\u0627\u0644\u062d\u062f_\u0627\u0644\u0623\u062f\u0646\u0649_\u0644\u0644\u062c\u0645\u0644\u0629",
        "\u062d\u062f_\u0627\u0644\u062c\u0645\u0644\u0629",
    ),
    "vat_rate": (
        "vat_rate", "vat", "tva", "tax_rate", "taxe", "tax",
        "\u0627\u0644\u0636\u0631\u064a\u0628\u0629", "\u0636\u0631\u064a\u0628\u0629",
        "\u0646\u0633\u0628\u0629_\u0627\u0644\u0636\u0631\u064a\u0628\u0629",
    ),
    "low_stock_threshold": (
        "low_stock_threshold", "threshold", "seuil", "alert_threshold",
        "stock_alert", "reorder_point",
        "\u062d\u062f_\u0627\u0644\u062a\u0646\u0628\u064a\u0647",
        "\u062d\u062f_\u0627\u0644\u0645\u062e\u0632\u0648\u0646_\u0627\u0644\u0645\u0646\u062e\u0641\u0636",
    ),
    "allow_negative_stock": (
        "allow_negative_stock", "negative_stock", "stock_negatif",
        "\u0627\u0644\u0633\u0645\u0627\u062d_\u0628\u0627\u0644\u0633\u0627\u0644\u0628",
        "\u0645\u062e\u0632\u0648\u0646_\u0633\u0627\u0644\u0628",
    ),
    "expiry_date": (
        "expiry_date", "expiry", "expiration", "date_expiration",
        "date_peremption", "best_before", "dlc",
        "\u062a\u0627\u0631\u064a\u062e_\u0627\u0644\u0635\u0644\u0627\u062d\u064a\u0629",
        "\u0627\u0644\u0635\u0644\u0627\u062d\u064a\u0629",
        "\u062a\u0627\u0631\u064a\u062e_\u0627\u0646\u062a\u0647\u0627\u0621_\u0627\u0644\u0635\u0644\u0627\u062d\u064a\u0629",
    ),
    "description": (
        "description", "desc", "details", "detail", "notes",
        "\u0627\u0644\u0648\u0635\u0641", "\u0648\u0635\u0641", "\u062a\u0641\u0627\u0635\u064a\u0631",
    ),
    "image_path": (
        "image_path", "image", "photo", "picture", "chemin_image",
        "\u0627\u0644\u0635\u0648\u0631\u0629", "\u0635\u0648\u0631\u0629",
        "\u0645\u0633\u0627\u0631_\u0627\u0644\u0635\u0648\u0631\u0629",
    ),
    "is_active": (
        "is_active", "active", "status", "etat", "actif", "enabled",
        "\u0627\u0644\u062d\u0627\u0644\u0629", "\u062d\u0627\u0644\u0629", "\u0646\u0634\u0637",
    ),
    "current_stock": (
        "current_stock", "stock", "quantity", "qty", "stock_quantity",
        "qte", "quantite", "on_hand",
        "\u0627\u0644\u0643\u0645\u064a\u0629", "\u0627\u0644\u0645\u062e\u0632\u0648\u0646",
        "\u0627\u0644\u0643\u0645\u064a\u0629_\u0627\u0644\u062d\u0627\u0644\u064a\u0629", "\u0631\u0635\u064a\u062f",
    ),
}

#: Columns recognised only to be reported as "informational, ignored"
#: (derived or audit columns that no import will ever write).
_IGNORED_ONLY_FIELDS: dict[str, tuple[str, ...]] = {
    "avg_cost": ("avg_cost", "pmp", "average_cost", "\u0645\u062a\u0648\u0633\u0637_\u0627\u0644\u062a\u0643\u0644\u0641\u0629"),
    "created_at": ("created_at", "date_created", "\u062a\u0627\u0631\u064a\u062e_\u0627\u0644\u0625\u0646\u0634\u0627\u0621"),
    "updated_at": ("updated_at", "date_updated", "\u062a\u0627\u0631\u064a\u062e_\u0627\u0644\u062a\u062d\u062f\u064a\u062b"),
}

#: File field -> the Pydantic field it feeds (error messages speak the
#: file's language, the schema speaks its own).
_CREATE_FIELD_MAP: dict[str, str] = {
    "name": "name",
    "barcode": "barcode",
    "sku": "sku",
    "description": "description",
    "unit": "unit",
    "sale_price": "price",
    "purchase_price": "cost",
    "low_stock_threshold": "low_stock_threshold",
    "allow_negative_stock": "allow_negative_stock",
    "wholesale_price": "wholesale_price",
    "wholesale_min_qty": "wholesale_min_qty",
    "vat_rate": "vat_rate",
    "expiry_date": "expiry_date",
    "image_path": "image_path",
    "category": "category_id",
}
_UPDATE_FIELD_MAP: dict[str, str] = dict(_CREATE_FIELD_MAP)
_SCHEMA_TO_FILE_FIELD: dict[str, str] = {
    schema: file_field for file_field, schema in _CREATE_FIELD_MAP.items()
}
#: Fields that never write stock or history (Objective 5 guard rail).
_NEVER_ON_IMPORT: frozenset[str] = frozenset(
    {"quantity", "current_stock", "avg_cost"}
)

#: Fields required for a *create* row (update rows may be partial).
_REQUIRED_ON_CREATE: tuple[str, ...] = ("name", "sale_price")


# ---------------------------------------------------------------------------
# Cell parsing helpers
# ---------------------------------------------------------------------------

_ARABIC_DIGITS = str.maketrans(
    "\u0660\u0661\u0662\u0663\u0664\u0665\u0666\u0667\u0668\u0669"
    "\u06f0\u06f1\u06f2\u06f3\u06f4\u06f5\u06f6\u06f7\u06f8\u06f9",
    "01234567890123456789",
)

_TRUE_WORDS = frozenset({
    "true", "1", "yes", "y", "oui", "vrai", "on", "x",
    "\u0646\u0639\u0645", "\u0646\u0639\u0645\u0627", "\u0635\u062d",
})
_FALSE_WORDS = frozenset({
    "false", "0", "no", "n", "non", "faux", "off",
    "\u0644\u0627", "\u0643\u0630\u0628", "\u063a\u064a\u0631",
})


def _cell_to_raw(value: Any) -> str:
    """Normalise one parsed cell (CSV string or XLSX value) to text."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if value.is_integer():
            return str(int(value))
        return _format_decimal(Decimal(str(value)))
    if isinstance(value, Decimal):
        return _format_decimal(value)
    return str(value)


def _format_decimal(value: Decimal) -> str:
    """Plain, exponent-free text (``1E+2`` never reaches a spreadsheet)."""
    return format(value.normalize(), "f")


def parse_decimal(raw: str) -> Decimal | None:
    """Parse a money/quantity cell.

    Blank means "not provided". Both decimal conventions work: ``12.34``
    and ``12,34`` (``1.234,56`` / ``1,234.56`` too — the right-most
    separator wins). Exported files never carry thousands separators, so
    the round-trip is unaffected by the ambiguity.
    """
    text = raw.replace("\u00a0", " ").replace("\u202f", " ").strip()
    text = text.translate(_ARABIC_DIGITS)
    if not text:
        return None
    negative = False
    if text.startswith("(") and text.endswith(")"):
        negative = True
        text = text[1:-1]
    if text[:1] in "+-":
        negative = text[0] == "-" or negative
        text = text[1:]
    if "," in text and "." in text:
        if text.rfind(",") > text.rfind("."):
            text = text.replace(".", "").replace(",", ".")
        else:
            text = text.replace(",", "")
    elif "," in text:
        text = text.replace(",", ".")
    try:
        number = Decimal(text)
    except (InvalidOperation, ValueError) as exc:
        raise ValueError(f"'{raw.strip()}' is not a number") from exc
    if negative:
        number = -number
    return number


def parse_bool(raw: str) -> bool:
    """Parse a boolean cell (en / fr / ar spellings, 1/0, yes/no)."""
    text = raw.strip().lower()
    if text in _TRUE_WORDS:
        return True
    if text in _FALSE_WORDS:
        return False
    raise ValueError(f"'{raw.strip()}' is not a true/false value")


def parse_date(raw: str) -> date | None:
    """Parse a date cell.

    ISO (``2026-01-31``) when the year leads; day-first
    (``31/01/2026``) otherwise — the French/Algerian convention this app
    ships with. Ambiguity is resolved by which side carries the 4-digit
    year, never by guessing.
    """
    text = raw.strip().translate(_ARABIC_DIGITS)
    if not text:
        return None
    match = re.match(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})", text)
    if match:
        year, month, day = (int(part) for part in match.groups())
    else:
        match = re.match(r"^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})", text)
        if not match:
            raise ValueError(
                f"'{raw.strip()}' is not a date (use YYYY-MM-DD or DD/MM/YYYY)"
            )
        day, month, year = (int(part) for part in match.groups())
    try:
        return date(year, month, day)
    except ValueError as exc:
        raise ValueError(f"'{raw.strip()}' is not a valid date") from exc


def _csv_safe(value: str) -> str:
    """Neutralise spreadsheet formula injection in an exported cell."""
    if value.startswith(_FORMULA_PREFIXES):
        return "'" + value
    return value


def _csv_unsafe(value: str) -> str:
    """Inverse of :func:`_csv_safe` (round-trip symmetry)."""
    if value.startswith("'") and value[1:2].startswith(_FORMULA_PREFIXES):
        return value[1:]
    return value


# ---------------------------------------------------------------------------
# File parsing
# ---------------------------------------------------------------------------


@dataclass
class ParsedTable:
    """Headers + raw data rows of one uploaded file."""

    headers: list[str]
    rows: list[tuple[int, list[str]]]  # (1-based data row, cells)
    format: ExportFormat
    blank_rows: int = 0


def _decode_upload(content: bytes) -> str:
    """Decode an uploaded CSV to text, refusing anything ambiguous."""
    if content.startswith(codecs.BOM_UTF8):
        return content.decode("utf-8-sig")
    if content.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        return content.decode("utf-16")
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError(
            'The file is not UTF-8 encoded. Save it as "CSV UTF-8" '
            "or upload an .xlsx file.",
            details={"error": str(exc)[:200]},
            code="IMPORT_ENCODING_UNSUPPORTED",
        ) from exc
    if "\x00" in text:
        raise ValidationError(
            "The file contains binary data and cannot be imported.",
            code="IMPORT_ENCODING_UNSUPPORTED",
        )
    return text


def _sniff_delimiter(sample: str) -> str:
    """Detect the delimiter, honouring Excel's ``sep=;`` preamble."""
    first_line = sample.splitlines()[0] if sample else ""
    match = re.match(r"^sep=(.)\s*$", first_line.strip(), flags=re.IGNORECASE)
    if match:
        return match.group(1)
    try:
        return csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
    except csv.Error:
        return ","


def _too_many_rows() -> ValidationError:
    return ValidationError(
        f"The file has more than {MAX_IMPORT_ROWS} data rows.",
        details={"limit": MAX_IMPORT_ROWS},
        code="IMPORT_TOO_MANY_ROWS",
    )


def _parse_csv(content: bytes) -> ParsedTable:
    text = _decode_upload(content)
    lines = text.splitlines()
    body = text
    if lines and re.match(r"^sep=.", lines[0].strip(), flags=re.IGNORECASE):
        body = "\n".join(lines[1:])
    delimiter = _sniff_delimiter(body[:8192])

    reader = csv.reader(io.StringIO(body, newline=""), delimiter=delimiter)
    try:
        header_row = next(reader)
    except StopIteration:
        raise ValidationError("The file is empty.", code="IMPORT_EMPTY_FILE") from None
    headers = [str(cell).strip() for cell in header_row]
    if not any(headers):
        raise ValidationError(
            "The first row does not contain any column header.",
            code="IMPORT_MISSING_HEADER",
        )

    rows: list[tuple[int, list[str]]] = []
    blank = 0
    for row_number, cells in enumerate(reader, start=1):
        if len(rows) >= MAX_IMPORT_ROWS:
            raise _too_many_rows()
        if not any(str(cell).strip() for cell in cells):
            blank += 1
            continue
        padded = [str(cell) for cell in cells[: len(headers)]]
        padded += [""] * (len(headers) - len(padded))
        rows.append((row_number, padded))
    return ParsedTable(headers=headers, rows=rows, format="csv", blank_rows=blank)


def _reject_unsupported_workbook(filename: str, content: bytes) -> None:
    lowered = filename.lower()
    for extension in (".xlsm", ".xlsb", ".xls", ".xlt", ".xltx", ".xltm"):
        if lowered.endswith(extension):
            raise ValidationError(
                "Only .xlsx and .csv files can be imported "
                "(macro-enabled and legacy .xls workbooks are not supported).",
                details={"filename": filename},
                code="IMPORT_FORMAT_UNSUPPORTED",
            )
    try:
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            names = archive.namelist()
    except zipfile.BadZipFile as exc:
        raise ValidationError(
            "The file is not a valid .xlsx workbook.",
            details={"error": str(exc)[:200]},
            code="IMPORT_FORMAT_UNSUPPORTED",
        ) from exc
    if not any(name.startswith("xl/") for name in names):
        raise ValidationError(
            "The file is not a valid .xlsx workbook.",
            code="IMPORT_FORMAT_UNSUPPORTED",
        )
    if any("vbaProject.bin" in name for name in names):
        raise ValidationError(
            "Macro-enabled workbooks are not supported. Save the file "
            "as .xlsx (without macros) and try again.",
            code="IMPORT_FORMAT_UNSUPPORTED",
        )


def _parse_xlsx(filename: str, content: bytes) -> ParsedTable:
    """Read the first worksheet.

    ``data_only=True`` makes openpyxl return the *last saved values* —
    a formula is never evaluated by this importer (§Objective 5).
    """
    _reject_unsupported_workbook(filename, content)
    try:
        workbook = load_workbook(
            io.BytesIO(content), read_only=True, data_only=True
        )
    except Exception as exc:  # noqa: BLE001 - any reader failure is a bad file
        raise ValidationError(
            "The workbook could not be read.",
            details={"error": str(exc)[:200]},
            code="IMPORT_FORMAT_UNSUPPORTED",
        ) from exc
    try:
        sheet = workbook.worksheets[0]
        rows_iter = sheet.iter_rows(values_only=True)
        try:
            header_row = next(rows_iter)
        except StopIteration:
            raise ValidationError(
                "The file is empty.", code="IMPORT_EMPTY_FILE"
            ) from None
        headers = [
            str(cell).strip() if cell is not None else ""
            for cell in (header_row or ())
        ]
        if not any(headers):
            raise ValidationError(
                "The first row does not contain any column header.",
                code="IMPORT_MISSING_HEADER",
            )
        rows: list[tuple[int, list[str]]] = []
        blank = 0
        for row_number, cells in enumerate(rows_iter, start=1):
            if len(rows) >= MAX_IMPORT_ROWS:
                raise _too_many_rows()
            values = [_cell_to_raw(cell) for cell in (cells or ())]
            if not any(value.strip() for value in values):
                blank += 1
                continue
            padded = values[: len(headers)]
            padded += [""] * (len(headers) - len(padded))
            rows.append((row_number, padded))
    finally:
        workbook.close()
    return ParsedTable(
        headers=headers, rows=rows, format="xlsx", blank_rows=blank
    )


def parse_table(filename: str, content: bytes) -> ParsedTable:
    """Dispatch on the file extension, with the size cap applied first."""
    if len(content) > MAX_IMPORT_BYTES:
        raise AppError(
            "The import file exceeds the 20 MB limit.",
            details={"bytes": len(content), "limit": MAX_IMPORT_BYTES},
            code="IMPORT_FILE_TOO_LARGE",
            status_code=413,
            message_key="import_file_too_large",
        )
    if not content:
        raise ValidationError("The file is empty.", code="IMPORT_EMPTY_FILE")
    lowered = filename.lower()
    if lowered.endswith((".xlsx", ".xlsm", ".xlsb", ".xls")):
        return _parse_xlsx(filename, content)
    if lowered.endswith((".csv", ".txt")):
        return _parse_csv(content)
    if content[:2] == b"PK":
        return _parse_xlsx(filename, content)
    return _parse_csv(content)


# ---------------------------------------------------------------------------
# Column mapping
# ---------------------------------------------------------------------------


def auto_map(
    headers: Sequence[str],
) -> tuple[dict[str, int], list[str], list[str]]:
    """Match headers to fields. Returns ``(mapping, unmapped, warnings)``.

    First match wins; a second column claiming an already-taken field is
    reported as unmapped with a warning instead of silently shadowing.
    Informational columns stay in the mapping (so the report can name
    them) but are never written — see ``_NEVER_ON_IMPORT``.
    """
    normalized = [_normalize_key(header) for header in headers]
    lookup: dict[str, str] = {}
    for aliases in (_FIELD_ALIASES, _IGNORED_ONLY_FIELDS):
        for field_name, spellings in aliases.items():
            for alias in spellings:
                lookup.setdefault(alias, field_name)

    mapping: dict[str, int] = {}
    unmapped: list[str] = []
    warnings: list[str] = []
    for index, header in enumerate(headers):
        target = lookup.get(normalized[index])
        if target is None:
            unmapped.append(header)
            continue
        if target not in EXPORT_FIELDS:
            unmapped.append(header)
            warnings.append(f"column '{header}' is informational and ignored")
            continue
        if target in mapping:
            unmapped.append(header)
            warnings.append(
                f"column '{header}' also matches '{target}'; using column "
                f"'{headers[mapping[target]]}' instead"
            )
            continue
        mapping[target] = index
    return mapping, unmapped, warnings


def validate_mapping(
    mapping: dict[str, Any], headers: Sequence[str]
) -> dict[str, int]:
    """Server-side check of a client-provided mapping (untrusted input)."""
    clean: dict[str, int] = {}
    used_columns: dict[int, str] = {}
    for target, index in mapping.items():
        if target not in EXPORT_FIELDS:
            raise ValidationError(
                f"Unknown import field '{target}'.",
                details={"field": str(target)},
                code="IMPORT_MAPPING_INVALID",
            )
        if not isinstance(index, int) or isinstance(index, bool):
            raise ValidationError(
                f"Column index for '{target}' must be a number.",
                code="IMPORT_MAPPING_INVALID",
            )
        if index < 0 or index >= len(headers):
            raise ValidationError(
                f"Column index for '{target}' ({index}) is outside the file "
                f"({len(headers)} columns).",
                code="IMPORT_MAPPING_INVALID",
            )
        if index in used_columns:
            raise ValidationError(
                f"Columns for '{used_columns[index]}' and '{target}' point "
                "at the same file column.",
                code="IMPORT_MAPPING_INVALID",
            )
        used_columns[index] = target
        clean[target] = index
    return clean


# ---------------------------------------------------------------------------
# Row planning / applying
# ---------------------------------------------------------------------------


@dataclass
class _RowPlan:
    row: int
    action: str = "create"
    name: str | None = None
    barcode: str | None = None
    messages: list[str] = dataclass_field(default_factory=list)
    payload: dict[str, Any] = dataclass_field(default_factory=dict)
    product_id: uuid.UUID | None = None
    existing_archived: bool = False
    archive_after: bool = False


class ProductTransferService(BaseService):
    """Export, preview and apply for the product catalogue."""

    def __init__(self, db: Session) -> None:
        super().__init__(db)
        self.products = ProductService(db)
        self._repo = ProductRepository(db)

    # ------------------------------------------------------------------
    # Export
    # ------------------------------------------------------------------

    def export(
        self, req: ProductExportRequest, *, user_id: uuid.UUID | None
    ) -> tuple[bytes, str, str, int]:
        """Render the requested scope to bytes.

        Returns ``(data, media_type, filename, rows)``.
        """
        products = self._collect(req)
        if req.format == "csv":
            data = self._render_csv(products)
            media_type = _CSV_MEDIA_TYPE
            extension = "csv"
        else:
            data = self._render_xlsx(products, req)
            media_type = _XLSX_MEDIA_TYPE
            extension = "xlsx"
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
        filename = sanitize_filename(f"products_{req.scope}_{stamp}.{extension}")
        self._audit_export(
            req, user_id=user_id, rows=len(products), filename=filename
        )
        logger.info(
            "product_export_done",
            scope=req.scope,
            format=req.format,
            rows=len(products),
        )
        return data, media_type, filename, len(products)

    def _collect(self, req: ProductExportRequest) -> list[Product]:
        if req.scope == "selected":
            ids = list(dict.fromkeys(req.product_ids))
            products: list[Product] = []
            for start in range(0, len(ids), _ID_CHUNK):
                products.extend(self._repo.get_many(ids[start : start + _ID_CHUNK]))
            if len(products) != len(ids):
                found = {product.id for product in products}
                missing = [str(i) for i in ids if i not in found][:10]
                raise ValidationError(
                    "Some selected products no longer exist.",
                    details={"missing": missing},
                )
            products.sort(key=lambda p: (p.name.lower(), str(p.id)))
            return products

        collected: list[Product] = []
        page = 1
        while True:
            chunk, total = self.products.list(
                page=page,
                page_size=_WALK_PAGE_SIZE,
                search=req.search,
                category_id=req.category_id,
                status=req.status,
                sort_by="name",
                sort_order="asc",
            )
            if total > MAX_EXPORT_ROWS:
                raise AppError(
                    f"Export exceeds {MAX_EXPORT_ROWS} products",
                    details={"total": total, "limit": MAX_EXPORT_ROWS},
                    code="EXPORT_ROW_LIMIT",
                    status_code=422,
                    message_key="export_row_limit",
                )
            collected.extend(chunk)
            if len(collected) >= total or not chunk:
                break
            page += 1
        return collected

    def _row_values(self, product: Product) -> dict[str, Any]:
        return {
            "product_id": str(product.id),
            "name": product.name,
            "barcode": product.barcode or "",
            "sku": product.sku or "",
            "category": product.category.name if product.category else "",
            "unit": product.unit,
            "sale_price": product.price,
            "purchase_price": product.cost,
            "wholesale_price": (
                product.wholesale_price
                if product.wholesale_price is not None
                else ""
            ),
            "wholesale_min_qty": (
                product.wholesale_min_qty
                if product.wholesale_min_qty is not None
                else ""
            ),
            "vat_rate": int(product.vat_rate or 0),
            "low_stock_threshold": product.low_stock_threshold,
            "allow_negative_stock": bool(product.allow_negative_stock),
            "expiry_date": product.expiry_date or "",
            "description": product.description or "",
            "image_path": product.image_path or "",
            "is_active": product.archived_at is None,
            # informational: exported, ignored by import
            "current_stock": product.quantity,
        }

    def _csv_cell(self, value: Any) -> str:
        if isinstance(value, bool):
            return "true" if value else "false"
        if isinstance(value, Decimal):
            return _format_decimal(value)
        if isinstance(value, float):
            return _format_decimal(Decimal(str(value)))
        if isinstance(value, datetime):
            return value.date().isoformat()
        if isinstance(value, date):
            return value.isoformat()
        if value is None:
            return ""
        if isinstance(value, str):
            # csv.writer does the comma/quote/newline escaping; only
            # spreadsheet-formula injection needs a manual prefix.
            return _csv_safe(value)
        return str(value)

    def _render_csv(self, products: Sequence[Product]) -> bytes:
        buffer = io.StringIO(newline="")
        writer = csv.writer(buffer, lineterminator="\r\n")
        writer.writerow(EXPORT_FIELDS)
        for product in products:
            values = self._row_values(product)
            writer.writerow(
                [self._csv_cell(values[name]) for name in EXPORT_FIELDS]
            )
        # utf-8-sig: Excel must not turn Arabic into mojibake on open.
        return buffer.getvalue().encode("utf-8-sig")

    def _xlsx_cell(self, value: Any) -> Any:
        if isinstance(value, Decimal):
            return float(value)
        if isinstance(value, str):
            # openpyxl turns "=..." into a real formula cell; keep every
            # text cell text (see _csv_safe).
            return _csv_safe(value)
        return value if value is not None else ""

    def _render_xlsx(
        self, products: Sequence[Product], req: ProductExportRequest
    ) -> bytes:
        workbook = Workbook(write_only=True)
        sheet = workbook.create_sheet(title="Products")
        sheet.append(list(EXPORT_FIELDS))
        for product in products:
            values = self._row_values(product)
            sheet.append([self._xlsx_cell(values[name]) for name in EXPORT_FIELDS])

        info = workbook.create_sheet(title="Export info")
        info.append(["field", "value"])
        info.append(["scope", req.scope])
        info.append(["status", req.status])
        info.append(["search", req.search or ""])
        info.append(
            ["category_id", str(req.category_id) if req.category_id else ""]
        )
        info.append(["rows", len(products)])
        info.append(["generated_at", datetime.now(timezone.utc).isoformat()])
        info.append(
            [
                "stock_columns",
                "current_stock is informational: import never writes stock",
            ]
        )

        buffer = io.BytesIO()
        workbook.save(buffer)
        return buffer.getvalue()

    # ------------------------------------------------------------------
    # Import
    # ------------------------------------------------------------------

    def run_import(
        self,
        *,
        filename: str,
        content: bytes,
        dry_run: bool,
        on_conflict: OnConflict,
        mapping: dict[str, Any] | None = None,
        user_id: uuid.UUID | None = None,
        archive_allowed: bool = True,
    ) -> ImportReport:
        """Plan every row, then (unless it is a dry run) apply it.

        File-level problems raise before a single row is written; row
        problems are reported with their row number and message.
        ``archive_allowed`` carries the caller's ``product_archive``
        permission — rows that archive a product are refused when the
        caller does not hold it.
        """
        table = parse_table(filename, content)

        if mapping:
            clean_mapping = validate_mapping(mapping, table.headers)
            used = set(clean_mapping.values())
            unmapped = [
                header
                for index, header in enumerate(table.headers)
                if index not in used
            ]
            warnings: list[str] = []
        else:
            clean_mapping, unmapped, warnings = auto_map(table.headers)

        if "name" not in clean_mapping:
            raise ValidationError(
                "No column could be matched to the product name. "
                "Map a column to 'name' before importing.",
                details={
                    "headers": table.headers[:50],
                    "missing_field": "name",
                },
                code="IMPORT_MISSING_REQUIRED_COLUMN",
            )

        for field_name in INFORMATIONAL_FIELDS:
            if field_name in clean_mapping:
                warnings.append(
                    f"'{field_name}' is exported for reference only — "
                    "import never changes stock quantities"
                )

        plans = self._plan(table, clean_mapping, on_conflict)
        all_warnings = warnings + _row_warnings(table)

        if not dry_run and any(plan.archive_after for plan in plans):
            if not archive_allowed:
                raise ForbiddenError(
                    "This file archives products; the product_archive "
                    "permission is required to import it.",
                    details={"required_permission": "product_archive"},
                )
            if any(plan.action == "create" and plan.archive_after for plan in plans):
                # Archiving a product we are about to create is pointless
                # and would hide it instantly — treat as a row error.
                for plan in plans:
                    if plan.action == "create" and plan.archive_after:
                        plan.action = "failed"
                        plan.messages.append(
                            "is_active=false cannot be combined with a new product"
                        )

        report_args = dict(
            dry_run=dry_run,
            filename=sanitize_filename(filename, max_length=200),
            fmt=table.format,
            mapping=clean_mapping,
            unmapped=unmapped,
            warnings=all_warnings,
            blank_rows=table.blank_rows,
            total_rows=len(table.rows),
        )
        if dry_run:
            return self._build_report(plans, **report_args)  # type: ignore[arg-type]

        self._apply(
            plans,
            on_conflict=on_conflict,
            filename=filename,
            user_id=user_id,
        )
        return self._build_report(plans, **report_args)  # type: ignore[arg-type]

    # -- planning ------------------------------------------------------

    def _plan(
        self,
        table: ParsedTable,
        mapping: dict[str, int],
        on_conflict: OnConflict,
    ) -> list[_RowPlan]:
        requested_ids: list[uuid.UUID] = []
        barcodes: list[str] = []
        for _, cells in table.rows:
            raw_id = _csv_unsafe(_cell_at(cells, mapping, "product_id")).strip()
            if raw_id:
                try:
                    requested_ids.append(uuid.UUID(raw_id))
                except ValueError:
                    pass  # reported per row below
            barcode = _csv_unsafe(_cell_at(cells, mapping, "barcode")).strip()
            if barcode:
                barcodes.append(barcode)

        by_id = self._load_by_id(requested_ids)
        by_barcode = self._load_by_barcode(barcodes)
        categories = self._category_index()

        plans: list[_RowPlan] = []
        seen_ids: dict[uuid.UUID, int] = {}
        seen_barcodes: dict[str, int] = {}

        for row_number, cells in table.rows:
            plan = _RowPlan(row=row_number)
            values = {
                field_name: _csv_unsafe(_cell_at(cells, mapping, field_name))
                for field_name in EXPORT_FIELDS
                if field_name in mapping
            }
            plan.name = (values.get("name") or "").strip() or None
            plan.barcode = (values.get("barcode") or "").strip() or None

            # -- identity (file id first, then barcode) -------------------
            raw_id = (values.get("product_id") or "").strip()
            parsed_id: uuid.UUID | None = None
            if raw_id:
                try:
                    parsed_id = uuid.UUID(raw_id)
                except ValueError:
                    plan.action = "failed"
                    plan.messages.append(
                        f"product_id '{raw_id}' is not a valid identifier"
                    )
                    plans.append(plan)
                    continue
                plan.product_id = parsed_id
                if parsed_id in seen_ids:
                    plan.action = "failed"
                    plan.messages.append(
                        f"product_id already used by row {seen_ids[parsed_id]}"
                    )
                    plans.append(plan)
                    continue
                seen_ids[parsed_id] = row_number

            if plan.barcode:
                if plan.barcode in seen_barcodes:
                    plan.action = "failed"
                    plan.messages.append(
                        f"barcode '{plan.barcode}' already used by row "
                        f"{seen_barcodes[plan.barcode]}"
                    )
                    plans.append(plan)
                    continue
                seen_barcodes[plan.barcode] = row_number

            existing = by_id.get(parsed_id) if parsed_id is not None else None
            if existing is None and plan.barcode:
                existing = by_barcode.get(plan.barcode)
                if existing is not None and parsed_id is not None:
                    plan.messages.append(
                        "product_id did not match any product — matched by barcode"
                    )

            if existing is not None and plan.barcode:
                owned = (existing.barcode or "").strip()
                if owned and owned != plan.barcode:
                    other = by_barcode.get(plan.barcode)
                    if other is not None and other.id != existing.id:
                        plan.action = "failed"
                        plan.messages.append(
                            f"barcode '{plan.barcode}' already belongs to "
                            "another product"
                        )
                        plans.append(plan)
                        continue

            plan.existing_archived = bool(
                existing is not None and existing.archived_at is not None
            )
            if existing is not None:
                plan.product_id = existing.id

            # -- action under the conflict policy -------------------------
            if existing is None:
                plan.action = "create"
            elif on_conflict == "skip":
                plan.action = "skip"
                plan.messages.append("product already exists — skipped")
            elif on_conflict == "reject":
                plan.action = "failed"
                plan.messages.append("product already exists (policy: reject)")
            else:  # update
                plan.action = "update"

            if plan.action == "update" and plan.existing_archived:
                active_raw = (values.get("is_active") or "").strip()
                wants_active = _is_truthy_safe(active_raw) if active_raw else None
                if wants_active is True:
                    plan.action = "skip"
                    plan.messages.append(
                        "product is archived and cannot be reactivated by import"
                    )

            if plan.action in ("create", "update"):
                self._build_payload(plan, values, categories)

            plans.append(plan)
        return plans

    def _build_payload(
        self,
        plan: _RowPlan,
        values: dict[str, str],
        categories: dict[str, Category],
    ) -> None:
        """Parse + schema-validate one row into its create/update payload."""
        schema_map = (
            _CREATE_FIELD_MAP if plan.action == "create" else _UPDATE_FIELD_MAP
        )
        payload: dict[str, Any] = {}
        for file_field, schema_field in schema_map.items():
            if file_field not in values:
                continue
            raw = values[file_field].strip()
            if raw == "":
                if plan.action == "create" and file_field in _REQUIRED_ON_CREATE:
                    plan.action = "failed"
                    plan.messages.append(
                        f"{file_field} is required for a new product"
                    )
                continue  # blank = default on create, unchanged on update
            try:
                parsed = _parse_value(file_field, raw)
            except ValueError as exc:
                plan.action = "failed"
                plan.messages.append(f"{file_field}: {exc}")
                continue
            if parsed is not None:
                payload[schema_field] = parsed

        # Category travels as a NAME (ids do not survive a new database).
        if "category" in values:
            raw_category = values["category"].strip()
            if raw_category:
                category = categories.get(_fold_category(raw_category))
                if category is None:
                    plan.action = "failed"
                    plan.messages.append(
                        f"category '{raw_category}' does not exist"
                    )
                elif category.archived_at is not None:
                    plan.action = "failed"
                    plan.messages.append(
                        f"category '{raw_category}' is archived"
                    )
                else:
                    payload["category_id"] = category.id

        is_active_raw = (values.get("is_active") or "").strip()
        if is_active_raw:
            try:
                if parse_bool(is_active_raw) is False:
                    plan.archive_after = True
            except ValueError as exc:
                plan.action = "failed"
                plan.messages.append(f"is_active: {exc}")

        if plan.action == "failed":
            return

        try:
            if plan.action == "create":
                ProductCreateRequest(**payload)
            elif not payload:
                plan.action = "skip"
                plan.messages.append("no changed fields — skipped")
                return
            else:
                ProductUpdateRequest(**payload)
        except PydanticValidationError as exc:
            plan.action = "failed"
            for error in exc.errors():
                schema_field = ".".join(str(part) for part in error["loc"])
                file_field = _SCHEMA_TO_FILE_FIELD.get(schema_field, schema_field)
                plan.messages.append(f"{file_field}: {error['msg']}")
            return

        plan.payload = payload

    # -- apply ---------------------------------------------------------

    def _apply(
        self,
        plans: Sequence[_RowPlan],
        *,
        on_conflict: OnConflict,
        filename: str,
        user_id: uuid.UUID | None,
    ) -> None:
        created = updated = 0
        for plan in plans:
            if plan.action in ("skip", "failed"):
                continue
            try:
                if plan.action == "create":
                    product = self.products.create(
                        ProductCreateRequest(**plan.payload)
                    )
                    created += 1
                    if plan.archive_after:
                        self.products.archive(product.id)
                else:
                    if plan.product_id is None:  # pragma: no cover - defensive
                        plan.action = "failed"
                        plan.messages.append("no product matched — row not applied")
                        continue
                    self.products.update(
                        plan.product_id, ProductUpdateRequest(**plan.payload)
                    )
                    updated += 1
                    if plan.archive_after and not plan.existing_archived:
                        self.products.archive(plan.product_id)
            except AppError as exc:
                plan.action = "failed"
                plan.messages.append(exc.message)
            except Exception as exc:  # noqa: BLE001 - row isolation barrier
                logger.warning(
                    "product_import_row_failed", row=plan.row, error=str(exc)
                )
                plan.action = "failed"
                plan.messages.append("unexpected error — row not applied")

        skipped = sum(1 for plan in plans if plan.action == "skip")
        self._audit_import(
            filename=filename,
            user_id=user_id,
            on_conflict=on_conflict,
            created=created,
            updated=updated,
            skipped=skipped,
        )

    # -- report --------------------------------------------------------

    def _build_report(
        self,
        plans: Sequence[_RowPlan],
        *,
        dry_run: bool,
        filename: str,
        fmt: ExportFormat,
        mapping: dict[str, int],
        unmapped: list[str],
        warnings: list[str],
        blank_rows: int,
        total_rows: int,
    ) -> ImportReport:
        counts = {"create": 0, "update": 0, "skip": 0, "failed": 0}
        for plan in plans:
            counts[plan.action] = counts.get(plan.action, 0) + 1

        # Failures are the rows the operator must see; when the report is
        # capped they are kept first, then the listing is put back in file
        # order for reading.
        ordered = sorted(
            plans,
            key=lambda plan: (0 if plan.action == "failed" else 1, plan.row),
        )
        truncated = len(ordered) > MAX_REPORT_ROWS
        selected = ordered[:MAX_REPORT_ROWS] if truncated else ordered
        rows = [
            ImportRow(
                row=plan.row,
                action=plan.action,  # type: ignore[arg-type]
                name=plan.name,
                barcode=plan.barcode,
                messages=plan.messages,
            )
            for plan in sorted(selected, key=lambda plan: plan.row)
        ]
        return ImportReport(
            dry_run=dry_run,
            applied=not dry_run,
            filename=filename,
            format=fmt,
            total_rows=total_rows,
            created=counts["create"],
            updated=counts["update"],
            skipped=counts["skip"],
            failed=counts["failed"],
            mapping=mapping,
            unmapped_columns=unmapped,
            ignored_fields=[
                field_name
                for field_name in INFORMATIONAL_FIELDS
                if field_name in mapping
            ],
            blank_rows_ignored=blank_rows,
            rows=rows,
            rows_truncated=truncated,
            warnings=warnings,
        )

    # -- audit ---------------------------------------------------------

    def _audit_export(
        self,
        req: ProductExportRequest,
        *,
        user_id: uuid.UUID | None,
        rows: int,
        filename: str,
    ) -> None:
        details = {
            "format": req.format,
            "scope": req.scope,
            "status": req.status,
            "search": req.search,
            "category_id": str(req.category_id) if req.category_id else None,
            "selected_ids": len(req.product_ids),
            "rows": rows,
            "filename": filename,
        }
        with self.transaction():
            self.db.add(
                AuditLog(
                    user_id=user_id,
                    action=AuditAction.EXPORT.value,
                    entity_type="product_export",
                    details=filename,
                    after_state=json.dumps(details, default=str),
                    module=AuditModule.EXPORTS.value,
                )
            )

    def _audit_import(
        self,
        *,
        filename: str,
        user_id: uuid.UUID | None,
        on_conflict: OnConflict,
        created: int,
        updated: int,
        skipped: int,
    ) -> None:
        details = {
            "filename": filename,
            "on_conflict": on_conflict,
            "created": created,
            "updated": updated,
            "skipped": skipped,
        }
        with self.transaction():
            self.db.add(
                AuditLog(
                    user_id=user_id,
                    action=AuditAction.IMPORT.value,
                    entity_type="product_import",
                    details=filename,
                    after_state=json.dumps(details),
                    module=AuditModule.PRODUCTS.value,
                )
            )

    # -- lookups -------------------------------------------------------

    def _load_by_id(self, ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, Product]:
        unique = list(dict.fromkeys(ids))
        found: dict[uuid.UUID, Product] = {}
        for start in range(0, len(unique), _ID_CHUNK):
            chunk = unique[start : start + _ID_CHUNK]
            for product in self._repo.get_many(chunk):
                found[product.id] = product
        return found

    def _load_by_barcode(self, barcodes: Sequence[str]) -> dict[str, Product]:
        found: dict[str, Product] = {}
        unique = list(dict.fromkeys(barcodes))
        for start in range(0, len(unique), _ID_CHUNK):
            chunk = unique[start : start + _ID_CHUNK]
            stmt = select(Product).where(Product.barcode.in_(chunk))
            for product in self.db.scalars(stmt).all():
                if product.barcode:
                    found[product.barcode] = product
        return found

    def _category_index(self) -> dict[str, Category]:
        return {
            _fold_category(category.name): category
            for category in self.db.scalars(select(Category)).all()
        }

    # ------------------------------------------------------------------
    # Template
    # ------------------------------------------------------------------

    def template(
        self, *, fmt: ExportFormat, locale: str
    ) -> tuple[bytes, str, str]:
        """Header-only template (never an example row that somebody could
        import by accident). Returns ``(data, media_type, filename)``."""
        if fmt == "csv":
            text_buffer = io.StringIO(newline="")
            writer = csv.writer(text_buffer, lineterminator="\r\n")
            writer.writerow(EXPORT_FIELDS)
            data = text_buffer.getvalue().encode("utf-8-sig")
            return data, _CSV_MEDIA_TYPE, "products_template.csv"

        workbook = Workbook(write_only=True)
        sheet = workbook.create_sheet(title="Products")
        sheet.append(list(EXPORT_FIELDS))
        docs = workbook.create_sheet(title="columns")
        docs.append(
            ["field", "required", "type", "writable_on_import", "description"]
        )
        for field_name in EXPORT_FIELDS:
            docs.append(
                [
                    field_name,
                    "yes" if field_name in _REQUIRED_ON_CREATE else "no",
                    _FIELD_TYPES.get(field_name, "text"),
                    "yes" if field_name in IMPORTABLE_FIELDS else "no",
                    _field_description(field_name, locale),
                ]
            )
        out = io.BytesIO()
        workbook.save(out)
        return out.getvalue(), _XLSX_MEDIA_TYPE, "products_template.xlsx"


_FIELD_TYPES: dict[str, str] = {
    "product_id": "uuid",
    "sale_price": "number",
    "purchase_price": "number",
    "wholesale_price": "number",
    "wholesale_min_qty": "number > 0",
    "vat_rate": "0 | 9 | 19",
    "low_stock_threshold": "number",
    "allow_negative_stock": "true/false",
    "expiry_date": "YYYY-MM-DD",
    "is_active": "true/false",
    "current_stock": "number (information only)",
}

#: Template column documentation, en / fr / ar. The in-app import screen
#: carries its own localized copy; this sheet keeps a downloaded file
#: self-explanatory when it travels outside the app.
_FIELD_DOCS: dict[str, dict[str, str]] = {
    "product_id": {
        "en": "Internal id; used to match an existing product on import.",
        "fr": "Identifiant interne ; sert a apparier un produit existant.",
        "ar": "\u0627\u0644\u0645\u0639\u0631\u0641 \u0627\u0644\u062f\u0627\u062e\u0644\u064a\u061b "
              "\u064a\u0633\u062a\u062e\u0645 \u0644\u0645\u0637\u0627\u0628\u0642\u0629 \u0645\u0646\u062a\u062c "
              "\u0645\u0648\u062c\u0648\u062f.",
    },
    "name": {
        "en": "Product name (required).",
        "fr": "Nom du produit (obligatoire).",
        "ar": "\u0627\u0633\u0645 \u0627\u0644\u0645\u0646\u062a\u062c (\u0645\u0637\u0644\u0648\u0628).",
    },
    "barcode": {
        "en": "Barcode; unique across products and units.",
        "fr": "Code-barres ; unique sur tous les articles.",
        "ar": "\u0627\u0644\u0628\u0627\u0631\u0643\u0648\u062f \u0641\u064a\u062f\u0627\u064b "
              "\u0641\u064a \u0643\u0644 \u0627\u0644\u0645\u0646\u062a\u062c\u0627\u062a.",
    },
    "category": {
        "en": "Category name (must already exist).",
        "fr": "Nom de categorie (doit exister).",
        "ar": "\u0627\u0633\u0645 \u0627\u0644\u0641\u0626\u0629 (\u064a\u062c\u0628 \u0623\u0646 "
              "\u062a\u0643\u0648\u0646 \u0645\u0648\u062c\u0648\u062f\u0629).",
    },
    "sale_price": {
        "en": "Selling price (required for a new product).",
        "fr": "Prix de vente (obligatoire pour un nouveau produit).",
        "ar": "\u0633\u0639\u0631 \u0627\u0644\u0628\u064a\u0639 (\u0645\u0637\u0644\u0648\u0628 "
              "\u0644\u0644\u0645\u0646\u062a\u062c \u0627\u0644\u062c\u062f\u064a\u062f).",
    },
    "purchase_price": {
        "en": "Reference purchase price (cost).",
        "fr": "Prix d'achat de reference (cout).",
        "ar": "\u0633\u0639\u0631 \u0627\u0644\u0634\u0631\u0627\u0621 \u0627\u0644\u0645\u0631\u062c\u0639\u064a.",
    },
    "vat_rate": {
        "en": "VAT rate: 0, 9 or 19 only.",
        "fr": "Taux de TVA : 0, 9 ou 19 uniquement.",
        "ar": "\u0646\u0633\u0628\u0629 \u0627\u0644\u0636\u0631\u064a\u0628\u0629: 0 \u0623\u0648 9 "
              "\u0623\u0648 19 \u0641\u0642\u0637.",
    },
    "is_active": {
        "en": "true = active, false = archived.",
        "fr": "true = actif, false = archive.",
        "ar": "true = \u0646\u0634\u0637, false = \u0645\u0623\u0631\u0642\u0646.",
    },
    "current_stock": {
        "en": "Information only - import never changes stock.",
        "fr": "Information uniquement - l'import ne change jamais le stock.",
        "ar": "\u0645\u0639\u0644\u0648\u0645\u0627\u062a \u0641\u0642\u0637\u061b \u0627\u0644\u0625\u0633\u062a\u064a\u0631\u0627\u062f "
              "\u0644\u0627 \u064a\u063a\u064a\u0631 \u0627\u0644\u0645\u062e\u0632\u0648\u0646.",
    },
}


def _field_description(field_name: str, locale: str) -> str:
    entry = _FIELD_DOCS.get(field_name, {})
    return entry.get(locale) or entry.get("en") or field_name


def _fold_category(name: str) -> str:
    return _normalize_key(name)


def _cell_at(
    cells: Sequence[str], mapping: dict[str, int], field_name: str
) -> str:
    index = mapping.get(field_name)
    if index is None or index >= len(cells):
        return ""
    return cells[index]


def _is_truthy_safe(raw: str) -> bool:
    try:
        return parse_bool(raw)
    except ValueError:
        return False


def _parse_value(file_field: str, raw: str) -> Any:
    """Convert one file cell to the schema's Python type."""
    if file_field in (
        "sale_price",
        "purchase_price",
        "wholesale_price",
        "wholesale_min_qty",
        "vat_rate",
        "low_stock_threshold",
    ):
        number = parse_decimal(raw)
        if number is None:
            return None
        if file_field == "vat_rate":
            if number != number.to_integral_value():
                raise ValueError(f"'{raw}' is not one of 0, 9, 19")
            return int(number)
        return number
    if file_field == "allow_negative_stock":
        return parse_bool(raw)
    if file_field == "expiry_date":
        return parse_date(raw)
    if file_field == "is_active":
        return parse_bool(raw)
    if len(raw) > 5_000:
        raise ValueError("value is too long")
    return raw


def _row_warnings(table: ParsedTable) -> list[str]:
    if table.blank_rows:
        return [f"{table.blank_rows} blank row(s) were ignored"]
    return []
