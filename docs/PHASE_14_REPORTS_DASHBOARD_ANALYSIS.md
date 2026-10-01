# Phase 14 — Reports + Dashboard — Reverse Engineering & Decision Record

| | |
|---|---|
| **Phase** | 14 (Reports/Dashboard), per `docs/PHASE_0_ROADMAP.md` |
| **Step** | A only — analysis and decision record |
| **Document status** | DRAFT FOR APPROVAL (Step A gate) |
| **Author / date** | opencode, 2026-09-30 |
| **Baseline at writing** | commit `7e15343d99f22ec1224fd7040942d54f0ea7c5d4` (`phase-13: complete expenses`), backend 874 tests green, Flutter 1049 tests green, ruff 64 baseline, Alembic head `2f6b9c4d8a31`, working tree clean |
| **Deliverable of this step** | This file only |
| **Explicitly NOT done** | No application code, no migration, no Flutter screen, no commit |

---

## 0. Evidence base

### 0.1 Sources inspected (this step)

| Source | What was verified there |
|---|---|
| `docs/PHASE_0_ROADMAP.md` | Phase 14 feature list, Phase 15 (Printing/Exports) list, acceptance criteria, dependency graph |
| `docs/PHASE_0_BUSINESS_RULES.md` | Retained rules (1–18), rule 7 (UNVERIFIED: payment split, tax, rounding, **cash-drawer effect**, negative stock), permission matrix |
| `docs/PHASE_0_API_BLUEPRINT.md` | Intended `GET /reports/*` endpoints, `GET /reports/financial` response fields, `GET /dashboard` response fields |
| `python_app/database/db_manager.py:1117-1197` | Legacy `get_financial_report` — exact SQL, field semantics, `max(0,…)` clamp, float math |
| `python_app/modules/reports.py:33-118` | Legacy report bundle `get_full_report` (12 sections), `resolve_period` presets, `get_dashboard_stats` |
| `python_app/gui/main_window.py` | Legacy report UX: period presets (today/yesterday/7 days/month/custom), device filter, report tabs (`show_reports` :13587, profit :14457, top products :14577, slow moving :14841, device breakdown :14868, returns/voids :14889, expenses :14919, trend :14288), exports `_export_active_report_csv` :13907 / `_excel` :13999 / shift PDF :14126, `export_report_excel/csv/pdf` :12989/:13050/:13073 |
| `new_app/backend/app/services/sale.py` | Totals (`_compute_totals` :680-745), payment rules (:686-721), stored fields (:851-853), pack summary `unit_cost = 0` GATE 9 (:520), pack component cost (:607), cost snapshot (:379-381), line gross (:407), quantity semantics (:351-358, :978) |
| `new_app/backend/app/services/returns.py` | Refund computation, pro-rata invoice-discount share (:1158-1166), return line base quantity (:851-865), return cost |
| `new_app/backend/app/models/sale.py` | `subtotal`/`discount` (:41-42), `device_id`/`sale_date` (:56-57), void attribution (:64-71), line columns (:151-155), `SalePayment` (:173) |
| `new_app/backend/app/models/return_doc.py` | `returns.total` (:46), `return_date` (:57), return line columns incl. `selling_unit_multiplier`, `unit_cost`, `quantity_base` (:129-141) |
| `new_app/backend/app/models/debt.py`, `supplier_ledger.py` | Ledger entry types, `entry_date`, positive-amount + sign convention |
| `new_app/backend/app/models/catalog.py` | `avg_cost` (:77), `quantity` (:78), `low_stock_threshold` (:79), `category_id` (:85), `is_active` (:306) |
| `new_app/backend/app/models/enums.py` | `SaleStatus` (completed/void), `PaymentMethod` (cash/card/credit/partial), `REPORT_FINANCIAL`/`EXPORT_DATA` (:60-61) |
| `new_app/backend/app/repositories/expense.py:67-77` | Established date-range rule: `[date_from 00:00Z, date_to+1 00:00Z)` — inclusive calendar day in **UTC** |
| `new_app/backend/app/repositories/debt.py:98-118` | `ledger_sum_for_customer` = sale − payment − sale_void − sale_refund |
| `new_app/backend/app/repositories/party.py:92-106` | `total_outstanding` = Σ `customers.balance > 0` (AR snapshot) |
| `new_app/backend/app/repositories/inventory.py` | `total_stock_value` |
| `new_app/backend/app/domain/valuation.py` | `inventory_value` (:60-71), `quantize_money` (:91), `weighted_average_cost` (:29) |
| `new_app/backend/app/domain/unit_conversions.py` | `selling_to_base`: base = selling × multiplier |
| `new_app/backend/app/db/base.py:97-110` | `numeric_money` / `numeric_quantity` = `NUMERIC(18,3)` |
| `new_app/backend/app/api/v1/router.py:27-44` | Router mounts (no `/reports`, no `/dashboard` today) |
| `new_app/backend/app/api/v1/pos.py` | `GET /api/v1/sales` = minimal history (pos_sale), void endpoint + `X-Device-ID` |
| `new_app/backend/app/api/v1/expenses.py:101-126` | `GET /expenses/summary` already accepts `date_from/date_to/status/paid_from_drawer` |
| `new_app/backend/app/api/v1/returns.py:76-93` | `GET /returns` accepts `from`/`to`/`reason` + pagination |
| `new_app/backend/app/core/seed.py:69-70, 75-96` | `report_financial` + `export_data` granted to admin and manager; **not** cashier |
| `new_app/backend/migrations/versions/*` | Full index inventory (§16) |
| `new_app/lib/router/app_router.dart:82-143, 217-294` | Routes exist for `dashboard` and `reports`; nav rail has **no Reports destination**; Dashboard destination is **ungated**; scope constants pattern (:175-200) |
| `new_app/lib/features/dashboard/dashboard_screen.dart:12` | Placeholder `Dashboard - Phase 2` |
| `new_app/lib/features/reports/reports_screen.dart:11` | Placeholder `Reports - Phase 2` |
| `new_app/lib/features/expenses/expenses_providers.dart:28` | Client formats dates with `DateFormat('yyyy-MM-dd').format(value.toLocal())` |
| `new_app/lib/features/pos/pos_providers.dart:29-44` | Per-install device id `pos-<ms>-<rand>` persisted in SharedPreferences |
| `new_app/backend/tests/**`, `new_app/test/**` | Test conventions (§17) |

### 0.2 Evidence priority applied

1. `PHASE_0_BUSINESS_RULES.md` (retained rules + rule 7 + permission matrix)
2. Approved phase decisions / `PHASE_0_API_BLUEPRINT.md` + `PHASE_0_ROADMAP.md`
3. Current services and repositories (modern implementation)
4. PostgreSQL schema / migrations
5. Legacy behavior — **behavioral evidence only, never copied as a formula**
6. Existing tests
7. Explicit assumptions (each one flagged in §21.A)

Nothing in this document invents a second business calculation: every formula either
reuses an existing domain helper or is defined once here as the single authority for Phase 14.

---

## 1. Scope

### 1.1 In scope (Phase 14)

- One reporting data service + repository (server-side SQL aggregation), no duplicated money math.
- Report surfaces: financial/P&L, product performance, category analysis, daily timeline, hourly timeline, peak hours, slow moving, voided invoices, device breakdown, returns/expense/debt/supplier sections, dashboard KPIs.
- Dashboard screen (KPI cards, recent sales, top products) and Reports screen (tabs + date-range selector), plus the missing nav destinations.
- Report permissions wiring (`report_financial`), export permission wiring (`export_data`).
- Export **contract** (§12) and, for CSV only, the Phase 14 rendering path.
- Index migration for date-range scans (§16) — documented here, created in Step C only.
- Tests for every formula, KPI, permission, cap and localization parity.

