# PROJECT REPORT — Supermarket Pro / Klick POS (Windows Desktop POS)

**Audit type:** read-only static analysis of the repository at `D:\prjts\supermarket_logiciel 2`
**Audit date:** 2026-11-12
**Auditor role:** senior software architect / code auditor
**Report split:** §1–§8 in this file; **§9–§13 are in `PROJECT_REPORT_PART_2.md`** (Windows packaging readiness, code quality, missing features, final checklist, files-read log).

> **Reading conventions used in this report**
> - All paths are relative to the repository root unless stated otherwise.
> - `file:line` citations come from the repository as read during this audit.
> - Anything that could not be established from the code is marked **UNKNOWN - needs confirmation**, together with what is missing.
> - No secret values are reproduced. Secret *locations* are flagged only.

---

## 1. Executive Summary

### What the application is

A **two-tier, local-first Point-of-Sale / retail management system** for a supermarket or grocery shop, consisting of:

1. **A Flutter Windows desktop client** (`new_app/`, 220 Dart files, ~94,449 lines of Dart) — Arabic/French/English UI, RTL-capable, keyboard-first (F-keys, numpad, barcode-wedge capture), light/dark themes.
2. **A Python FastAPI backend** (`new_app/backend/`, 394 Python files inside `app/`, `migrations/`, `scripts/`, `tools/`, ~67,241 lines) that owns **all** business logic, stock, money, numbering, reporting and PDF rendering.
3. **A PostgreSQL database** accessed through SQLAlchemy 2.0 + Alembic migrations (37 migration scripts, current head `0037`).
4. **A licensing subsystem** (offline Ed25519 activation codes + 10-day free trial) and **a Windows installer design/implementation** (Inno Setup + embedded CPython + PostgreSQL EDB + WinSW service), documented as phases R1–R6.

The client never touches the database. It speaks REST/JSON to `http://<server>:8000/api/v1` and prints **PDF documents rendered by the backend**.

### Who it is for

A single shop (and optionally several till PCs on a shop LAN) in an **Algerian retail context**, evidenced by:

- Currency/format conventions in `new_app/lib/core/money.dart`, `number_format.dart`.
- Algerian fiscal identifiers `NIF / NIS / RC / AI / RIB` and `wilaya` in `app/models/settings.py` and `app/models/facturation.py`.
- Arabic-first documentation content (`new_app/lib/features/documentation/doc_content.dart`, 3,602 lines) and `IBMPlexSansArabic` bundled fonts.
- A **Zakat** calculation module (`app/models/zakat.py`, `app/domain/zakat.py`, `app/services/zakat.py`, `lib/features/zakat/`).
- Arabic/French/English localisation in both tiers.

### Main features (verified in code)

| Domain | Status |
|---|---|
| POS checkout (cart, discounts, split/credit payments, holds, favourites, packs, selling units, wholesale tiers, promotions, loyalty) | Implemented |
| Sales history, invoice reprint, void with stock/debt reversal | Implemented |
| Returns (sale-linked and independent, pro-rata refunds) + return void | Implemented |
| Products, categories, variants, selling units, purchase units, package stock (boxes/cartons), packs, bulk CSV/XLSX import/export, price labels | Implemented |
| Inventory movements, adjustments, low stock | Implemented |
| Customers, debt ledger, debt ceiling, customer payments | Implemented |
| Suppliers, supplier ledger, payables, supplier payments | Implemented |
| Purchases (draft → received → cancelled) with PMP (moving average cost) | Implemented |
| Expenses (post/cancel) | Implemented |
| Promotions (percentage / fixed price, one active per product) | Implemented |
| Loyalty (points + cashback, ledger, rewards, clawbacks) | Implemented |
| Facturation (FAC/DEV/PRO/BC/BL fiscal documents, numbering per type/year, client fiscal identities, posting to POS sale, A4 PDF) | Implemented |
| Reports (11 report endpoints + dashboard), CSV/XLSX/PDF export | Implemented |
| Printing (80 mm / A4 PDF through the Windows print dialog), price labels | Implemented (no ESC/POS) |
| Users/roles/permissions (RBAC: admin/manager/cashier, 30 scopes), PIN+Argon2id, JWT sessions | Implemented |
| Audit trail (append-only, filters, detail) | Implemented |
| Backup / restore (`pg_dump`, signed manifest v2, ZIP upload/download, safety backup before restore) | Implemented |
| LAN multi-PC (UDP discovery, pairing/approval/revocation, device guard, heartbeat/backoff) | Implemented |
| Connected hardware inventory (printers/scanners/USB/COM via PowerShell) | Implemented (read-only presence checks) |
| Licensing (trial + lifetime activation, enforcement guard) | Implemented |
| In-app documentation, About, storage usage, data transfer | Implemented |

### Overall maturity

**Mature / near production-ready — far beyond a prototype.** Evidence:

- 37 Alembic migrations with an append-only document model, check constraints, partial unique indexes and explicit snapshot columns.
- Backend test suite: **116 unit test modules** (`backend/tests/unit/`) + **24 integration modules** (`backend/tests/integration/`); Flutter suite: **~180 test files** (`test/unit`, `test/widget`) including golden images.
- Very heavy in-code design documentation: nearly every module opens with a decision record ("GATE n", "§x.y", phase references). No `TODO`/`FIXME`/`HACK` markers were found anywhere in `backend/app` or `lib/` (verified by grep).
- Production hardening already exists: `run_production.py`, WinSW service XML, `DATA_DIR` separation, secret provisioning (`app/core/secrets.py`), rate limiting, placeholder-secret refusal, signed backups, licensing guard.
- A complete installer design + rehearsal harness (`installer/setup.iss`, `stage_payload.ps1`, `build_installer.ps1`, `rehearsal_harness.ps1`, `docs/R5_INSTALLER_DESIGN.md`).

**Caveats that keep it from "shipped":** the developer still runs two processes manually (uvicorn + `flutter run -d windows`); the `.env` in the working tree is a real development configuration with a real DB password; the installer is a *rehearsed* artifact (`docs/R5_INSTALLER_DESIGN.md` ends with "**PASS WITH LIMITATIONS**"), not a released, signed installer; no auto-update; no shift/cash-drawer reconciliation; no ESC/POS/cash-drawer/customer-display support.

### Repository shape (important)

The repository is a **workspace of several trees**, not a single app:

| Path | What it is | Files |
|---|---|---|
| `new_app/` | **The current application** (Flutter + FastAPI + backend tests + Windows runner) | 10,869 (incl. `.venv`, `build/`) |
| `new_app_upload/` | A **near-duplicate snapshot** of `new_app/` (same `pubspec.yaml`/`pubspec.lock` dates 2026-10-26), used for upload/delivery; not referenced by anything | 1,005 |
| `new_app_upload.zip` | 93 MB archive of the above | 1 |
| `python_app/` | **Legacy Tkinter/CustomTkinter POS** (pre-Flutter), kept for parity reference; not part of the product | 42 (incl. `__pycache__`) |
| `reference/` | Seven Phase-0 analysis documents of the legacy app | 7 |
| `docs/` | 53 design/audit/phase documents (Phase 0–17, licensing audit, R1–R5) | 53 |
| `facture-docs/` | 7 reports for the "facturation" (invoicing) sub-project | 7 |
| `installer/` | Windows installer sources (Inno Setup + PowerShell staging + provisioning driver) | 7 |
| Root `*.md`, `*.txt` | `MANIFEST.md`, `FLUTTER_DEPENDENCY_MAP.md`, `PYTHON_DEPENDENCY_MAP.md`, `PARITY_COMPARISON_GUIDE.md`, `FILE_HASHES.txt`, `README.md`, `command.txt`, stray `tatus` (a captured `git diff --stat`) | 10 |

Ignored/mentioned but not analysed as source: `new_app/build/`, `new_app/.dart_tool/`, `new_app/backend/.venv/` (contains 4,074 `*.py` + 4,497 `*.pyc` of third-party packages), `__pycache__/`, `.mypy_cache/`, `.ruff_cache/`, `.pytest_cache/`, `.git/`, `new_app_upload/.dart_tool/`.

---

## 2. Tech Stack & Versions

### 2.1 Frontend — Flutter (Windows desktop)

`new_app/pubspec.yaml`:

- `name: supermarket_pos`, `version: 1.0.0+1`, `publish_to: none`
- Dart SDK constraint: `sdk: ^3.12.2`
- Installed toolchain on the audited machine: **Flutter 3.44.8 stable, Dart 3.12.2, DevTools 2.57.0** (verified by running `flutter --version`).

| Package | Version | Used for |
|---|---|---|
| `flutter` / `flutter_localizations` | SDK | App framework, Material/Cupertino localisation delegates |
| `cupertino_icons` | ^1.0.8 | Icon font |
| `flutter_riverpod` | ^2.6.1 | **State management / DI** (all providers, `StateNotifier`, `ProviderScope` overrides in `main.dart`) |
| `go_router` | ^14.8.1 | **Routing** (`lib/router/app_router.dart`, `ShellRoute`, redirect gates) |
| `dio` | ^5.7.0 | **HTTP client** (`lib/network/api_client.dart`), interceptors, byte downloads |
| `ffi` | ^2.2.0 | Win32 `GetDiskFreeSpaceExW` for disk usage (`lib/features/storage/local_storage_measure.dart`) |
| `intl` | ^0.20.1 | Number/date formatting |
| `freezed_annotation`, `json_annotation` | ^2.4.4 / ^4.9.0 | Model codegen annotations |
| `shared_preferences` | ^2.3.4 | Locale, theme, POS/scan settings, paired server URL + `server_id`, device id |
| `flutter_secure_storage` | ^9.2.4 | **JWT** and **device token** (Windows Credential Manager/DPAPI backend) |
| `file_picker` | ^10.1.2 | Import (CSV/XLSX), image picking for products, backup upload |
| `printing` | ^5.15.1 | `Printing.layoutPdf` → Windows print dialog; `PdfPreview` |
| `pdf` | ^3.13.1 | Page formats (`PdfPageFormat.roll80`, `a4`) for the preview/print path |

Dev dependencies: `flutter_lints ^6.0.0`, `build_runner ^2.4.13`, `freezed ^2.5.8`, `json_serializable ^6.9.2`, `mocktail ^1.0.4`, `flutter_test`.

Assets: `assets/fonts/IBMPlexSansArabic-{Regular,Bold}.ttf` (+ `OFL.txt`), `assets/brand/klick_pos_logo.svg`, `assets/docshots/` (empty apart from `.gitkeep`; documentation screenshots are intentionally not fabricated — see `pubspec.yaml` comment).

**No `google_fonts`**: typography is bundled by design because the app runs on an offline LAN (`pubspec.yaml` comment).

### 2.2 Backend — Python / FastAPI

`new_app/backend/pyproject.toml` and `requirements.lock.txt`:

