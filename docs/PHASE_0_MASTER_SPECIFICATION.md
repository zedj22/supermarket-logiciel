# Phase 0 — Master Specification

## Scope and evidence

This is a static forensic specification of `reference/python_app`. The reference was read only; no source, configuration, or database files were changed. The application is a CustomTkinter desktop POS backed by MySQL/MariaDB through PyMySQL and a SQLite-to-MySQL compatibility wrapper. The existing Flask server is a small, separate legacy API, not the desktop application's main runtime.

**Verified startup:** `main.py` adds its directory to `sys.path`, constructs `LicenseManager`, skips its license check because the enforcement block is commented out, then creates `gui.main_window.MainWindow` and enters Tk's `mainloop`. `MainWindow` loads settings/translations/theme, constructs database/managers, initializes or repairs selected schemas, negotiates network/setup state, builds navigation, and opens its default dashboard. Database initialization is conditional on `network_mode`; connection failure is printed and the UI may continue in a degraded state.

## Final static inventory

| Item | Result |
|---|---:|
| Python files inspected | 22 |
| Python LOC | approximately 22,900 |
| Largest file | `gui/main_window.py`, 15,589 LOC |
| Core database file | `database/db_manager.py`, approximately 2,200 LOC |
| Classes / functions & methods | approximately 25 / 450+ |
| Persisted tables identified | 22: 16 core, plus debt, audit, categories, users, packs, pack_items |
| Legacy candidates | `modules/sales_v21.py`, `gui/sale_window.py`, `gui/add_product_window.py`, `server/server.py` |
| Silent/suppressed exception sites | numerous; GUI contains well over 100 explicit `except Exception: pass` sites (full audit is sampled/risk-ranked) |

## Behavioral summary

The product supports a dashboard; product/category/image management; variants; packs; POS with barcode/name lookup, favourites, held carts, weighted units, customer selection, item/invoice discounts and cash/card/partial/credit payments; customer debt ledger and payments; supplier and purchase workflow; stock adjustments and movement history; returns and invoice voids; expenses; dashboards/reports; CSV/XLSX/PDF exports; A4/80 mm invoice PDFs/printing; Arabic/French/English UI; themes; LAN discovery/pairing; database backup; license/device records; and basic PIN users/roles.

The behavioral reference must be preserved where proven, but implementation defects are not requirements. Each target behavior below is therefore marked as retain, correct, or deliberately replace in the feature matrix.

## Source-of-truth traceability pattern

Every Phase 1+ work item must record: **old source/method → observed behavior → approved business rule → service command/query → API contract → Flutter feature → automated acceptance test**. Examples are documented in the POS, database, API, business-rules, and feature-matrix documents.

## Critical findings

1. `MainWindow` owns UI, SQL, business rules, authentication, translations, reports, printing, network monitoring, configuration and schema repair. It cannot be safely evolved.
2. Schema construction is split across `DatabaseManager`, feature managers, and GUI initialization; columns such as `products.category_id` and `sale_items.pack_id` are used outside the core creation path.
3. Money and quantities use `DOUBLE`, risking rounding error. PostgreSQL must use `NUMERIC`.
4. Sale, debt, discounts, cost capture/audit, and printing are not one atomic workflow. Debt ledger and `customers.balance` can diverge; voiding a partial debt sale appears to reverse paid amount rather than debt.
5. Exceptions are frequently hidden; operational failures can look like empty data or successful UI refreshes.
6. Direct shared-MySQL access, plaintext database credentials, disabled license enforcement, a hardcoded application secret, MD5 device identity, and debug Flask are security risks.

## Target product decision

Flutter Desktop is a presentation client only. A local FastAPI service owns authorization, business transactions, printing/export jobs, LAN device access, backups and audit. PostgreSQL is private to the backend. The product works without the Internet in single-PC mode; multi-PC mode uses an approved LAN server, authenticated HTTPS where feasible, and no direct client database credentials.

## Completion / unknowns

Static code confirms the paths documented here. Runtime behavior requiring hardware, an actual database, installed printers, real translations/rendering, or a populated data set remains **UNVERIFIED** and must be replay-tested against a fixture database before parity sign-off. No Flutter, FastAPI, PostgreSQL migration, or replacement application was created in this phase.