### 1.2 Out of scope (Phase 14)

| Excluded | Why | Gate |
|---|---|---|
| Cash-drawer reconciliation / expected cash | Business Rule 7 marks cash-drawer effect **UNVERIFIED**; no payment method exists on `debt_ledger_entries` to reconstruct it | G7 |
| PDF rendering, A4/80mm print, Arabic PDF text | Roadmap Phase 15 owns printing; no renderer exists yet | G16 |
| XLSX rendering | Roadmap Phase 15 owns "Excel export" | G19 |
| Dashboard `alerts` | Requires a threshold/alert policy that Phase 0 never defined | G27 |
| Device pairing, device registry, `GET /devices` | Roadmap Phase 16 (LAN/Multi-PC/Devices) | — |
| Snapshot/materialized report tables | Current data is already snapshot-based (§4.3) | G25 |
| Any change to Phase 11/12/13 services | Phase boundary | — |

---

## 2. Legacy evidence (behavioral only)

### 2.1 Legacy financial report — `db_manager.py:1117-1197`

| Legacy field | Legacy computation | Verdict for Phase 14 |
|---|---|---|
| `gross_sales` | `SUM(total + discount) WHERE status != 'void'` | Structure kept; expressed as modern `SUM(sales.subtotal)` |
| `discounts` | `SUM(discount)` → **invoice discount only** | Rejected as the only discount figure — line discounts are invisible in it. Modern reports `line_discounts`, `invoice_discounts`, `discounts_total` |
| `net_sales` | `max(0.0, gross − discounts − returns)` | Clamp **rejected** (§5.3, D4) |
| `paid_cash` | `SUM(paid_amount)` | Modern value is net of change (`paid − change`); legacy had no change concept |
| `outstanding_debt` | `SUM(total − paid_amount)` over period invoices → **period debt created**, not AR snapshot | Semantics preserved for the blueprint field, plus a separately named AR snapshot (§5.7) |
| `cogs` | `SUM(si.quantity * COALESCE(p.cost,0))` — **live** product cost | Rejected: modern uses the immutable `sale_lines.unit_cost` snapshot |
| `items_sold` | `SUM(si.quantity)` | Kept (document units), explicitly defined |
| `net_profit` | `net_sales − cogs − expenses_total` | Kept (this is why `profit_margin_pct` uses `net_profit`) |
| date filter | `DATE(sale_date) BETWEEN start AND end` (server-local date, no index) | Replaced by indexed half-open UTC interval (§6) |
| errors | `except Exception: pass` → silent zeros | Rejected: modern endpoints return typed errors |
| money | Python `float` | Rejected: `Decimal` + `quantize_money` |

### 2.2 Legacy report bundle — `reports.py:93-118` (`get_full_report`)

`financial`, `top_products`, `slow_moving`, `device_breakdown`, `returns`, `voided`,
`debt_collected`, `expenses`, `profit_by_category`, `daily_timeline`, `hourly_revenue`
— plus `get_hourly_traffic` / `predict_crowd_level` (peak hours, `lookback_days=60`).

Presets (`resolve_period`, `reports.py:71-91`): `today`, `yesterday`, `week`/`7days`,
`month`, custom dates. Legacy UX adds a **device filter** (server mode only,
`main_window.py:13644-13649`).

Exports: `_export_active_report_csv` / `_export_active_report_excel` / shift-report PDF
re-ran their own queries for the same period (`main_window.py:13907, 13999, 14126`) —
the classic "export can disagree with the screen" defect. Phase 14's contract
(§12) forbids a second query path: **export = the exact payload the screen already holds**.

### 2.3 What Phase 14 takes from legacy, and what it refuses

Takes: surface set, tab structure, period presets, device filter concept, field labels,
the idea that one period drives every section.
Refuses: float math, live-cost COGS, `max(0,…)` clamp, invoice-only `discounts`,
silent exception swallowing, `DATE()`-based non-indexed filtering, duplicate export queries.

---

## 3. Current architecture (as-is)

### 3.1 Backend

- **No `/reports` and no `/dashboard` router exist** (`api/v1/router.py:27-44`).
- Aggregates that already exist and must be reused, not re-implemented:

| Aggregate | Location |
|---|---|
| AR snapshot `total_debt` / `customers_with_debt` | `GET /debts/summary` → `repositories/party.py:92-106` |
| Stock value `total_stock_value` | `GET /inventory` → `repositories/inventory.py` |
| Expense totals (count/total/drawer/external) with date filters | `GET /expenses/summary` → `repositories/expense.py` |
| Return list with date filters | `GET /returns?from&to` → `repositories/returns.py` |
| Ledger sum (customer) | `repositories/debt.py:98-118` |
| Ledger sum (supplier) | `repositories/purchase.py` `ledger_sum_for_supplier` |
| Low-stock products | `GET /products/low-stock`, `repositories/catalog.py:search/list_low_stock` |
| PMP / valuation / rounding | `domain/valuation.py` |
| Unit conversion | `domain/unit_conversions.py` |

- **Sales history is not a report**: `GET /api/v1/sales` is explicitly "minimal history for
  POS reprint" (`pos.py:159-166`), gated by `pos_sale`, no date filters, no totals
  (`SaleService.list_sales`, `services/sale.py` — page/page_size/user only).

### 3.2 Flutter

- `DashboardScreen` = `Center(Text('Dashboard - Phase 2'))`; `ReportsScreen` = `Center(Text('Reports - Phase 2'))`.
- Routes `/dashboard` and `/reports` exist (`app_router.dart:82-83, 141-143`) but the nav rail
  has **no Reports destination** and the Dashboard destination is **not permission-gated**
  (`app_router.dart:217-294`).
- Scope constants + `hasPermissionProvider` pattern already established (`app_router.dart:175-215`).
- HTTP = Dio (`apiClientProvider.dio`); date params already formatted locally
  (`expenses_providers.dart:28`); no chart library, no PDF/XLSX library in `pubspec.yaml`.

### 3.3 Test baseline

Backend `tests/unit/*` + `tests/integration/*` (874), Flutter `test/unit/*` + `test/widget/*` (1049),
ruff baseline 64, Alembic single head `2f6b9c4d8a31`.

---

## 4. Reporting source-of-truth map

### 4.1 Metric → authoritative source

| Metric | Authority | Filters | Existing helper to reuse |
|---|---|---|---|
| Gross sales | `sales.subtotal` | `status='completed'`, `sale_date` in range | — |
| Invoice discount | `sales.discount` | same | — |
| Line discounts | `Σ(sales.subtotal − sales.total) − sales.discount` | same | — |
| Sales after discounts | `Σ sales.total` | same | — |
| Returns refund | `returns.total` | `return_date` in range | `repositories/returns.py` |
| COGS | `Σ sale_lines.unit_cost × base_qty` | sale completed + in range | — |
| Returned cost | `Σ return_lines.unit_cost × base_qty` | `return_date` in range | — |
| Expenses | `expenses.amount`, `status='posted'` | `expense_date` in range | `repositories/expense.py:summary` |
| Debt created (period) | `Σ max(0, sales.total − sales.paid)` | completed, in range | — |
| Debt collected (period) | `debt_ledger_entries` `entry_type='payment'` | `entry_date` in range | `debt.ledger_sum_for_customer` |
| AR outstanding (snapshot) | `customers.balance > 0` | — | `party.CustomerRepository.total_outstanding` |
| Supplier payable (snapshot) | `supplier_ledger_entries` signed sum | — | `purchase.ledger_sum_for_supplier` |
| Inventory valuation (snapshot) | `Σ products.quantity × products.avg_cost` (base units) | — | `valuation.inventory_value` |
| Payment split | `sale_payments.method`, `sales.paid`, `sales.change` | completed, in range | — |
| Device | `sales.device_id` / `returns.device_id` (nullable) | — | client `pos_providers.dart:29` |
| Categories | `products.category_id` (nullable) | — | `repositories/catalog.py` |