- Language/runtime: **Python**, `requires-python = ">=3.10"`. Installed interpreter on the machine: **CPython 3.10.11** (both system Python and `backend/.venv`).
- Web framework: **FastAPI 0.141.1**, ASGI server **uvicorn 0.53.0** (`uvicorn[standard]`), Starlette 1.6.0.
- ORM: **SQLAlchemy 2.0.54** (pinned `<2.1` on purpose: 2.1 switches `postgresql://` to psycopg3 while the code uses psycopg2 — see comment in `pyproject.toml`).
- Migrations: **Alembic 1.20.0**.
- DB driver: **psycopg2-binary 2.9.13**.
- Validation/settings: **Pydantic 2.13.5**, **pydantic-settings 2.15.0**.
- Config file loading: **python-dotenv 1.2.3** (`dotenv_values` used directly by `run_production.py` and `installer/installer_provision.py`).
- Auth crypto: **python-jose 3.5.0** (HS256 JWT), **passlib 1.7.4 + argon2-cffi 25.1.0** (Argon2id PIN hashing), **cryptography 50.0.1** (Ed25519 licence signatures, DPAPI/HMAC state files).
- Logging: **structlog 26.1.0** (JSON-ish key/value events), rotating file handler (`app/core/logging.py`).
- PDF/print rendering: **reportlab 5.0.1**, **arabic-reshaper 3.0.1**, **python-bidi 0.6.11** (Arabic shaping + RTL bidi).
- Spreadsheets: **openpyxl 3.1.5** (XLSX export/import).
- HTTP client (outbound, tests/tools): **httpx 0.28.1**.
- Multipart: **python-multipart 0.0.32** (backup upload).
- Dev/test only: `pytest`, `pytest-asyncio`, `pytest-cov`, `ruff`, `mypy` (strict, `python_version = "3.10"`), `pymupdf` (PDF geometry assertions), `setuptools`.

### 2.3 Database

- **PostgreSQL** (the live development `.env` uses `DATABASE_URL=postgresql://…`, verified by scheme only; the password is not reproduced here).
- Target version: **PostgreSQL 18** in the installer (`installer/setup.iss`: `postgresql-18.6-5-windows-x64.exe`, `PgDataDir={commonappdata}\SupermarketPro\postgres\data`, `PgPort 5432`).
- Development docs still mention SQLite for tests (`docs/PHASE_1_SETUP.md`); the engine supports SQLite (`app/db/engine.py` branches on the URL and sets `check_same_thread=False`), and unit tests create in-memory SQLite schemas via `Base.metadata.create_all`.
- **No ORM other than SQLAlchemy**; no raw SQL string concatenation in the paths reviewed (all queries go through SQLAlchemy Core/ORM; the only raw SQL is `SELECT version_num FROM alembic_version`, `pgcrypto`/trigram setup and `pg_dump`/`psql` subprocesses).
- Alembic head at audit time: revision **`e5b7d2c9a41f` (0037_zakat_basis_wholesale)**, `down_revision = 'a7c1e9f3b5d2'` (0036).

### 2.4 Other tools/services

- **Inno Setup 7** (`ISCC.exe`) for the installer, driven by `installer/build_installer.ps1`.
- **WinSW** service wrapper (`new_app/backend/winsw/SupermarketProBackend.xml`) — the backend runs as a Windows service in production.
- **PowerShell 5.1** for installer staging, ACL grants (`installer/stage_payload.ps1`, `backend/winsw/grant_data_dir_acl.ps1`), hardware enumeration (`app/services/hardware.py`) and the legacy text-print path (`lib/features/pos/print_service.dart`).
- **PostgreSQL EDB installer** + **VC++ 2015–2022 x64 redistributable**, both SHA-256-pinned in `installer/setup.iss`.
- **Ed25519 offline licence generator** (`backend/tools/license_generator/`, deliberately excluded from the customer package — see `backend/customer_package.json`).
- No Docker, no Node, no CI configuration was found in the tree (`UNKNOWN - needs confirmation` if CI exists externally).

---

## 3. Architecture

### 3.1 How frontend and backend communicate

- **Protocol:** plain HTTP/1.1, REST, JSON (`Content-Type: application/json`), plus raw `application/pdf` for print endpoints and `application/zip`/`.sql` for backups.
- **Base URL:** `http://localhost:8000` by default (`new_app/lib/core/constants.dart:17 AppConstants.defaultServerBaseUrl`). It is resolved at boot by `initialBaseUrl()` (`lib/features/devices/device_identity.dart:238`), which prefers:
  1. the paired server URL in `SharedPreferences` (`paired_server_url`),
  2. a `supermarket_endpoint.json` descriptor (`{base_url, host, port}`) written by the backend launcher into `<DATA_DIR>/config/` and the dev sibling `new_app/app/` (`run_production.py::_publish_local_endpoint`),
  3. the constant default.
- **Ports:** HTTP `8000` (`PORT` in `.env`), UDP discovery `8000` (`DISCOVERY_PORT`, deliberately the same number — `app/core/config.py` comment "a store only only ever has to remember/open one port number").
- **API prefix:** `/api/v1` (`app/main.py` → `app.include_router(api_router, prefix="/api/v1")`). Health is therefore `/api/v1/health`.
- **Not WebSocket.** There is no push channel: the client polls a 10 s heartbeat (`lib/features/devices/connection_provider.dart`, `heartbeatInterval`), and the backend exposes no WS routes.
- **Multi-PC:** UDP broadcast discovery → HTTP probe (`/health` + `/system/info`) → `POST /devices/pair` with a 6-digit code → admin approval → one-time `device_token` → every later call carries `X-Device-ID` + `X-Device-Token` (`app/api/device_guard.py`, `lib/network/api_client.dart`).

### 3.2 Folder-by-folder explanation

#### Backend — `new_app/backend/`

```
app/
├── main.py                  FastAPI app factory, lifespan (data dirs, trial, discovery), CORS, request-id middleware
├── api/
│   ├── dependencies.py      JWT auth dependency, require_permission / require_any / require_all, session heartbeat
│   ├── device_guard.py      X-Device-ID / X-Device-Token enforcement (LAN_MODE only), pairing allowlist
│   └── v1/                  32 router modules — one per feature (see §5)
├── core/
│   ├── config.py            Pydantic Settings, DATA_DIR/LOG_DIR/LICENSE paths, placeholder-secret refusal
│   ├── constants.py         money precision, Argon2 params, pagination, placeholder secret values
│   ├── security.py          Argon2id hash/verify, JWT create/decode, SHA-256 token fingerprint
│   ├── exceptions.py        Typed AppError hierarchy → {error:{code,message,details}} envelope + handlers
│   ├── middleware.py        X-Request-ID propagation
│   ├── rate_limit.py        In-process sliding-window limiter (auth + app-wide + licence activation)
│   ├── logging.py           structlog setup, rotating file sink (R2)
│   ├── secrets.py           Per-install secret provisioning (secrets.env, database.env)
│   ├── seed.py              Roles/permissions seed (idempotent, CLI)
│   ├── rbac_bootstrap.py    Read-only RBAC audit + initialize (writes only roles/permissions)
│   ├── postgres_discovery.py   Read-only PostgreSQL instance discovery (registry/disk/service)
│   ├── postgres_provisioning.py  Create-if-absent DB, alembic upgrade, RBAC init, dedicated install
│   ├── server_identity.py   Persistent server_id
│   ├── db_dump.py           Schema/dump helpers
│   └── filenames.py         Safe Content-Disposition filenames
├── db/                      engine.py (lazy engine factory), session.py (get_db), base.py (mixins, money/quantity columns)
├── models/                  19 ORM modules → 41 tables (§6)
├── schemas/                 Pydantic request/response contracts per feature
├── repositories/            Query layer (base, catalog, report, …)
├── services/                31 business services (sale.py 2,040 lines, catalog.py 1,680, returns.py 1,598, …)
├── domain/                  Pure domain logic (facturation totals, loyalty, packaging, promotion, units, valuation, wholesale, zakat)
├── printing/                reportlab renderers: invoice_80mm, invoice_a4, facture_a4, labels, price_labels, fonts, styles
├── exporting/               XLSX + export contract
├── licensing/               Ed25519 activation, licence manager, trial, guard, fingerprint, state store, backup policy
├── discovery/               UDP packet codec + responder
└── permissions/             Package marker (RBAC lives in models/enums + core/seed)
migrations/                  37 Alembic revisions (0001 … 0037)
tests/                       116 unit + 24 integration modules
scripts/                     QA seeders, benchmarks (1,000-product seed, large-sale, reports, G7 PDF spike)
tools/license_generator/     Owner-only offline licence generator (never shipped)
winsw/                       Service XML, ACL script, operator README
data/, backups/, logs/       Development runtime state
```

#### Frontend — `new_app/lib/`

```
main.dart                 Boot: SharedPreferences, secure storage, ApiClient with resolved base URL, provider overrides
router/app_router.dart    GoRouter + all routes + redirect gates (splash → setup-network → setup → licence → login → shell)
network/api_client.dart   Dio wrapper, auth/device headers, error-envelope decoding, 401 vs device-guard separation
core/                     Formatters (money, numbers, quantity expressions), colours, strings (5,282 lines, AR/FR/EN),
                          shortcuts, barcode scanner gateway, Raw Input decoder, reusable widgets
features/<domain>/        One folder per screen: *_screen.dart (UI), *_providers.dart (state + API), *_models.dart,
                          dialogs. 29 domains: about, audit, auth, backup_restore, clients, dashboard, data_transfer,
                          debts, devices, documentation, expenses, facturation, hardware, invoice_clients, licensing,
                          loyalty, packs, pos, products, promotions, purchases, reports, returns, sales, settings,
                          shell, splash, stock, storage, suppliers, users, zakat
theme/                    AppTheme (light/dark, seed colours, typography), theme provider
l10n/                     Locale provider (ar/fr/en, persisted)
```

#### Windows runner — `new_app/windows/`

Standard Flutter `windows/` CMake project (`project(supermarket_pos)`, `BINARY_NAME "supermarket_pos"`) plus a **custom native addition**: `runner/raw_scanner_input.cpp/.h` (489 + header lines) — a Win32 **Raw Input** capture for barcode scanners, referenced from `flutter_window.cpp`. Plugin registrant includes `flutter_secure_storage_windows` and `printing`, with `jni` listed as an FFI plugin (`windows/flutter/generated_plugins.cmake`).

### 3.3 State management, routing, dependency injection

- **State:** Riverpod throughout.
  - `StateNotifierProvider` for `authProvider` (`AuthNotifier`/`AuthState`), `lanConnectionProvider`, settings providers, POS providers.
  - `Provider` for stateless services (`apiClientProvider`, `printServiceProvider`, `pdfPreviewProvider`).
  - `FutureProvider`/`StreamProvider` for async reads; `installBootstrappedProvider` is a `Provider<bool>` overridden in `main.dart`.
  - **DI:** constructor injection of `ApiClient`, `SecureCredentialStorage`, `FlutterSecureStorage`, `Dio`, `PrintService`, `PdfPreviewBuilder`, discovery factory, probe function — all overridable in `ProviderScope` for tests.
- **Routing:** a single `GoRouter` created once (`routerProvider`), refreshed by a `ValueNotifier` fed by `ref.listen` on auth/network/splash/licence state. Redirect order is explicit and documented in `app_router.dart`:
  splash → first-run network wizard → first-admin setup → expired-licence parking → login → shell.
  One `ShellRoute` hosts the `AppNavRail` + app bar (brand, shortcuts help, connection chip, user monogram, logout, trial banner).
