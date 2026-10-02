# PHASE 15 — PRINTING / EXPORTS — ANALYSIS & SPECIFICATION (STEP A)

**Status:** ANALYSIS ONLY — no features implemented, no application code modified, no
dependencies added, no migrations created, no commits/pushes.

**Baseline:** Phase 14 closed at commit `879c8e5` ("phase-14: complete reports and dashboard").
This document depends on Phase 14 and preserves every Phase 14 contract.

**Objective of this document:** inspect the current repository and produce the complete
Phase 15 architecture/specification so that implementation (Steps B+) can proceed against
explicit, evidence-based decisions and gates.

---

## 0. Scope, method and sources

### 0.1 What this document is

| It IS | It is NOT |
|---|---|
| A static, evidence-based audit of the current code | An implementation |
| Architecture decisions with rationale and gates | A migration or dependency change |
| Layout/print/export specifications ready for Step B | A claim of runtime/hardware verification |
| A list of owner questions that cannot be answered from code | A source of invented legal/fiscal fields |

### 0.2 Evidence classes used throughout

| Class | Meaning |
|---|---|
| **[MODERN]** | Verified in current code (`new_app/` Flutter + `new_app/backend/` FastAPI) |
| **[PHASE-0]** | Approved Phase 0 rule/roadmap/blueprint (`docs/PHASE_0_*`, `reference/docs/PHASE_0_*`) |
| **[PHASE-8]** | Phase 8 sale/invoice/printing contract (`docs/PHASE_8_*`) |
| **[PHASE-14]** | Frozen Phase 14 export contract (`docs/PHASE_14_*`) |
| **[LEGACY]** | Behavioral evidence only from `python_app/` (never to be copied blindly) |
| **[UNVERIFIED]** | Requires runtime, hardware, or owner verification — never silently resolved |

### 0.3 Path correction (important)

Earlier planning notes refer to `python_app/` as the modern FastAPI backend. It is not.
The verified layout is:

| Path | Role | Evidence |
|---|---|---|
| `new_app/backend/` | Modern FastAPI backend (Phases 0–14) | `new_app/backend/app/main.py:22,56` |
| `new_app/` (lib, test, windows) | Modern Flutter Windows desktop app | `new_app/pubspec.yaml:1` |
| `python_app/` | **Legacy** CustomTkinter desktop app (ReportLab/OpenPyXL live here) | `python_app/requirements.txt:1-12` |
| `reference/` | Phase 0 legacy **docs only** (no code) | `reference/docs/*` |
| `docs/` | Phase specs 0–14 | `docs/PHASE_*.md` |

Stale root artifacts (`MANIFEST.md`, `FILE_HASHES.txt`, `FLUTTER_DEPENDENCY_MAP.md`,
`PYTHON_DEPENDENCY_MAP.md`, `PARITY_COMPARISON_GUIDE.md`) describe a codebase that does not
exist in this checkout (e.g. they reference `flutter_app/.../receipt_pdf_generator.dart`,
which is absent from git history). They are **not** used as evidence in this document.

### 0.4 Primary sources inspected

| Source | Used for |
|---|---|
| `docs/PHASE_0_ROADMAP.md:626-661` | Phase 15 feature list, backend/Flutter split, acceptance criteria |
| `docs/PHASE_0_MASTER_SPECIFICATION.md:43` | "FastAPI owns printing/export jobs" |
| `docs/PHASE_0_ARCHITECTURE.md:27,39,61` | job services; "printing after commit cannot roll back a sale" |
| `docs/PHASE_0_FEATURE_MATRIX.md:17` | Print/export target: "backend jobs/templates", P1/15 |
| `docs/PHASE_0_PERFORMANCE_AUDIT.md:12,15` | PDF/XLSX off the UI path; SLOs incl. receipt <3s, export <5s |
| `docs/PHASE_0_API_BLUEPRINT.md:707` | `PRINTER_ERROR 503 Printer unavailable` |
| `docs/PHASE_0_DATABASE_ANALYSIS.md:47` | blueprint tables `print_jobs`, `export_jobs` (not implemented) |
| `docs/PHASE_0_BUSINESS_RULES.md` §12–§14 (`reference/docs/`) | 80mm/A4 formats, reportlab, store settings, auto-print toggles |
| `docs/PHASE_0_POS_WORKFLOW.md:228-232` | ask_before_print / auto_print flow |
| `docs/PHASE_0_SECURITY_AUDIT.md:14` | user file operations → traversal risk; record export attempts |
| `docs/PHASE_0_LOCALIZATION_AUDIT.md:7,12,14` | Arabic in print/PDF; stable keys; visual RTL snapshots |
| `docs/PHASE_8_POS_ANALYSIS.md:582,854` | "print hook stub"; print non-blocking |
| `docs/PHASE_8_POS_IMPLEMENTATION.md:7,731` | text print only; PDF deferred to Phase 15 |
| `docs/PHASE_14_REPORTS_DASHBOARD_ANALYSIS.md:502-533,456-463,537-543` | **frozen export contract**, permissions, PDF/XLSX deferrals |
| `docs/PHASE_14_REPORTS_DASHBOARD_ANALYSIS.md:676-760` | gates G13/G16/G19, DEF-1..DEF-3, confirmations C3, A6, D12 |

---

## 1. CURRENT IMPLEMENTATION AUDIT

### A. Phase 8 sale/invoice payloads

**Endpoints** — `new_app/backend/app/api/v1/pos.py`:

| Method/Path | Handler | Lines | Permission |
|---|---|---|---|
| `POST /api/v1/sales` | `create_sale` | 75–100 | `pos_sale` (+`pos_credit_sale`/`pos_discount` in service) |
| `GET /api/v1/sales` (history, "minimal history for POS reprint") | `list_sales` | 103–117 | `pos_sale` |
| `GET /api/v1/sales/by-invoice/{invoice_number}` | `get_sale_by_invoice` | 120–131 | `pos_sale` |
| `GET /api/v1/sales/{sale_id}` (detail / reprint) | `get_sale` | 134–145 | `pos_sale` |
| `POST /api/v1/sales/{sale_id}/void` | `void_sale` | 148–169 | `pos_void` |

**Request** — `new_app/backend/app/schemas/sale.py`:
`CreateSaleRequest` (70–97): `client_request_id`, `items[1..200]`, `customer_id`,
`invoice_discount`, `payment_method ∈ {cash,card,partial,credit}` (literal at :19),
`paid`, `device_id`, `note`. `SaleLineRequest` (22–67): `product_id|pack_id` (exclusive,
validator 52–67), `variant_id`, `selling_unit_id`, `quantity`, `unit_price` (hint only),
`line_discount`, `barcode`. **No client-sent totals** (comment :73).

**Response `SaleResponse`** — `schemas/sale.py:137-169` — full field list:

| # | Field | Line | Notes |
|---|---|---|---|
| 1 | `id` | 140 | UUID |
| 2 | `invoice_number` | 141 | `INV-YYYYMMDD-HHMMSS-mmm-xxxx` |
| 3 | `client_request_id` | 142 | idempotency |
| 4 | `customer_id` | 143 | **UUID only — no name/phone** |
| 5 | `status` | 144 | `completed` / `void` |
| 6 | `subtotal` | 145 | Decimal → JSON string (`StrictBaseModel`, `schemas/common.py:21-27`) |
| 7 | `discount` | 146 | invoice-level discount only |
| 8 | `total` | 147 | `subtotal − Σline_discount − invoice_discount` (`services/sale.py:681`) |
| 9 | `paid` | 148 | |
| 10 | `change` | 149 | `max(0, paid − total)` |
| 11 | `debt` | 150 | `max(0, total − paid)`; `= total` for credit |
| 12 | `payment_method` | 151 | |
| 13 | `device_id` | 152 | |
| 14 | `note` | 153 | |
| 15 | `sale_date` | 154 | UTC datetime |
| 16–18 | `voided_at`, `voided_by`, `void_reason` | 157–159 | null unless voided |
| 19 | `lines[]` | 160 | see §1.F |
| 20 | `payments[]` | 161 | `{id, method, amount}` only (`schemas/sale.py:131-134`; DB also has `reference`, `payment_date` — `models/sale.py:201-205` — **not exposed**) |
| 21 | `idempotent_replay` | 162 | |
| 22 | `unit_summary` | 163–169 | e.g. `"2 Box · 48 piece"` (detail only) |

`SaleCreateResponse` (186–189) adds `price_overrides[]` (172–183).

**Line shape `SaleLineResponse`** — `schemas/sale.py:100-128`: `id`, `product_id`,
`pack_id`, `variant_id`, `product_name`, `product_sku`, `product_barcode`, `product_unit`,
`variant_name`, `selling_unit_name`, `selling_unit_multiplier`, `unit_price`, `unit_cost`,
`quantity`, `line_discount`, `line_total`. Pack semantics documented at 107–111:
pack summary line (`pack_id` set, charged) vs pack component line (`line_total = 0`).

**Not present in the payload:** cashier/user name (although `sales.user_id` **is persisted**,
`models/sale.py:32-36`), customer name/phone/address, store header, any tax/fiscal field,
returns linkage, base quantity (client derives `qty × multiplier`, `pos_models.dart:567-572`).

### B. Existing sale detail / reprint endpoints

- `GET /api/v1/sales/{sale_id}` → `SaleResponse` — `pos.py:134-145` →
  `SaleService.get_sale` (`services/sale.py:1256-1263`).
- `GET /api/v1/sales/by-invoice/{invoice_number}` → `SaleResponse` — `pos.py:120-131` →
  `services/sale.py:1265-1272`; route registered **before** `/{sale_id}` (`pos.py:120` vs `134`).
- `GET /api/v1/sales` history — `pos.py:103-117`, documented as "Minimal history for POS
  reprint" (`pos.py:115`).
- Repository: `repositories/sale.py:28-30` (`find_by_invoice_number`), `:44-51` (`list_recent`).
- Returns reprint: `GET /api/v1/returns/{return_id}` — "Return detail / reprint",
  `api/v1/returns.py:98-109` (permission `pos_return`); list filter by source
  `invoice_number` at `returns.py:69-95`. **No by-return-number lookup.**
- Purchases detail: `GET /api/v1/purchases/{purchase_id}` — `api/v1/purchases.py:73-85`
  (permission `purchase_view`), returns `PurchaseResponse` incl. `supplier_name`
  (`schemas/purchase.py:105-127`).
- Flutter consumers: `new_app/lib/features/pos/sale_detail_dialog.dart:144`
  (`dio.get('/api/v1/sales/${saleId}')`), `sale_history_dialog.dart:38-47`,
  provider `pos_providers.dart:811-849`.

### C. Existing print hook/stub

**Backend: none.** No print endpoint, no print stub, no `print_jobs` table. `print_jobs`
appears only in planning docs (`docs/PHASE_0_DATABASE_ANALYSIS.md:47`,
`PHASE_0_ROADMAP.md:626-659`) and the blueprint error code `PRINTER_ERROR`
(`PHASE_0_API_BLUEPRINT.md:707`). Zero hits for `print_jobs` in `new_app/backend/migrations`.