### 4.2 Rules that make formulas exact

- **Base quantity** (money-relevant): `base_qty = quantity × COALESCE(selling_unit_multiplier, 1)`
  for `sale_lines` (no `quantity_base` column exists there); `COALESCE(return_lines.quantity_base,
  quantity × COALESCE(selling_unit_multiplier, 1))` for `return_lines`.
  Mirrors `domain/unit_conversions.selling_to_base`.
- **Charged lines**: pack component lines carry `line_total = 0` and `line_discount = 0`
  (`services/sale.py:600-612`), so `Σ(line_total + line_discount)` over **all** lines equals
  gross of charged lines without any pack special-case.
- **Pack cost**: pack summary line has `unit_cost = 0` (GATE 9, `services/sale.py:520`) while
  component lines carry `unit_cost` (`services/sale.py:607`) — therefore COGS must sum
  **all** lines (no "charged" filter), otherwise pack cost disappears.
- **Money**: `Decimal`, quantised with `valuation.quantize_money` (`NUMERIC(18,3)` storage),
  one quantisation at output, never inside intermediate sums.

### 4.3 Reproducibility

`sale_lines.unit_cost` and `return_lines.unit_cost` are immutable snapshots
("Sales / decreases NEVER change avg_cost", `valuation.py:9-15`; void never rewrites totals,
`models/sale.py:61-63`). Historical reports are therefore reproducible without snapshot tables.
Only **inventory valuation** is a live point-in-time figure by nature — labelled as such everywhere.
→ Gate G25: no snapshot tables, no materialized views.

---

## 5. Formula definitions (single authority)

Notation: `R = [date_from 00:00Z, date_to+1 00:00Z)`. All sums are `Decimal`; each output field is
quantised once with `quantize_money` unless stated. Percentages are quantised to 2 decimals.

### 5.1 Sales block (financial report)

| Field | Formula | Status filter | Date field |
|---|---|---|---|
| `gross_sales` | `Σ sales.subtotal` | `completed` | `sale_date` |
| `line_discounts` | `Σ(sales.subtotal − sales.total − sales.discount)` | `completed` | `sale_date` |
| `invoice_discounts` | `Σ sales.discount` | `completed` | `sale_date` |
| `discounts_total` | `gross_sales − Σ sales.total` (= line + invoice) | `completed` | `sale_date` |
| `sales_after_discounts` | `Σ sales.total` | `completed` | `sale_date` |
| `returns_count` | `COUNT(returns.id)` | — | `return_date` |
| `returns_total` | `Σ returns.total` | — | `return_date` |
| `net_sales` | `sales_after_discounts − returns_total` (may be negative) | mixed | mixed |
| `invoice_count` | `COUNT(sales.id)` | `completed` | `sale_date` |
| `items_sold` | `Σ sale_lines.quantity` over charged lines (document units) | `completed` | `sale_date` |

> Voided sales are excluded from every revenue/COGS line (`status='completed'`), matching the
> Phase 12 invariant that void preserves totals but must not be counted.

### 5.2 COGS block

| Field | Formula |
|---|---|
| `cogs` | `Σ sale_lines.unit_cost × base_qty` over **all** lines of completed sales in `R` |
| `returns_cost` | `Σ return_lines.unit_cost × base_qty` for returns in `R` |
| `cogs_net` | `cogs − returns_cost` |

Rationale for period-matching returns: a return is the reversal event of the period; matching it
to the original sale's period would be an as-of-time re-cut of history that no other report does.
Documented in §20 (D9).

### 5.3 Profit block

| Field | Formula |
|---|---|
| `gross_profit` | `net_sales − cogs_net` |
| `expenses_total` | `Σ expenses.amount` where `status='posted'`, `expense_date` in `R` |
| `expenses_drawer` | same, restricted to `paid_from_drawer = true` |
| `expenses_external` | `expenses_total − expenses_drawer` |
| `net_profit` | `gross_profit − expenses_total` |
| `profit_margin_pct` | `net_profit / net_sales × 100` if `net_sales > 0` else `0.00` |

Both `gross_profit` and `net_profit` are exposed because Phase 0's example numbers are
internally inconsistent (§20 D1) — exposing both makes the ambiguity impossible to hit.

### 5.4 Payment split block (period, completed sales)

| Field | Formula |
|---|---|
| `paid_cash` | `Σ(paid − change)` where `sale_payments.method = 'cash'` |
| `paid_card` | `Σ(paid − change)` where `method = 'card'` |
| `paid_partial` | `Σ paid` where `method = 'partial'` (`change = 0` by rule, `services/sale.py:698-708`) |
| `collected_total` | `paid_cash + paid_card + paid_partial` |
| `debt_created` | `Σ max(0, sales.total − sales.paid)` (credit + partial remainder) |
| `change_total` | `Σ sales.change` |
| Invariant | `collected_total + debt_created = sales_after_discounts` (asserted by test) |

Debt **collections** have no cash/card field on `debt_ledger_entries` → `debt_collected` is
reported as a single amount (period `entry_type='payment'`), never split by tender.

### 5.5 Debt block

| Field | Formula | Type |
|---|---|---|
| `outstanding_debt` | `Σ max(0, sales.total − sales.paid)` for completed sales in `R` | period (blueprint field) |
| `debt_collected` | `Σ debt_ledger_entries.amount` where `entry_type='payment'`, `entry_date` in `R` | period |
| `ar_outstanding` | `Σ customers.balance` where `balance > 0` | current snapshot |
| `customers_with_debt` | `COUNT(customers)` where `balance > 0` | current snapshot |

### 5.6 Supplier block (period + snapshot)

| Field | Formula |
|---|---|
| `supplier_payable` | signed sum of `supplier_ledger_entries` (`purchase +`, `payment −`, `purchase_cancel −`) — reuse `ledger_sum_for_supplier` |
| `purchases_total` | `Σ purchases.total` where `status='received'`, `purchase_date` in `R` |
| `supplier_paid` | `Σ supplier_ledger_entries.amount` where `entry_type='payment'`, `entry_date` in `R` |
| `suppliers_with_balance` | count of suppliers with non-zero payable |

### 5.7 Inventory block (snapshots, no date range)

`stock_value = Σ products.quantity × products.avg_cost` — reuse
`valuation.inventory_value` / `InventoryRepository.total_stock_value`.
`low_stock_count` = products with `is_active AND quantity <= low_stock_threshold`.

### 5.8 Row-level reports (products / categories)

Grouped over charged lines joined to completed sales in `R`:

| Column | Formula |
|---|---|
| `qty_sold` | `Σ sale_lines.quantity × COALESCE(selling_unit_multiplier, 1)` (base units) |
| `gross` | `Σ(line_total + line_discount)` |
| `line_discounts` | `Σ line_discount` |
| `invoice_discount_share` | `Σ sales.discount × (line_gross / NULLIF(sales.subtotal, 0))` — pro-rata, same rule as returns (`services/returns.py:1158-1166`) |
| `net_revenue` | `gross − line_discounts − invoice_discount_share` |
| `return_qty`, `return_amount` | `Σ return_lines` for the product, `return_date` in `R` |
| `cogs`, `return_cost` | as §5.2, grouped by product |
| `gross_profit` | `(net_revenue − return_amount) − (cogs − return_cost)` |
| `margin_pct` | `gross_profit / (net_revenue − return_amount) × 100` if denominator > 0 else `0.00` |