- **Permission gating:** `hasPermissionProvider(scope)` drives `buildNavGroups` (`lib/features/shell/nav_items.dart`); the backend remains the security boundary (stated in `app_router.dart` comments).
- **API layout:** every feature has `*_providers.dart` that call `dio` directly against `/api/v1/...` (no repository abstraction layer on the client); models are hand-written `fromJson`/`toJson` (no generated `.g.dart` files were found — `freezed`/`json_serializable` are declared but codegen output is not committed).

### 3.4 Architecture / data-flow diagram (text)

```
┌───────────────────────────── Windows till PC ─────────────────────────────┐
│  Flutter desktop app (supermarket_pos.exe)                                 │
│  ┌──────────────┐   ┌────────────────────┐   ┌───────────────────────────┐ │
│  │ UI screens   │──▶│ Riverpod providers │──▶│ ApiClient (Dio)           │ │
│  │ (features/*) │◀──│ (state + calls)    │◀──│ Bearer JWT + X-Device-*   │ │
│  └──────────────┘   └────────────────────┘   └───────────┬───────────────┘ │
│         │  keyboard-wedge scanner (Raw Input + Flutter gateway)            │
│         │  PDF bytes ──▶ `printing` ──▶ Windows spooler ──▶ printer        │
└─────────┼──────────────────────────────────────────────────────────────────┘
          │ HTTP/JSON  http://<server>:8000/api/v1   (LAN)
          ▼
┌────────────────────────── Server PC (WinSW service) ──────────────────────┐
│ uvicorn (1 worker) → FastAPI app.main:app                                  │
│   middleware: RequestID → CORS                                             │
│   router deps: api_rate_guard → device_guard → license_guard                │
│   per-route deps: get_current_user → require_permission(scope)             │
│   services/ (business rules, transactions)                                 │
│   repositories/ + models/ (SQLAlchemy ORM)                                 │
└───────────┬───────────────────────────────────────────┬───────────────────┘
            │ psycopg2 (pool 5/10, pre-ping)             │ subprocess
            ▼                                           ▼
   PostgreSQL 18  (C:\ProgramData\SupermarketPro\postgres\data)   pg_dump / psql / PowerShell
            ▲
            │ file state (never in DB): <DATA_DIR>\license\{trial.state, license.state, hmac.key}
            │ <DATA_DIR>\config\{.env, secrets.env, database.env, supermarket_endpoint.json}
            │ <DATA_DIR>\backups\*.sql|*.json|*.zip , <DATA_DIR>\logs\backend.log
```

### 3.5 Transaction / consistency model (as implemented)

- Each API request gets one SQLAlchemy `Session` (`app/db/session.py::get_db`); services own commit/rollback.
- Sale checkout is **one atomic transaction**: sale + lines + payments + stock decrement + `inventory_movements` + debt ledger + loyalty ledger + audit (`app/services/sale.py`).
- Money and quantities are `NUMERIC(18,3)` end-to-end; Python side uses `Decimal` in services/schemas (models annotate `float` but columns are `Numeric`).
- **Idempotency** is pervasive and explicit: `client_request_id` unique columns on `sales`, `purchases`, `returns`, `expenses`, `promotions`, `debt_ledger_entries`, `supplier_ledger_entries`, `zakat_calculations`, `zakat_payments`, plus `loyalty_ledger_entries.source_event_key`.
- Documents are **append-only**: voids and cancellations never rewrite totals, they add compensating ledger/movement rows (`app/models/sale.py` comments; `app/services/void.py`).

---

## 4. Features Inventory (detailed)

Legend for completeness: **Complete** = implemented end-to-end with validation, persistence and UI; **Partial** = works but with documented gaps; **Stub** = placeholder only; **Broken** = confirmed defect.

### 4.1 POS / Checkout

- **What:** catalog browsing + search + barcode scan, favourites strip, cart with quantity expressions (`10*24`, `+`, `-`), selling-unit and pack selection, price override with permission, line and invoice discounts, wholesale tier pricing, promotion pricing, loyalty lookup/redeem, customer picker with quick-add, credit/partial payment, change calculation, park/hold carts, sale commit, receipt print/preview, reprint by invoice number.
- **Backend:** `app/api/v1/pos.py` (`POST /sales`, `/pos/cart/validate`, `/pos/holds*`, `/pos/favorites*`), `app/services/sale.py` (2,040 lines), `app/domain/wholesale.py`, `app/domain/promotion.py`, `app/domain/packaging.py`, `app/domain/loyalty.py`, `app/services/loyalty.py`, `app/services/void.py`.
- **Frontend:** `lib/features/pos/pos_screen.dart` (6,500 lines), `pos_providers.dart` (1,361), `pos_models.dart` (963), `payment_dialog.dart`, `pos_return_lines.dart`, `holds_dialog.dart`, `pack_picker_dialog.dart`, `price_override_dialog.dart`, `invoice_discount_dialog.dart`, `loyalty_discount_dialog.dart`, `print_preview_dialog.dart`, `print_service.dart`, `print_document.dart`, `pdf_preview.dart`, `sale_detail_dialog.dart`, `sale_history_dialog.dart`; `lib/features/sales/sales_screen.dart`.
- **Completeness:** **Complete** for single-PC; **Partial** by design for offline (no offline queue: "Sales are never stored offline — the server must be reachable" — `lib/features/documentation/doc_content.dart`).
- **Notes:** checkout is idempotent via one `client_request_id` per attempt reused on retry (`pos_providers.dart:445-509`, `1336`).

### 4.2 Products / Catalog

- **What:** product CRUD (soft-delete/archive, permanent deletion rules), barcode/SKU uniqueness, image path, VAT rate metadata (0/9/19 — metadata only), wholesale price + min qty, low-stock threshold, allow-negative-stock flag, expiry date; variants (price/cost overrides, own barcode/SKU/quantity); **selling units** (multiplier, own barcode, own price, base-unit flag); **purchase units** (multiplier, default flag); **package stock** (`full_packages` per purchase unit, derive loose base); price labels; bulk import/export.
- **Backend:** `app/api/v1/products.py` (24 endpoints), `app/api/v1/product_transfer.py` (3), `app/services/catalog.py` (1,680), `app/repositories/catalog.py` (495), `app/domain/unit_conversions.py`, `app/domain/packaging.py`, `app/models/catalog.py`.
- **Frontend:** `lib/features/products/` — `products_screen.dart` (2,137), `products_providers.dart` (1,184), `product_form_dialog.dart` (1,689), `categories_dialog.dart`, `variant_form_dialog.dart`, `selling_unit_form_dialog.dart`, `purchase_unit_form_dialog.dart`, `label_print_dialog.dart`, `product_image_picker_service.dart`, `models.dart`.
- **Completeness:** **Complete**.

### 4.3 Categories

- CRUD with hierarchy (`parent_id`), sort order, unique name, product counts. `app/api/v1/categories.py`, `app/services/catalog.py`, `lib/features/products/categories_dialog.dart`.
- **Complete.**

### 4.4 Packs (bundles)

- Pack definition (name, barcode, price, active, image), component lines with **selling-unit snapshot** (quantity pinned in base units), availability endpoint. Selling a pack consumes component stock and writes `pack_component` movements; pack lines are charged, component lines are not.
- `app/api/v1/packs.py`, `app/services/pack.py` (696), `app/models/catalog.py::Pack/PackItem`, `lib/features/packs/` (`packs_screen.dart` 894, `pack_form_dialog.dart` 988, `pack_detail_dialog.dart`).
- **Complete.**

### 4.5 Inventory / Stock

- Stock levels per product/variant, movement journal (`inventory_movements`, immutable, with before/after), manual adjustments with reason, per-product movement history, low-stock list, packaging state endpoints (receive/sell/sell-packages), PMP (`avg_cost`) maintenance on purchase receive.
- `app/api/v1/inventory.py`, `app/services/inventory.py` (1,432), `app/models/inventory.py`, `app/domain/valuation.py`; UI `lib/features/stock/stock_screen.dart` (1,860), `adjust_dialog.dart`, `inventory_providers.dart`.
- **Complete** (no formal "stock take/count sheet" document flow; adjustments only — see §11).

### 4.6 Customers & Debt

- Customer CRUD, phone search, balance + **debt ceiling**, debt ledger (`debt_ledger_entries`: sale/payment/adjustment), payment recording with idempotency, per-customer debt list, loyalty summary/history/adjustment.
- `app/api/v1/customers.py` (11 endpoints), `app/services/customers.py`, `app/services/debt.py`, `app/models/party.py`, `app/models/debt.py`; UI `lib/features/clients/` (`clients_screen.dart` 870, `customer_form_dialog.dart`, `debt_payment_dialog.dart`), `lib/features/debts/debts_screen.dart`.
- **Complete.** Credit sale additionally requires `pos_credit_sale`.

### 4.7 Suppliers & Payables

- Supplier CRUD (contact, email, notes), cached `balance`, append-only `supplier_ledger_entries` (purchase/payment/purchase_cancel), ledger view, payment recording with idempotency.
- `app/api/v1/suppliers.py` (7), `app/services/suppliers.py`, `app/services/supplier_ledger.py`, `app/models/supplier_ledger.py`; UI `lib/features/suppliers/` (`suppliers_screen.dart` 794, `supplier_form_dialog.dart`, `supplier_payment_dialog.dart`).
- **Complete.**

### 4.8 Purchases

- Purchase document lifecycle **draft → received → cancelled**; lines snapshot product data and purchase-unit multiplier; receiving posts stock + PMP + movements + payable atomically; cancellation reverses them; supplier optional; drafts deletable.
- `app/api/v1/purchases.py` (7), `app/services/purchases.py` (901), `app/models/purchase.py`; UI `lib/features/purchases/` (`purchases_screen.dart`, `purchase_form_dialog.dart`, `purchase_line_dialog.dart`, `purchase_detail_dialog.dart`, `purchase_pickers.dart`).
- **Complete.**

### 4.9 Returns & Voids

- Returns linked to a sale line (quantity ≤ unreturned sold quantity) or independent; pro-rata refund with invoice-discount conservation; stock restored with `RETURN` movements; optional reason vocabulary; idempotency key; return detail; return void.
- Sale **void**: one-way `completed → void`, restores stock, reverses debt, keeps totals intact, refuses if returns exist, requires reason + `pos_void`; cash/card refund is recorded as `cash_pending` but not executed (`app/api/v1/pos.py` docstring).
- `app/api/v1/returns.py` (3), `app/services/returns.py` (1,598), `app/services/void.py` (452), `app/models/return_doc.py`; UI `lib/features/returns/` (7 files), `lib/features/pos/pos_return_lines.dart`.
- **Complete.**

### 4.10 Expenses

- Post/cancel expense with category vocabulary (rent/utilities/salary/maintenance/supplies/transport/other), `paid_from_drawer` flag, server-assigned date, idempotency, cancellation attribution, summary endpoint. All three roles hold expense scopes (owner decision documented in `app/core/seed.py`).
- `app/api/v1/expenses.py` (4), `app/services/expenses.py` (419), `app/models/expense.py`; UI `lib/features/expenses/` (6 files).
- **Complete.**