**Flutter: a real text print path (Phase 8 UX FIX #4):**

| Piece | Location | Lines |
|---|---|---|
| `abstract class PrintService { Future<void> printText(String text); }` | `new_app/lib/features/pos/print_service.dart` | 13–17 |
| `PrintServiceException` | same | 19–25 |
| `WindowsPrintService` — writes `pos_receipt_<millis>.txt` to `Directory.systemTemp`, pipes through `powershell.exe … Out-Printer`, exit-code check, best-effort temp cleanup | same | 28–72 |
| `printServiceProvider` (overridable in tests) | same | 75–77 |
| `buildReceiptText(SaleDetail, locale)` — the plain-text receipt renderer | `sale_detail_dialog.dart` | 60–108 |
| `_showPrintPreview` (confirm dialog, keys `print-preview-*`) | `sale_detail_dialog.dart` | 249–286 |
| `_print` — failure → localized `print_failed`, **never success on failure** | `sale_detail_dialog.dart` | 288–314 |
| Buttons: copy invoice / reprint / print | `sale_detail_dialog.dart` | 407–444 |
| Test fake `_FakePrintService` | `test/widget/pos_screen_test.dart` | 37–48 |
| Receipt text snapshot tests | `test/unit/sale_line_snapshots_test.dart` | 136–233 |

Phase 8 contract preserved by this design [PHASE-8]: **printing is never part of the sale
transaction** (`print_service.dart:1-5`), print is non-blocking
(`docs/PHASE_8_POS_ANALYSIS.md:854` "COMPLETED ──print hook──► EMPTY"), failure is never
reported as success. Post-checkout does **not** prompt print (`pos_screen.dart:685-703`);
print is reachable only via History → Detail.

### D. Invoice numbering and fields

| Document | Generator | Format | File:line |
|---|---|---|---|
| Sale | `_generate_invoice_number()` | `INV-YYYYMMDD-HHMMSS-mmm-xxxx` (UTC, ms + 4 hex) | `services/sale.py:88-95` (call `:824`) |
| Purchase | `_generate_invoice_number()` | `PUR-…` same shape | `services/purchases.py:68-73` (call `:158`) |
| Return | `_generate_return_number()` | `RET-…` same shape | `services/returns.py:75-82` (call `:598`) |

Storage: `sales.invoice_number` `String(50) UNIQUE INDEX` (`models/sale.py:26`, migration
`...0002_phase2_domain_models.py:213,236`); `returns.return_number` (`models/return_doc.py:27`).
Uniqueness is probabilistic + DB unique index (no per-day sequence table). Idempotency is
separate (`sales.client_request_id`, unique — `models/sale.py:52-54`).

### E. Customer / supplier information available

- Sale payload: **`customer_id` only** (`schemas/sale.py:143`). Flutter shows a generic
  "Customer" label (`sale_detail_dialog.dart:375-382`).
- `Customer` model: `name, phone, address, balance, debt_ceiling` (+ archive/audit mixins)
  — `models/party.py:14-35`; response `schemas/party.py:19-31`.
- `Supplier` model: `name, phone, address, email, contact_person, notes, balance` —
  `models/party.py:38-68`.
- Suppliers never appear in sale payloads; they appear on purchases — and
  `PurchaseResponse.supplier_name` **is** denormalized (`schemas/purchase.py:112`).
- **No ICE/NIF/RC/tax-id fields exist on customers or suppliers** (repo-wide grep: 0 hits).
- Names ARE available in reports: `SalesDetailRow.user_name/customer_name`
  (`schemas/report.py:277-291`), `VoidedSaleRow.voided_by_name` (:252-263).

### F. Product / variant / unit / selling-unit information

Snapshotted onto each sale line at checkout, never re-read (UX FIX #11) —
`services/sale.py:954-1034`, model `models/sale.py:119-184`:

| Snapshot | Response field |
|---|---|
| Product name / SKU / barcode (variant barcode wins, else product; pack uses pack barcode — `services/sale.py:1013-1017, 971`) | `product_name`, `product_sku`, `product_barcode` |
| Base unit enum (`piece`,`kg`,`pack`,…) | `product_unit` |
| Variant name / selling-unit name / multiplier | `variant_name`, `selling_unit_name`, `selling_unit_multiplier` |
| Unit price / unit cost / quantity / line discount / line total | `unit_price`, `unit_cost`, `quantity`, `line_discount`, `line_total` |

- **Single-language catalog**: `Product.name` `models/catalog.py:65`, `ProductVariant.name`
  :142, `ProductSellingUnit.name` :185, `Pack.name` :303 — **no ar/fr/en product names**.
  UI localization of unit labels is client-side (`strings.dart:19-45` `unitLabel()`).
- **No weight columns**; weights are unit multipliers (`models/catalog.py:192-194`).
- Barcodes exist on product/variant/selling-unit/purchase-unit/pack (unique) —
  `models/catalog.py:66,143,195,242,304` — **the receipt never prints a barcode**.
- Pack rendering today: pack summary line + component lines with `line_total = 0`
  (`services/sale.py:962-1004`).
- Returns carry `quantity_base` explicitly (`schemas/returns.py:146-170`, model
  `models/return_doc.py:137-139`).

### G. Discounts / taxes / totals / payment information

Server-computed totals (`services/sale.py:641-745`):

| Concept | Where | Semantics |
|---|---|---|
| `subtotal` | `:657` | Σ charged line gross |
| line discounts | `:658-660` | per-line `line_discount`, summed for display only |
| invoice `discount` | `:649,672-681` | |
| `total` | `:681` | `subtotal − Σline_discount − invoice_discount` |
| `paid` / `change` | `:682,687,697,741` | |
| `debt` | `:686,696,716` | cash/card ≥ total required; partial `0<paid<total`; credit `paid=0, debt=total`; `customer_id` mandatory when `debt>0` (`:724-734`) |
| `payments[]` | inserted `:884-890` | method+amount only |

**TAX / FISCAL FIELDS: NONE, ANYWHERE.** Repo-wide grep for
`tax|vat|tva|ice|nif|rib|fiscal` in `new_app/backend` → 1 hit, a comment
(`schemas/purchase.py:12` "no tax"); in `new_app/lib` → 0 hits. Phase 0 DB blueprint
*planned* `tax` on sale-line snapshots (`docs/PHASE_0_DATABASE_ANALYSIS.md:49`) — **not
implemented**. Phase 15 must NOT invent fiscal fields (see §7.3, §22 Q1).

### H. Arabic / French / English infrastructure

**Flutter** [MODERN]:
- `AppLocale { ar, fr, en }`, default **`ar`**, persisted — `lib/l10n/locale_provider.dart:5,41`;
  `isRtl` at `:23` (used only by a test; UI relies on implicit RTL).
- String catalogue: `lib/core/strings.dart` (2,443 lines) — `translations` map at :8–12,
  Arabic block :54+ (~764 keys), French :847+, English :1647+; `AppStrings.t(key, locale)`
  falls back to the raw key (:4–6).
- RTL arrives implicitly via `MaterialApp(locale:)` + `GlobalMaterialLocalizations`
  (`lib/main.dart:19-24, 50-54`). **No explicit `Directionality` widget anywhere.**
- Existing print/export keys: `print`, `reprint`, `print_preview`, `print_failed`
  (`strings.dart:400-403` ar / `1193-1196` fr / `1993-1996` en); `export_csv`,
  `export_xlsx`, `export_pdf`, `export_row_limit`, `export_failed`, `export_permission`,
  `export_started`, `export_done`, `export_report_name` (`strings.dart:825-832` ar /
  `1625-1632` fr / `2422-2429` en). `export_xlsx`/`export_pdf`/`export_started`/
  `export_permission` exist but are **unused** (reserved for Phase 15, decision C3).

**Backend: localization-free by design.** No dictionaries; errors carry `message_key`
("a localization key that Flutter will translate" — `core/exceptions.py:26-36`). Report
payloads are neutral English snake_case; Arabic appears only client-side. Known gap: Flutter
does not yet translate `message_key` (no `errors.*` keys in `strings.dart`) — pre-existing,
not Phase 15-owned, but new export/print errors must be handled per §16.

### I. Theme infrastructure

- `lib/theme/app_theme.dart` — `dark()` :8, `light()` :60, `grey()` :112, `_textTheme()` :164;
  typography = `GoogleFonts.cairoTextTheme()` (:165) then color `copyWith` only.
- `lib/core/colors.dart` — `AppColors` palettes + semantic colors.
- **No `ThemeData.fontFamily` anywhere**; **no bundled `.ttf/.otf` in `new_app`**
  (glob `new_app/**/*.{ttf,otf}` → only build artifacts of MaterialIcons/CupertinoIcons);
  `pubspec.yaml:41-42` `assets:` commented out; `new_app/assets/` does not exist.
- **Arabic UI font = Cairo fetched at runtime by `google_fonts`** → an existing offline risk
  (tests disable it: `test/widget/theme_test.dart:11`). Phase 15 PDF output must not
  inherit this risk (§15).

### J. Existing file/export utilities

1. **CSV** (Phase 14, frozen) — client-side:
   - Builder `lib/features/reports/report_csv.dart` (520 lines): `kExportRowLimit = 50000`
     (:24), `csvField` RFC4180 (:28–35), `buildCsv` CRLF (:38–45), `csvBytes` UTF-8+BOM
     (:48–49), `reportCsvFilename` (:52–60), per-report builders (:71–520).
   - Orchestrator `lib/features/reports/report_export.dart` (271 lines): page-walkers with
     cap checks (:41–205), `FilePicker.platform.saveFile(... bytes:)` (:243–247), cancel →
     silent (:248), toasts (:233–271).
   - Entry: `reports_screen.dart:82-240` dispatch, export button gated by `export_data`
     (:247, :273–287).
2. **Temp print file** — `print_service.dart:34-38` (`Directory.systemTemp`), deleted in
   `finally` (:64–70).
3. **Image open** — `product_image_picker_service.dart:32-45` (extension allowlist).
4. **No** `share_plus`, no Downloads logic, no `path_provider` use in app code; `dart:io`
   used in only 4 files. Evidence of save-dialog defaulting to CWD: two untracked CSVs at
   repo root (`new_app/reports_*.csv`).
5. **Backend writes no files**: no `StreamingResponse`/`Content-Disposition`/`.xlsx` hits
   in `new_app/backend/app`.

### K. Flutter desktop platform setup

- `new_app/windows/` — stock Flutter runner (`BINARY_NAME "supermarket_pos"`,
  `windows/CMakeLists.txt:7`); `main.cpp` untouched template (1280×720, `main.cpp:28-30`).
- Linked plugins (`windows/flutter/generated_plugins.cmake:5-11`):
  `flutter_secure_storage_windows` (non-FFI) + `jni` (FFI). From
  `.flutter-plugins-dependencies`: also `file_picker`, `path_provider_windows`,
  `shared_preferences_windows`.
- **No `printing` plugin, no `win32` Dart plugin, no custom method channel, no registry
  writes** (only the stock theme probe:
  `windows/runner/win32_window.cpp:21-27,275`).
- Platforms: Windows only (`.metadata`: `root` + `windows`).
- App data: `Directory.systemTemp` + `file_picker` + `shared_preferences` (locale/theme) +
  `flutter_secure_storage` (credentials). No disk logging.

### L. FastAPI backend setup

- Entry `new_app/backend/app/main.py`: `create_app()` :22, CORS :43–49,
  `RequestIDMiddleware` :50, exception handlers :53, routers :56 (`/api/v1`).
- Feature routers mounted in `app/api/v1/router.py:29-48` (18 modules).
- Auth/permissions: `app/api/dependencies.py` — `get_current_user` :44–100,
  `require_permission(scope)` factory :106–128, `require_any_permission` :131–144.
- Service layer: `app/services/base.py` — `BaseService` :36, `transaction()` :46–74,
  `run_in_transaction()` :76–108. 15 services; repositories in `app/repositories/`.
- Errors: `app/core/exceptions.py` — `AppError(code, status_code, message_key, details)`
  :26–55, typed subclasses :58–130, envelope
  `{"error": {code, message_key, message, details, request_id}}` :253–277; client mirror
  `new_app/lib/network/api_client.dart:52-107`.
- Middleware: CORS + RequestID only (no audit middleware). Logging: structlog
  (`core/logging.py:14-50`).
- **No background tasks / queue / scheduler** (0 hits for `BackgroundTasks|Celery|arq`).
- Audit is **row-level inside service transactions** (§13).
- Config `app/core/config.py:8-50`: only store value is `STORE_NAME = "Supermarket Pro"`
  (:47), exposed by `GET /system/info` (`api/v1/system.py:63-69`). **No store phone /
  address / footer / logo setting exists.**

### M. Python dependency structure

`new_app/backend/pyproject.toml:6-19` (runtime): `fastapi, uvicorn[standard], sqlalchemy,
alembic, psycopg2-binary, pydantic, pydantic-settings, python-jose[cryptography],
passlib[argon2], python-multipart, httpx, structlog`. Dev (`:21-29`): `pytest, pytest-asyncio,
pytest-cov, httpx, ruff, mypy`.

**Absent (verified): `reportlab`, `openpyxl`, `xlsxwriter`, `arabic-reshaper`,
`python-bidi`, `fpdf`, `weasyprint`, `pandas`.** No lockfile anywhere; installs via
`pip install -e ".[dev]"` (`docs/PHASE_1_SETUP.md:18`) into `new_app/backend/.venv`.
Legacy `python_app/requirements.txt:4-10` declares `reportlab>=4.0.0`,
`arabic-reshaper>=3.0.0`, `python-bidi>=0.4.2`, `openpyxl>=3.1.0` (plus unused
`python-docx`, `qrcode`) — **legacy-only**, not installed for the modern backend.

### N. `pubspec` dependencies

`new_app/pubspec.yaml` (SDK `^3.12.2`; lock: `flutter >=3.44.0`):
`flutter_riverpod ^2.6.1`, `go_router ^14.8.1`, `dio ^5.7.0`, `intl ^0.20.1`,
`google_fonts ^6.2.1`, `freezed_annotation`, `json_annotation`, `shared_preferences`,
`flutter_secure_storage ^9.2.4`, `file_picker ^10.1.2`, `cupertino_icons`.
Dev: `flutter_lints`, `build_runner`, `freezed`, `json_serializable`, `mocktail`.

**Absent (verified in pubspec.yaml + pubspec.lock): `pdf`, `printing`, `excel`, `share_plus`.**
`path_provider`/`win32` exist only as transitive deps, never imported by app code.

### O. Windows-specific capabilities already present

| Capability | Evidence | Status |
|---|---|---|
| Spawn PowerShell, pipe text to default printer (`Out-Printer`) | `print_service.dart:41-53` | working (text only) |
| Write/delete temp files | `print_service.dart:34-70` | working |
| Native Windows save dialog (comdlg32 `GetSaveFileNameW`) | `file_picker` 10.3.10 → `report_export.dart:243-247` | working |
| Native open/extension-filter dialogs | `product_image_picker_service.dart:32-45` | working |
| Any print dialog / printer enumeration / copies control | — | **none** |
| ESC/POS / raw printer channel / `win32print` | — | **none** |
| PDF generation | — | **none** |
| Registry read | `win32_window.cpp:21-27` (theme only) | stock runner |

---

## 2. LEGACY PRINTING AUDIT

All legacy ReportLab code lives in **one file**: `python_app/gui/main_window.py` (17,326
lines). No other legacy module imports reportlab/platypus/pdfgen. Dependencies pinned at
`python_app/requirements.txt:5,8,9,10`.

### 2.1 Inventory of legacy entry points

| # | Function | Lines | Status |
|---|---|---|---|
| A | `_invoice_pdf_font(self)` — OS font probe | 11596–11617 | active |
| B | `_create_invoice_pdf(invoice_number, paper="A4", auto_print, direct)` | 11619–11929 | active |
| C | `print_invoice_80mm(invoice_number, direct=False)` | 11931–11941 | active |
| D | `print_invoice_a4(...)` | 11943–11953 | active |
| E/F/G | `export_report_excel/csv/pdf(period)` | 12989–13414 | **dead (no callers)** |
| H | `_ask_export_path(kind, default_name)` | 12967–12987 | active |
| I/J | `_export_active_report_csv/excel()` | 13907–14124 | active (menus :13844-13845) |
| K | `_export_shift_report_pdf()` — Z-report 80mm/A4 | 14126–14282 | active (menu :13847) |

Print triggers: post-payment `:10863-10883` (`ask_before_print`, `default_paper`,
`auto_print_invoice`, `direct=True`); invoice dialog `:12126-12150`; history reprint
`:12403-12415`; settings `:15192-15308` with shipped config
`python_app/config/app_settings.json:5-10` (`invoice_footer: "شكرًا لزيارتكم"`,
`default_paper: "80mm"`, both auto flags **false**).

No `win32print`, no `subprocess` print, no ESC/POS anywhere in legacy.

### 2.2 Legacy invoice PDF — extracted specification

**Fonts** (`:11596-11617`): candidate OS paths `C:/Windows/Fonts/tahoma.ttf`,
`arial.ttf`, `Arial.ttf`, `segoeui.ttf`, `/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf`
→ registered as `InvoiceFont`, else **fallback `Helvetica`** (which cannot render Arabic).

**Paper** (`:11728-11742`, verified):

```
80mm: width=80*mm; height=max(160*mm, (125+items*18)*mm); margins (R,L,T,B)=(4,4,5,5)mm;
      content=72mm; body 9pt / title 15pt
A4:   pagesize=A4 (210×297mm); margins=(13,13,12,12)mm; content=184mm; body 10.5pt / title 19pt
```

**Layout** (`:11781-11908`): store name (title) → "فاتورة بيع" → invoice no → date →
customer → optional phone/address → rule → item table → (optional item-discount note) →
totals table (الإجمالي/الخصم/الصافي/المدفوع/الباقي/الدين المتبقي) → footer text →
A4-only canvas footer `Supermarket Pro • page` (`:11897-11906`).

Item table: header `[المجموع, السعر, الكمية, المنتج]` → visually RTL (product on the
right); column shares 80mm `0.27/0.23/0.15/0.35`, A4 `0.24/0.20/0.14/0.42`
(`:11799-11838`); pack components indented `"    ↳ name"` with qty only, pack header gets
`"🎁 "` (`:11810-11831`); `repeatRows=1` (`:11851`).

**No logo is ever drawn** (`reportlab.platypus.Image` never imported), despite
`PHASE_0_BUSINESS_RULES.md` §12 saying A4 is "full-page invoice with logo".

**Arabic** (`:11701-11714`): `arabic_reshaper.reshape` → `bidi.algorithm.get_display`
applied to **every** string (including pure-numeric money), then drawn with the TTF.
Invoice styles do **not** set `wordWrap="RTL"` (report/Z styles do — legacy inconsistency).

**Data** (`:11629-11680`): SQL over `sales`+`customers` (customer **name**), `sale_items`
name/qty/price/total/`item_discount` (with silent column-fallback try/except). Money format
`f"{float(v or 0):,.2f} دج"`. Derived `net = total − discount`, `remaining = net − paid`.

**NOT printed by legacy:** cashier, payment method, barcode/QR, unit of measure,
**any fiscal/legal field (ICE/NIF/RC/TVA/tax stamp — zero occurrences in printed output)**,
logo, void status, customer phone/address on the invoice body.

**Save/print** (`:11682-11697, 11910-11929`): `direct` → `%TEMP%\SupermarketPro\` (same
name overwrite) else Save-As dialog; `auto_print` → `os.startfile(path, "print")` (shell
print verb → default printer) with fallback to merely opening the file; filename passed
through the translator `t()` (locale-dependent names).

**Z-report** (`:14126-14282`): 80mm×**400mm fixed** page or A4; device name, timestamp,
gross/cash/credit, discounts/returns/expenses, `net drawer cash = paid_cash −
drawer_expenses − returns_total` (`:14200`); save-dialog only, no auto-open.

**Legacy Excel** (`:12989-13048` dead, `:13999-14124` active): openpyxl `Workbook`,
`ws.sheet_view.rightToLeft = True` on **every** sheet (verified `:12999, 13007, 13010,
13013`), freeze panes `A2`, autofilter, column-letter widths, header fills, multi-sheet.
**Legacy CSV** (`:13907-13997`): `utf-8-sig`, sections, thousands separators.

### 2.3 Font files in the repository

Repo-wide scan `*.ttf|*.otf|*.ttc`: **8 files, all Flutter build artifacts**
(MaterialIcons, CupertinoIcons). **No Arabic font, no PDF font is bundled anywhere**
(nothing under `python_app/`, `reference/`, `python_app.zip`, or `new_app/` sources).
No `.pdf` files exist in the repo.

### 2.4 Classification (legacy behavior — evidence only)

**A. Preserved presentation behavior** (expected output shape, mirrored today or adopted):
1. Document order: identity header → items → totals → closing message.
2. `INV-YYYYMMDD-HHMMSS-mmm` numbering surfaced on the receipt (modern adds `-xxxx`).
3. Visually RTL item table (product column on the right) for Arabic.
4. Pack header line + `↳` component lines without their own money values.
5. `net = total − discount`, `remaining = net − paid` display semantics.
6. Reprint entry points from history/detail dialogs.
7. CSV with UTF-8 BOM (kept by Phase 14).
8. Z-report economics: cash − drawer expenses − returns = net drawer cash (if Z-report is
   ever built).
9. Print failure never reported as success; print flow separated from the transaction.
10. The 80mm-vs-A4 product concept and per-print paper choice.

**B. Obsolete behavior (must NOT be carried over):**
1. ReportLab Platypus code itself and its SQL-over-GUI structure.
2. Manual `reshape → get_display` on *every* string including pure numbers.
3. `os.startfile(path, "print")` shell verb + silent fallback to "open the file".
4. `%TEMP%\SupermarketPro` same-name overwrite spool.
5. Hard-coded `C:/Windows/Fonts/*` probing with `Helvetica` fallback (proprietary fonts,
   silent Arabic loss on non-Windows).
6. Dead exports `export_report_excel/csv/pdf` (no callers) and orphaned translation key.
7. Save-As dialog as the prerequisite for printing (reprint double-dialog).
8. Fixed 80mm×400mm Z page; single-tall-page 80mm invoice (no roll pagination).
9. Locale-translated filenames.
10. Deprecated openpyxl `cell.font.copy()` style API (`:13023-13041`).
11. Declared-but-unused deps (`python-docx`, `qrcode`).

**C. Behavior that must be verified (UNVERIFIED):**
1. `ask_before_print` vs `auto_print_invoice` interaction — shipped config never
   auto-prints (`app_settings.json:7,10`).
2. 80mm PDF → thermal printer: relies on driver scaling; **no media-size negotiation** —
   must be re-tested on real hardware.
3. `get_display` on numeric money strings (`:11713`) — sign/digit reordering risk.
4. Invoice styles lacking `wordWrap="RTL"` → long-name wrapping defects (do not preserve).
5. Linux/macOS irrelevance: modern target is Windows only; legacy Debian font fallbacks
   are irrelevant.
6. Legacy `sale_items.item_discount` fallback swallowing schema errors (`:11649-11678`).

**D. Behavior with no modern equivalent (gaps):**
1. Any PDF output at all (invoices, reports, Z-report).
2. A4 invoice format and paper selection.
3. Store header (name/phone/address), invoice footer message, customer name on receipt.
4. Z-report / end-of-shift PDF.
5. XLSX export (string `export_xlsx` exists but unused).
6. Auto-print/ask-before-print settings.
7. Logo and fiscal block — **also missing in legacy**; a green-field requirement, not a
   regression (see §22 Q1/Q2).

---

## 3. DOCUMENT TYPES

### 3.1 Which modern documents Phase 15 should render

Rule: **do not invent document types.** A document qualifies iff (a) the roadmap or a
frozen contract asks for it, and (b) a modern endpoint/payload already carries its data.

| Candidate | Verdict | Basis |
|---|---|---|
| Completed sale invoice / receipt (80mm + A4) | **IN** — roadmap acceptance "80mm/A4 invoices print correctly"; payload complete | `pos.py:134-145`, §1.A |
| Sale reprint | **IN** — same payload, Phase 8 reprint contract | `pos.py:120-131`, `sale_detail_dialog.dart` |
| Voided sale (invoice marked VOID) | **IN (as invoice with VOID marking)** — payload carries `status/voided_at/void_reason` | `schemas/sale.py:144,155-159` |
| Return document (80mm + A4) | **IN** — full re-fetchable payload, "detail / reprint" docstring | `returns.py:98-109`, `schemas/returns.py:173-191` |
| Purchase document (A4) | **OPTIONAL / owner** — payload complete (`supplier_name`, lines, totals) but roadmap Phase 15 lists only "invoices" | `purchases.py:73-85`, §22 Q7 |
| Financial / products / categories / daily / hourly / peak-hours / slow-moving / voided / sales detail / suppliers report exports (CSV+XLSX+PDF) | **IN** — Phase 14 frozen contract + roadmap "Excel/CSV/PDF export" | §9, §10, §11 |
| Dashboard PDF | **OPTIONAL / owner** — payload exists, not in contract, "where appropriate" only | `schemas/report.py:352+`, §22 Q8 |
| Z-report / shift report | **UNSUPPORTED** — no modern shift concept/endpoint (legacy-only) | §2.1 K |
| Expense list/summary export | **OUT** — not in Phase 14 export set; Phase 15 must not widen the contract | `api/v1/expenses.py` |
| Debt ledger export/print | **OUT** — not in contract | `api/v1/debts.py:30` |
| Fiscal/official invoice variants, barcode/QR labels, delivery notes | **UNSUPPORTED** — no domain data | §1.G |

### 3.2 Document matrix

Legend: ✅ supported/decided · ⬜ not applicable · ❌ unsupported · 🟡 owner decision needed
· ⚠ data source exists but not exposed yet (see §1.A/E gaps).

| # | Document | Source endpoint/service | Printable | PDF | 80mm | A4 | XLSX | CSV | Arabic | Reprint | Current data source |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Sale invoice (completed) | `GET /api/v1/sales/{id}` (+ `/by-invoice/{n}`) → `SaleService.get_sale` | ✅ | ✅ | ✅ | ✅ | ⬜ | ⬜ | ✅ | ✅ | `SaleResponse` (`schemas/sale.py:137-169`) — ⚠ no cashier/customer/store header |
| 2 | Sale reprint (history) | `GET /api/v1/sales` → detail | ✅ | ✅ | ✅ | ✅ | ⬜ | ⬜ | ✅ | ✅ | same |
| 3 | Voided invoice | `GET /api/v1/sales/{id}` (`status=void`) | ✅ | ✅ | ✅ | ✅ | ⬜ | ⬜ | ✅ | ✅ | `SaleResponse` + `voided_at/void_reason/voided_by` |
| 4 | Return document | `GET /api/v1/returns/{id}` | ✅ | ✅ | ✅ | ✅ | ⬜ | ⬜ | ✅ | ✅ | `ReturnResponse` (`schemas/returns.py:173-191`) |
| 5 | Purchase document | `GET /api/v1/purchases/{id}` | 🟡 | 🟡 | 🟡 | 🟡 | ⬜ | ⬜ | ✅ | ✅ | `PurchaseResponse` (`schemas/purchase.py:105-127`) |
| 6 | Financial report | `GET /reports/financial` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `FinancialReportResponse` (`schemas/report.py:32`) |
| 7 | Products report | `GET /reports/products` (server cap 500) | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `ProductReportResponse` (:126) |
| 8 | Categories report | `GET /reports/categories` (≤500) | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `CategoryReportResponse` (:157) |
| 9 | Daily report | `GET /reports/daily` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `DailyReportResponse` (:182) |
| 10 | Hourly report | `GET /reports/hourly` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `HourlyReportResponse` (:198) |
| 11 | Peak-hours report | `GET /reports/peak-hours` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `PeakHoursReportResponse` (:213) |
| 12 | Slow-moving report | `GET /reports/slow-moving` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing, no totals) | ✅ | ⬜ | `SlowMovingResponse` (:237) |
| 13 | Voided report | `GET /reports/voided` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing, no totals) | ✅ | ⬜ | `VoidedReportResponse` (:266) |
| 14 | Sales detail report | `GET /reports/sales` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing, totals) | ✅ | ⬜ | `SalesDetailResponse` (:303) |
| 15 | Suppliers report | `GET /reports/suppliers` | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ (existing) | ✅ | ⬜ | `SupplierReportResponse` (:320) |
| 16 | Dashboard snapshot | `GET /dashboard` | 🟡 | 🟡 | ⬜ | 🟡 | 🟡 | ❌ | 🟡 | ⬜ | `DashboardResponse` (:352) |
| 17 | Z-report / shift report | ❌ no endpoint | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | legacy only (`main_window.py:14126`) |
| 18 | Expense / debt exports | endpoints exist | ❌ | ❌ | ⬜ | ❌ | ❌ | ❌ | ❌ | ❌ | out of contract |

Notes:
- Report rows/figures must come from **the exact Phase 14 payloads** — §9/§10 map them
  field-by-field; no new formulas.
- "Reprint" for reports = re-request with same filters (not a stored document).
- ⚠ gaps for rows 1–4 (customer name, cashier name, store identity) are resolved by
  additive payload extension in Step B (§4.5.3) — flagged as gate **G19**.

---

## 4. PDF ARCHITECTURE DECISION

### 4.1 The three realistic options

| | **Option A — Python backend renderer (ReportLab)** | **Option B — Flutter/Dart renderer (`pdf` package)** | **Option C — Hybrid (split rendering)** |
|---|---|---|---|
| Meaning | Backend builds every PDF (invoices + reports) from `DocumentData`; Flutter only previews/prints/saves bytes | Dart `pdf`/`printing` widgets build every PDF in the app; backend only serves data (as today) | e.g. receipts rendered in Dart, report PDFs in Python (or vice versa) |
| Arabic shaping | `arabic_reshaper` + `python-bidi` per line — **legacy-proven on this exact content** [LEGACY `main_window.py:11701-11714`] | `pdf` package ships `src/pdf/font/arabic.dart` + `bidi_utils.dart` (upstream tests exist), but history is rocky (issue #1401 "not support Arabic", #1920 Mar-2026 bidi crash on diacritics, closed #743 "RTL not implemented") — **[UNVERIFIED for our text]** | two shaping stacks to maintain |
| RTL layout | Explicit: layout code decides column order per locale (deterministic) | `pw.TextDirection.rtl` + manual layout; table mirroring is hand-rolled | same as both |
| Arabic fonts | Bundle OFL TTF into backend, `pdfmetrics.registerFont` (+ family), embedded subsets | Bundle same TTF as Flutter asset, `pw.Font.ttf(...)` | duplicated asset wiring |
| A4 | native (`reportlab.lib.pagesizes.A4`) | native (`PdfPageFormat.a4`) | native both |
| 80mm | native custom `(80*mm, H)` pagesize — legacy-proven | native `PdfPageFormat(80*mm, H)` | native both |
| Deterministic output | ✅ fixed library, stable bytes per input; pytest-assertable geometry | ✅ mostly; layout engine changes across package versions can shift bytes | mixed |
| Offline | ✅ pure Python, no network | ✅ pure Dart **provided fonts are bundled** (must not rely on `google_fonts` runtime fetch) | ✅ |
| Windows desktop | ✅ backend runs locally at `127.0.0.1:8000` | ✅ in-process | ✅ |
| Preview support | ❌ backend cannot draw UI → client must rasterize bytes (needs a preview lib anyway) | ✅ `PdfPreview` widget included | ✅ (client preview lib still needed) |
| Printing | ❌ backend cannot reach the local printer → client prints bytes | ✅ `Printing.layoutPdf` in-process | ✅ |
| Testing | ✅ pytest: geometry via MediaBox, shaping via pure functions, structure via open re-render | ⚠ Flutter tests + widget goldens; byte assertions weaker | two test stacks |
| Maintenance | one renderer for ALL documents; team already owns Python backend | one renderer; team already owns Flutter UI | **two renderers + two DocumentData models — worst** |
| Performance | ~ms per receipt page locally; report PDF bounded by row caps | similar; rasterized preview costs more | mixed |
| Dependency footprint | `reportlab` + `arabic-reshaper` + `python-bidi` (backend) | `pdf` (+ `printing` for print/preview) | **all of the above** |

### 4.2 Roadmap and Phase 0 constraints (decisive)

The roadmap Phase 15 split [PHASE-0 `docs/PHASE_0_ROADMAP.md:641-651`] is explicit:

- **Backend Work: "Print service, Export service, PDF generation, Excel generation"**
- **Flutter Work: "Print dialog, Export format selection, Print preview"**

Reinforced by:
- `PHASE_0_MASTER_SPECIFICATION.md:43`: "A local FastAPI service owns … printing/export jobs".
- `PHASE_0_FEATURE_MATRIX.md:17`: target remedy for print/export = **"backend jobs/templates"**.
- `PHASE_0_PERFORMANCE_AUDIT.md:12`: "PDF/XLSX work runs from UI path" is a **defect**;
  remedy = backend job worker.
- `PHASE_14_REPORTS_DASHBOARD_ANALYSIS.md:512, DEF-3`: "Phase 14 freezes the export data
  contract so Phase 15 only adds a renderer"; server-side export service deferred to 15.
- `PHASE_0_ARCHITECTURE.md:61`: printing happens after commit and cannot roll back a sale.

These rules place **generation on the backend**. Flutter's roadmap duties (dialog, format
selection, preview) are client concerns that consume generated bytes.

### 4.3 Decision — G2

> **RECOMMENDATION: Option A — Python backend renderer using ReportLab.**
>
> - Backend renders **all** PDFs (80mm invoices, A4 invoices/returns/purchases, report PDFs).
> - Backend renders **all** XLSX (§5).
> - Flutter uses the `printing` package **only** for preview + system print dialog
>   (plumbing, not authoring) and `file_picker` for save.
> - Option C (split rendering) is **rejected**: two document models, two shaping pipelines,
>   two test stacks, and divergent output between an 80mm receipt and its A4 twin.
> - Option B is **rejected as the authoring stack** (roadmap assigns PDF generation to the
>   backend; ReportLab is legacy-proven on this content; one renderer serves invoice+report;
>   server-side audit applies to actual generation). It remains the *fallback* if the §4.6
>   Arabic spike fails (see G7).

### 4.4 If Option A: exact architecture definition

**Renderer package:** `reportlab` (Platypus flowables for tables/totals; `canvas` only for
page furniture). Pure-Python, BSD-3-Clause, offline, mature.

**Module layout (proposed, Step B):**

```
new_app/backend/app/printing/
  __init__.py
  fonts.py          # font registration (single source of truth, §15)
  text.py           # shape_text(), sanitize_text(), locale direction helpers
  styles.py         # shared paragraph/cell styles (sizes, colors, RTL wrap)
  document_data.py  # DocumentData dataclasses (invoice/return/purchase/report)
  templates/
    invoice_80mm.py # builds flowables from InvoiceDocumentData
    invoice_a4.py
    report_table.py # generic report PDF (title/meta/table/totals)
  render.py         # render_document(data, paper, locale) -> bytes
```

**Arabic shaping strategy:**
1. `sanitize_text()` first (§17.3 — strip control/bidi-override chars).
2. `shape_text(value, locale)`: **only when the string contains U+0600–U+06FF**:
   `arabic_reshaper.reshape(v)` → `bidi.algorithm.get_display(v)`. For non-Arabic strings,
   return as-is (fixes legacy defect of bidi on pure numbers — §2.4 C3).
3. Money/quantities are formatted by one formatter (`format_money`, `format_qty`) producing
   Western digits + `DA` label from existing localization keys — never `get_display`-ed.
4. Paragraph styles for Arabic set `wordWrap='RTL'` + `alignment=TA_RIGHT` (legacy report
   styles proved this; legacy invoice styles omitted it — do not preserve that bug).
5. `python-bidi` `base_dir` set per detected content; mixed ar+Latin lines handled by the
   bidi algorithm as a whole string.

**Font strategy:** see §15 — bundle OFL fonts inside the backend package; **fail typed**
(`MISSING_FONT`) if registration fails; never fall back to `Helvetica` for Arabic and never
probe `C:/Windows/Fonts/*`.

**Page sizing:**
- 80mm: `pagesize = (80*mm, computed_height)` (§7.6); margins from §7.2.
- A4: `pagesize = A4`, margins §8.2; multi-page with `repeatRows=1` and canvas footer.

**Reusable document model (`DocumentData`)** — see §4.5 and §8.5.

**Template architecture:** templates receive a fully-built `DocumentData` and a
`TemplateContext` (locale, direction, styles, formatters). Templates contain **zero
business logic** — no totals computation, no discount rules, no DB access. Anything the
template needs must already be on `DocumentData` (derived fields computed once in
`document_data.py`, unit-tested).

### 4.5 Unified DocumentData contract (G8)

**Direction:** `DocumentData -> Template -> Renderer` (explicitly preferred over
business logic inside templates).

```
ExportRequest / PrintRequest
        │  (existing services build payloads)
        ▼
  ReportData  (exact Phase 14 response objects)     ── for reports
  DocumentData (invoice/return/purchase view-model) ── for documents
        │
        ├──► CSV renderer   (frozen Phase 14 client builder — §11)
        ├──► XLSX renderer  (openpyxl — §5, §10)
        └──► PDF renderer   (ReportLab — §4.4, §7, §8, §9)
```

**4.5.1 ReportData** = the existing Phase 14 response schemas verbatim
(`schemas/report.py`). No transformation, no re-query, no recomputation.

**4.5.2 InvoiceDocumentData (proposed view-model, built in backend):**

| Block | Fields | Source |
|---|---|---|
| `store` | `name` (+ `phone`, `address`, `footer`, `logo` **iff** provided — Q1/Q2/Q3) | `settings.STORE_NAME` today (`core/config.py:47`) |
| `header` | `invoice_number`, `document_title` (localized key), `sale_date`, `status`, `voided_at/reason/by_name` | `SaleResponse` |
| `cashier` | `name` **iff exposed** (⚠ additive field, §1.A) | `sales.user_id` → `users.full_name` |
| `customer` | `id`, `name`, `phone` **iff exposed** (⚠ additive) | `customers` row via `customer_id` |
| `lines[]` | name, variant, sku/barcode, qty, unit label, unit_price, line_discount, line_total, base_qty (derived `qty × multiplier`), `kind ∈ product|pack_summary|pack_component` | `SaleLineResponse` + rule from `pos_models.dart:567-572` |
| `totals` | subtotal, line_discounts_sum (derived), invoice_discount, total, paid, change, debt | `SaleResponse` + `services/sale.py:641-745` semantics |
| `payments[]` | method, amount (+ localized labels) | `SaleResponse.payments` |
| `meta` | `device_id`, `idempotent_replay=false`, `note`, `locale`, `generated_at` | payload |

ReturnDocumentData mirrors this with `ReturnResponse` fields (`return_number`,
source `invoice_number`, `reason`, `refund_total` etc.). PurchaseDocumentData uses
`PurchaseResponse` (`supplier_name`, `paid`, `status`, `purchase_date`).

**4.5.3 Additive payload extension (needed for a complete receipt — G19):**
`SaleResponse` gains optional fields served by existing DB data:
`customer_name`, `cashier_name`, and a `store` block (`name` [+ contact when Phase 17
settings exist]). Additive optional fields preserve every Phase 8/14 contract (precedent:
additive schema growth in Phases 11–14). Until implemented, templates must tolerate `null`
and omit those rows (never print blanks/placeholders).

### 4.6 Arabic spike requirement (G7)

Before Step B implementation, a throwaway spike must prove on this machine:
1. `reportlab` + bundled font renders connected Arabic with correct RTL order for an
   80mm receipt and an A4 page (screenshot + PDF byte check).
2. Mixed `منتج 123 / Product 456` lines, negative money, and Arabic diacritics (if the
   owner's data contains them) do not reorder digits or signs.
3. Font license confirmed and packaged (§15).

If the spike fails → fall back to Option B authoring for invoices only, re-evaluating G2.
Until then **G7 = UNVERIFIED**.

---

## 5. XLSX ARCHITECTURE DECISION

### 5.1 Options

| Criterion | **A — Backend `openpyxl`** | **B — Flutter/Dart `excel` package** |
|---|---|---|
| RTL support | ✅ `ws.sheet_view.rightToLeft = True` — **legacy-proven** (`main_window.py:12999,13007,13010,13013`) | ❌ no documented `rightToLeft` sheet view API |
| Arabic text | ✅ raw strings (Excel shapes natively — no reshaping needed) | ✅ raw strings |
| Formatting (number/date formats, fonts, fills) | ✅ full (`0.000`, `yyyy-mm-dd`, header styles) | ⚠ partial |
| Merged cells | ✅ | ✅ |
| Formulas | ✅ (we will write **values only** — §10) | ⚠ |
| Multiple sheets | ✅ | ✅ |
| Column widths / row heights | ✅ | ✅ |
| Freeze panes / autofilter | ✅ | ✅ |
| Print settings (landscape, fit-to-width, repeat header row) | ✅ (`ws.page_setup`, `ws.print_title_rows`) | ❌ |
| Offline | ✅ | ✅ |
| Testing | ✅ pytest re-opens workbook and asserts cells | ⚠ widget/unit tests, weaker |
| Maintenance | mature, ubiquitous, legacy-proven here | younger, less capable, second stack |
| Dependency footprint | 1 backend dep | 1 Flutter dep (but then backend would still need openpyxl-free… or exports become client-side and audit weakens) |
| Server-side audit | ✅ generation happens server-side | ❌ client-side generation → self-reported audit |
| Alignment with roadmap ("Backend: Excel generation") | ✅ `PHASE_0_ROADMAP.md:645` | ❌ contradicts roadmap |

### 5.2 Decision — G3

> **RECOMMENDATION: Option A — backend `openpyxl`.**
>
> Preserves the Phase 14 data contract: `ReportData (exact payload) → rows → workbook`.
> No client re-query, no new formulas, no RTL compromise. Server-side generation makes
> §13 export audit real rather than self-reported.

### 5.3 Architecture definition

```
new_app/backend/app/exporting/
  __init__.py
  contract.py     # row/column spec per report (single source shared with tests)
  xlsx.py         # render_xlsx(report_slug, payload, locale, filters) -> bytes
  (csv.py)        # OPTIONAL later, byte-parity gated — §11.3 / G31 (not in Step B by default)
```

- Large sheets use `openpyxl.Workbook(write_only=True)` above a row threshold (§14).
- Workbook written to an in-memory buffer / spooled temp file, never to a user path.
- Header styles derived from one theme module (mirroring the Phase 14 table look:
  header fill, bold white header font — legacy precedent `main_window.py:14035-14045`).

---

## 6. PRINT ARCHITECTURE

### 6.1 Analysis of the five approaches

| Approach | Verdict for this project |
|---|---|
| **A. Generate PDF then print** | **PRIMARY.** One artifact serves preview, print, and save. Matches legacy behavior (PDF → printer) and roadmap (backend generates). |
| **B. Direct Windows printing (existing)** | `Out-Printer` (current `print_service.dart:41-53`) prints **text only** — cannot carry PDF layout, RTL table, or A4. Shell print verb (`os.startfile(path,'print')` legacy) gives **no** dialog/copies/paper control and silently falls back to "open file". Keep `Out-Printer` only as a non-PDF fallback? **No** — silent alternates are forbidden; the text path is superseded (§6.5). |
| **C. Thermal-specific (ESC/POS raw)** | Not present anywhere (0 hits). Requires a raw channel (`win32print`/vendor SDK), printer-specific code pages for Arabic, no preview fidelity, new native deps, and hardware we do not have. **DEFERRED** to owner decision + hardware (G21, §22 Q4). |
| **D. System print dialog** | **PRIMARY for the print step.** Printer selection, copies, paper size, and preferences are OS-guaranteed concerns — delegate to Windows via the `printing` plugin (`Printing.layoutPdf`), with PowerShell `Start-Process -Verb Print` as a documented fallback (default printer, no dialog). ⚠ exact dialog behavior on Windows = **UNVERIFIED (G20)**. |
| **E. Application print preview** | **PRIMARY.** Replace the text preview (`sale_detail_dialog.dart:249-286`) with `PdfPreview` from the `printing` package (rasterized, zoomable, page-accurate). Keeps the existing confirm-cancellation semantics (cancel → no print, no toast). |

### 6.2 Decision — G4

> **Recommended flow (backend render + client preview/print):**
>
> ```
> PrintRequest { document_type: sale|return|purchase, document_id, paper: 80mm|A4, locale }
>      │  POST /api/v1/print          (permission per document type — §12.3)
>      ▼
> backend: DocumentData builder → template → ReportLab → PDF bytes (+ audit — §13)
>      │  application/pdf (+ sanitized Content-Disposition filename)
>      ▼
> Flutter: PdfPreview (preview, cancel, zoom)  ──confirm──► Printing.layoutPdf
>                                          │                    │
>                                          │              Windows print dialog
>                                          │              (printer/copies/paper)
>                                          ▼
>                                    Save via file_picker (always available)
> ```

- Print failures surface exactly like today: typed, localized, **never success-on-failure**
  (`sale_detail_dialog.dart:298-313` preserved).
- Printing stays **outside the sale transaction** (Phase 8 rule, `print_service.dart:1-5`;
  `PHASE_0_ARCHITECTURE.md:61`).
- The `PrintService` abstraction is **kept** (injectable for tests) but gains a PDF method
  (`printPdf(Uint8List)`) implemented via the `printing` plugin; `printText` becomes
  legacy-internal (its receipt text builder `buildReceiptText` is superseded by the PDF
  preview — snapshot tests migrate to DocumentData fixtures, §19).

### 6.3 80mm thermal strategy (G21)

**Recommended default: print an 80mm-wide PDF through the Windows printer driver**
configured for 80mm paper — i.e., exactly the legacy mechanism, minus its defects.

| Question | Answer |
|---|---|
| Why this over ESC/POS? | Zero new native deps, preview == print (WYSIWYG), Arabic handled by the one shaping pipeline, legacy-proven on this content, works with any Windows driver (USB or network). |
| What the app controls | PDF page width 80mm, margins, content, filename, invoking the print dialog. |
| What the driver/printer must provide | Media set to 80mm, correct scale 100%. |
| Guaranteed by current environment | ✅ PDF generation, ✅ temp files, ✅ PowerShell invocation, ✅ save dialogs. |
| **Requires runtime/device verification** | ⚠ print dialog availability of the `printing` plugin on Windows; ⚠ 80mm media negotiation/scale; ⚠ network printers; ⚠ multi-copy; ⚠ Arabic rasterization on device; ⚠ long-receipt roll feed (§7.6). |
| If verification fails | Fallback 1: `Start-Process -Verb Print` (default printer, no dialog). Fallback 2: save-PDF + user prints from a viewer. ESC/POS stays deferred (owner, Q4). |

### 6.4 Printer selection / copies / paper / margins

- **Selection, copies, paper, orientation, scaling** → Windows print dialog
  (OS-guaranteed once invoked). The app must not hardcode a printer name.
- Application-level defaults: paper default `80mm` for documents, `A4` for reports
  (legacy `default_paper` precedent, `app_settings.json:8`); user can switch in the
  preview before printing.
- App-side margins live in the templates (§7.2/§8.2) — the driver must be at 100% scale
  (documented in QA plan §19.3).

### 6.5 Relationship to the existing text printer

Phase 15 replaces text receipt printing with PDF printing as the single path. No silent
fallback between the two (no "if PDF fails, print text" — that would hide failures). The
text builder remains untouched until its tests are migrated (§19.2), then removed in the
implementation step that ships PDF printing, keeping: `PrintService` abstraction,
`printServiceProvider`, non-blocking print, localized failure.

---

## 7. 80MM THERMAL SPECIFICATION

### 7.1 Page geometry

| Property | Value | Basis |
|---|---|---|
| Page width | **80 mm (226.77 pt)** | legacy `main_window.py:11730` [LEGACY] |
| Margins | left/right **4 mm**, top **5 mm**, bottom **5 mm** | legacy `:11733` |
| Content width | **72 mm** | derived |
| Base body font | **8.5–9 pt** | legacy 9pt (`:11735`) |
| Title (store name) | **14–15 pt bold, centered** | legacy 15pt |
| Meta text | **7.5 pt** | legacy report meta scale |
| Line rules | 0.5–0.8 pt hairlines | legacy `:11787,11841` |

### 7.2 Content order (top → bottom)

1. **Store identity block**: `store.name` (title, centered); optional phone/address lines
   when available (Q3); `document_title` = localized `invoice`/`return` label.
2. **Document meta**: invoice/return number, date+time (locale display, UTC source),
   device id (if present), cashier name (⚠ if exposed, G19), **VOID banner + reason**
   when `status = void` (rendered as a bold boxed overlay line — never hides totals).
3. **Customer block**: name (or localized "cash customer" when `customer_id = null`),
   phone if available; omitted entirely when unknown.
4. **Item rows** (visual RTL when `locale = ar`): columns
   `product | qty×unit | unit price | line total` (72 mm shares ≈ 40/18/20/22 %).
   - Row 1: name (+ ` (variant)` when present); Row 2 (7.5 pt): `sku` / selling unit /
     `Base: <qty> <unit>` (derivation `qty × multiplier` — same as `pos_models.dart:567-572`).
   - Pack summary rows marked with a text marker (`[pack]`/localized — **no emoji** unless
     the bundled font proves the glyph, §15.5); pack component rows indented `  └` with
     **no money cells** (mirrors legacy `:11814-11825` and `line_total = 0` semantics).
   - Per-line discount shown as a second-line note when `line_discount > 0`.
5. **Totals block** (label right / value left in RTL):
   `subtotal`, `line discounts` (Σ, shown when ≠ 0), `invoice discount` (when ≠ 0),
   **`total`** (bold, boxed), `paid`, `change`, `debt` (only when > 0), `payment method`
   (localized label from existing keys `label_cash/card/partial/credit`), payments list
   when `payments[]` has >1 row. All values straight from the payload — no recomputation
   beyond the Σline-discount derivation (tested for consistency with
   `subtotal − total − invoice_discount`).
6. **Footer**: store name again + optional owner footer text (Q3); NO invented legal text.
7. **Barcode/QR**: **NOT rendered** — the domain has product barcodes only; there is no
   invoice barcode/QR data and no fiscal QR (would be invention). Owner may add later (Q1).

### 7.3 Explicitly missing / unknown legal-fiscal fields (owner review — do NOT invent)

| Field | Status |
|---|---|
| ICE / NIF / RC / ART / NIS | **absent from entire domain** (§1.G) |
| TVA / tax rate / tax amount | **absent** — receipts must not display tax lines |
| Fiscal device/registry number, Z-fiscal, duty stamp | **absent** |
| Mandatory legal mentions (e.g. "facture non récupérable", warranty text) | **absent** |
| QR / GS1 / invoice hash | **absent** |

→ tracked as **G5/G6 caveat** + **§22 Q1**.

### 7.4 Localization

- `locale = ar`: full RTL — meta lines right-aligned, table columns mirrored, totals
  labels right; `wordWrap='RTL'`.
- `locale = fr/en`: LTR mirror of the same template (no separate template).
- Numbers: Western digits, dot decimals (contract-compatible, §15.4); currency suffix from
  existing localized keys (UI uses `DA` — `strings.dart:453/1247/2047`).

### 7.5 Determinism & identity

Same `DocumentData` + `locale` + `paper` ⇒ same bytes (except PDF `CreationDate` — tests
must not hash whole files; assert structure, §19.1).

### 7.6 Pagination / roll behavior

- Page height is **content-driven**: minimum 140 mm; grows with item count
  (`≈ 60 mm header/footer furniture + 7 mm × item rows + totals block`), replacing the
  legacy formula `max(160mm, 125 + n×18 mm)` (`main_window.py:11731`) with the same idea.
- Segment cap at **400 mm per page**: longer receipts paginate into 400 mm segments; the
  store identity block repeats at the top of continuation segments and the footer block
  (totals + closing) is kept together on the final segment. This replaces legacy's
  single-unbounded-page approach (§2.4 B8) while remaining a single logical document.
- Physical roll feed, driver media length, and cutter behavior are **device-verified**
  under G17 (§19.3 item 3).

---

## 8. A4 INVOICE SPECIFICATION

### 8.1 Page geometry

| Property | Value | Basis |
|---|---|---|
| Page size | **A4 210 × 297 mm (595.28 × 841.89 pt)** | `reportlab.lib.pagesizes.A4` |
| Margins | 13 mm L/R, 12 mm T/B | legacy `:11741` |
| Content width | **184 mm** | derived |
| Body / title | 10.5 pt / 19 pt | legacy `:11742` |

### 8.2 Document architecture

1. **Header**: store identity (name 19 pt centered; contact lines when available;
   logo only when a licensed asset exists — Q2). Document title (`invoice`/`return`
   localized) + `document number` + VOID banner when applicable.
2. **Meta table** (2 columns × N rows, boxed): invoice/return number, date+time, cashier
   (⚠ if exposed), customer name/phone, payment method, device id, source invoice number
   (returns), supplier name (purchases), status/dates (void).
3. **Item table** with header row (`repeatRows = 1`): columns
   `# | product (name + variant) | sku/barcode | unit | qty | unit price | discount |
   line total` — widths tuned to 184 mm (legacy shares `:11833-11838` as a starting point:
   0.24/0.20/0.14/0.42 for 4 columns; modern uses 8 columns — final widths set in Step B
   and golden-tested).
4. **Totals block** (right 45 % / left 55 %): same rows as §7.2 step 5.
5. **Payments block**: method(s) + amounts; debt line when > 0.
6. **Footer**: store name, optional owner footer, **`page N of M`** (A4 only — legacy
   `:11897-11906` behavior, but using actual page count, not just "page N").
7. No signature lines, no legal blocks, no logo unless owner supplies them (Q1/Q2).

### 8.3 Multi-page behavior

- Table header repeats on every page (`repeatRows=1` — legacy intent, `:11851`).
- Totals/payments blocks are **not** split: they follow the table on the last page; if a
  page break would split them, a `KeepTogether` moves the whole block.
- Header/footer identity appear once (page 1) + page numbers on all pages.

### 8.4 RTL / fr / en

Same single template with `direction` from locale; `wordWrap='RTL'` + `TA_RIGHT` for ar;
column mirror for ar; fr/en LTR. Mixed text passes through `shape_text()` (§4.4).

### 8.5 One model for both papers (G8 requirement)

**Yes — one `DocumentData`, two templates.** Both `invoice_80mm.py` and `invoice_a4.py`
consume the identical `InvoiceDocumentData`/`ReturnDocumentData`/`PurchaseDocumentData`
built by one backend builder. Business logic (which lines, which totals, pack semantics,
base-qty derivation, void marking) lives **only** in `document_data.py`, shared and
unit-tested once. Templates differ in geometry/columns/page furniture only. The same rule
applies to report PDFs (`report_table.py` renders `ReportData` at A4 portrait/landscape).

---

## 9. REPORT PDF EXPORT

Phase 14 payloads are the **only** data source [PHASE-14 §12.2]. Every report PDF is:

```
[Header]  store.name · localized report title · date_from – date_to (+ filters meta) · generated_at
[Body]    table of payload rows (localized headers — same keys as CSV §14 of Phase 14)
[Totals]  summary block = payload totals object (only where the payload has one)
[Footer]  store.name · page N of M
```

Rules: no charts (no chart dependency — Phase 14 G24 precedent), no new formulas, no
fabricated aggregates, ISO-ish meta dates preserved in the meta block, RTL when
`locale = ar`, `export_data` permission to request (§12.3).

| # | Report | Printable PDF | Layout | Summary/totals section | Charts | Orientation | Pagination | RTL |
|---|---|---|---|---|---|---|---|---|
| R1 | Financial | ✅ | multi-section table: sales block, cost/profit block, payment split block, debt block, **device_breakdown** sub-table | ✅ — payload object IS the aggregate (`schemas/report.py:32-81`) | ❌ deferred (G32) | A4 **portrait** (device breakdown fits) | table headers repeat | ✅ |
| R2 | Products | ✅ | wide 14-column table | ✅ `ReportTotals` (:85) rendered as a totals row + label | ❌ | A4 **landscape** | repeat header; ≤500 rows (server cap) | ✅ |
| R3 | Categories | ✅ | table | ✅ `ReportTotals` | ❌ | A4 portrait | ≤500 rows, single page likely | ✅ |
| R4 | Daily | ✅ | table (one row/day) | ✅ `ReportTotals` | ❌ | A4 portrait | repeat header | ✅ |
| R5 | Hourly | ✅ | table (24 rows) | ✅ `ReportTotals` — **note:** client CSV intentionally leaves `sales_total` cell blank (D5); PDF must mirror the screen (leave blank or omit with same rule) | ❌ | A4 portrait | single page | ✅ |
| R6 | Peak-hours | ✅ | table (24 rows) | ✅ `ReportTotals` | ❌ | A4 portrait | single page | ✅ |
| R7 | Slow-moving | ✅ | table | ❌ **none** (detail list has no totals on screen — "export = what you see") | ❌ | A4 landscape | repeat header | ✅ |
| R8 | Voided | ✅ | table | ❌ none | ❌ | A4 landscape | repeat header | ✅ |
| R9 | Sales detail | ✅ | table (14 cols) | ✅ `SalesDetailTotals` (:294) | ❌ | A4 **landscape** | repeat header | ✅ |
| R13 | Suppliers | ✅ | compact 4-figure summary card + period | ✅ payload IS the summary (:320) | ❌ | A4 portrait | single page | ✅ |
| — | Dashboard | 🟡 optional (Q8/G26) | KPI grid + recent/top tables | n/a (KPI set) | ❌ | A4 portrait | single page | ✅ |

Notes:
- Filters meta (`device_id`, `status`, `sort`, `days`, `threshold`, `lookback_days`) is
  rendered in the PDF meta block — Phase 14 explicitly allows meta for PDF
  (`analysis:520`), unlike CSV.
- Row-level reports (R2/R7/R8/R9): server-side export re-runs the same endpoint/service
  with the same filters up to the 50,000-row cap (§12.1) — identical semantics to the
  client page-walk, no second query path.
- Expense/debt/Z-report PDFs: **not in contract** (§3.1).

---

## 10. XLSX REPORT EXPORT

### 10.1 Workbook structure (one workbook per export)

| Element | Specification |
|---|---|
| Worksheet name | localized report title, sanitized: ≤31 chars, no `[]:*?/\`, unique fallback `report` (G10-compatible ASCII slug when locale is unavailable) |
| Row 1 — title | `<store.name> — <localized report title>` (merged across the used columns) |
| Row 2 — meta | `period: <dateFrom> – <dateTo>` + non-default filters (`device_id`, `status`, `sort`, `days`, `threshold`, `lookback_days`) + `generated_at: ISO` — **only for XLSX/PDF** (Phase 14 `analysis:520`) |
| Row 3 — blank | spacer |
| Row 4 — header row | localized headers, **same keys and column order as the Phase 14 CSV** (`report_csv.dart` builders), bold white on filled background |
| Row 5..N — data rows | payload values verbatim (no recompute, no fabrication) |
| Last row — totals | **only for aggregate reports** (financial, products, categories, daily, hourly, peak-hours, sales detail) labeled with existing `label_total` key; **omitted** for detail lists without on-screen totals (slow-moving, voided) — exactly the CSV totals rule (Phase 14 `analysis:522`) |
| Financial extra | second block below: `device_breakdown` sub-table preceded by a blank row (mirrors `financialCsv` `:140-154`) |
| Number formats | money/qty cells written as **numbers** with format `0.000` (3 decimals max, NUMERIC(18,3)); percent fields as numbers with `0.00"%"`-style format but stored value = the payload number (contract: percentages 2 decimals) |
| Date formats | **ISO strings exactly as in the payload** by default (frozen "ISO date semantics"); Excel-native date cells are a possible owner-approved enhancement only (§22 Q8 covers scope, not this) |
| Column widths | computed from max cell length (clamped 10–60); name columns wider |
| Freeze panes | at the row below the header row |
| Autofilter | on header row for row-level reports |
| RTL | `sheet_view.rightToLeft = True` when `locale = ar` (legacy-proven) |
| Print settings | landscape for wide tables (products, sales detail, voided, slow-moving), portrait otherwise; fit-to-width 1 page; repeat header row as print title; margins 0.5" — best-effort (openpyxl supports it) |
| Cell security | string cells sanitized against spreadsheet formula injection (§17.4) |
| Multi-sheet | **not used** for a single report (one report = one sheet). A future "all reports" workbook is out of scope. |

### 10.2 Rules inherited from Phase 14 (unchanged)

- Source = exact report payload/filters (or same-endpoint page-walk ≤ 50,000 rows).
- Localized headers from the same on-screen keys.
- Totals rule as on screen — **never fabricate totals** for detail reports.
- Filenames: `reports_<report>_<from>_<to>_<yyyy-MM-dd-HHmmss>.xlsx` (ASCII pattern
  identical to `reportCsvFilename`, `report_csv.dart:52-60`).
- Empty result ⇒ workbook with headers (+ totals row where applicable), never a silent
  empty file.

---

## 11. CSV (FROZEN — OWNED BY PHASE 14)

### 11.1 What stays untouched

- **`report_csv.dart` (520 lines) and `report_export.dart` (271 lines) are NOT modified,
  replaced, or "improved" in Phase 15.** Frozen elements: row cap `kExportRowLimit = 50000`
  (:24), RFC 4180 quoting, CRLF, UTF-8 BOM, ISO dates, raw dot decimals, localized headers,
  totals rule, ASCII filename pattern, Arabic-as-data (no RTL shaping), error keys, and
  `export_data` gating.
- Existing tests (`test/unit/reports_csv_test.dart`, export-gating widget tests) remain
  authoritative.

### 11.2 Integration into the unified workflow (§12)

Phase 15's export format dialog routes **CSV to the existing client builder** (unchanged
code path) and **XLSX/PDF to the backend export service**. The dialog is a presentation
change only; the CSV bytes remain produced by Phase 14 code.

### 11.3 Optional server-side CSV (G31 — DEFERRED by default)

Phase 14 explicitly allows moving CSV server-side with an unchanged contract
(`analysis:802/A6`). If pursued later it must ship with a **byte-parity test** comparing
backend CSV output to `report_csv.dart` fixtures for all 10 reports × 3 locales. Not part
of default Step B (duplication risk); owner decides (§22 Q11).

### 11.4 Known contract gaps recorded (not changed by Phase 15)

- Server-side 50,000 enforcement is documented (`PHASE_14_IMPLEMENTATION.md:54`) but
  **client-only** in code — Phase 15's backend export service implements it (G22) for
  XLSX/PDF; the client guard for CSV stays as is.
- Filename carries only report + dates (not `device_id`/`status`/…) — frozen as-is.
- CSV does not sanitize spreadsheet formula metacharacters — see G33 / §22 Q10.

---

## 12. UNIFIED EXPORT / PRINT SERVICE

### 12.1 Service architecture (G11)

Yes — the deferred Phase 15 service is appropriate, in two sibling services:

```
POST /api/v1/exports                       POST /api/v1/print
ExportRequest {                             PrintRequest {
  report: slug (allowlist),                  document_type: sale|return|purchase,
  format: xlsx|pdf  (csv = client path),     document_id: UUID,
  date_from, date_to,                        paper: 80mm|A4,
  filters {device_id,status,sort,            locale: ar|fr|en
           days,threshold,lookback_days}                                  }
}                                    │
        │                            ▼
        ▼                     DocumentData builder (document_data.py)
ReportService (EXISTING — same code path                    ▼
 as the GET /reports/* endpoints; no          Template (invoice_80mm | invoice_a4)
 second query path)                                    ▼
        ▼                      ReportLab renderer → PDF bytes
ReportData (exact Phase 14 payload)           │
        ▼                                     ▼
FormatRenderer                          PrintResponse (application/pdf)
  ├── XLSX (openpyxl)                   (+ audit row, §13)
  └── PDF  (ReportLab)
        ▼
ExportResponse (bytes + Content-Disposition)
(+ audit row, §13)
```

Design rules:
- **Row cap enforced server-side**: `total > 50000` → `422 export_row_limit` (fulfils the
  documented Phase 14 intent, G22). Client-side CSV guard unchanged.
- Report queries are invoked through the **same `ReportService` methods** used by
  `GET /reports/*` (`services/report.py`) — "export = what you see" preserved (D12).
- CSV is **not** rendered server-side in the default plan (§11.2).
- Synchronous request/response (no queue) — §12.5.
- Filenames generated **server-side** from an allowlist slug + ISO dates + timestamp
  (pattern §10.1); returned in `Content-Disposition`. Client save dialog prefills it via
  `file_picker` (existing behavior `report_export.dart:243-247`).

### 12.2 PrintRequest → response (same pattern)

- Permissions vary by document (§12.3); response is PDF bytes; `document_type`/`paper`
  are allowlisted enums (never free-form paths/templates).
- Reprint uses the same endpoint (documents are re-fetchable — §1.B); there is no stored
  "printed" state required for correctness (print is non-blocking, non-transactional).

### 12.3 Permissions (G23) — no new scopes invented

| Action | Scope | Precedent |
|---|---|---|
| View reports (already) | `report_financial` | Phase 14 (`enums.py:60`) |
| Execute export (XLSX/PDF) | **`export_data`** | Phase 14 frozen rule (`analysis:530`, `enums.py:61`) — first server-side enforcement of this scope |
| Print sale invoice (incl. reprint/void) | **`pos_sale`** (`pos_void` for void prints if desired) | Phase 8 detail endpoints (`pos.py:134-145`) |
| Print return | **`pos_return`** | `returns.py:98-109` |
| Print purchase | **`purchase_view`** | `purchases.py:73-85` |
| View audit rows | `audit_view` (existing) | `enums.py:68` |

Client gating mirrors today: export button only with `export_data`
(`reports_screen.dart:247,273-287`); print buttons inside document detail dialogs gated by
the same scopes that allow viewing them. Request-time 403 still enforced by the backend
(unchanged envelope, `core/exceptions.py:90-96`).

### 12.4 Backend structure (proposed)

```
app/printing/    (§4.4)          — document rendering
app/exporting/   (§5.3)          — report rendering (XLSX)
app/services/export.py           — ExportService: validation, cap, audit, bytes
app/services/print.py            — PrintService: DocumentData build, audit, bytes
app/api/v1/exports.py            — POST /exports   (require_permission(EXPORT_DATA))
app/api/v1/print.py              — POST /print     (per-document scope)
```

Both follow Router → Schema → Service (→ Repository only for document loading) exactly
like `api/v1/system.py:50-69` / existing feature routers.

### 12.5 Sync vs jobs (G30 — DEFERRED)

Phase 0 lists `print_jobs`/`export_jobs` tables (`PHASE_0_DATABASE_ANALYSIS.md:47`) and a
job worker with progress/cancel (`PERFORMANCE_AUDIT.md:12`). For Phase 15 scope (≤50,000
rows, local FastAPI, target <5s — §18) **synchronous generation is sufficient**; durable
job tables and async progress are **DEFERRED** until a measured need exists (multi-PC
Phase 16 or >5s renders). Audit still records every attempt (§13). This is a recorded
deviation from the blueprint's table list (implemented-convention precedent, Phase 10
GATE 12 / Phase 11 style).

---

## 13. AUDIT (G12)

### 13.1 Existing audit architecture

- Table `audit_logs` exists: `new_app/backend/app/models/audit.py:19-46` —
  `user_id`, `action` (String(30)), `entity_type`, `entity_id`, `details` (Text),
  `before_state`/`after_state` (Text/JSON), `ip_address`, `device_id`, `action_at`.
- Convention: **row-level `_audit(...)` inside the service transaction** — helpers in
  `services/auth.py:546`, `customers.py:158`, `debt.py:184`, `pack.py:665`,
  `purchases.py:786`, `expenses.py:377`, `returns.py:1174`, `void.py:306` (signature
  pattern `void.py:306-327`).
- `AuditAction` enum (`models/enums.py:180-193`) has **no `export`/`print` members**;
  the column is a plain string, so adding members is code-only (additive precedent:
  Phase 11 `RECEIVE`, `enums.py:192-193`) — **no migration required**.
- No audit middleware; no retention policy exists anywhere.

### 13.2 Should export/print be audited? — YES (required)

Phase 14 explicitly deferred it to Phase 15 (`analysis:531`, DEF-3) and Phase 0 security
requires recording "export attempts" (`PHASE_0_SECURITY_AUDIT.md:17`).

### 13.3 What to store (specification only — no schema in Step A)

One `audit_logs` row per **attempt** (success **and** failure):

| Column | Value |
|---|---|
| `action` | `export` \| `print` (new enum members) |
| `user_id` | requesting user |
| `entity_type` | `report` (exports) \| `sale` / `return` / `purchase` (prints) |
| `entity_id` | null for reports; document UUID for prints |
| `details` (JSON string) | `format` (xlsx/pdf/csv), `report` slug, `date_from`, `date_to`, `filters` (as sent), `paper`, `locale`, `rows` (export row count), `bytes` (generated size), `duration_ms`, `result` (`success`\|`failure`), `error_code` (on failure), `device_id` |
| `device_id` | client-provided `device_id` (existing field convention) |
| `ip_address` | request IP (as elsewhere) |

**Safe/useful:** metadata above. **Never stored:** row contents, file contents, full
payloads, paths, printer drivers' internals beyond a printer name if the client reports one.
Client-side CSV success cannot be server-audited without a client report call — recorded as
part of §22 Q11 (server-side CSV decision).

Retention: follow existing `audit_logs` behavior (no retention mechanism exists) — owner
confirm (§22 Q9).

---

## 14. FILE / STREAM STRATEGY (G-context: §12)

**Decision: generate in memory → return bytes → client saves via existing `file_picker`
save dialog.** Nothing is persisted server-side.

| Concern | Decision |
|---|---|
| Return bytes vs stream | **Bytes** (`Response(content=..., media_type="application/pdf"|"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")`) for typical sizes (invoices, reports ≤ ~5k rows) |
| Large XLSX (approaching 50,000 rows) | openpyxl **write-only mode** into a `SpooledTemporaryFile`/`BytesIO`, then `StreamingResponse` chunks; temp file deleted in `finally` — bounds memory (Phase 0 perf concern) |
| Large PDF | ReportLab writes to a buffer directly; pagination keeps per-page memory flat |
| Temp files | Only transient spooling (`tempfile` with random names, `finally` cleanup) — same hygiene as `print_service.dart:64-70`. Never `%TEMP%\SupermarketPro`-style predictable overwrite names |
| Server-side saves | **None.** No export artifacts written to any user-reachable directory by the backend (eliminates path traversal surface, §17) |
| Client-side saves | Existing `FilePicker.platform.saveFile(bytes:)` (Windows `GetSaveFileNameW`); filename pre-generated server-side, sanitized (§17.2) |
| Offline | Fully local: `127.0.0.1:8000` (or LAN in Phase 16). No cloud/remote assumptions |
| CWD pollution | Current save dialog may default to CWD (evidence: two untracked `new_app/reports_*.csv`); Phase 15 keeps behavior but the success toast already shows the absolute path (`report_export.dart:253`) |

---

## 15. ARABIC / RTL / FONT STRATEGY (G7 — critical)

### 15.1 Pipeline (PDF, backend)

```
raw string ── sanitize_text() ── containsArabic? ──yes──► arabic_reshaper.reshape
   │                        │                              │
   │                        no                             ▼
   │                        │                        bidi get_display
   ▼                        ▼                              ▼
emit as-is  ◄───────────────┴──────────────────────► draw with embedded TTF
```

- **Shaping**: `arabic-reshaper` (contextual letterforms) — same tool the legacy used on
  this exact content [LEGACY `main_window.py:11701-11714`].
- **Bidi**: `python-bidi` `get_display` **only for strings containing Arabic** (fixes
  legacy over-application to numbers — §2.4 B2/C3).
- Paragraph/cell styles with Arabic set `wordWrap='RTL'` + right/center alignment.

### 15.2 Font selection & bundling (legal)

| Option | License | Verdict |
|---|---|---|
| **Cairo** (Regular + Bold), same family the UI already requests via `GoogleFonts.cairoTextTheme` (`app_theme.dart:165`) | **OFL 1.1** — redistribution allowed with license notice | ✅ **RECOMMENDED** — visual consistency UI↔documents, covers Arabic + Latin/French accents |
| Noto Sans Arabic + Noto Sans (Latin) | OFL 1.1 | ✅ acceptable alternative (broader coverage) |
| `C:/Windows/Fonts/tahoma.ttf` / `arial.ttf` (legacy) | **proprietary Microsoft** | ❌ forbidden — not redistributable, environment-dependent, silent Arabic loss |
| DejaVuSans (legacy Linux fallback) | free | ❌ insufficient Arabic shaping coverage |

Rules:
- Bundle font files **in the backend package** (`app/printing/fonts/*.ttf` + `OFL.txt`),
  and (if the Flutter preview needs a themed fallback) as Flutter assets — **fonts are
  data files, not secrets**; what must never be done is shipping proprietary/ licensed
  font binaries. `google_fonts` runtime download must **not** be used for documents
  (offline requirement).
- Registration in `fonts.py` with **typed failure** (`MISSING_FONT`) if the file is absent
  or checksum-invalid — never silent `Helvetica` fallback (legacy defect §2.4 B5).
- G7 spike must confirm OFL compliance + glyph coverage (Latin accents é/è/à/ç, Arabic
  core + harakat if present in data).

### 15.3 XLSX & preview

- **XLSX**: no reshaping — write logical Arabic strings; Excel performs shaping/RTL.
  Set `sheet_view.rightToLeft` for `ar`. Font name referenced by the workbook may be set
  to a common family (e.g. the bundled family's name) — no font embedding involved.
- **Preview**: `PdfPreview` rasterizes the **same bytes** printed → preview/print parity.

### 15.4 Numbers, dates, negatives, mixed text

| Case | Rule |
|---|---|
| Digits | Western digits everywhere (existing behavior in payloads/CSV/UI) |
| Money | raw dot-decimal in exports (frozen); display formatting 2 decimals + localized `DA` on documents |
| Negative values | explicit leading `-` **after** shaping decision — negatives are only in report payloads (profit/returns); never bidi-reorder numeric cells |
| Dates | exports ISO (frozen); documents use locale display of the same UTC value |
| Customer/product names | as stored (single-language catalog — §1.F); sanitized (§17.3); shaped iff Arabic |
| Mixed `اسم Product 123` | single bidi pass over the whole string; golden-tested |

### 15.5 Emoji/glyph limits

Document templates must not use glyphs the bundled font lacks (legacy used `🎁`/`↳`).
Markers are plain text/localized (`[pack]`, `└`) unless glyph coverage is proven in G7.

### 15.6 UI-side note (out of Phase 15 scope, recorded)

The Flutter UI font (Cairo) is fetched at runtime by `google_fonts` → Arabic UI may
degrade offline. Not Phase 15's to fix; noted for owner awareness (§22 Q2 context).

---

## 16. ERROR HANDLING (G14)

All errors use the existing envelope (`core/exceptions.py:26-55,253-277`):
`{"error": {code, message_key, message, details, request_id}}`. `message_key` is localized
client-side via `AppStrings` (add the corresponding keys to all 3 locales — parity test).

### 16.1 Backend typed errors

| Condition | Code | HTTP | message_key (new unless noted) |
|---|---|---|---|
| Unknown/unsupported `format` or `report` slug | `EXPORT_FORMAT_UNSUPPORTED` | 422 | `export_format_unsupported` |
| Renderer raised (ReportLab/openpyxl) | `EXPORT_RENDER_FAILED` | 500 | `export_render_failed` |
| Print template/render failure | `PRINT_RENDER_FAILED` | 500 | `print_render_failed` |
| Font missing/unloadable | `MISSING_FONT` | 500 | `missing_font` (ops-facing; also logged) |
| Invalid/missing document data (bad UUID, unsupported paper/locale) | `VALIDATION_ERROR` (existing) | 422 | existing |
| Document not found | `NOT_FOUND` (existing) | 404 | existing |
| Row cap exceeded | `EXPORT_ROW_LIMIT` | 422 | maps to existing client key `export_row_limit` |
| Output oversized for safe in-memory handling | `EXPORT_TOO_LARGE` | 413 | `export_too_large` |
| Permission denied | `FORBIDDEN` (existing) | 403 | existing (`export_permission` key already localized) |
| Printer unavailable **on the client** | `PRINTER_ERROR` (**blueprint code**, `PHASE_0_API_BLUEPRINT.md:707`) | 503 (client-side concept; see below) | `printer_unavailable` |

Print-invocation failures occur **client-side** (the backend never touches a printer):
`PrintServiceException` (existing, `print_service.dart:19-25`) → localized
`print_failed` + detail; preview failures → new key `print_preview_failed`; save/write
failures → existing `export_failed`.

### 16.2 Client rules (hard)

- **No silent failure**: no `catch (_) {}` that swallows a print/export outcome. (The two
  existing benign catches — temp-file cleanup `print_service.dart:67-69`, body-parse
  fallback — are not outcome-swallowing and remain.)
- **No fake success**: success toasts/dialogs only after verified completion (existing
  rule `sale_detail_dialog.dart:298-313`, legacy `:11915-11927`).
- **Cancellation is not an error**: cancelling the save dialog or the preview → neutral,
  no toast (existing `report_export.dart:248`); cancelling the print dialog → neutral.
- Loading states: export button disabled + spinner (existing `reports_screen.dart:277`),
  print button busy guard (existing `_printBusy`, `sale_detail_dialog.dart:128`).
- New keys needed: `export_format_unsupported`, `export_render_failed`,
  `print_render_failed`, `missing_font`, `export_too_large`, `print_preview_failed`,
  `printer_unavailable`, plus dialog labels (`print_dialog_title`, `paper_80mm`,
  `paper_a4`, `save_pdf`, …) — all three locales (G28).

---

## 17. SECURITY (G13)

### 17.1 Path traversal / arbitrary output paths

- The backend **never accepts a destination path** from the client and never writes files
  to disk in the happy path (§14) → traversal surface for exports is eliminated by design.
- Temp spooling uses `tempfile` random names under the OS temp dir only; cleanup in
  `finally`.
- Client: the only path chosen is by the **user** through the native save dialog — the app
  never constructs output paths.

### 17.2 User-controlled filenames

- Filenames are generated server-side from allowlisted slugs + ISO dates + timestamp
  (pattern §10.1). Sanitizer: strip path separators (`/ \`), control chars, `<>:"|?*`,
  leading/trailing dots/spaces, Windows reserved names (`CON`, `PRN`, `AUX`, `NUL`,
  `COM1-9`, `LPT1-9`), cap length (~120 chars), force ASCII (existing Phase 14 rule).
- `document_id`/`report` never interpolated raw into filenames.

### 17.3 User-controlled content (product/customer names, notes, reasons)

- **PDF**: text is drawn as glyphs — no HTML/script interpretation; ReportLab has no
  "PDF injection" from plain strings. Defense-in-depth: `sanitize_text()` strips
  `Cc` control chars, Unicode bidi overrides (`U+202A–U+202E`, `U+2066–U+2069`), and
  LRM/RLM marks (`U+200E/U+200F`) from **all** rendered strings (bidi-override exploits
  can visually reverse invoice amounts).
- **XLSX/CSV strings**: formula injection below.

### 17.4 Spreadsheet formula injection (critical for XLSX)

User-controlled strings beginning with `=`, `+`, `-`, `@` (also leading tab/CR) execute as
formulas when the file is opened in Excel/Sheets.

**Rule for the new XLSX renderer:**
- Numeric-typed cells (money/qty/percents written as Python `int/float/Decimal`) are safe
  by type — negatives legitimately start with `-` and are **not** altered.
- **String** cells whose value matches `^[=+\-@\t\r]` are neutralized by prefixing a
  single quote (`'`) — Excel displays the text verbatim and does not evaluate it — or by
  writing them as explicit inline strings with the prefix (choose one, unit-test both the
  prefix rule and that normal strings are untouched).
- Sanitization happens **at write time in `xlsx.py`**, applied to every string column
  (including headers and localized labels — belt and braces).

**CSV (frozen) is NOT sanitized** — changing bytes would violate the Phase 14 contract.
Recorded as **G33 / §22 Q10** (accept vs future contract amendment). Risk context: exports
are internal financial data produced by the app's own users.

### 17.5 Secrets

- No secrets, tokens, or `.env` values in PDFs/XLSX/audit rows. `device_id` and user names
  are operational data already present in payloads.
- Fonts are licensed assets with their license file — not secrets; proprietary system
  fonts must not be copied (§15.2).

### 17.6 Resource abuse

- Server-side row cap (§12.1) prevents unbounded generation; PDF page count bounded by the
  same cap; request body for `PrintRequest`/`ExportRequest` is small and schema-validated
  (`StrictBaseModel`).

---

## 18. PERFORMANCE TARGETS (G15)

Basis: Phase 0 SLOs (`PHASE_0_PERFORMANCE_AUDIT.md:15`) — "receipt job begins <3s",
"export <5s for agreed data size", "dashboard/report daily <2s"; sale command <500ms
**excluding printing** (`ARCHITECTURE.md:61` print runs after commit).

| Target | Budget (p95, local dev machine, warm) | Measurement |
|---|---|---|
| 80mm receipt PDF generation (≤30 lines) | **≤ 300 ms** server-side; ≤ 300 ms for build+transfer | backend test timing + endpoint benchmark (pattern: `backend/scripts/benchmark_reports_phase14.py`) |
| A4 invoice PDF (≤100 lines, 1 page) | **≤ 500 ms**; multi-page ≤ 1.5 s | same |
| End-to-end "print job begins" (user confirm → dialog shown) | **< 3 s** (Phase 0 SLO) | Flutter integration timing on Windows |
| Report PDF (payload already computed; ≤ 1 000 rows) | **≤ 2 s** server-side | benchmark script |
| Report data fetch (unchanged) | < 2 s daily/report (Phase 0) | existing Phase 14 benchmarks (`docs/phase14_benchmark_results.json`) |
| XLSX report (≤ 5 000 rows) | **≤ 2 s** | benchmark |
| XLSX at the 50 000-row cap | **≤ 5 s** (Phase 0 "export <5s"), memory bounded via write-only mode (target peak ≤ 300 MB) | benchmark with synthetic fixture; record actuals |
| CSV export (client-side, unchanged) | no regression vs Phase 14 | existing tests |
| Print preview startup (single page) | **≤ 1 s** to first rasterized frame | Flutter widget timing |
| Report screen interaction | unchanged (Phase 14 budgets) | existing |

Notes: no target is claimed for physical printer throughput (device-dependent — QA plan
records observed values only). Budgets are verified in implementation Step D with
recorded numbers, not asserted in advance (measurement definition above makes them
falsifiable).

---

## 19. TEST STRATEGY (G16)

### 19.1 Backend (pytest — `new_app/backend/tests/`)

| Area | Tests |
|---|---|
| DocumentData validation | builder from `SaleResponse` fixture: pack summary/components, base-qty derivation, void marking, missing optional fields (null customer/cashier/store contact tolerated), totals consistency (`line_discounts_sum` vs `subtotal − total − invoice_discount`) |
| PDF generation smoke | renders 80mm + A4 without exception; bytes start with `%PDF`; non-empty |
| **A4 dimensions** | parse `MediaBox` from uncompressed page: `595.28 × 841.89 pt` (±0.1) |
| **80mm dimensions** | `MediaBox` width `226.77 pt` (±0.1); height per §7.6 rule |
| Arabic output | unit tests on `shape_text()` (connected forms, mixed ar/Latin, pure numbers untouched, diacritics); plus PDF-level check with `pageCompression` disabled in the test profile: shaped Arabic bytes present, raw unshaped sequence absent |
| RTL layout | column order/alignment assertions via the template's flowable list (structure tests, not pixels) |
| Report PDF | one test per report slug: title/meta/table/totals presence; totals **absent** for slow-moving/voided; landscape for wide reports |
| XLSX generation | re-open with openpyxl: sheet name, title/meta rows, header row (localized keys), row count == payload, totals row present/absent per contract, number formats (`0.000`), ISO date strings, column widths set, freeze panes, autofilter, `rightToLeft=True` for `ar` / `False` for `en` |
| Formula injection | string `=cmd\|…`, `+1`, `-1`, `@x` written as safe cells; numeric `-12.5` untouched; normal strings untouched |
| Export errors | 403 without `export_data`; 422 `EXPORT_FORMAT_UNSUPPORTED`; 422 `EXPORT_ROW_LIMIT` at cap+1; 422 invalid range/report (existing `REPORT_INVALID_RANGE` etc.); 404 unknown document; 413 oversized |
| Print endpoint | per-document permissions (`pos_sale`, `pos_return`, `purchase_view`), 80mm/A4 enum enforcement, filename header sanitization |
| Audit | export/print attempts insert `audit_logs` rows with expected `action`/`details`/`result` (success **and** failure); no payload data stored |
| CSV preservation | Phase 14 CSV tests must pass **unmodified** (regression gate for G10) |
| Contract parity | report payloads passed to XLSX equal the GET endpoint's payload (same fixtures) |

### 19.2 Flutter (`new_app/test/`)

| Area | Tests |
|---|---|
| Export dialog | format selection (CSV → existing builder; XLSX/PDF → backend call), disabled states |
| Permission gating | `export_data` absent → no export UI (extend `reports_screen_test.dart:332-346`); print buttons follow document-view scopes |
| Preview | `PdfPreview` receives bytes; cancel → no print, no toast (port of `pos_screen_test.dart:2173-2241` semantics); confirm → `PrintService.printPdf` called once |
| Print actions | fake `PrintService` success/failure (extend `_FakePrintService`, `pos_screen_test.dart:37-48`); failure shows localized `print_failed`, **never success** |
| Error states | row-limit, render failure, printer unavailable, preview failure — localized via 3 locales |
| Localization | parity test for every new key in ar/fr/en (pattern `reports_localization_test.dart:144-150`); existing `export_xlsx`/`export_pdf` keys now exercised |
| RTL | Arabic locale print/export dialogs render RTL (smoke) |
| Loading/cancel | busy guards, double-click protection (`_printBusy`, `_exporting`) |
| Snapshots | receipt **text** snapshots (`sale_line_snapshots_test.dart:136-233`) migrate to DocumentData fixtures; PDF golden/pixel tests **not** required in Phase 15 (rasterizer dep) — structural backend tests + manual QA cover rendering; recorded as a deliberate choice (golden files deferred) |

### 19.3 Manual hardware QA plan (G17 — UNVERIFIED until executed)

| # | Scenario | Device classes |
|---|---|---|
| 1 | 80mm receipt print, ar / fr / en | USB thermal (e.g. 58/80mm POS printer) **and** network thermal — models from owner (Q5) |
| 2 | 80mm reprint from history, multi-copy (2×) | same |
| 3 | Long receipt (40+ lines) roll feed / pagination | same |
| 4 | A4 invoice print (1 page and 3 pages) | common Windows office printer (inkjet/laser) |
| 5 | Report PDF A4 portrait + landscape | office printer |
| 6 | Printer unavailable / offline / paper out → typed localized error, no false success | any (unplug/disable) |
| 7 | Printer selection + copies + paper size in dialog | any multi-printer Windows host |
| 8 | Arabic shaping/RTL visual inspection of PDF + XLSX opened in Excel (RTL sheet) | any |
| 9 | XLSX opened in Excel/LibreOffice: BOM, formats, freeze, filter, formula-injection sample | desktop |
| 10 | Offline (no internet): fonts present, print works, export works | airplane-mode PC |
| 11 | Print canceled by user → neutral, no error toast | any |
| 12 | Save-PDF fallback path | any |

Acceptance (roadmap): "80mm invoices print correctly", "A4 invoices print correctly",
"Arabic text renders in PDF", "Excel/CSV exports work" — mapped to §19.1/§19.2 + QA items
1/4/8/9.

---

## 20. DEPENDENCY POLICY (no additions in Step A)

Minimum required additions to deliver §4–§6 (all proposed, none installed):

### Backend (`new_app/backend/pyproject.toml`)

| Package | Reason | Maint. | Offline | License | Windows | Arabic/RTL |
|---|---|---|---|---|---|---|
| `reportlab>=4.0.0` | PDF renderer (G2) | very active, de-facto standard | ✅ pure Python | BSD-3-Clause | ✅ | via shaping libs below; TTF embedding |
| `arabic-reshaper>=3.0.0` | contextual Arabic letterforms (legacy-proven here) | small but stable | ✅ | MIT (reconfirm at pin) | ✅ | **core** |
| `python-bidi>=0.4.2` | bidi reordering (legacy-proven here) | stable | ✅ | MIT (reconfirm at pin) | ✅ | **core** |
| `openpyxl>=3.1.0` | XLSX renderer (G3) | very active | ✅ | MIT | ✅ | RTL sheet view |
| *(asset)* Cairo or Noto OFL `.ttf` + `OFL.txt` | embedded document font (G7) | n/a | ✅ | **OFL 1.1** | ✅ | **core** |

Explicitly **not** added: `fpdf2`, `weasyprint`, `xlsxwriter`, `pandas`, `pypdf`
(structural tests parse MediaBox directly), any job queue, `win32print`.

### Flutter (`new_app/pubspec.yaml`)

| Package | Reason | Maint. | Offline | License | Windows | Arabic/RTL |
|---|---|---|---|---|---|---|
| `printing` (^5.x) | `PdfPreview` (print preview, G4/E) + `Printing.layoutPdf` system print dialog; transitively brings `pdf` (used only for preview plumbing, **not** authoring) | active (nfet.net / DavBfr) | ✅ | Apache-2.0 | ✅ documented (behavior **UNVERIFIED** → G20) | preview rasterizes backend-shaped Arabic |

Explicitly **not** added: `pdf` as an authoring dependency, `excel`, `share_plus`,
`windows_printer`, ESC/POS packages, `path_provider` (still unused directly).

### Maintenance implications (recorded)

- Four new backend deps are all mature/low-churn; two (`arabic-reshaper`, `python-bidi`)
  are small and stable — the legacy ran them for years on this content.
- Flutter gains one plugin (+1 transitive) — replaces nothing until PDF print ships.
- No dependency is added in Step A; installation happens in implementation Step B after
  gates G2/G3/G4/G7 sign-off.

---

## 21. PHASE 15 GATES (G1–G33)

| # | Gate | Status | Decision / evidence |
|---|---|---|---|
| 1 | Current invoice/document payload verified | **RESOLVED** | Full inventory §1.A–G incl. 22-field `SaleResponse`, line/payment shapes, numbering, and the explicit gaps (no cashier/customer/store header, no tax fields) |
| 2 | PDF architecture selected | **RESOLVED** | Option A backend ReportLab (§4.3), justified by roadmap backend/Flutter split + Phase 0 rules; full module/strategy definition §4.4 |
| 3 | XLSX architecture selected | **RESOLVED** | Option A backend openpyxl (§5.2), RTL proven by legacy |
| 4 | Print architecture selected | **RESOLVED** | Backend PDF bytes → Flutter `PdfPreview` → system print dialog (§6.2); runtime sub-items tracked in G20 |
| 5 | 80mm layout defined | **RESOLVED** | §7 geometry/order/totals; legal-fiscal gaps explicitly listed, not invented |
| 6 | A4 layout defined | **RESOLVED** | §8 header/meta/table/totals/multi-page/RTL |
| 7 | Arabic/RTL/font strategy approved | **UNVERIFIED** | Design done (§4.4, §15) but requires: rendering spike §4.6, font selection + OFL packaging confirmation, glyph-coverage check. Blocks Step B PDF work |
| 8 | Unified DocumentData contract | **RESOLVED** | §4.5/§8.5 — one model, template-per-paper, zero business logic in templates |
| 9 | Report-to-export mapping | **RESOLVED** | §9 (PDF) + §10 (XLSX) + §11 (CSV) for all 10 reports + dashboard optional; no new formulas |
| 10 | CSV preservation | **RESOLVED** | §11 — `report_csv.dart`/`report_export.dart` untouched; their tests are a regression gate |
| 11 | Server-side export service design | **RESOLVED** | §12.1 — `POST /exports`, same `ReportService` code path, server-side row cap, sanitized filenames |
| 12 | Export audit design | **RESOLVED** | §13 — `audit_logs` rows via additive `AuditAction.export/print` (no migration); attempts incl. failures; no schema created in Step A |
| 13 | Security requirements | **RESOLVED** | §17 — no server-side paths, filename sanitizer, bidi-override stripping, XLSX formula-injection neutralization, resource caps |
| 14 | Error contract | **RESOLVED** | §16 — typed codes on the existing envelope, blueprint `PRINTER_ERROR` aligned, no silent failure/fake success, cancel ≠ error |
| 15 | Performance targets | **RESOLVED** | §18 — budgets derived from Phase 0 SLOs with defined measurement; hardware printer timing excluded |
| 16 | Test strategy | **RESOLVED** | §19.1/§19.2 — geometry, Arabic, XLSX structure, injection, errors, audit, Flutter dialog/preview/permission/localization |
| 17 | Manual printer QA plan | **UNVERIFIED** | §19.3 planned but hardware-dependent; requires owner devices (Q5) |
| 18 | Owner decisions | **UNVERIFIED** | §22 Q1–Q12 pending; defaults documented so implementation can start on non-blocked items |
| 19 | Receipt header data source (store identity/logo/footer/cashier/customer) | **UNVERIFIED** | Data exists in DB (`users.full_name`, `customers.name`, `STORE_NAME`) but not in payloads; additive extension designed (§4.5.3); logo/footer need owner (Q2/Q3) |
| 20 | Windows print runtime (`printing` plugin dialog/printer/copies) | **UNVERIFIED** | pub.dev documents Windows support; actual dialog behavior must be runtime-tested on this machine (QA §19.3 items 5/7/11) |
| 21 | 80mm thermal method (PDF-through-driver vs ESC/POS) | **UNVERIFIED** | Default = PDF-through-driver (§6.3); ESC/POS deferred pending owner + hardware (Q4) |
| 22 | Server-side 50,000-row cap | **RESOLVED** | §12.1 — enforced in export service (implements the documented Phase 14 intent); client CSV guard untouched |
| 23 | Print/export permission matrix | **RESOLVED** | §12.3 — reuses `report_financial`/`export_data`/`pos_sale`/`pos_return`/`purchase_view`; **no new scopes** |
| 24 | Post-sale auto-print / ask-before-print settings | **DEFERRED** | Legacy settings exist but modern settings screen has only language/theme; Phase 17 owns settings. Owner may pull forward (Q6) |
| 25 | Z-report / shift report | **DEFERRED** | No modern shift concept/endpoint; legacy-only behavior (§2.1 K). Owner decision (Q12) |
| 26 | Dashboard PDF | **DEFERRED** | Optional; not in Phase 14 contract (Q8) |
| 27 | Purchase document printing | **DEFERRED** | Data fully supports it; roadmap Phase 15 says "invoices" only (Q7) |
| 28 | Localization parity for new strings | **RESOLVED** | Existing keys cover print/export basics (§1.H); new keys enumerated in §16.2 with 3-locale parity test |
| 29 | 80mm pagination / roll behavior | **RESOLVED** (design) | §7.6 content-driven page height with segment cap; physical roll feed verified under G17 |
| 30 | `print_jobs`/`export_jobs` tables & job worker | **DEFERRED** | Synchronous generation suffices at Phase 15 scale (§12.5); blueprint tables deferred with recorded rationale |
| 31 | Server-side CSV renderer | **DEFERRED** | Client CSV stays authoritative; server parity only with byte-parity tests (§11.3, Q11) |
| 32 | Report PDF charts | **DEFERRED** | No chart dependency (Phase 14 G24 precedent); tables only |
| 33 | CSV spreadsheet-formula injection | **UNVERIFIED** | Frozen CSV is unsanitized; changing bytes violates Phase 14 (§17.4). Owner accepts risk or approves future contract amendment (Q10) |

**Counts: 33 gates — RESOLVED 19, DEFERRED 7, UNVERIFIED 7.**

**Blocking for implementation start:** G7 (spike + font), G19 (header data) — both
resolvable in Step B without owner input for the *data* parts; G17/G20/G21 are
hardware-verifiable only after implementation; G18/G33 owner answers have documented
defaults and do not block non-default-dependent work.

---

## 22. OWNER QUESTIONS

Only questions that cannot be answered from source/code. Each: why it matters → default
recommendation → phase/block affected.

**Q1 — Legal/fiscal presentation on invoices (80mm + A4).**
*Why:* Algerian fiscal rules may mandate ICE/NIF/RC/TVA mentions, tax lines, or specific
wording; **the domain contains zero fiscal fields** (§1.G) and legacy printed none either —
Phase 15 must not invent them. *Default:* ship without any fiscal block; add later as
static configured text + (if required) schema fields. *Affects:* G5/G6, acceptance, §7.3.

**Q2 — Logo / company header source.**
*Why:* business rules say A4 "with logo" (`PHASE_0_BUSINESS_RULES.md` §12) but no logo
asset exists anywhere; licensing must be clean. *Default:* text-only header using
`STORE_NAME`; logo rendered only once an owner-supplied asset + license is added.
*Affects:* G19, §8.2.

**Q3 — Store identity fields (phone, address, invoice footer text).**
*Why:* legacy printed them from `app_settings.json`; modern backend has **only**
`STORE_NAME` (no settings table until Phase 17). *Default:* print `STORE_NAME` only; contact
lines/footer appear when settings land (Phase 17) — templates already tolerate absence.
*Affects:* G19, §7.2.

**Q4 — Thermal printing method: 80mm PDF through the Windows driver (recommended) vs
ESC/POS raw.**
*Why:* determines dependencies, preview fidelity, Arabic quality, and QA effort; ESC/POS
needs a raw channel + printer-specific code pages. *Default:* PDF-through-driver (§6.3).
*Affects:* G21, §20, QA.

**Q5 — Printer hardware for QA (USB/network thermal model, office A4 model).**
*Why:* G17/G20/G21 cannot be closed without devices; media negotiation is driver-specific.
*Default:* QA on whatever generic drivers exist → gates stay UNVERIFIED. *Affects:* G17,
G20, G21.

**Q6 — Print defaults & post-sale prompt (default paper 80mm? auto-print/ask-before-print?).**
*Why:* legacy had `default_paper`/`auto_print_invoice`/`ask_before_print`; modern settings
screen has neither, and Phase 17 owns settings. *Default:* explicit print from the
document dialog via preview; paper default 80mm for documents / A4 for reports; **no**
auto-print in Phase 15. *Affects:* G24, §6.4.

**Q7 — Scope beyond sale invoices: print return documents? void-marked invoices? purchase
documents?**
*Why:* roadmap says "invoices"; payloads for all three exist (§3.1). *Default:* returns
YES (80mm+A4, data complete), voided invoice YES with VOID banner, purchases DEFERRED.
*Affects:* G27, document matrix §3.2.

**Q8 — Report formats scope: XLSX+PDF for all 10 Phase 14 reports? Dashboard PDF?**
*Why:* roadmap lists Excel/CSV/PDF generally; dashboard is "where appropriate". *Default:*
all 10 reports get CSV (existing) + XLSX + PDF; dashboard PDF deferred; charts never
(G32). *Affects:* G9, G26.

**Q9 — Export/print audit retention & visibility.**
*Why:* rows accumulate in `audit_logs`; no retention policy exists; Phase 15 adds no UI.
*Default:* retain indefinitely (consistent with current audit), no audit UI in Phase 15,
visible via existing `audit_view` scope if/when an audit screen arrives.
*Affects:* G12.

**Q10 — CSV spreadsheet-formula injection: accept the frozen behavior or amend the contract?**
*Why:* Phase 14 CSV does not neutralize leading `=+-@` in strings (§17.4); sanitizing
would change frozen bytes. XLSX (new) will be sanitized regardless. *Default:* keep CSV
frozen in Phase 15; revisit at Phase 17 with a contract amendment if the owner wants it.
*Affects:* G33, G10.

**Q11 — Server-side CSV migration (byte-parity) in Phase 15, or stay client-side?**
*Why:* determines whether CSV executions are server-audited and whether two CSV builders
exist temporarily. *Default:* stay client-side (Phase 14 path untouched); server CSV only
later with byte-parity tests (§11.3). *Affects:* G31, audit completeness (§13.3).

**Q12 — Z-report / end-of-shift report: bring the legacy feature forward?**
*Why:* legacy had a printable Z-report; the modern app has no shift concept/endpoint, and
Phase 14 excluded drawer reconciliation (G7 there). Building it requires new report
semantics = new contract. *Default:* DEFER (G25) until the owner defines shift/drawer
scope. *Affects:* G25.

---

## 23. STEP A OUTPUT REPORT

### 23.1 Files inspected (representative; all reads, no writes)

**Docs:** `docs/PHASE_0_ROADMAP.md`, `PHASE_0_API_BLUEPRINT.md`, `PHASE_0_ARCHITECTURE.md`,
`PHASE_0_MASTER_SPECIFICATION.md`, `PHASE_0_FEATURE_MATRIX.md`, `PHASE_0_PERFORMANCE_AUDIT.md`,
`PHASE_0_DATABASE_ANALYSIS.md`, `PHASE_0_SECURITY_AUDIT.md`, `PHASE_0_EXCEPTION_AUDIT.md`,
`PHASE_0_LOCALIZATION_AUDIT.md`, `PHASE_0_POS_WORKFLOW.md`, `PHASE_8_POS_ANALYSIS.md`,
`PHASE_8_POS_IMPLEMENTATION.md`, `PHASE_14_REPORTS_DASHBOARD_ANALYSIS.md`,
`PHASE_14_IMPLEMENTATION.md`, `reference/docs/PHASE_0_BUSINESS_RULES.md`,
`reference/docs/PHASE_0_SECURITY_AUDIT.md`, `reference/docs/PHASE_0_LOCALIZATION_AUDIT.md`.

**Backend (`new_app/backend`):** `app/main.py`, `app/api/v1/{router,pos,returns,purchases,
reports,dashboard,system,expenses,customers}.py`, `app/api/dependencies.py`,
`app/schemas/{sale,returns,purchase,report,party,common,expense}.py`,
`app/services/{sale,returns,void,purchases,report,base}.py`,
`app/repositories/{sale,report}.py`, `app/models/{sale,return_doc,party,catalog,audit,
enums}.py`, `app/core/{config,exceptions,logging}.py`, `pyproject.toml`, `pytest.ini`,
`tests/` layout, `scripts/benchmark_reports_phase14.py`.

**Flutter (`new_app`):** `pubspec.yaml`, `pubspec.lock`, `lib/main.dart`,
`lib/features/pos/{print_service,sale_detail_dialog,sale_history_dialog,pos_screen,
pos_providers,pos_models}.dart`, `lib/features/reports/{report_csv,report_export,
reports_screen,reports_providers,report_models,report_widgets}.dart`,
`lib/features/dashboard/*`, `lib/features/returns/return_detail_dialog.dart`,
`lib/core/{strings,colors}.dart`, `lib/l10n/locale_provider.dart`, `lib/theme/app_theme.dart`,
`lib/network/api_client.dart`, `windows/` runner + plugin registrants, `test/` (unit+widget).

**Legacy (`python_app`):** `gui/main_window.py` (invoice PDF 11596–11953, exports
12967–14282, print triggers 10863–10883/12126–12415, settings 15192–15308),
`requirements.txt`, `config/app_settings.json`, `modules/sales.py`, `database/db_manager.py`.

**Repo-wide scans:** `*.ttf/otf/ttc` (8 build artifacts only), `print/print_job/pdf/xlsx/
reportlab/openpyxl/arabic/bidi/tax/ice/nif` across `new_app/`, git history for
`receipt_pdf_generator.dart` (absent), git status (only 2 untracked legacy CSV exports).

### 23.2 Key current-state findings

1. Modern backend is `new_app/backend` (not `python_app/`); zero PDF/XLSX/Arabic libs
   installed; zero print/export endpoints; no `print_jobs`/`export_jobs` tables.
2. Print today = Flutter plain-text → PowerShell `Out-Printer`; preview is a monospace text
   dialog; print never part of the sale transaction and never reports false success.
3. `SaleResponse` is complete for money/lines/payments/void but **lacks cashier name,
   customer name, and store header**; there are **no tax/fiscal fields anywhere**.
4. Reprint/detail endpoints exist for sales, returns, purchases; returns/purchases have no
   print UI.
5. Phase 14 CSV is entirely client-side and frozen; `export_xlsx`/`export_pdf` keys are
   pre-reserved; the documented 50,000 server cap does not exist in code yet.
6. No bundled fonts anywhere; UI Arabic font depends on runtime network fetch (offline risk).
7. Legacy ReportLab output spec (80mm/A4 geometry, totals block, RTL tables, reshaper+bidi)
   is fully recovered as evidence — including its defects (Helvetica fallback, shell print
   verb, no roll pagination, bidi on numbers, no `wordWrap=RTL` on invoice styles).
8. Phase 0 mandates backend generation ("FastAPI owns printing/export jobs", "backend jobs
   templates", perf rule "PDF/XLSX off UI path") and the roadmap assigns PDF/Excel
   generation to the backend, dialogs/preview to Flutter.

### 23.3 Decisions summary

| # | Question | Recommendation |
|---|---|---|
| 1 | **PDF architecture** | **Option A: backend ReportLab** + shaping via `arabic-reshaper`/`python-bidi`, bundled OFL font, `DocumentData → Template → Renderer`; Flutter uses `printing` only for preview/print (§4.3) |
| 2 | **XLSX architecture** | **Option A: backend openpyxl**, one sheet per report, RTL sheet view for `ar`, values-only, sanitized strings (§5.2) |
| 3 | **Print architecture** | `POST /print` → PDF bytes → `PdfPreview` → Windows system print dialog; save-PDF always available; text `Out-Printer` path superseded (§6.2) |
| 4 | **80mm strategy** | 80mm-wide PDF through the configured Windows driver (default), content-driven height, full RTL, no invented fiscal fields; ESC/POS deferred (§6.3, §7) |
| 5 | **A4 strategy** | A4 PDF, 13/12mm margins, meta table + repeating-header table + totals + page N of M; same DocumentData as 80mm (§8) |
| 6 | **Arabic/RTL/font** | sanitize → reshape-if-Arabic → bidi-if-Arabic → embedded OFL font (Cairo/Noto); XLSX raw + `rightToLeft`; preview = same bytes; no proprietary fonts (§15) |
| 7 | **Export/audit strategy** | unified `POST /exports` (XLSX/PDF; CSV stays Phase 14 client-side), same `ReportService` path, server-side 50k cap, `audit_logs` rows for every attempt via additive `export`/`print` actions, no new tables (§12, §13) |

### 23.4 Gates & owner questions

- **33 gates: 19 RESOLVED, 7 DEFERRED, 7 UNVERIFIED** (§21).
- **12 owner questions** with defaults (§22): fiscal text, logo, store identity, thermal
  method, QA hardware, print defaults/scope, report format scope, audit retention,
  CSV injection, server-side CSV, Z-report, (plus dashboard/purchase scope folded into Q7/Q8).

### 23.5 Zero-implementation confirmation

- Files created: **1** — `docs/PHASE_15_PRINTING_EXPORTS_ANALYSIS.md` (documentation only).
- Application code modified: **0**.
- Dependencies added: **0** (`pyproject.toml` / `pubspec.yaml` / lockfiles untouched).
- Database migrations created: **0**.
- Commits / pushes: **0** (working tree contains only this new doc + pre-existing
  untracked legacy CSV artifacts).

**STOP — END OF STEP A.**