Categories report = same aggregation grouped by `products.category_id`
(`NULL → "uncategorized"`), capped at 500 rows.
**Consistency invariant (tested):** `Σ` of the totals row equals the financial report's
`net_sales` / `cogs_net` computed independently in §5.1/§5.2 (each row is quantised once,
so the totals row is computed from the unrounded aggregate, not from summed rows).

### 5.9 Per-report date fields

| Report | Date field |
|---|---|
| financial, products, categories, daily, hourly, sales/voided-by-sale | `sales.sale_date` |
| returns | `returns.return_date` |
| voided invoices (event report) | `sales.voided_at` (non-NULL whenever `status='void'`, Phase 12) |
| expenses | `expenses.expense_date` |
| debt movement | `debt_ledger_entries.entry_date` |
| supplier movement | `supplier_ledger_entries.entry_date` |
| purchases | `purchases.purchase_date` |

---

## 6. Date semantics

1. **Range shape**: `date_from`, `date_to` are `date` query params, **inclusive both ends**, expanded
   server-side to `[date_from 00:00:00Z, (date_to + 1 day) 00:00:00Z)` — byte-for-byte the rule
   already implemented for expenses (`repositories/expense.py:67-77`).
2. **Timezone**: boundaries are **UTC** (`timestamptz` storage; `tzinfo=timezone.utc` in existing code).
   *Assumption A1*: UTC is the business-day boundary. The Flutter client sends **local** calendar dates
   (`expenses_providers.dart:28`), so rows can shift by the client's UTC offset at day edges
   (±1 h for UTC+1). Flagged as non-blocking confirmation C1 (§19). Hourly/peak buckets use the same UTC rule.
3. **Timestamp choice**: business period = `sale_date` (server `now()` on creation); voids are
   reported by `voided_at`; returns by `return_date`; never `created_at`.
4. **Presets** (client-side, mirroring legacy `resolve_period`): `today`, `yesterday`,
   `last_7_days`, `this_month`, `custom`. Presets are resolved to local calendar dates then sent as `date_from`/`date_to`.
5. **Caps** (server enforced, HTTP 422 `REPORT_RANGE_TOO_WIDE`):
   - daily report: ≤ 400 days
   - hourly report: ≤ 31 days
   - peak-hours: `lookback_days` 1–90 (default 30)
   - slow-moving: `days` 1–365 (default 30)
6. **No DST handling**: UTC boundaries have no DST; documented as a consequence of A1.
7. **Empty range**: `date_to < date_from` → 422 `REPORT_INVALID_RANGE`.

---

## 7. Dashboard

Endpoint `GET /api/v1/dashboard`, one round trip, permission `report_financial`.

| KPI | Definition | Source | Rationale |
|---|---|---|---|
| `today_sales` | `Σ sales.total` completed today | sales | blueprint + legacy `get_dashboard_stats` |
| `today_invoices` | `COUNT` completed today | sales | legacy `today_sales_count` |
| `today_net_profit` | today `net_sales − cogs_net − expenses` | sales+lines+expenses | Phase 14 objective "accurate KPIs" |
| `today_expenses` | `Σ expenses.amount` posted today | expenses | Phase 13 data |
| `total_products` | `COUNT(products)` where `is_active` | products | blueprint |
| `total_customers` | `COUNT(customers)` | customers | blueprint |
| `stock_value` | `InventoryRepository.total_stock_value` | inventory | blueprint |
| `low_stock_count` | active products with `quantity <= low_stock_threshold` | products | blueprint |
| `customers_with_debt` | `balance > 0` count | `debts/summary` | blueprint |
| `total_debt` | `Σ customers.balance>0` | `debts/summary` | blueprint |
| `recent_sales[≤5]` | latest completed sales in selected period: invoice, time, total, method | sales | blueprint |
| `top_products[≤5]` | §5.8 ordered by `net_revenue DESC`, page_size 5 | report repo | blueprint |
| `alerts` | — | — | **deferred**, G27 |

Optional period selector affects `top_products`/`recent_sales` only (default = today);
snapshot KPIs ignore the range. No server-side cache (G28): a KPI that can be stale is worse
than a KPI that costs 100 ms.

---

## 8. Report surfaces

Common parameters: `date_from`, `date_to`, optional `device_id` (sales/returns/voided only),
`page`/`page_size` where rows are unbounded.

| # | Surface | Endpoint | Rows / caps | Key columns (beyond totals) |
|---|---|---|---|---|
| R1 | Financial / P&L | `GET /reports/financial` | single object | §5.1–§5.5 blocks |
| R2 | Product performance | `GET /reports/products` | paginated, `page_size ≤ 100`; `sort ∈ {net_revenue, qty_sold, gross_profit, return_qty, margin_pct}` | §5.8 columns + category |
| R3 | Category analysis | `GET /reports/categories` | ≤ 500 rows, no pagination | §5.8 aggregated by category |
| R4 | Daily timeline | `GET /reports/daily` | ≤ 400 rows | date, net_sales, cogs_net, gross_profit, expenses, net_profit, invoice_count, items_sold, returns_total |
| R5 | Hourly timeline | `GET /reports/hourly` | ≤ 31 days → ≤ 744 rows | hour (ISO), net_sales, invoice_count |
| R6 | Peak hours | `GET /reports/peak-hours?lookback_days` | exactly 24 rows | hour 0–23, net_sales, invoice_count, items_sold |
| R7 | Slow moving | `GET /reports/slow-moving?days&threshold` | paginated | product, category, qty, stock_value, last_sale_date; filter `is_active`, `quantity > threshold`, no `sale_lines` in window |
| R8 | Voided invoices | `GET /reports/voided` | paginated | invoice, `sale_date`, `voided_at`, total, payment_method, `void_reason`, voided_by user, device_id, line count |
| R9 | Sales detail (report table + export row source) | `GET /reports/sales?status=completed\|void\|all&payment_method&user_id&device_id` | paginated | invoice, date, customer, user, method, subtotal, discounts, total, paid, change, device |
| R10 | Returns section | reuse `GET /returns?from&to` + totals from R1 | existing | existing columns |
| R11 | Expenses section | reuse `GET /expenses/summary?date_from&date_to&paid_from_drawer` | existing | existing |
| R12 | Debt summary | reuse `GET /debts/summary` + `outstanding_debt`/`debt_collected` from R1 | existing | existing |
| R13 | Suppliers / payables | `GET /reports/suppliers` | small object | §5.6 |
| R14 | Inventory valuation | reuse `GET /inventory` → `total_stock_value` | existing | existing |
| R15 | Device breakdown | grouping on R1/R9 (`device_id`, `NULL → "unknown"`) | derived | device_id, invoice_count, net_sales, share_pct |

Notes:
- **Reports screens are the only place that assembles these**; no screen may compute money.
- R9 exists because `GET /api/v1/sales` is a POS reprint helper with no filters/totals (§3.1) —
  it is not extended, to keep POS and reporting permissions separate.
- R15 is a grouping, not a new endpoint (blueprint named `device_name`; we use `device_id`, §20 D5).

---

## 9. Cash register / drawer

**Gate G7 — UNVERIFIED.**