### 4.11 Users / Roles / Permissions

- PIN-based users (4–6 digits, Argon2id), active/inactive, failed-attempt counter + `locked_until`, roles admin/manager/cashier, 30 permission scopes, many-to-many `user_roles`/`role_permissions`, session table with revocation, PIN change by admin, `/auth/me` returning flat scopes.
- `app/api/v1/users.py` (7), `app/api/v1/auth.py` (10), `app/services/auth.py` (715), `app/core/seed.py`, `app/models/enums.py::PermissionScope`; UI `lib/features/users/users_screen.dart`, `lib/features/auth/` (login, setup, reauth, pin pad, permission helpers).
- **Partial:** roles/permissions are **seeded and fixed**; there is no UI to create custom roles or toggle scope grants (only user CRUD + PIN). `UNKNOWN - needs confirmation` whether that is acceptable scope.

### 4.12 Facturation (fiscal documents)

- Separate fiscal domain: `invoice_clients` (NIF/RC/AI/NIS/wilaya) isolated from POS customers; documents FAC/DEV/PRO/BC/BL in one table with `UNIQUE(doc_type, year, number)` and per-(type,year) counters; typed `show_*` display options; totals/timbre computed in `app/domain/facturation.py`; preview, edit, post-to-POS-sale (creates a sale through `SaleService` with `client_request_id = facture:{id}`), A4 PDF rendering; permissions `facturation_view`/`facturation_manage` (admin+manager only).
- `app/api/v1/factures.py` (7), `app/api/v1/invoice_clients.py` (5), `app/services/facturation.py` (1,598), `app/domain/facturation.py` (439), `app/models/facturation.py`, `app/printing/templates/facture_a4.py` (350); UI `lib/features/facturation/` (9 files, `facturation_pickers.dart` 866, `invoice_form_dialog.dart` 842), `lib/features/invoice_clients/` (4).
- **Complete.**

### 4.13 Reports & Dashboard

- Dashboard KPIs (`GET /dashboard`), 11 reports: financial, sales, products, categories, daily, hourly, peak-hours, slow-moving, voided, suppliers, loyalty.
- Exports: `POST /exports` (XLSX) and client-side CSV (`lib/features/reports/report_csv.dart`), PDF table rendering (`app/printing/templates/report_table.py`).
- `app/api/v1/reports.py`, `app/services/report.py` (987), `app/repositories/report.py` (1,767), `app/exporting/xlsx.py`, `app/exporting/contract.py` (938); UI `lib/features/reports/` (11 files), `lib/features/dashboard/`.
- **Complete.** Performance indexes added in migration 0020 and benchmarked (`backend/scripts/benchmark_reports_phase14.py`, `docs/phase14_benchmark_results.json`).

### 4.14 Settings

- Store identity + fiscal identity, invoice footer, default paper (80 mm/A4), print prompts, `allow_debt`, `low_stock_threshold` — one singleton row `app_settings`. Client-side preferences (locale, theme, scan settings, POS settings) live in `SharedPreferences`.
- `app/api/v1/settings.py` (2), `app/services/settings.py`, `app/models/settings.py`; UI `lib/features/settings/settings_screen.dart` (1,513), `settings_provider.dart`, `pos_settings_provider.dart`, `scan_settings_provider.dart`, `scan_diagnostics_panel.dart`, `raw_scanner_poc_panel.dart`.
- **Complete.**

### 4.15 Backup / Restore

- `pg_dump` → `.sql` + JSON sidecar manifest (v2: `format_version`, `payload_sha256`, `created_by`, Ed25519 `signature`, `key_id`, embedded public key), listing, inspect, download (ZIP with dump+manifest), upload (ZIP or raw `.sql`), restore with `psql --single-transaction`, mandatory `confirm: true`, automatic safety backup, post-restore connectivity check, audit rows.
- `app/api/v1/backups.py` (6), `app/services/backup.py` (846), `app/services/backup_manifest.py` (350), `app/licensing/backup_policy.py`; UI `lib/features/backup_restore/backup_restore_screen.dart`, `lib/features/settings/backup_provider.dart`.
- **Complete**, but **manual only** — no scheduler (see §11).

### 4.16 Printing

- Backend renders PDFs with reportlab + Arabic reshaping: 80 mm receipt (`invoice_80mm.py`, 371), A4 invoice (`invoice_a4.py`), A4 facture (`facture_a4.py`), price labels (`price_labels.py`, 633), label batch (`labels.py`, 544), report tables.
- Client requests bytes (`POST /print`, `POST /print/labels`) and hands them to `Printing.layoutPdf` → **Windows print dialog**. Legacy text path via PowerShell `Out-Printer` (`print_service.dart::printText`).
- `app/api/v1/print.py` (2), `app/services/print.py` (703), `app/printing/*`; UI `lib/features/pos/print_preview_dialog.dart`, `pdf_preview.dart`, `lib/features/products/label_print_dialog.dart`.
- **Complete with explicit limits:** no ESC/POS, no cash-drawer kick, no customer display (`doc_content.dart` "Not supported" chapter).

### 4.17 Barcode

- Primary: **keyboard-wedge** capture. Two layers: an app-level gateway (`lib/core/barcode_scanner.dart`, 1,575 lines — digit-run + Enter detection, dialog suspension, layout experiments) and a **native Win32 Raw Input** path (`windows/runner/raw_scanner_input.cpp`, decoder in `lib/core/raw_scanner/raw_scanner_decoder.dart`), plus diagnostics (`scan_capture_recorder.dart`, `scan_diagnostics.dart`, settings panels).
- Lookup-first behaviour against `GET /products/barcode-lookup`, also for selling-unit and variant barcodes.
- **Complete** for wedge scanners; `UNKNOWN - needs confirmation` for HID-POS/serial scanners (no such driver code found).

### 4.18 LAN / Multi-PC

- Backend: `POST /devices/pair`, `GET /devices/pairings/{id}`, pairing-code generation, list/approve/deny/revoke, device guard, UDP responder (`app/discovery/`), `server_id` identity.
- Client: wizard (`setup_wizard_screen.dart`), discovery service (UDP + TCP probe), connection state machine with heartbeat/backoff/rediscovery, reconnect dialog, devices screen, status chip.
- **Complete**, single-server only (no replication/offline sync).

### 4.19 Licensing

- 10-day trial started on first backend start (`app/licensing/trial.py`), file state outside PostgreSQL, HMAC + optional DPAPI sealing (`state_store.py`), Ed25519 lifetime activation (`activation_code.py`, `license_manager.py`, `verification_keys.json` public keys only), router-level `license_guard` with modes `off|trial|on`, per-endpoint policy for backup actions, UI licensing screen + activation panel + trial banner.
- **Complete** (activation requires an offline code produced by the owner-only generator).

### 4.20 Audit

- Append-only `audit_logs` with actor snapshot, module, outcome, request id, session id, device verification, before/after JSON, business reason and entity reference; list with filters, summary, detail.
- `app/api/v1/audit.py` (3), `app/services/audit.py` (440); UI `lib/features/audit/` (5 files).
- **Complete.**

### 4.21 Zakat

- Calculation snapshot engine (`app/domain/zakat.py` 643 lines): nisab from gold price, inventory basis (market/cost/wholesale/override), receivables buckets, debt treatment, hawl, warnings/missing fields; saved immutable calculations, payments, PDF.
- `app/api/v1/zakat.py` (8), `app/services/zakat.py` (888), `app/models/zakat.py`; UI `lib/features/zakat/` (6 files, `zakat_screen.dart` 1,554).
- **Complete.**

### 4.22 Hardware & Storage screens

- `GET /hardware/overview` (+ refresh, test page, scanner test, COM test) — PowerShell-based presence checks, non-Windows returns an honest empty list with warnings (`app/services/hardware.py`).
- `GET /storage` — server disk/DB/backup usage (`app/services/storage.py` 442); client-side local usage via `GetDiskFreeSpaceExW` + directory walks (`local_storage_measure.dart`).
- UI: `lib/features/hardware/connected_devices_screen.dart`, `lib/features/storage/storage_screen.dart`, `lib/features/data_transfer/data_transfer_screen.dart`.
- **Complete.**

### 4.23 Documentation / About

- In-app AR/FR/EN documentation (13 chapters, `doc_content.dart` 3,602 lines, search + registry in `doc_registry.dart` 1,480), About with versions and server info.
- **Complete.**

---

## 5. API / Backend Reference

**Global facts**

- Base: `http://<host>:8000/api/v1`
- Error envelope: `{"error": {"code": "<CODE>", "message": "...", "details": {...}}}` (`app/core/exceptions.py`), plus FastAPI's default 422 shape for validation.
- Auth: `Authorization: Bearer <JWT>` for all business routes (`app/api/dependencies.py::get_current_user`). Public (no JWT): `/auth/setup*`, `/auth/login-users`, `/auth/login`, `/auth/verify-token`, `/auth/logout*`, `/health*`, `/system/info`, `/license/*`, `/devices/pair`, `/devices/pairings/{id}`.
- Router-level dependencies run on **every** route, in this order: `api_rate_guard` → `device_guard` → `license_guard` (`app/api/v1/router.py`).
- Permission column below lists the `require_permission(...)` dependency found in the endpoint signature (not re-verified for every file; entries marked *n/v* mean "not verified in this audit").

### 5.1 Health & system

| Method | Path | Purpose | Auth | Permission | File:line |
|---|---|---|---|---|---|
| GET | `/health` | Liveness + DB check (`database: connected/degraded`) | none | — | `app/api/v1/health.py:47` |
| GET | `/health/live` | Process liveness only | none | — | `health.py:70` |
| GET | `/health/ready` | Readiness incl. DB | none | — | `health.py:80` |
| GET | `/system/info` | server_id, store name, versions, licence snapshot | none | — | `app/api/v1/system.py:171` |
| GET | `/dashboard` | KPI bundle | JWT | *n/v* (`report_financial` expected) | `app/api/v1/dashboard.py:29` |

### 5.2 Auth (`/auth`)

| Method | Path | Purpose | Auth | Request → Response | File:line |
|---|---|---|---|---|---|
| POST | `/auth/setup` | Create first admin (only when none exists) | none (rate-limited) | `{name, pin, pin_confirm}` → `{user_id, name}` | `auth.py:54` |
| GET | `/auth/setup/check` | Is setup needed | none | → `{setup_needed: bool}` | `auth.py:77` |
| GET | `/auth/login-users` | Public selector list | none | → `{items:[{id,full_name,is_active,roles[]}],total}` | `auth.py:85` |
| POST | `/auth/login` | PIN login | none (rate-limited) | `{user_id,pin,device_name}` → `{access_token,expires_in,user}` | `auth.py:110` |
| POST | `/auth/verify` | Verify bearer token | Bearer | header only → `{valid,user,session_id}` | `auth.py:137` |
| POST | `/auth/verify-token` | Verify explicit token (query or body) | none | `?token=` or `{token}` → `{valid,user?,session_id?}` | `auth.py:159` |
| POST | `/auth/logout` | Revoke session of bearer token | Bearer | → `{message}` | `auth.py:193` |
| POST | `/auth/logout-token` | Revoke by explicit token (query param) | none | `?token=` → `{message}` | `auth.py:214` |
| POST | `/auth/reauth` | Re-verify PIN for sensitive actions | Bearer | `{pin}` → `{verified,message}` | `auth.py:229` |
| GET | `/auth/me` | Current user + flat permissions | Bearer | → `{id,full_name,is_active,roles[],permissions[]}` | `auth.py:251` |