What exists today:
- `sales.paid` / `sales.change` per invoice; `sale_payments.method` (cash/card/partial/credit).
- `expenses.paid_from_drawer` boolean (Phase 13) + `GET /expenses/summary?paid_from_drawer=true`.
- Debt payments carry **no tender field** (`debt_ledger_entries` has only `entry_type`, `amount`,
  `entry_date`, `note`, `user_id`) — cash paid against debt is indistinguishable from card.
- Voids record `cash_pending` refund intent but do not move money (Phase 12).
- No drawer/session table exists.

Consequences for Phase 14:
- We report **components only**: `paid_cash`, `paid_card`, `paid_partial`, `change_total`,
  `expenses_drawer`, `debt_collected`, `cash_pending` refunds.
- We do **not** compute expected cash, drawer balance, over/short, or shift reconciliation.
  Business Rule 7 requires product-owner approval before any such formula, and the data model
  cannot support it anyway (missing tender on debt payments).
- Roadmap Phase 14 does not list drawer reconciliation → excluding it does not shrink the phase.
  If the owner wants it, it needs (a) an approved rule and (b) a tender field on debt payments.

---

## 10. Permissions

| Concern | Decision |
|---|---|
| View all `/reports/*` and `/dashboard` | `require_permission(PermissionScope.REPORT_FINANCIAL)` |
| Any future export execution | `require_permission(PermissionScope.EXPORT_DATA)` |
| New scopes | **none** — existing enum values are sufficient (`models/enums.py:60-61`) |
| Roles | admin + manager hold both scopes; cashier holds neither (`core/seed.py:69-70`) — matches the Phase 0 matrix row "Financial reports/export/backup: yes / configured / no" |
| Nav rail | add a **Reports** destination gated by `report_financial`; **Dashboard** destination becomes gated by `report_financial` too (today it is ungated) |
| Route guard | `/reports` and `/dashboard` guarded by the same scope (pattern of `app_router.dart:175-215`) |
| Screen content | no money rendered before permission resolves; 403 → localized "not authorized", not an error dump |
| Auditing | report reads are not audited (read-only, no state change); export **execution** is audited when Phase 15 lands |

Visible behaviour change: a cashier loses the Dashboard rail entry. Flagged as non-blocking confirmation C2 (§19),
because the Phase 0 matrix is explicit but the current build shows it to everyone.

---

## 11. API surface (derived, not assumed)

Conventions: FastAPI + `response_model` strict schemas (`StrictBaseModel`), `Decimal` fields,
`tags=["reports"]`, mounted in `api/v1/router.py`, `date_from`/`date_to` as `date`,
pagination `page ≥ 1`, `page_size ≤ 100` (consistent with `MAX_PAGE_SIZE`), standard error envelope.

| Method | Path | Permission | Query params |
|---|---|---|---|
| GET | `/api/v1/reports/financial` | `report_financial` | `date_from`, `date_to`, `device_id?` |
| GET | `/api/v1/reports/sales` | `report_financial` | `date_from`, `date_to`, `status`, `payment_method?`, `user_id?`, `device_id?`, `page`, `page_size` |
| GET | `/api/v1/reports/products` | `report_financial` | `date_from`, `date_to`, `device_id?`, `sort`, `page`, `page_size` |
| GET | `/api/v1/reports/categories` | `report_financial` | `date_from`, `date_to`, `device_id?` |
| GET | `/api/v1/reports/daily` | `report_financial` | `date_from`, `date_to`, `device_id?` |
| GET | `/api/v1/reports/hourly` | `report_financial` | `date_from`, `date_to`, `device_id?` |
| GET | `/api/v1/reports/peak-hours` | `report_financial` | `lookback_days` (1–90, default 30), `device_id?` |
| GET | `/api/v1/reports/slow-moving` | `report_financial` | `days` (1–365, default 30), `threshold` (default 0), `page`, `page_size` |
| GET | `/api/v1/reports/voided` | `report_financial` | `date_from`, `date_to`, `device_id?`, `page`, `page_size` |
| GET | `/api/v1/reports/suppliers` | `report_financial` | `date_from`, `date_to` |
| GET | `/api/v1/dashboard` | `report_financial` | `date_from?`, `date_to?` (default today) |

Reused unchanged: `GET /debts/summary`, `GET /expenses/summary`, `GET /returns`,
`GET /inventory`, `GET /products/low-stock`.

Errors: `403 PERMISSION_DENIED` (envelope code), `422 REPORT_INVALID_RANGE`,
`422 REPORT_RANGE_TOO_WIDE`, `422 REPORT_SORT_INVALID`. No `except Exception: pass`.

File layout (follows existing convention of one file holding related routers, like `pos.py`):
`app/repositories/report.py` → `app/services/report.py` → `app/api/v1/reports.py`
(`reports_router` prefix `/reports`, `dashboard_router` prefix `/dashboard`) → router mounts.

---

## 12. Export strategy

### 12.1 Format split (gates G13 / G19)

| Format | Phase | Path | Why |
|---|---|---|---|
| **CSV** | **14** (G13 RESOLVED) | Client-side builder from the **same JSON payload** the screen shows, saved via `file_picker` | No new dependency; headers must be localized (§14) and the backend has no i18n table; guarantees "export = what you see" (legacy re-queried, §2.2) |
| XLSX | 15 (G19 DEFERRED) | Backend `openpyxl` or Dart `excel` — decision deferred with the renderer | Roadmap Phase 15 "Excel export" |
| PDF | 15 (G16 DEFERRED) | Roadmap Phase 15 print service | No renderer exists today (verified: no `pdf`/`printing` package in `pubspec.yaml`, no reportlab in backend deps) |

Phase 14 therefore **freezes the export data contract** so Phase 15 only adds a renderer.

### 12.2 Export contract (all formats)

| Aspect | Rule |
|---|---|
| Data source | The exact report payload currently loaded (same endpoint, same filters). Row-level export pages through the same endpoint with `page_size=100`. |
| Row cap | 50 000 rows (500 pages). Exceeding → localized error `export_row_limit`, advising a narrower range. |
| Selected filters | Always echoed in the file: header comment block is **not** used (breaks CSV parsers) — filters are captured in the filename and in a leading `# meta` column set only for XLSX/PDF; CSV carries a final `total` row instead. |
| Columns | Fixed per report, in the order of §8, localized header row (keys from §14). |
| Totals | Final row labelled `total` for aggregate reports (financial, products, categories, daily, hourly, peak-hours); omitted for pure detail lists where the screen has no totals row. |
| Localization | Header labels translated client-side from the same keys used on screen; numbers/dates formatted with the active locale. |
| Arabic / RTL | CSV is a data format → **no RTL shaping**; UTF-8 content only. RTL applies to XLSX/PDF text layout (Phase 15). |
| Number formatting | Raw dot-decimal, no thousand separators, 3 decimals max (`NUMERIC(18,3)`); percentages 2 decimals + `%` omitted from CSV (kept numeric). |
| Date/time | ISO 8601 (`YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SSZ`) — locale-independent inside CSV. |
| Encoding | UTF-8 **with BOM** (Excel on Windows), CRLF line endings, RFC 4180 quoting (`"` doubling), delimiter `,`. |
| File naming | `reports_<report>_<dateFrom>_<dateTo>_<yyyy-MM-dd-HHmmss>.csv`, e.g. `reports_financial_2026-09-01_2026-09-30_2026-09-30-143012.csv` (ASCII only). |
| Error handling | 403 → localized permission message; 422 range errors → localized; empty result → file with headers + totals row (never a silent empty file); write failure → localized `export_failed` toast, no partial file left behind. |
| Permissions | Button visible only with `export_data`; request-time 403 still enforced. |
| Audit | Read-only export, not audited in Phase 14; Phase 15 adds audit when the export service becomes server-side. |