### 5.3 Users (`/users`)

| Method | Path | Purpose | Permission | File:line |
|---|---|---|---|---|
| GET | `/users` | List users | `user_manage` | `users.py:43` |
| POST | `/users` | Create user | `user_manage` | `users.py:70` |
| GET | `/users/roles` | List roles | `user_manage` | `users.py:85` |
| GET | `/users/{id}` | Get user | `user_manage` | `users.py:105` |
| PUT | `/users/{id}` | Update user (name/active/roles) | `user_manage` | `users.py:118` |
| DELETE | `/users/{id}` | Delete user | `user_manage` | `users.py:135` |
| POST | `/users/{id}/pin` | Change PIN | `user_manage` | `users.py:146` |

### 5.4 Products (`/products`) and transfers

| Method | Path | Purpose | File:line |
|---|---|---|---|
| GET | `/products/barcode-lookup` | Resolve barcode → product/variant/selling unit | `products.py:137` |
| GET | `/products` | Paginated list (`page`, `page_size` ≤ 100) | `products.py:161` |
| GET | `/products/search` | Search by name/barcode/SKU | `products.py:220` |
| GET | `/products/low-stock` | Below threshold | `products.py:255` |
| GET | `/products/{id}` | Detail | `products.py:288` |
| POST | `/products` | Create | `products.py:304` |
| PUT | `/products/{id}` | Update | `products.py:321` |
| DELETE | `/products/{id}` | Archive / permanent-delete rules | `products.py:338` |
| GET/POST | `/products/{id}/variants` | List / create variant | `products.py:363,385` |
| PUT/DELETE | `/products/{id}/variants/{variant_id}` | Update / delete variant | `products.py:403,430` |
| GET/POST | `/products/{id}/selling-units` | List / create | `products.py:476,495` |
| PUT/DELETE | `/products/{id}/selling-units/{unit_id}` | Update / delete | `products.py:512,537` |
| GET/POST | `/products/{id}/purchase-units` | List / create | `products.py:600,617` |
| PUT/DELETE | `/products/{id}/purchase-units/{unit_id}` | Update / delete | `products.py:634,651` |
| GET | `/products/{id}/packaging-state` | Full packages + loose base | `products.py:686` |
| POST | `/products/{id}/packaging-state/receive` | Receive packages | `products.py:701` |
| POST | `/products/{id}/packaging-state/sell` | Break/sell loose | `products.py:726` |
| POST | `/products/{id}/packaging-state/sell-packages` | Sell N whole packages | `products.py:746` |
| GET | `/products/import/template` | Import template | `product_transfer.py:44` |
| POST | `/products/export` | CSV/XLSX export | `product_transfer.py:69` |
| POST | `/products/import` | Bulk import | `product_transfer.py:93` |

Permissions for products: `product_view`, `product_create`, `product_update`, `product_archive`, `export_data`/`import` (exact mapping per endpoint *n/v*).

### 5.5 Promotions (`/promotions`)

| Method | Path | Purpose | File:line |
|---|---|---|---|
| POST | `/promotions` | Create (multi-product, transactional) | `promotions.py:41` |
| GET | `/promotions` | List | `promotions.py:63` |
| GET | `/promotions/{id}` | Detail | `promotions.py:83` |
| PUT | `/promotions/{id}` | Update | `promotions.py:97` |
| POST | `/promotions/{id}/toggle` | Activate/deactivate | `promotions.py:114` |

### 5.6 Packs (`/packs`)

| Method | Path | File:line |
|---|---|---|
| GET | `/packs` | `packs.py:54` |
| POST | `/packs` | `packs.py:89` |
| GET | `/packs/{id}` | `packs.py:115` |
| PUT | `/packs/{id}` | `packs.py:130` |
| DELETE | `/packs/{id}` | `packs.py:152` |
| GET | `/packs/{id}/availability` | `packs.py:173` |

### 5.7 Categories (`/categories`)

`GET /` (`categories.py:56`), `GET /{id}` (100), `POST /` (116), `PUT /{id}` (133), `DELETE /{id}` (150).

### 5.8 Customers (`/customers`)

| Method | Path | Purpose | File:line |
|---|---|---|---|
| GET | `/customers/search?q=` | Quick search | `customers.py:158` |
| GET | `/customers` | Paginated list | `customers.py:188` |
| POST | `/customers` | Create | `customers.py:222` |
| GET | `/customers/{id}` | Detail | `customers.py:239` |
| PUT | `/customers/{id}` | Update | `customers.py:254` |
| DELETE | `/customers/{id}` | Archive | `customers.py:275` |
| GET | `/customers/{id}/debts` | Ledger | `customers.py:294` |
| POST | `/customers/{id}/pay` | Record payment (idempotent) | `customers.py:324` |
| GET | `/customers/{id}/loyalty` | Loyalty summary | `customers.py:347` |
| GET | `/customers/{id}/loyalty/history` | Ledger history | `customers.py:390` |
| POST | `/customers/{id}/loyalty/adjustment` | Manual adjustment | `customers.py:418` |

### 5.9 Loyalty (`/loyalty`)

`GET /settings` (141), `PUT /settings` (155), `POST /preview` (179), `GET /lookup?…` (290) — `loyalty.py`.

### 5.10 Suppliers (`/suppliers`) & debts

`GET /` (112), `POST /` (142), `GET /{id}` (158), `PUT /{id}` (173), `DELETE /{id}` (195), `GET /{id}/ledger` (213), `POST /{id}/payments` (247) — `suppliers.py`.
`GET /debts/summary` — `debts.py:30`.

### 5.11 Facturation (`/factures`) & invoice clients

| Method | Path | Purpose | File:line |
|---|---|---|---|
| POST | `/factures` | Create document | `factures.py:142` |
| POST | `/factures/preview` | Compute totals without saving | `factures.py:172` |
| GET | `/factures` | List (filters) | `factures.py:195` |
| GET | `/factures/{id}` | Detail | `factures.py:241` |
| PUT | `/factures/{id}` | Update | `factures.py:257` |
| POST | `/factures/{id}/post` | Post FAC as a POS sale | `factures.py:290` |
| POST | `/factures/{id}/pdf` | Render A4 PDF | `factures.py:323` |
| GET | `/invoice-clients` | List | `invoice_clients.py:77` |
| POST | `/invoice-clients` | Create | `invoice_clients.py:110` |
| GET | `/invoice-clients/{id}` | Detail | `invoice_clients.py:138` |
| PUT | `/invoice-clients/{id}` | Update | `invoice_clients.py:153` |
| DELETE | `/invoice-clients/{id}` | Archive (blocked if documents exist) | `invoice_clients.py:170` |

### 5.12 Licensing (`/license`)

`POST /license/activation-request` (260) — build the request payload for the owner; `POST /license/activate` (283) — install a signed code (rate-limited: `LICENSE_ACTIVATION_RATE_LIMIT_PER_MINUTE = 10`); `GET /license/status` (302). `app/api/v1/license.py`. No JWT required (pre-login surface).

### 5.13 Expenses (`/expenses`)

`POST /` (46), `GET /` (69), `GET /summary` (100), `POST /{id}/cancel` (131).

### 5.14 Inventory (`/inventory`)

`GET /` (50), `GET /movements` (93), `GET /movements/{product_id}` (131), `POST /adjust` (154), `GET /{product_id}` (176).

### 5.15 Sales & POS

| Method | Path | Purpose | Permission | File:line |
|---|---|---|---|---|
| POST | `/sales` | Atomic checkout (idempotent) | `pos_sale` (+ discount/credit checks) | `pos.py:75` |
| GET | `/sales` | Minimal history (page/page_size) | `pos_sale` | `pos.py:103` |
| GET | `/sales/by-invoice/{invoice_number}` | Reprint lookup | `pos_sale` | `pos.py:120` |
| GET | `/sales/{sale_id}` | Detail | `pos_sale` | `pos.py:134` |
| POST | `/sales/{sale_id}/void` | Void (one-way) | `pos_void` | `pos.py:148` |
| POST | `/pos/cart/validate` | Stateless revalidation | `pos_sale` | `pos.py:177` |
| POST | `/pos/holds` | Create hold | `pos_sale` | `pos.py:192` |
| GET | `/pos/holds` | List holds | `pos_sale` | `pos.py:208` |
| GET | `/pos/holds/{id}` | Hold detail | `pos_sale` | `pos.py:222` |
| POST | `/pos/holds/{id}/restore` | Restore + revalidate | `pos_sale` | `pos.py:236` |
| DELETE | `/pos/holds/{id}` | Delete hold (204) | `pos_sale` | `pos.py:251` |
| GET | `/pos/favorites` | List favourites | `pos_sale` | `pos.py:267` |
| POST | `/pos/favorites/{product_id}` | Pin | `pos_sale` | `pos.py:280` |
| DELETE | `/pos/favorites/{product_id}` | Unpin | `pos_sale` | `pos.py:294` |

### 5.16 Purchases (`/purchases`)

`GET /` (48), `GET /{id}` (73), `POST /` (91), `PUT /{id}` (114), `POST /{id}/receive` (132), `POST /{id}/cancel` (151), `DELETE /{id}` (167).

### 5.17 Returns (`/returns`)

`POST /` (43), `GET /` (69), `GET /{id}` (98). Return void is exposed through `app/services/void.py` invoked from the returns router (*n/v* exact route).

### 5.18 Reports (`/reports`)

`GET /financial` (49), `/sales` (66), `/products` (97), `/categories` (124), `/daily` (141), `/hourly` (158), `/peak-hours` (175), `/slow-moving` (191), `/voided` (211), `/suppliers` (236), `/loyalty` (252).

### 5.19 Exports / Print

| Method | Path | Purpose | File:line |
|---|---|---|---|
| POST | `/exports` | XLSX export of a report/dataset | `exports.py:37` |
| POST | `/print` | Render sale/return/purchase PDF (`document_type`, `document_id`, `paper`, `locale`) | `print.py:60` |
| POST | `/print/labels` | Render label sheet PDF (`items[]`, `layout`) | `print.py:88` |

### 5.20 Devices (`/devices`) — LAN pairing

`POST /devices/pair` (`devices.py:93`), `GET /devices/pairings/{pairing_id}` (137 — `POLL_PATH`), `GET /devices` (168), `GET /devices/pairing-code` (185 — `CODE_PATH`), `POST /devices/{id}/approve` (212), `POST /devices/{id}/deny` (230), `POST /devices/{id}/revoke` (250). Pairing paths are in the device-guard allowlist.

### 5.21 Hardware (`/hardware`)

`GET /overview` (60), `POST /overview/refresh` (79), `POST /printers/test-page` (94), `POST /scanners/test` (109), `POST /serial-ports/test` (124).

### 5.22 Audit (`/audit`)

`GET /` (100, filters: user/module/action/outcome/device/date), `GET /summary` (148), `GET /{event_id}` (185).

### 5.23 Settings / Backups / Storage / Zakat

| Method | Path | Purpose | File:line |
|---|---|---|---|
| GET | `/settings` | Store/fiscal/print settings singleton | `settings.py:63` |
| PUT | `/settings` | Update settings | `settings.py:77` |
| GET | `/backups` | List backups (from filesystem) | `backups.py:65` |
| POST | `/backups` | Create backup (pg_dump) | `backups.py:79` |
| GET | `/backups/{id}/inspect` | Manifest + integrity + schema compat | `backups.py:98` |
| GET | `/backups/{id}/download` | ZIP (dump + manifest) | `backups.py:115` |
| POST | `/backups/upload` | Stage uploaded ZIP/`.sql` | `backups.py:137` |
| POST | `/backups/{id}/restore` | Restore (`confirm: true`) | `backups.py:170` |
| GET | `/storage` | Server disk/DB/backup usage | `storage.py:30` |
| GET | `/zakat/context` | Inputs prefill | `zakat.py:56` |
| POST | `/zakat/calculate` | Compute (no save) | `zakat.py:72` |
| POST | `/zakat/pdf` | Render PDF (unsaved) | `zakat.py:88` |
| GET | `/zakat` | List calculations | `zakat.py:110` |
| POST | `/zakat` | Save calculation | `zakat.py:126` |
| GET | `/zakat/{id}` | Detail | `zakat.py:143` |
| POST | `/zakat/{id}/payment` | Record payment | `zakat.py:158` |
| GET | `/zakat/{id}/pdf` | PDF of saved calculation | `zakat.py:175` |

**Total: ~160 route handlers** across 32 router modules.

---

## 6. Database

### 6.1 Engine, location, creation

- **Type/version:** PostgreSQL (installed by the installer as **PostgreSQL 18.6**, `installer/setup.iss`). Development uses a locally installed PostgreSQL; `DATABASE_URL` in `new_app/backend/.env` is a `postgresql://` URL (user/password not reproduced).
- **Where the DB lives:**
  - Production: `<DATA_DIR>\postgres\data` = `C:\ProgramData\SupermarketPro\postgres\data` (`setup.iss` `#define PgDataDir`), listening on `127.0.0.1:5432`.
  - Development: whatever the installed PostgreSQL instance uses; the project itself stores no `.db` file (`backend/data/` contains only `server_id`; `backend/backups/` holds dumps).
- **ORM:** SQLAlchemy 2.0 declarative (`app/db/base.py` mixins: `UUIDMixin` UUID PK client-generated, `TimestampMixin` created/updated, `VersionMixin`, `ArchiveMixin` soft archive, `numeric_money`/`numeric_quantity` = `NUMERIC(18,3)`).
- **Creation on first run:**
  - **Installer path:** `installer_provision.py` → `app/core/postgres_provisioning.py::provision_database()` — creates the database if absent, creates the `app_user` role with a generated password in `<DATA_DIR>/config/database.env`, runs `python -m alembic upgrade head` as a subprocess, then initializes RBAC (roles/permissions only). Reusing an existing server is chosen by `plan_provisioning()`; a dedicated install is gated by 4 conditions (execute flag + `R3_ALLOW_POSTGRESQL_INSTALL=1` + SHA-256 + explicit runner).
  - **Development path:** no automatic DB creation. `alembic upgrade head` (or `python -m alembic upgrade head`) must be run manually; then `python -m app.core.seed` for RBAC. `alembic.ini` uses `script_location = migrations`, `prepend_sys_path = .`.
  - `0001_initial` is an **empty baseline** (only `alembic_version`); all tables arrive from `0002` onward.
- **Migrations:** 37 files in `backend/migrations/versions/`, ordered `0001_initial` → `0037_zakat_basis_wholesale` (`e5b7d2c9a41f`). Migration 0023 installs `pg_trgm` inside a SAVEPOINT for the trigram indexes.

### 6.2 Tables (41) with key columns

All tables have `id UUID PK`, `created_at`, `updated_at` unless noted.

**Auth / RBAC**

| Table | Key columns | Notes |
|---|---|---|
| `users` | `full_name` 150, `pin_hash` 255, `is_active`, `failed_login_attempts`, `locked_until`, `last_login_at`, `last_logout_at` | Argon2id hash |
| `roles` | `name` 50 UNIQUE, `description` | admin/manager/cashier seeded |
| `permissions` | `scope` 50 UNIQUE, `description` | 30 scopes from `PermissionScope` |
| `user_roles` | `user_id→users`, `role_id→roles`, UNIQUE(user,role) | CASCADE |
| `role_permissions` | `role_id`, `permission_id`, UNIQUE(role,perm) | CASCADE |
| `auth_sessions` | `user_id`, `token_hash` 64 UNIQUE, `device_name`, `expires_at`, `revoked_at`, `last_seen_at` | JWT revocation |

**Catalog**

| Table | Key columns |
|---|---|
| `categories` | `name` 100 UNIQUE, `parent_id→categories` (SET NULL), `sort_order`, `archived_at` |
| `products` | `name` 200 idx, `barcode` 50 UNIQUE, `sku`, `description`, `unit`, `price`, `cost`, `avg_cost` (PMP), `quantity`, `low_stock_threshold` (5), `wholesale_price` NULL, `wholesale_min_qty` NULL, `vat_rate` smallint (0/9/19), `allow_negative_stock`, `expiry_date`, `image_path` 500, `category_id` SET NULL; GIN trigram indexes on `name`, `barcode` |
| `product_variants` | `product_id` CASCADE, `name`, `barcode` UNIQUE, `sku`, `price` NULL, `cost` NULL, `quantity`, UNIQUE(product,name) |
| `product_selling_units` | `product_id`, `name`, `unit_type`, `multiplier`, `barcode` UNIQUE, `selling_price` NULL (inherit), `is_base_unit`, UNIQUE(product,name) |
| `product_purchase_units` | `product_id`, `name`, `unit_type`, `multiplier`, `barcode`, `is_default` |
| `product_stock_packages` | `product_id`, `purchase_unit_id`, `full_packages`, UNIQUE(product,unit) |
| `packs` | `name`, `barcode` UNIQUE, `price`, `is_active`, `image_path` |
| `pack_items` | `pack_id` CASCADE, `product_id` RESTRICT, `variant_id`, `quantity` (base units), `selling_unit_id/name/multiplier` snapshots |

**Parties / ledgers**

| Table | Key columns |
|---|---|
| `customers` | `name` idx, `phone` idx, `address`, `balance`, `debt_ceiling` |
| `suppliers` | `name` idx, `phone`, `address`, `email`, `contact_person`, `notes`, `balance` |
| `debt_ledger_entries` | `customer_id` RESTRICT, `entry_type` (sale/payment/adjustment), `amount`, `reference_sale_id` SET NULL, `client_request_id` UNIQUE, `user_id`, `entry_date` idx |
| `supplier_ledger_entries` | `supplier_id` RESTRICT, `entry_type` (purchase/payment/purchase_cancel), `amount`, `reference_purchase_id`, `client_request_id` UNIQUE, index(supplier, entry_date) |

**Sales**

| Table | Key columns |
|---|---|
| `sales` | `invoice_number` 50 UNIQUE, `customer_id` SET NULL, `user_id` SET NULL, `status` (completed/void), `subtotal`, `discount`, `total`, `paid`, `change`, `payment_method` (cash/card/credit/partial), `client_request_id` UNIQUE, `note`, `device_id`, `sale_date` idx, `voided_at/by/reason`, loyalty summary (`loyalty_points_earned`, `cashback_earned`, `points_redeemed`, `redeemed_value`, `amount_due` — all nullable + CHECK ≥ 0), `version` |
| `sale_lines` | `sale_id` RESTRICT, `product_id`/`variant_id`/`pack_id` (nullable), snapshots (`product_name`, `sku`, `barcode`, `unit`, `variant_name`, `selling_unit_name/multiplier`), `unit_price`, `unit_cost`, `quantity`, `line_discount`, `line_total` |
| `sale_payments` | `sale_id`, `method`, `amount`, `reference`, `payment_date` |

**Purchases / returns / expenses**

| Table | Key columns |
|---|---|
| `purchases` | `invoice_number` UNIQUE, `status` (draft/received/cancelled), `client_request_id` UNIQUE, `received_at`, `cancelled_at`, `supplier_id` NULL, `user_id`, `subtotal`, `discount`, `total`, `paid`, `purchase_date` idx |
| `purchase_lines` | snapshots + `unit_cost`, `quantity`, `line_total`, `purchase_unit_id/name/multiplier`, `base_qty_equivalent` |
| `returns` | `return_number` UNIQUE, `sale_id` NULL, `customer_id`, `user_id`, `reason` NULL, `total`, `subtotal`, `discount`, `client_request_id` UNIQUE, `return_date` idx |
| `return_lines` | `return_id`, `product_id`/`pack_id`/`variant_id`/`sale_line_id`, snapshots, `unit_cost`, `quantity`, `quantity_base`, `line_discount`, `line_total` |
| `expenses` | `title` NULL, `category` idx, `amount`, `note`, `user_id`, `device_id`, `expense_date` idx, `status` (posted/cancelled), `paid_from_drawer`, `client_request_id` (partial UNIQUE where NOT NULL), `cancelled_at/by/reason` |

**Facturation**

| Table | Key columns |
|---|---|
| `invoice_clients` | `name` idx, `address`, `wilaya`, `phone`, `nif`, `rc`, `ai`, `nis`, `archived_at` |
| `invoice_documents` | `doc_type` CHECK IN (FAC,DEV,PRO,BC,BL), `number`, `year`, UNIQUE(doc_type,year,number), `document_date` idx, `client_id` RESTRICT, `payment_method` CHECK (cash/transfer/cheque), 5 `show_*` booleans, `sale_id` UNIQUE SET NULL, `posted_at`, `version` |
| `invoice_document_lines` | `document_id` CASCADE, `product_id` SET NULL, `variant_id`/`selling_unit_id`/`pack_id` SET NULL, `description`, `quantity` >0, `unit_price_ht` ≥0, `tva_rate`, `discount_pct` 0..100, `position` |
| `invoice_document_counters` | `doc_type`, `year`, `last_number`, UNIQUE(doc_type,year) |

**Inventory / POS helpers / devices**