---

## 13. PDF / print boundary

- **No PDF/print renderer exists in the modern app** (verified in `pubspec.yaml` and backend deps).
- Roadmap Phase 15 ("Printing/Exports": 80 mm thermal, A4 invoice, Arabic text, PDF generation)
  owns it and depends on Phase 14.
- **Decision:** Phase 14 delivers report *data* (JSON + CSV); it defines the printable data contract
  (§12.2 columns/totals/localization) and stops. No `print`/`pdf` dependency may be added in Phase 14 (G16, G24).
- Invoice printing/reprint stays where it is today (POS reprint is a Phase 8 concern), untouched.

---

## 14. Localization

- Locales: `ar`, `fr`, `en` — existing parity test convention (`test/unit/*_localization_test.dart`).
- **No hardcoded strings** in reports/dashboard/export code; every label through `AppStrings.t(key, loc)`.
- Existing keys reused where they exist (`dashboard`, `reports`, `expenses`, `returns_history`, …).

| Key group | Examples | Est. keys |
|---|---|---|
| Report names / tabs | `report_financial`, `report_products`, `report_categories`, `report_timeline`, `report_peak_hours`, `report_slow_moving`, `report_voided`, `report_sales`, `report_suppliers`, `report_device` | 10 |
| KPI labels (financial + dashboard) | `kpi_gross_sales`, `kpi_discounts`, `kpi_net_sales`, `kpi_cogs`, `kpi_gross_profit`, `kpi_net_profit`, `kpi_margin`, `kpi_paid_cash`, `kpi_collected`, `kpi_debt_created`, `kpi_ar_outstanding`, `kpi_expenses`, `kpi_stock_value`, `kpi_low_stock`, `kpi_today_sales`, `kpi_today_profit`, `kpi_invoices`, `kpi_items_sold`, `kpi_returns_count`, `kpi_debt_collected`, `kpi_supplier_payable`, `kpi_total_products`, `kpi_total_customers`, `kpi_recent_sales` | 24 |
| Filters / presets / range | `filter_from`, `filter_to`, `filter_device`, `filter_status`, `filter_payment`, `preset_today`, `preset_yesterday`, `preset_last_7_days`, `preset_this_month`, `preset_custom`, `filter_sort`, `filter_lookback`, `filter_threshold`, `filter_all_devices` | 14 |
| Table headers | `col_invoice`, `col_date`, `col_time`, `col_customer`, `col_user`, `col_device`, `col_method`, `col_subtotal`, `col_line_discounts`, `col_invoice_discount`, `col_total`, `col_paid`, `col_change`, `col_qty`, `col_gross`, `col_net_revenue`, `col_returns_qty`, `col_returns_amount`, `col_cogs`, `col_gross_profit`, `col_margin`, `col_expenses`, `col_net_profit`, `col_category`, `col_product`, `col_sku`, `col_stock`, `col_stock_value`, `col_last_sale`, `col_voided_at`, `col_void_reason`, `col_hour`, `col_share`, `col_count` | 34 |
| Totals / states / misc | `label_total`, `label_unknown_device`, `label_uncategorized`, `state_no_data`, `state_loading`, `state_error`, `label_today`, `label_period`, `label_as_of`, `label_snapshot`, `label_documents`, `label_percent` | 12 |
| Export labels + errors | `export_csv`, `export_xlsx`, `export_pdf`, `export_row_limit`, `export_failed`, `export_permission`, `export_started`, `export_done`, `export_report_name` | 9 |
| **Total** | | **≈ 103 keys × 3 locales ≈ 309 entries** |

Final key list is frozen in Step B and must satisfy: every key present in all three locale blocks
(asserted by a parity test), counts identical across locales.

---

## 15. Performance

| Budget | Target |
|---|---|
| `GET /reports/financial` | ≤ 300 ms p95 at 200 k sales rows |
| `GET /reports/products` / `categories` | ≤ 500 ms p95 |
| `GET /reports/daily` / `hourly` / `peak-hours` | ≤ 300 ms p95 |
| `GET /dashboard` | ≤ 400 ms p95 (single request, parallel sub-queries in one service call) |
| Payload | ≤ 200 KB per report page; `page_size ≤ 100` |

Mechanisms (in order of preference):
1. **Aggregate in SQL** (one `GROUP BY` per report), never N+1 and never "load rows and sum in Python".
2. Reuse existing aggregates (§3.1) instead of re-querying.
3. Indexes from §16 (`sales.sale_date` is the single biggest lever — every report starts with that range).
4. Hard caps from §6 and §8 (400/744/500 rows, `page_size ≤ 100`).
5. **No server-side cache** (G28) — correctness over speed; re-query cost is bounded by the caps.
6. Verification in Step D: `EXPLAIN (ANALYZE, BUFFERS)` on financial/products/daily queries against a
   seeded 200 k-row dataset; record timings in the Step D report.

---

## 16. Database / index strategy

### 16.1 Index inventory (verified across `migrations/versions/*`)

| Table | Existing indexes (relevant) |
|---|---|
| `sales` | PK, `invoice_number` (uniq), `customer_id`, `user_id`, `client_request_id` (uniq) — **no `sale_date`, no `status`** |
| `sale_lines` | `sale_id`, `product_id`, `variant_id`, `pack_id` |
| `sale_payments` | `sale_id` |
| `debt_ledger_entries` | `customer_id`, `entry_type`, `reference_sale_id`, `client_request_id` (uniq) — **no `entry_date`** |
| `supplier_ledger_entries` | `supplier_id`, `entry_type`, `reference_purchase_id`, `(supplier_id, entry_date)` composite, `client_request_id` (uniq) — **no single-column `entry_date`** |
| `returns` | `return_date` ✓, `sale_id`, `customer_id`, `return_number` (uniq) |
| `expenses` | `expense_date` ✓, `category`, `user_id` |
| `purchases` | `purchase_date` ✓, `status`, `supplier_id` |
| `inventory_movements` | `movement_date` ✓, `movement_type`, `product_id`, `variant_id` |
| `products` | `barcode` (uniq), `category_id`, `sku` — **no index needed for `avg_cost`/`quantity`** (aggregated by seq scan on a catalog-sized table) |

### 16.2 Decision (gate G18)

- **One additive migration** `0020_phase14_report_indexes.py`, `down_revision = 2f6b9c4d8a31`:

| Index | Table (columns) | Justification |
|---|---|---|
| `ix_sales_sale_date` | `sales (sale_date)` | Every report's range predicate; currently a full scan |
| `ix_sales_status_sale_date` | `sales (status, sale_date)` | Void/completed split on top of the range scan |
| `ix_debt_ledger_entries_entry_date` | `debt_ledger_entries (entry_date)` | Period debt movement (no date index at all today) |
| `ix_supplier_ledger_entries_entry_date` | `supplier_ledger_entries (entry_date)` | Existing composite has `supplier_id` as leading column, unusable for period scans |

- **No new tables, no views, no materialized views, no report snapshots** (G25).
- **No column changes, no backfills.** `downgrade()` drops the four indexes (fully reversible).
- Migration verified with `alembic current/heads/check` and the existing migration integration test.

---

## 17. Test strategy

### 17.1 Backend (`tests/unit/test_reports.py`, `tests/unit/test_dashboard.py`, `tests/unit/test_report_permissions.py`)