| Table | Key columns |
|---|---|
| `inventory_movements` | `product_id` RESTRICT, `variant_id`, `movement_type` (sale, sale_void, purchase, purchase_delete, return, adjustment, pack_component, package_break, package_receive), `quantity_change/before/after`, `document_quantity/unit`, `purchase_unit_id`, `packages_change`, `unit_cost`, `avg_cost_after`, `reason`, `source_document_type/id`, `user_id`, `device_id`, `movement_date` idx |
| `pos_holds` | `user_id`, `device_id` idx, `customer_id`, `cart_snapshot` JSON, `invoice_discount`, `note` |
| `product_favorites` | `product_id` CASCADE, `user_id`, UNIQUE(product,user) |
| `devices` | `device_id` UNIQUE, `pairing_id` UUID UNIQUE, `display_name`, `status` (pending/approved/rejected/revoked), `client_version`, `token_hash` 64, `requested_ip`, `last_ip`, `approved_at/by`, `rejected_at`, `revoked_at`, `last_seen_at` |
| `audit_logs` | `user_id`, `action` 30 idx, `entity_type/id`, `details`, `before_state`, `after_state`, `ip_address`, `device_id`, `action_at`, `outcome`, `module`, `actor_name`, `device_name`, `device_verified`, `session_id`, `request_id`, `reason`, `entity_ref`, `metadata_json`; 6 composite indexes |

**Settings / loyalty / zakat**

| Table | Key columns |
|---|---|
| `app_settings` | singleton `id=1`; `store_name/phone/address/invoice_footer`, fiscal `store_wilaya/email/nif/nis/rc/ai/rib`, `default_paper` CHECK (80mm,A4), `ask_before_print`, `auto_print_invoice`, `allow_debt`, `low_stock_threshold` |
| `loyalty_settings` | singleton `id=1`; `points_enabled`, `points_rate` (0.01), `cashback_enabled`, `cashback_rate`, deprecated `point_value`/`min_redemption_points`/`max_redemption_percent`, `max_reward_discount_percent` (20), `min_reward_points` (100), `earn_on_debt_settlement` |
| `loyalty_accounts` | `customer_id` UNIQUE CASCADE, `points_balance` ≥0, `cashback_balance` ≥0 |
| `loyalty_ledger_entries` | `account_id` CASCADE, `event_type` CHECK (sale_earn, debt_settlement_earn, redeem, return_clawback, void_clawback, adjustment, expiry), `points_delta`, `cashback_delta`, `balance_after_*`, `source_event_key` UNIQUE, `sale_id`, `return_id`, `created_by` |
| `zakat_calculations` | `zakat_date`, hawl fields, nisab fields, inventory basis/override, cash/receivables, liabilities, net/due, `warnings`/`missing_fields`/`result`/`inputs` JSON, `client_request_id` UNIQUE |
| `zakat_payments` | `calculation_id` CASCADE, `amount` >0, `method` CHECK (cash/transfer/cheque/other), `paid_at`, `client_request_id` UNIQUE |

### 6.3 Relations (principal FKs)

```
categories ─┬─< products ─┬─< product_variants
            │             ├─< product_selling_units ─< pack_items.selling_unit_id
            │             ├─< product_purchase_units ─< product_stock_packages
            │             └─< pack_items (as component)
packs ─< pack_items
customers ─┬─< sales ─┬─< sale_lines ─< return_lines
           │          ├─< sale_payments
           │          └─< debt_ledger_entries.reference_sale_id
           ├─< debt_ledger_entries
           └─1 loyalty_accounts ─< loyalty_ledger_entries
suppliers ─┬─< purchases ─< purchase_lines
           └─< supplier_ledger_entries
sales ─< returns ─< return_lines
invoice_clients ─< invoice_documents ─< invoice_document_lines
users ─┬─< auth_sessions, user_roles>─ roles ─< role_permissions >─ permissions
       └─ (SET NULL) from sales/purchases/returns/expenses/audit_logs/… 
```

### 6.4 Indexes & constraints (highlights)

- Sales reporting: `ix_sales_sale_date`, `ix_sales_status_sale_date`, `ix_debt_ledger_entries_entry_date`, `ix_supplier_ledger_entries_entry_date`, `ix_audit_logs_*` composites (migration 0020/0031).
- Search: `ix_products_name_trgm`, `ix_products_barcode_trgm` (GIN, `pg_trgm`, migration 0023).
- Partial unique: `ux_expenses_client_request_id`, `ux_promotions_client_request_id` (`WHERE client_request_id IS NOT NULL`).
- Uniqueness for idempotency: `sales.client_request_id`, `purchases.client_request_id`, `returns.client_request_id`, `debt_ledger_entries.client_request_id`, `supplier_ledger_entries.client_request_id`, `loyalty_ledger_entries.source_event_key`, `zakat_*.client_request_id`.
- CHECK constraints: money/quantity ≥ 0 where meaningful, `loyalty_settings.id = 1`, `app_settings.id = 1`, `invoice_documents.year > 0`, `invoice_document_lines.quantity > 0`, `discount_pct BETWEEN 0 AND 100`, `doc_type IN (…)`, `payment_method IN (…)`, `default_paper IN ('80mm','A4')`.

### 6.5 Seed / default data

- **RBAC** (`app/core/seed.py`): all 30 permission scopes; roles `admin` (all), `manager` (operational + facturation + promotions + financial reports + export), `cashier` (POS sale/credit/discount/return, product/category view, customer view+manage, all three expense scopes). Idempotent; supports `python -m app.core.seed` and `initialize_rbac()`.
- **No default user** — first admin is created through `POST /auth/setup` (`AuthService.setup_first_admin`, only when none exists).
- **`app_settings` / `loyalty_settings`** rows are created lazily by their services with the defaults listed above.
- **QA/demo data:** `backend/scripts/qa_seed_1000_products.py` (442 lines) and `qa_cleanup_1000_products.py` (314) — explicit QA tooling, not run at startup.
- **Development backups present** in `backend/backups/` (real dumps from Oct 2026) — these are development artifacts and must not ship.

---

## 7. Authentication & Security Review

### 7.1 Login flow (as implemented)

1. Client checks `GET /auth/setup/check`; if `setup_needed`, routes to `/setup` and calls `POST /auth/setup` (creates first admin, PIN + confirm, min 4 / max 6 digits).
2. Otherwise `GET /auth/login-users` lists active users (id, name, roles) for the selector.
3. `POST /auth/login` with `{user_id, pin, device_name}`:
   - per-IP rate limit `AUTH_RATE_LIMIT_PER_MINUTE = 15` (`app/core/rate_limit.py`, called at `auth.py` login),
   - per-account lockout after `LOCKOUT_THRESHOLD = 5` failures for `LOCKOUT_DURATION_MINUTES = 15`,
   - Argon2id verify (`app/core/security.py::verify_pin`),
   - creates an `auth_sessions` row with SHA-256 `token_hash`, `expires_at` = now + `JWT_ACCESS_TOKEN_EXPIRE_MINUTES = 480`,
   - returns HS256 JWT with `sub`, `sid`, `exp`, `iat`.
4. Client stores JWT in `flutter_secure_storage`, caches id/name/roles/permissions, and calls `GET /auth/me` to merge flat scopes.
5. On app start: `POST /auth/verify-token` (body `{token}`) → session validity → `GET /auth/me`; failure clears storage.
6. `POST /auth/logout` or `/auth/logout-token` sets `revoked_at`.
7. `POST /auth/reauth` re-verifies the PIN for sensitive actions (rate-limited per IP+user).
8. Every authenticated request also does a **throttled liveness write** (`last_seen_at`, at most every 60 s — `api/dependencies.py::_touch_session`).

### 7.2 Roles & permissions

- Roles are **seeded and fixed** (admin/manager/cashier). Authorization is by **scope**, not by role (`User.has_permission(scope)` walks `user_roles → role_permissions → permissions`).
- 30 scopes (`app/models/enums.py:PermissionScope`): POS (sale, credit, discount, void, return), products (view/create/update/archive), categories, inventory (view/adjust), customers/suppliers (view/manage), purchases (view/create/delete), expenses (view/create/cancel), promotions (view/create/update), reports (financial), export, backup/restore, facturation (view/manage), admin (user_manage, settings_manage, device_manage, audit_view).
- Route-level enforcement: `Depends(require_permission(...))` in each endpoint signature.
- **Note:** the *client* also gates navigation on scopes, but the code comment is explicit that this is cosmetic and the backend is the boundary (`app_router.dart`).

### 7.3 Password/PIN hashing & token handling

- PINs: **Argon2id**, `time_cost=3`, `memory_cost=65536 (64 MB)`, `parallelism=4`, `hash_len=32`, `salt_len=16` (`app/core/constants.py`, `app/core/security.py`). Salt is per-hash (argon2 internal). Never SHA-256/MD5.
- JWT: HS256 with `JWT_SECRET_KEY`; raw token **never stored server-side**, only `sha256(token)` in `auth_sessions.token_hash`; revocation checked per request.
- Device tokens: only SHA-256 hash stored (`devices.token_hash`); plaintext returned once in the approval poll.
- Backup signing: Ed25519 per-install keypair (`app/services/backup_manifest.py`), public key embedded in the manifest so another install can verify.
- Licence: Ed25519 signature verified on **every read**; state file additionally HMAC-verified and optionally DPAPI-sealed machine-scope (`app/licensing/state_store.py`).

### 7.4 Hard-coded secrets / credentials

| Location | Finding | Severity |
|---|---|---|
| `new_app/backend/.env` (present in working tree) | Real development `DATABASE_URL` with a **plaintext DB password**, plus `APP_SECRET_KEY`/`JWT_SECRET_KEY`. Values masked here: `postgresql://postgres:****@localhost:5432/...`. File is listed in `.gitignore` (`.env`, `.env.*`, `!.env.example`) — verify with `git ls-files` that it was never committed (**UNKNOWN - needs confirmation**; `.gitignore` alone does not prove history is clean). | **High (distribution hygiene)** |
| `app/core/config.py` defaults | `APP_SECRET_KEY = "change-me-in-production"`, `JWT_SECRET_KEY = "jwt-change-me-in-production"` | Mitigated: production start **refuses** placeholders (`_reject_placeholder_secrets`); `run_production.py` re-checks. |
| `app/licensing/verification_keys.json` | Public Ed25519 keys + `release_metadata.json` fingerprints — **public material only** | OK by design (`customer_package.json` forbids private keys) |
| `installer/setup.iss` | Pinned SHA-256 of vendor artifacts (PostgreSQL EDB installer, VC++ redist) | OK |
| `app/core/postgres_provisioning.py` / `installer_provision.py` | DB passwords generated at install time into `<DATA_DIR>/config/database.env` (mode 0600) and `pg_admin.env` | OK |

### 7.5 Network exposure / transport

- Development `.env` on the audited machine: `HOST=0.0.0.0`, `LAN_MODE=1`, `DISCOVERY_ENABLED=1`, `APP_ENV=development`. That means the API is reachable from the whole LAN and **the device guard is enforced**, but also:
  - **No TLS anywhere.** The service never terminates TLS (documented decision, `app/core/config.py` "does not terminate TLS (owner Q8)"), so JWTs, PINs and device tokens travel in clear text over the shop LAN.
  - CORS is configured with `allow_credentials=True`, `allow_methods=["*"]`, `allow_headers=["*"]` and default `CORS_ORIGINS = ["http://localhost:3000", "http://localhost:8080"]` (`app/main.py`). For a desktop client CORS is irrelevant; the defaults are not a hole, but the wildcard methods/headers + credentials combination would be if origins were later widened.
  - Docs endpoints (`/docs`, `/redoc`) are disabled when `APP_ENV=production` (`app/main.py`). Good.
- Production installer writes `LAN_MODE=0` and `HOST=127.0.0.1` by default (`setup.iss::BuildEnvContent`), and only adds firewall rules when the operator sets `LAN_MODE=1` (`ProductionFirewall`).

### 7.6 Input validation / injection

- All request bodies are Pydantic v2 models with constrained types; pagination is bounded (`page_size le=100`), strings have max lengths, enums are `Literal`/`Enum`.
- ORM queries use bound parameters; no f-string SQL was found in application code. The only dynamic SQL strings are static script bodies for PowerShell CIM queries, where values are single-quote-escaped (`app/services/hardware.py::_cim_quote`) and the process is launched **without** `shell=True`.
- File paths from users: backup uploads are validated (SHA-256, manifest structure, schema revision **before** destructive work), filenames sanitized (`app/core/filenames.py`, `Content-Disposition`).
- The storage feature accepts **no path parameters at all** — it measures only three fixed local locations (`local_storage_measure.dart` header comment).
- Data-dir safety: every writable path is absolute and refused inside the install tree in production (`docs/R1_DATA_PATHS.md`, `tests/unit/test_data_paths.py`).

### 7.7 Specific security observations

| # | Issue | Severity | Detail / file |
|---|---|---|---|
| S1 | JWT passed as a **query parameter** in `POST /auth/logout-token` | Medium | `app/api/v1/auth.py:214` (`token: str` query). Query strings land in uvicorn access logs (`access_log=True` in `run_production.py::build_uvicorn_kwargs`) and in proxies. The client uses this endpoint on logout (`auth_provider.dart`). Fix: accept `Authorization` bearer (already exists as `/auth/logout`) or a JSON body. |
| S2 | `GET /auth/login-users` enumerates all active users pre-auth | Low | By design (`auth.py:85` docstring) — needed for the PIN selector. Names/roles only, no hashes. Consider making it optional for single-user shops. |
| S3 | No TLS on the LAN API | Medium (accepted risk) | Device tokens + JWTs in cleartext on Wi-Fi LANs. Documented as a non-goal; worth revisiting for shops with Wi-Fi tills. |
| S4 | In-process rate limiting and in-process device/licence caches | Low-Medium | Hard single-worker invariant (`run_production.py` comment). Running `--workers >1` would silently weaken limits; the launcher prevents it, but the constraint is not enforced by the app itself. |
| S5 | Real `.env` with password inside the repository working tree | High (hygiene) | See §7.4. Must not be included in any distribution or zip (`new_app_upload.zip` is 93 MB — **UNKNOWN - needs confirmation** whether it contains `.env`/`.venv`). |
| S6 | Development DB dumps in `new_app/backend/backups/` | Medium (hygiene) | Real `.sql` dumps (1.5 MB, Oct 2026) carrying customer/business data. `customer_package.json` marks `data/` as must-exclude but does not mention `backups/`; `stage_payload.ps1` copies only the first-party backend tree, so verify the exclusion list. |
| S7 | `PrintService.printText` shells out to PowerShell with a temp file | Low | `print_service.dart` escapes single quotes in the path and uses `-NonInteractive`; acceptable, but a native path would be safer. |
| S8 | Audit rows can contain `before_state`/`after_state` JSON | Low | `AuditService` redacts before serializing (documented in `app/models/audit.py`); verify every new writer goes through it. |
| S9 | Session heartbeat writes on GET requests | Low | Throttled to 60 s and failures are swallowed (`_touch_session`), so no read can 500 from it. |
| S10 | `APP_ENV=development` accepts placeholder secrets with only a warning | Low | Correct for dev; production refuses. |

**Positive findings worth recording:** placeholder-secret refusal at boot; per-request session revocation check with token fingerprint; per-account lockout + per-IP rate limits; Argon2id with strong parameters; no raw token persistence; device tokens single-use/hashed; licence verification fail-closed ("never treat cannot-tell as licensed"); audit trail designed to survive user deletion (actor name snapshot, SET NULL FKs); backup restore requires explicit confirmation and takes a safety backup first.

---

## 8. How the App Runs Today (CRITICAL)

### 8.1 Documented / actual developer workflow

From `command.txt` (repository root) and `docs/PHASE_1_SETUP.md`:

```
# Terminal 1 — backend
cd C:\Users\MSI\Desktop\supermarket_logiciel\new_app\backend
.venv\Scripts\activate
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
# (also recorded: --host 127.0.0.1 --port 8000, and `python -m uvicorn app.main:app --host 127.0.0.1 --port 8000`)

# Terminal 2 — desktop client
cd C:\Users\MSI\Desktop\supermarket_logiciel\new_app
flutter run -d windows
```

Setup (once):

```
cd new_app/backend
python -m venv .venv
.venv\Scripts\activate
pip install -e ".[dev]"          # or: pip install -r requirements.lock.txt
alembic upgrade head             # schema (NOT automatic in development)
python -m app.core.seed          # roles/permissions (NOT automatic)
python -m pytest tests/ -v

cd new_app
flutter pub get
flutter test test/unit/ test/widget/
dart analyze lib/
```

Production-ish single-machine start (documented, R2):

```
set DATA_DIR=C:\ProgramData\SupermarketPro
<backend>\.venv\Scripts\python.exe <backend>\run_production.py
# or: run_production.py --check   → prints resolved JSON config and exits
```

### 8.2 Required environment variables

`new_app/backend/.env` (development) — keys present at audit time (values not reproduced):

| Key | Value seen | Notes |
|---|---|---|
| `APP_ENV` | `development` | `development` / `testing` / `production` |
| `APP_SECRET_KEY` | set | placeholder validator warns in dev, refuses in prod |
| `DATABASE_URL` | `postgresql://…` | **required**; app will not start without it |
| `JWT_SECRET_KEY` | set | HS256 signing |
| `LOG_LEVEL` | `INFO` | structlog |
| `HOST` | `0.0.0.0` | binds all interfaces on this machine |
| `PORT` | `8000` | HTTP port |
| `STORE_NAME` | `Supermarket Pro` | receipt header |
| `LAN_MODE` | `1` | device guard ON |
| `DISCOVERY_ENABLED` | `1` | UDP responder ON |
| `DISCOVERY_PORT` | `8000` | same as HTTP |
| `SERVER_ID` / `SERVER_ID_FILE` | empty / `data/server_id` | identity persisted on first start |

Optional/derived: `DATA_DIR`, `LOG_DIR`, `LOG_FILE_*`, `PG_INSTALL_DIR/PG_BIN_DIR/PG_DATA_DIR/PG_SERVICE_NAME/PG_PORT`, `PG_DUMP_PATH`, `PSQL_PATH`, `BACKUP_DIR`, `LICENSE_ENFORCEMENT`, `LICENSE_STATE_DIR`, `TRIAL_DAYS`, `LICENSE_VERIFICATION_KEYS_FILE`, `SERVICE_LIFETIME_MINUTES`-family (`SESSION_LIFETIME_MINUTES`, `LOCKOUT_*`), `*_RATE_LIMIT_PER_MINUTE`, `CORS_ORIGINS`, `POWERSHELL_PATH`.

Production adds: `<DATA_DIR>\config\.env` (installer-written), `<DATA_DIR>\config\secrets.env` (generated once), `<DATA_DIR>\config\database.env` (generated once), `<DATA_DIR>\config\pg_admin.env` (generated once), and process env `DATA_DIR` (+`APP_ENV=production` forced by the launcher).

### 8.3 Machine prerequisites (as of this audit)

| Component | Required | Verified on this machine |
|---|---|---|
| Windows | 10/11 x64 | yes |
| Flutter SDK | 3.44.8+ (Dart 3.12.2) | **Flutter 3.44.8 stable / Dart 3.12.2** |
| Visual Studio C++ desktop workload (for `flutter build windows`) | required by Flutter tooling | not verified |
| Python | 3.10.x | **3.10.11** (system + `.venv`) |
| PostgreSQL | server reachable via `DATABASE_URL` | PostgreSQL URL configured; server version **UNKNOWN - needs confirmation** |
| `pg_dump` / `psql` | for backup/restore | **not on PATH** in this environment (the code comments say so and search standard install dirs + `PG_DUMP_PATH`) |
| PowerShell | `powershell.exe` | Windows default |
| Inno Setup 7 (`ISCC.exe`) | only for building the installer | expected at `D:\R5Isolation\tools\innosetup-7\ISCC.exe` (`build_installer.ps1`) — **UNKNOWN - needs confirmation** that it's present |

### 8.4 Startup order

1. PostgreSQL must be running (the backend never starts or installs it in development).
2. Backend (uvicorn) on port 8000.
3. Flutter client. If the client is unpaired it shows the first-run network wizard; on the server PC the operator chooses "server" mode, and `initialBaseUrl()` resolves `http://localhost:8000` (or the published `supermarket_endpoint.json`).
4. First admin creation (`/setup`), then login.

### 8.5 Machine-dependent assumptions that break elsewhere

| Assumption | Where | Impact outside the dev machine |
|---|---|---|
| Absolute project path `C:\Users\MSI\Desktop\supermarket_logiciel\new_app` | `command.txt`, `docs/PHASE_1_SETUP.md`, WinSW XML (`C:\Program Files\Supermarket Pro\…`), `installer/setup.iss` | Developer-only docs; the WinSW/`.iss` paths are production targets and correct there, but they assume install dir `C:\Program Files\Supermarket Pro` and data root `C:\ProgramData\SupermarketPro`. |
| `localStorage` measurement uses `Directory.current` as the exports folder | `lib/features/storage/local_storage_measure.dart:72` | Depends on how the app is launched (shortcut working directory). Measured number changes with CWD; cosmetic only. |
| `http://localhost:8000` default base URL | `lib/core/constants.dart:17` | Correct for the server PC; a client PC must pair or be given the server address. |
| `.env` defaults `HOST=0.0.0.0` + `LAN_MODE=1` | `new_app/backend/.env` | On a laptop joined to an untrusted network this exposes the API. |
| `pg_dump` not on PATH | `app/core/config.py` comments, `app/services/backup.py` | Backups fail with an actionable error unless `PG_DUMP_PATH`/standard install dirs resolve. |
| Inno staging root `D:\R5Isolation` | `installer/build_installer.ps1` (mandatory `-IsolationRoot`), `docs/R5_INSTALLER_DESIGN.md` | Any other machine needs the isolation root prepared with the pinned vendor artifacts. |
| `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` fallback | `app/services/hardware.py` | Fine on Windows; non-Windows returns honest empty lists. |
| Flutter `windows/` runner binary name `supermarket_pos.exe` | `windows/CMakeLists.txt`, `setup.iss` icons/uninstall | Consistent — verified. |
| Client-side local cache dir `%APPDATA%\com.supermarket\supermarket_pos` | `local_storage_measure.dart:40-50`, mirrored from `Runner.rc` | Depends on CompanyName/ProductName staying in sync with `Runner.rc`. |

---

**Continue with §9 (Windows Packaging Readiness), §10 (Code Quality & Issues), §11 (Missing Features), §12 (Final Checklist) and §13 (Files Read Log) in `PROJECT_REPORT_PART_2.md`.**