1. **Formula fixtures**: hand-built scenario (cash sale with line + invoice discount, card sale,
   partial sale, credit sale, pack sale, selling-unit sale, voided sale, return with pro-rata discount,
   posted + cancelled + drawer expenses) → assert every field of `GET /reports/financial`.
2. **Invariants**: `collected_total + debt_created = sales_after_discounts`;
   `discounts_total = line_discounts + invoice_discounts`;
   `Σ products net_revenue = net_sales`; `drawer + external = expenses_total`;
   voided sales contribute 0 to revenue and COGS.
3. **Pack/COGS**: pack sale → summary line cost 0, component costs counted once.
4. **Selling units**: 2 boxes × multiplier 6 → COGS uses `quantity × 6`.
5. **Date semantics**: boundary tests at `date_from 00:00Z`, `date_to 23:59:59Z`,
   next-day exclusion; `date_to < date_from` → 422; range caps → 422.
6. **Snapshots**: mutate `products.avg_cost` after a sale → historical report unchanged.
7. **Permissions**: admin/manager 200, cashier 403 for every `/reports/*` and `/dashboard`.
8. **Exports (contract)**: row-cap guard, sort validation, status/payment filters.
9. **Dashboard**: KPI parity with the financial report for the same period.
10. **Regression**: existing 874 must stay green; Phase 11/12/13 tests untouched.

### 17.2 Flutter (`test/unit/reports_*_test.dart`, `test/widget/reports_*_test.dart`, `dashboard_*`)

- CSV builder: quoting/escaping, BOM, CRLF, decimal format, ISO dates, totals row, filename pattern.
- Localization parity for every new key (3 locales) + `dashboard`/`reports` nav labels.
- Providers: query serialization (presets → `date_from`/`date_to`), pagination, error mapping (403/422).
- Widgets: date-range selector, tab switch, empty/loading/error states, permission-hidden nav entries,
  export button visible only with `export_data`.
- `flutter analyze` clean, no `print`, no hardcoded user-facing strings.

### 17.3 Commands (Step E verification)

```
.venv\Scripts\python.exe -m pytest -q                      # 874 + new
.venv\Scripts\python.exe -m pytest tests/unit/test_reports.py -q
.venv\Scripts\python.exe -m ruff check .                    # 64 baseline must not grow
.venv\Scripts\alembic.exe current ; .venv\Scripts\alembic.exe heads ; .venv\Scripts\alembic.exe check
flutter analyze
flutter test
flutter build windows --debug
```

---

## 18. Explicit gates

| # | Gate | Status | Decision |
|---|---|---|---|
| 1 | Date semantics (range shape, timezone, timestamp field) | **RESOLVED** | Inclusive `[date_from 00:00Z, date_to+1 00:00Z)`, UTC, business timestamps `sale_date`/`return_date`/`voided_at`/`expense_date`/`entry_date`; caps per §6 |
| 2 | Sales / net sales formula | **RESOLVED** | §5.1: gross = `Σsubtotal`, discounts = line + invoice, net = `Σtotal − returns_total`, **unclamped** |
| 3 | Returns & voided invoices | **RESOLVED** | Returns subtract by `return_date` with their own cost; voids excluded from all revenue/COGS, reported by `voided_at`; both keep snapshots |
| 4 | COGS | **RESOLVED** | §5.2: `unit_cost × base_qty` over **all** lines (pack components carry cost, summary carries 0), returns subtracted, Decimal only |
| 5 | Expense inclusion | **RESOLVED** | Only `status='posted'` in range; drawer/external split preserved; reuses `repositories/expense.py` |
| 6 | Net profit & margin | **RESOLVED** | `gross_profit = net_sales − cogs_net`; `net_profit = gross_profit − expenses_total`; `profit_margin_pct = net_profit / net_sales`; both profit figures exposed (§20 D1) |
| 7 | Cash-drawer reconciliation | **UNVERIFIED** | Business Rule 7; no tender on debt payments. **Drawer reconciliation excluded from Phase 14**; only components reported (§9). Blocking for that sub-feature only |
| 8 | Customer debt reporting | **RESOLVED** | Period `outstanding_debt` (blueprint semantics) + `debt_collected` from ledger + snapshot `ar_outstanding`/`customers_with_debt` from `total_outstanding` |
| 9 | Supplier payables | **RESOLVED** | Snapshot via `ledger_sum_for_supplier`; period `purchases_total`/`supplier_paid`; new compact `GET /reports/suppliers` |
| 10 | Inventory valuation | **RESOLVED** | `valuation.inventory_value` / `total_stock_value`, labelled snapshot, no date range |
| 11 | Dashboard KPIs | **RESOLVED** | §7 list (blueprint fields + today profit/invoices/expenses + recent/top); `alerts` deferred |
| 12 | Permissions | **RESOLVED** | `report_financial` view, `export_data` export, no new scopes; nav gating change flagged as C2 |
| 13 | Exports (CSV) | **RESOLVED** | Phase 14 client-side CSV from the loaded payload, contract §12.2, caps and errors defined |
| 14 | Localization | **RESOLVED** | 3 locales, ≈103 new keys ×3, parity test, localized export headers |
| 15 | Performance & caps | **RESOLVED** | SQL aggregation, budgets §15, row/range caps §6–§8, `EXPLAIN` verification in Step D |
| 16 | PDF / print boundary | **DEFERRED** | Phase 15 owns the renderer; Phase 14 delivers data contract only, no print/PDF dependency |
| 17 | API surface | **RESOLVED** | 11 endpoints (§11) + 5 reused; derived from blueprint + task §8, no speculative endpoints |
| 18 | DB / index strategy | **RESOLVED** | Additive migration `0020`, 4 indexes (§16), no tables/views/backfills |
| 19 | XLSX export | **DEFERRED** | Roadmap Phase 15; contract frozen in §12.2 |
| 20 | Timezone / hourly bucketing | **RESOLVED** | UTC everywhere (assumption A1, consistent with `repositories/expense.py:67-77`); confirmation C1 |
| 21 | Device dimension | **RESOLVED** | `device_id` filter/grouping on sales/voids/returns; `NULL → "unknown device"`; `device_name` blueprint param renamed (§20 D5) |
| 22 | Slow-moving definition | **RESOLVED** | Active products with `quantity > threshold` and no `sale_lines` in the last `days`; sorted by `last_sale_date ASC NULLS FIRST` |
| 23 | Payment split | **RESOLVED** | §5.4 from recorded `method`/`paid`/`change`; debt collections reported unsplit (no tender field) |
| 24 | Charts / new dependencies | **RESOLVED** | Bar/trend charts built with plain Flutter widgets (no new package); interactive/advanced charts deferred |
| 25 | Report snapshots / materialized views | **RESOLVED** | None — cost data is already snapshotted (§4.3) |
| 26 | Void report date field | **RESOLVED** | `voided_at` (event date), documented in §5.9 |
| 27 | Dashboard `alerts` | **DEFERRED** | No threshold/alert policy exists in Phase 0; `low_stock_count` covers the actionable case |
| 28 | Report caching | **RESOLVED** | No server-side cache; every request computes fresh |

**Counts: 28 gates — RESOLVED 24, DEFERRED 3, UNVERIFIED 1.**
**Blocking questions: 1** (G7 cash-drawer rule — blocks only the drawer-reconciliation sub-feature,
which is outside roadmap Phase 14 scope; Phase 14 can start without it).

---

## 19. Deferred items and non-blocking confirmations

### 19.1 Deferred (decided, not now)

| ID | Item | Goes to |
|---|---|---|
| DEF-1 | PDF / print renderer, Arabic PDF text | Phase 15 |
| DEF-2 | XLSX export | Phase 15 |
| DEF-3 | Server-side export service + export audit | Phase 15 |
| DEF-4 | Dashboard `alerts` | Pending a Phase 0 policy |
| DEF-5 | Interactive/advanced charts (pie, zoom, tooltips beyond bars) | Phase 14 Step F scope decision |
| DEF-6 | Device registry / pairing / `GET /devices` | Phase 16 |
| DEF-7 | Variant-level PMP and variant-level valuation | already deferred by Phase 7 |
| DEF-8 | Payment-method breakdown of debt collections | needs a tender field (Rule 7) |

### 19.2 Non-blocking confirmations (owner may answer during Step A review)

| ID | Question | Default if unanswered |
|---|---|---|
| C1 | Is the business day UTC or Africa/Algiers local? | UTC (A1), day-edge drift ≤ offset |
| C2 | May the Dashboard nav entry be hidden from cashiers? | Yes — Phase 0 matrix says "no" for financial reports |
| C3 | Should `export_xlsx`/`export_pdf` buttons appear disabled in Phase 14 or be absent? | Absent (DEF-1/DEF-2) |
| C4 | Blueprint says `device_name`, schema has `device_id` — confirm rename | `device_id` |
| C5 | Legacy clamped `net_sales` at 0 — confirm unclamped | Unclamped (truthful; §20 D4) |
| C6 | `items_sold` counts document units (packs/multi-units included) — confirm | Document units (legacy parity) |
| C7 | Should the Reports screen also be reachable from the Dashboard? | Yes (secondary link) |

---

## 20. Discrepancy register

| ID | Area | Legacy | Phase 0 blueprint | Modern truth | Proposed | Disposition |
|---|---|---|---|---|---|---|
| D1 | Net profit example | `net_sales − cogs − expenses` (`db_manager.py:1186`) | example shows `17000 = 47000 − 30000` (expenses not subtracted) | both computable | expose `gross_profit` **and** `net_profit`; margin uses `net_profit` | Resolved — blueprint example is a labelling error |
| D2 | Discounts | `SUM(discount)` = invoice only | `discounts: 2000` | line + invoice both stored | report `line_discounts`, `invoice_discounts`, `discounts_total` | Resolved |
| D3 | COGS | `si.quantity × p.cost` (live) | `cogs` | `sale_lines.unit_cost` snapshot | snapshot only | Resolved — modern is authoritative |
| D4 | Net sales clamp | `max(0, …)` | `47000` (no clamp shown) | can go negative in a heavy-return period | unclamped + always show `returns_total` | Resolved (C5) |
| D5 | Device param | `device_name` column | `device_name` | `device_id` (client-generated `pos-…`) | `device_id` | Resolved (C4) |
| D6 | `outstanding_debt` | period `Σ(total − paid)` | same field name | AR snapshot exists separately | blueprint field = period; snapshot renamed `ar_outstanding` | Resolved |
| D7 | `paid_cash` | `SUM(paid_amount)` (no change concept) | `paid_cash` | `paid − change` per tender | `paid_cash` net of change + `paid_card`/`paid_partial`/`collected_total` | Resolved |
| D8 | `items_sold` | `Σ si.quantity` | `500` | same column exists | document units, explicitly defined | Resolved (C6) |
| D9 | Return↔COGS timing | returns not costed at all | `returns_total` only | `return_lines.unit_cost` exists | period-matched `returns_cost` in `cogs_net` | Resolved — documented, not silent |
| D10 | Date filter | `DATE(x) BETWEEN`, local, unindexed | `date_from/date_to` | `timestamptz` + UTC interval rule | §6 + §16 indexes | Resolved (C1) |
| D11 | Silent errors | `except Exception: pass` | standard envelope | typed API errors | 422/403 with codes | Resolved |
| D12 | Export divergence | export re-queries separately | "export options" | one payload per screen | export = loaded payload (§12.2) | Resolved |
| D13 | Dashboard for cashier | role-gated pages | matrix "no" | rail entry ungated | gate by `report_financial` | Resolved (C2) |
| D14 | Void date | (voided listed by sale date) | `date_from/date_to` | `voided_at` exists | filter on `voided_at` | Resolved |
| D15 | Reports nav | has a nav item | "Report screens" | route exists, **no nav destination** | add Reports destination | Resolved |
| D16 | Payment split | no split reporting | `paid_cash` only | recorded per sale; **not** on debt payments | split for sales only; debt unsplit | Resolved (Rule 7) |

---

## 21. Final implementation plan (Steps B→E — nothing executed in Step A)

### Step B — Backend (no migration yet)
1. `app/repositories/report.py` — SQL aggregates for §5.1–§5.8, §7, §8 (pure queries, `Decimal`, reuse `debt`/`party`/`inventory`/`expense` aggregates).
2. `app/services/report.py` — orchestration, range validation, caps, quantisation via `quantize_money`.
3. `app/schemas/report.py` — `StrictBaseModel` response models.
4. `app/api/v1/reports.py` — 11 endpoints (§11) with `require_permission(REPORT_FINANCIAL)`; mount both routers in `api/v1/router.py`.
5. Tests: `tests/unit/test_reports.py`, `test_dashboard.py`, `test_report_permissions.py` (§17.1).
6. Verify: pytest (874 + new), `ruff check .` (64 baseline unchanged).

### Step C — Migration
7. `migrations/versions/0020_phase14_report_indexes.py` (§16.2), reversible.
8. Verify: `alembic current/heads/check`, migration integration test.

### Step D — Performance pass
9. Seed 200 k sales (+ lines/returns/expenses), `EXPLAIN (ANALYZE)` the five hot queries, record timings against §15 budgets; adjust indexes only if a budget is missed.

### Step E — Flutter
10. `lib/features/reports/` providers + screens (tabs R1–R9/R13/R15, date-range selector, presets, pagination).
11. `lib/features/dashboard/` providers + screen (§7 cards, recent sales, top products) with plain-widget bars (G24).
12. CSV builder + `file_picker` save (§12.2), export button gated by `export_data`.
13. `app_router.dart`: Reports destination + scope constants + route guards (G12).
14. Localization keys for §14 (three blocks, parity test).
15. Tests per §17.2; verify `flutter analyze`, `flutter test`, `flutter build windows --debug`.

### Step F — Closeout
16. Update `docs/STATUS.md` / phase status docs, record human QA, then commit (only when explicitly approved).

### Acceptance mapping (roadmap Phase 14)

| Roadmap criterion | Where satisfied |
|---|---|
| Reports calculate correctly | §5 formulas + §17.1 invariant tests |
| Dashboard shows accurate KPIs | §7 + dashboard/financial parity test |
| Charts render properly | R4/R5/R6 series + G24 widget charts |

---

### §21.A Assumptions (each is a documented choice, not a guess)

- **A1** Report boundaries and hourly buckets use UTC (existing code precedent, C1).
- **A2** `variant.cost` is a base-unit cost (used verbatim as `line.unit_cost`, `services/sale.py:379-381`).
- **A3** `products.avg_cost` is per base unit (`valuation.py:64`).
- **A4** `voided_at` is non-NULL for every `status='void'` sale (Phase 12 invariant).
- **A5** `device_id` is present for POS sales/returns (client sends `X-Device-ID`) and may be NULL elsewhere.
- **A6** CSV is rendered client-side; if the owner prefers server-side CSV, the contract in §12.2 is unchanged and only §13's Phase boundary moves.
