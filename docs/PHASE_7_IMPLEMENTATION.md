# Phase 7 Implementation — Inventory, Stock Management & PMP/WAC

**Date:** 2026-09-24  
**Status:** ✅ Phase 7 FINAL complete (automated verification green) — human sign-off pending (checklist §28)  
**Final scope:** Phase 6 selling/purchase units live in **Products** only; Inventory/Adjust is **base-unit only** (no unit selector).  
**Backend Tests:** 462 passed, 0 failed  
**Flutter Tests:** 260 passed, 0 failed  
**Flutter Analyze:** No issues found  
**Flutter Build:** `√ Built build\windows\x64\runner\Debug\supermarket_pos.exe`  
**Migration:** `f1a2b3c4d5e6` (0008) applied to `supermarket_pro` (alembic current = head)  
**Live smoke:** `python _smoke_37.py` → `SMOKE PASSED — all checks green`  
**Git:** NOT committed (awaiting human sign-off)

> **Scope note:** This phase implements Inventory / Stock / PMP ONLY.  
> **Phase 6 product units (selling/purchase) are untouched and stay in the product editor.**  
> **Phase 8 (POS), Phase 10 (packs), and Phase 11 (purchasing workflow) were NOT started.**  
> **Phase 7 is NOT marked APPROVED until a human completes checklist §28.**  
> **Do not commit until manually tested.**

---

## 1. Objective

Deliver complete inventory management with authoritative stock tracking and moving weighted average cost (PMP / WAC):

- Stock levels view with PMP + valuation (quantity × avg_cost).
- Manual stock adjustment (increase / decrease / set); reason optional on increase (default "Manual stock increase"), required on decrease/set.
- Stock entry / packaging-aware receive (whole packages → base units).
- Movement history (immutable journal, global + per-product).
- Low-stock detection (threshold + filter).
- Stock valuation (per product + total inventory value).
- Full ar/fr/en localization, responsive UI (wide/medium/narrow + RTL), permission gates.
- Migration for `products.avg_cost`, movement `unit_cost` / `avg_cost_after`, `movement_date` index.
- Tests for PMP math, adjustments, movements, permissions, valuation, packaging+PMP.

## 2. Existing Architecture Before Phase 7

| Layer | Status |
|---|---|
| DB schema (Phase 2/5/6) | `products.cost/quantity` existed; `inventory_movements` existed (Phase 2) with document_* packaging fields — **no avg_cost / unit_cost / avg_cost_after / movement_date index** |
| Backend foundation | DI, StrictBaseModel, BaseService.transaction(), BaseRepository, structured errors, pagination |
| Auth/RBAC (Phase 4) | JWT + `require_permission`; scopes `inventory_view` / `inventory_adjust` already seeded (admin + manager; cashier has neither) |
| Conversion domain (Phase 6) | `unit_conversions.py`, `packaging.py` — Phase 7 reuses for package receive |
| Flutter | Riverpod shell, `AppStrings`, `hasPermissionProvider`; Stock route was a placeholder |
| Legacy | `python_app` decrements `products.qty` on sales; dashboard “stock value” used **selling** price; no legacy PMP |

**Migration assessment:** one migration required — `products.avg_cost`, `inventory_movements.unit_cost/avg_cost_after`, index on `movement_date`.

## 3. Architecture After Phase 7

```
HTTP Request
    ↓
RequestIDMiddleware → FastAPI Router (/api/v1/inventory)
    ↓
Depends(require_permission(PermissionScope.INVENTORY_VIEW | INVENTORY_ADJUST))  ← 401 / 403
    ↓
Pydantic request schema (StrictBaseModel, Decimal money/qty; reason optional on increase, required on decrease/set)
    ↓
InventoryService (BaseService.transaction(), BusinessRuleError / ValidationError)
    ├── domain/valuation.py  — weighted_average_cost, inventory_value, package base cost
    ├── domain/packaging.py  — package receive / break bookkeeping
    ├── domain/unit_conversions.py — Decimal QTY_QUANTUM
    ↓
InventoryMovementRepository (pagination + sort allowlists — persistence only)
    ↓
SQLAlchemy Session → Response models → JSON (Decimal → string for Flutter)
```

Flutter: `StockScreen` (tabs: inventory list | movement journal) → `inventoryProvider` / `movementsProvider` / `productStockDetailProvider` → `AdjustDialog` → Dio `ApiClient`.

**Concept separation (enforced):**

| Concept | Meaning | Phase |
|---|---|---|
| avg_cost (PMP) | Authoritative moving weighted average cost on **product** | 7 |
| cost | Nominal / last-purchase reference — never overwritten by sales | 5/7 boundary |
| Variant PMP | Deferred — variants share product avg_cost | documented, not this phase |
| POS sale decrement | Phase 8 — decrements must not change PMP | not this phase |

## 4. Files Created/Modified

### New files

| File | Purpose |
|---|---|
| `new_app/backend/migrations/versions/2026_09_23_1300_f1a2b3c4d5e6_0008_phase7_inventory_pmp.py` | avg_cost + unit_cost + avg_cost_after + movement_date index |
| `new_app/backend/app/domain/valuation.py` | PMP / valuation / package base cost (Decimal only) |
| `new_app/backend/app/repositories/inventory.py` | Movement journal + stock list queries |
| `new_app/backend/app/schemas/inventory.py` | Inventory request/response schemas |
| `new_app/backend/app/services/inventory.py` | `InventoryService` — list, movements, detail, adjust, seed |
| `new_app/backend/app/api/v1/inventory.py` | Inventory routes |
| `new_app/backend/tests/unit/test_inventory_pmp.py` | 34 Phase 7 tests |
| `new_app/backend/_smoke_37.py` | Live smoke against 127.0.0.1:8000 |
| `new_app/lib/features/stock/inventory_models.dart` | Flutter models (item, movement, detail) |
| `new_app/lib/features/stock/inventory_providers.dart` | Riverpod providers (debounce, pagination, adjust) |
| `new_app/lib/features/stock/adjust_dialog.dart` | Stock adjustment dialog |
| `new_app/test/widget/stock_screen_test.dart` | Responsive + RTL + permission + adjust tests |

### Modified files

| File | Change |
|---|---|
| `new_app/backend/app/models/catalog.py` | `Product.avg_cost` NUMERIC(18,3) NOT NULL DEFAULT 0 |
| `new_app/backend/app/models/inventory.py` | `unit_cost`, `avg_cost_after`, `movement_date` index |
| `new_app/backend/app/schemas/catalog.py` | `ProductResponse.avg_cost`; **quantity removed** from `ProductUpdateRequest` |
| `new_app/backend/app/schemas/__init__.py` | Export inventory schemas |
| `new_app/backend/app/services/catalog.py` | Create seeds avg_cost + ADJUSTMENT; receive(unit_cost) updates PMP |
| `new_app/backend/app/api/v1/products.py` | Packaging receive accepts optional `unit_cost` |
| `new_app/backend/app/api/v1/router.py` | Register `/inventory` |
| `new_app/backend/tests/integration/test_migrations.py` | `HEAD_REV = f1a2b3c4d5e6` + Phase 7 migration class |
| `new_app/lib/core/strings.dart` | Phase 7 keys × ar/fr/en |
| `new_app/lib/features/products/models.dart` | `ProductModel.avgCost` |
| `new_app/lib/features/stock/stock_screen.dart` | Full inventory UI (list / journal / detail / adjust) |
| `new_app/lib/router/app_router.dart` | Nav rail gated on `inventory_view`; `/stock` route |

## 5. API Endpoints

Static routes declared **before** `/{product_id}`:

| Method | Path | Permission | Notes |
|---|---|---|---|
| GET | `/api/v1/inventory` | `inventory_view` | Paginated list + `total_stock_value`; search, status, low_stock, sort allowlist |
| GET | `/api/v1/inventory/movements` | `inventory_view` | Global journal; product_id/variant_id/movement_type/search filters |
| GET | `/api/v1/inventory/movements/{product_id}` | `inventory_view` | Per-product journal |
| POST | `/api/v1/inventory/adjust` | `inventory_adjust` | increase \| decrease \| set; returns product detail |
| GET | `/api/v1/inventory/{product_id}` | `inventory_view` | Detail + packaging + variants + purchase_units + recent movements |

Error contract (same as Phase 4–6): 401 `UNAUTHORIZED`, 403 `FORBIDDEN`, 404 `NOT_FOUND`, 409 `CONFLICT`, 422 `VALIDATION` / `BUSINESS_RULE` — all with `code`, `message_key`, `message`, `details`, `request_id`.

## 6. Validation

**Schema level (Pydantic):**

- `operation`: `^(increase|decrease|set)$`
- `quantity`: `Decimal`, `ge=0`, max 18,3
- `unit_cost`: optional `Decimal`, `ge=0`, max 18,3
- `reason`: optional ≤ 500 on **increase** (blank/missing → service stores neutral default `"Manual stock increase"`); **required** non-blank on **decrease/set** (blank after strip → 422)
- `note`: optional ≤ 2000 (appended to reason on journal entry)
- `variant_id` / `purchase_unit_id`: optional UUIDs (mutually exclusive paths with product-only path)
- **`selling_unit_id` removed from `InventoryAdjustRequest`** — inventory/adjust is base-unit only (UI no longer sends unit ids; API keeps `purchase_unit_id` for packaging receive)

**Service level:**

- Invalid operation / negative quantity → 422 `ValidationError`
- Stock would go negative without `allow_negative_stock` → 422 `BusinessRuleError`
- Package quantity must be whole packages > 0 → 422
- Package unit ownership / archived → 404 / 422
- PMP formula errors (negative unit cost, non-positive receipt) → 422 via `ValuationError`
- Missing/blank reason on decrease/set → 422 (Pydantic model validator)
- Missing reason on increase → accepted; journal reason defaults to `"Manual stock increase"`
- `ProductUpdateRequest` no longer has `quantity` — Pydantic ignores unknown `quantity` on PUT (stock only via inventory endpoints)

## 7. Authorization

| Role | inventory_view | inventory_adjust |
|---|---|---|
| admin | ✅ | ✅ |
| manager | ✅ | ✅ |
| cashier | ❌ | ❌ |

- Every Phase 7 endpoint behind `require_permission`.
- Unauthenticated → 401; cashier adjust → 403; product read does not grant inventory write.
- Flutter: nav rail shows Stock only with `inventory_view`; StockScreen shows permission-denied without it; adjust buttons only with `inventory_adjust`.

## 8. Service Layer & Business Rules

`InventoryService(BaseService)`:

- All mutations inside `self.transaction()`; repos persistence-only.
- Paths in `adjust()`:
  1. **variant_id** → adjust `variant.quantity` only; product qty untouched; **variant PMP deferred** (snapshot product avg_cost on movement).
  2. **purchase_unit_id** → whole packages; base delta = packages × multiplier; document unit_cost is **per package** → base cost = unit_cost / multiplier. (API path retained; AdjustDialog no longer sends it.)
  3. **base product path** → direct base-unit delta (**only path used by the Flutter UI**).
  - **`_adjust_selling_unit` / `selling_unit_id` path removed** (Phase 7 final).

**PMP rules (authoritative):**

```
new_avg = (old_qty × old_avg + recv_qty × recv_cost) / (old_qty + recv_qty)
```

- Sales / decreases **never** change avg_cost.
- Increase without unit_cost leaves avg_cost unchanged.
- Receive into zero (or non-positive) stock without unit_cost may seed from nominal `cost`.
- Receive into zero **with** unit_cost → avg_cost = unit_cost.
- Quantize only at persistence (`NUMERIC(18,3)`).
- Package receive: document unit_cost / multiplier (never rewrite document quantity).

**Acceptance examples (authoritative):**

| Given | Result |
|---|---|
| 1×100 then +3×200 | qty 4, value 700, PMP **175** |
| 10×1000 then +10×1400 | PMP **1200** |
| Any decrease/sale | PMP unchanged |
| Fromage packaging sales/receives | PMP unchanged on sales; package receive updates via base cost |
| Set qty 0 then +5 @40 | PMP **40** (zero-stock reseed) |

Product create with qty>0: seeds `avg_cost = cost` + initial ADJUSTMENT movement (`seed_initial_stock`).

## 9. Repository Layer & Queries

`InventoryMovementRepository`:

- `list_movements` — page/page_size, product/variant/type/search filters, **sort allowlist** (`movement_date|created_at|quantity_change|movement_type`), default `movement_date DESC`.
- `list_recent_for_product` — detail panel (limit 20).
- `list_products_with_stock` — status (`active|archived|all`), low_stock, search name/barcode, sort allowlist (`name|quantity|avg_cost|price|updated_at`).
- `total_stock_value` — SUM(quantity × avg_cost) for list header.
- Movement type filter allowlist mirrors `StockMovementType`.

No full-table loads; count + page queries only.

## 10. Flutter UI

| Widget / key | Purpose |
|---|---|
| `StockScreen` | Two tabs: Inventory list / Movement journal |
| `stock-title` / `stock-subtitle` / `stock-refresh` / `stock-header-adjust` | Header (title `المخزون`, subtitle, refresh; contextual adjust only when product selected) |
| `stock-search` / `stock-status-filter` / `stock-low-filter` / `stock-toolbar` / `stock-toolbar-refresh` | One rounded toolbar (dominant search; stacked on narrow) |
| `stock-tab-list` / `stock-tab-movements` | Tab switching |
| `kpi-total-value` / `kpi-product-count` / `kpi-low-stock` / `kpi-out-stock` | KPI cards (wide/medium) / mini chips (narrow) |
| `stock-list` (medium/wide table) / `stock-cards` (narrow) | Inventory presentation |
| `stock-item-{id}` / `stock-card-{id}` | Row/card → opens detail |
| `stock-adjust-{id}` | Permission-gated per-row adjust button |
| `stock-detail-panel` / `detail-name` / `detail-quantity` / `detail-adjust` / `detail-close` | Side panel (wide) / stacked (medium/narrow) |
| `stock-loading` / `stock-error` / `stock-empty` / `stock-permission-denied` | States |
| `movements-list` / `movement-{id}` / `movement-type-filter` / `movements-refresh` | Journal (semantic badges: + green / − red / neutral info) |
| `adjust-dialog` / `adjust-operation` / `adjust-quantity` / `adjust-unit-cost` / `adjust-reason` / `adjust-note` / `adjust-new-stock-preview` / `adjust-submit` / `adjust-error` | Adjustment dialog (**base units only** — no unit selector) |

**Responsive breakpoints (full window width):**

| Mode | Width | Layout |
|---|---|---|
| WIDE | ≥ 1200 | Full table + detail side panel (360) |
| MEDIUM | 800–1199 | Table, reduced columns |
| NARROW | < 800 | Cards, stacked toolbar |

Adjust dialog: SegmentedButton (increase/decrease/set), qty with **base-unit label** (`base_unit` + unit label as suffix/helper), optional unit_cost, optional reason on increase (required on decrease/set), optional note, new-stock preview in **base** units on qty change, validates before POST. **No unit selector, no conversion preview, no `selling_unit_id` / `purchase_unit_id` in the payload.**

**Movement color semantics (visual only):**

| Direction / type | Color token | Applies to |
|---|---|---|
| Positive delta (`+10`, `+5`, receive, initial stock, adjustment increase) | `AppColors.success` (green) | Quantity text + badge/icon/dot |
| Negative delta (`-2`, `-3`, sale, decrease, return-out) | `AppColors.error` (red) | Quantity text + badge/icon/dot |
| SET / zero-delta adjustment | `AppColors.info` (blue/neutral) | Quantity + badge — never forced red |
| Purchase / package_receive (stock-in) | `AppColors.success` | Badge/icon |
| Sale (stock-out) | `AppColors.error` | Badge/icon |
| Other neutral types | `AppColors.info` | Badge/icon |

- Helpers: `movementDirectionFromQuantityChange`, `movementQuantityColor`, `movementTypeColor(type, quantityChange:)`, `formatSignedQuantityChange` in `stock_screen.dart`.
- Positive deltas always render with a visible `+` (`5.000` → `+5.000`); quantity Text uses `TextDirection.ltr` so Arabic RTL layout stays correct for numeric signs.
- Colors reuse existing `AppColors.success/error/info` tokens (dark/light/grey themes); no hard-coded `Color(...)` in journal widgets.
- Applied to journal rows, detail-panel recent movements, badges/dots/icons — same rules at wide/medium/narrow.

## 11. Localization

All Phase 7 strings via `AppStrings.t(key, locale)` / `unitLabel`; locale from `localeProvider`.

Keys (× ar/fr/en, parity enforced by `constants_test` + `products_localization_test`):  
`inventory`, `inventory_subtitle`, `stock_value`, `total_stock_value`, `avg_cost`, `adjust_stock`, `increase`, `decrease`, `set_quantity`, `operation`, `unit_cost`, `unit_cost_optional`, `reason`, `reason_optional`, `reason_required`, `invalid_unit_cost`, `note`, `enter_reason`, `adjustment_success`, `movement_history`, `movement_type`, `quantity_before`, `quantity_after`, `quantity_change`, `document_quantity`, `performed_by`, `no_movements`, `low_stock_only`, `product_detail`, `recent_movements`, `stocktake`, `purchase_receipt`, `manual_adjustment`, `movement_sale`, `movement_purchase`, `movement_return`, `movement_adjustment`, `movement_package_receive`, `movement_package_break`, `adjust_product`, `adjust_variant`, `select_operation`, `current_stock`, `new_stock`.

Arabic default + RTL; movement type labels never hardcoded in widgets (`movementTypeLabel`).

**Required/optional UI indicators (AdjustDialog):** reason/unit_cost show `helperText` — increase → `reason_optional` / `unit_cost_optional` (no red indicator); decrease/set → `reason_required` (reason label gets ` *`); confirm button stays enabled when quantity is valid (backend enforces required-reason via 422).

**Structured validation errors:** backend registers a `RequestValidationError` handler (`app/core/exceptions.py`) that converts FastAPI's default `detail: [{loc,msg,type}]` list into the standard envelope (`code=VALIDATION_ERROR`, joined human-readable `message`, per-field `details`, `request_id`). Flutter `backendErrorMessage` parses both envelope and detail-list shapes, so decrease/set 422 shows the real message (e.g. `reason: reason is required for decrease and set`) instead of the generic `validation_error`.

## 12. Tests

### Backend — `tests/unit/test_inventory_pmp.py` (51)

| Class | Coverage |
|---|---|
| `TestPMPFormula` | Acceptance A/B, zero-stock seed, negative cost reject, sales don’t change PMP |
| `TestProductCreateSeedsStock` | Create qty>0 → avg_cost = cost + ADJUSTMENT movement |
| `TestProductUpdateRejectsQuantity` | PUT quantity ignored / not in ProductUpdateRequest |
| `TestInventoryAdjustPMP` | increase/decrease/set, PMP update, valuation, structured errors |
| `TestVariantAdjustments` | variant qty only; product qty untouched; movement variant_id |
| `TestInventoryEndpoints` | list/movements/detail/adjust happy paths + pagination |
| `TestPackagingWithPMP` | package receive → base cost → weighted average; packaging sequences leave PMP unchanged on sales |
| `TestInventorySecurity` | 401 unauth; cashier denied view + adjust; admin allowed |
| `TestInventoryServicePersistence` | Transaction flush, journal immutability fields |
| `TestBaseUnitAdjustments` | base increase/decrease/set, insufficient-stock 422, **`selling_unit_id` not accepted**, package receive E/E2, purchase-unit decrease, unknown purchase unit 404 |

### Backend — migration integration

- `HEAD_REV = "f1a2b3c4d5e6"`; `TestPhase7InventoryPMPMigration` checks columns/index.

### Flutter — `test/widget/stock_screen_test.dart` (~30)

- Responsive: 600×500, 800×600, 1024×768, 1366×768, 1920×1080 — no overflow; cards vs table by breakpoint; scroll for below-fold items.
- Arabic RTL narrow — no overflow.
- KPI cards (wide) + compact chips (narrow): `kpi-total-value`, `kpi-product-count`, `kpi-low-stock`, `kpi-out-stock`.
- Toolbar: single rounded `stock-toolbar` with dominant search + status + low filter + refresh (stacked on narrow).
- Table status pills / barcode; detail panel side (wide) / stacked (medium).
- Contextual `stock-header-adjust` only when a product is selected.
- Movement journal tab lists movements + PMP text.
- Permission: shell hides Stock without `inventory_view`; StockScreen shows denied; no adjust buttons without `inventory_adjust`.
- Adjust dialog: open, increase without reason succeeds, decrease/set without reason show validation, preview, successful submit closes dialog; **required/optional helper text per operation**; **no `adjust-unit-selector` / `adjust-conversion-preview`**; base-unit label; payload has **no** `selling_unit_id` / `purchase_unit_id`; narrow 600×500 no overflow (direct screen mount).
- Movement color semantics: increase → `AppColors.success`, decrease → `AppColors.error`, set/zero → `AppColors.info`; type badges; signed `+` formatting.

### Flutter — `test/unit/api_client_test.dart` — `backendErrorMessage` detail-list parsing (envelope + FastAPI `detail: [{loc,msg}]` join + envelope preference).

Existing suites (auth, products, settings, localization, unit) remain green without modification.

## 13. Verification Results (Phase 7 FINAL)

```
flutter analyze --no-pub          → No issues found!
flutter test --no-pub             → 260 passed, 0 failed
flutter build windows --debug     → √ Built build\windows\x64\runner\Debug\supermarket_pos.exe
python -m compileall app          → OK
python -m pytest tests            → 462 passed, 0 failed (3 SAWarning in conftest rollback)
python -m alembic current         → f1a2b3c4d5e6 (head)
python -m alembic heads           → f1a2b3c4d5e6 (head)
python _smoke_37.py               → SMOKE PASSED — all checks green
```

Live smoke highlights (`_smoke_37.py` against `127.0.0.1:8000` + `supermarket_pro`):

- Unauth inventory → 401
- Create product qty=1 cost=100 → avg_cost=100.000 + seeded movement
- Increase 3 @ 200 → qty 4, value 700, **PMP 175**
- Decrease 2 → qty 2, PMP still 175, value 350
- Set 0 → PMP still 175; reseed +5 @40 → PMP 40
- Over-decrease → 422 BUSINESS_RULE_ERROR structured envelope
- Missing reason → 422 on decrease/set; increase without reason succeeds with default `"Manual stock increase"`
- PUT `quantity=999` → quantity unchanged (5.000), price updated
- Global movements total ≥ 5; product journal shows unit_cost=200.000, avg_cost_after=175.000
- DB: `avg_cost` NOT NULL, `unit_cost` YES nullable, movement_date index present, alembic `f1a2b3c4d5e6`
- Cashier RBAC skipped in this DB (login PIN mismatch) — covered by unit tests

## 14. Known Limitations, Deferred Decisions & Phase Completion

**Known limitations:**

- **Variant-level PMP deferred** — product.avg_cost is authoritative; variant movements snapshot product avg_cost.
- **POS sale decrement is Phase 8** — no automatic sale decrement outside packaging break/adjust in this phase.
- Cashier live smoke RBAC skipped when cashier PIN unknown — automated tests cover it.
- Flutter adjust dialog does not yet expose package/variant pickers (API supports them; UI may expand in later UX pass).
- `double.tryParse` for preview only; authoritative math is backend Decimal.

**Deferred decisions:**

- Whether inventory list should show separate packaging split (full packages / loose) in table — currently in detail panel.
- Movement journal export — not in Phase 7.
- Dashboard stock value (Phase 14) will use qty × avg_cost (not selling price) — legacy divergence documented.

**Phase 7 completion status:**

- [x] Migration 0008 (`avg_cost`, `unit_cost`, `avg_cost_after`, index)
- [x] Domain `valuation.py` with Decimal PMP
- [x] Inventory list / movements / detail / adjust API + permissions
- [x] Product create seeds stock + receive(unit_cost) PMP
- [x] ProductUpdateRequest no longer accepts quantity
- [x] Flutter models + providers + stock screen + adjust dialog
- [x] Localization ar/fr/en parity
- [x] Router permission gate for Stock
- [x] Backend tests: 462 passed
- [x] Flutter tests: 260 passed
- [x] `flutter analyze`: clean
- [x] `flutter build windows`: success
- [x] Live smoke `_smoke_37.py`: green
- [x] Unit selector removed (base-unit-only AdjustDialog + API schema)
- [x] Inventory screen redesigned (KPI cards, toolbar, table/cards, detail, journal badges)
- [x] Report written (`docs/PHASE_7_IMPLEMENTATION.md`)
- [ ] **Manual verification checklist (human) — PENDING (§28)**
- [ ] **Phase 8 / 10 / 11 NOT started**

## 15. Design Decisions (Non-Negotiables)

1. **`products.avg_cost` is authoritative PMP** — `products.cost` stays nominal/last-purchase.
2. **Decreases/sales never change PMP.**
3. **Decimal only** for PMP/valuation; quantize only at persistence.
4. **Every stock mutation writes an immutable movement** (reason: optional on increase with neutral default; required on decrease/set).
5. **Stock only via inventory endpoints** — product PUT cannot change quantity.
6. **Package document unit_cost is per package** — base cost = unit_cost / multiplier.
7. **Variant PMP deferred** — document; product-level only this phase.
8. **Reuse Phase 4 RBAC** — `inventory_view` / `inventory_adjust` only (no new scopes).
9. **Repositories persistence-only** — business rules in `InventoryService`.
10. **Valuation = quantity × avg_cost** (not selling price — legacy dashboard divergence intentional).

## 16. PMP Math Reference

```
weighted_average_cost(old_qty, old_avg, recv_qty, recv_cost):
  if recv_cost < 0 or recv_qty <= 0: ValuationError
  if old_qty <= 0: return recv_cost          # zero-stock seed
  return (old_qty*old_avg + recv_qty*recv_cost) / (old_qty + recv_qty)

inventory_value(qty, avg) = (qty * avg).quantize(0.001)

base_unit_cost_from_package(doc_unit_cost, multiplier) = doc_unit_cost / multiplier
```

Scenarios:

| Steps | PMP |
|---|---|
| start 1@100, +3@200 | 175 |
| 10@1000, +10@1400 | 1200 |
| any −qty (sale/decrease) | unchanged |
| 0 stock, +5@40 | 40 |
| package 10 Box×24 @200 → base cost 200/24 | applied to weighted average |

## 17. Migration Details

**Revision:** `f1a2b3c4d5e6`  
**Revises:** `e5f6a7b8c9d0` (Phase 6 head)  
**File:** `migrations/versions/2026_09_23_1300_f1a2b3c4d5e6_0008_phase7_inventory_pmp.py`

| Change | Column / object | Type | Notes |
|---|---|---|---|
| ADD | `products.avg_cost` | NUMERIC(18,3) NOT NULL DEFAULT 0 | authoritative PMP |
| ADD | `inventory_movements.unit_cost` | NUMERIC(18,3) NULL | receipt unit cost |
| ADD | `inventory_movements.avg_cost_after` | NUMERIC(18,3) NULL | PMP snapshot |
| CREATE INDEX | `ix_inventory_movements_movement_date` | on `movement_date` | history queries |

Non-destructive: existing rows get `avg_cost=0`; no rewrite of `products.cost`.  
Verified: `alembic current` = `f1a2b3c4d5e6 (head)` on `supermarket_pro`.

## 18. Backend Models

**`Product` (`catalog.py`):**

```python
avg_cost: Mapped[float] = numeric_money()  # NOT NULL DEFAULT 0 — Phase 7 PMP
cost: Mapped[float] = numeric_money()      # nominal / last-purchase (unchanged)
quantity: Mapped[float] = numeric_quantity()
```

**`InventoryMovement` (`inventory.py`):**

- Existing: product_id, variant_id, movement_type, quantity_change/before/after, document_*, purchase_unit_id, packages_change, reason, source_*, user_id, device_id, movement_date
- Phase 7 added: `unit_cost` nullable, `avg_cost_after` nullable
- `movement_date` indexed (`index=True` + migration index)

## 19. Backend Schemas

**`InventoryItemResponse`** — product_id, name, barcode, unit, quantity, thresholds, cost, **avg_cost**, **stock_value**, price, is_archived, category_*, updated_at.

**`InventoryListResponse`** — items, total, page, page_size, pages, **total_stock_value**.

**`InventoryMovementResponse`** — full journal row including unit_cost, avg_cost_after, user_name, movement_date.

**`InventoryAdjustRequest`** — product_id, variant_id?, operation, quantity, unit_cost?, **purchase_unit_id?** (API packaging path only; Flutter does not send it), reason (optional on increase → default `"Manual stock increase"`; required on decrease/set), note?  
**No `selling_unit_id` field** (removed in Phase 7 final).

**`InventoryProductDetailResponse`** — stock + packaging dict + variants[] + purchase_units[] + recent_movements[].

**`ProductResponse`** — now includes `avg_cost`.  
**`ProductUpdateRequest`** — **no `quantity` field** (Phase 7).

## 20. Backend API Implementation Notes

- Router registered as `prefix="/inventory"` in `app/api/v1/router.py`.
- Static paths (`""`, `/movements`, `/movements/{id}`, `/adjust`) before `/{product_id}`.
- `require_permission(PermissionScope.INVENTORY_VIEW|INVENTORY_ADJUST)` on each route.
- `adjust` returns `InventoryProductDetailResponse` after commit/flush so Flutter can refresh in one round-trip.
- Structlog on successful adjust: product_id, operation, delta, before/after, avg_cost (no secrets/PINs).

## 21. Flutter Models

**`InventoryItemModel`** — product_id, name, barcode, unit, quantity, low_stock_threshold, allow_negative_stock, cost, **avgCost**, **stockValue**, price, isArchived, category_*, updatedAt; helpers `isLowStock` / `isOutStock`.

**`InventoryMovementModel`** — full journal fields including unitCost, avgCostAfter, userName, movementDate.

**`InventoryProductDetailModel`** — stock + packaging + variants + purchase_units + recentMovements.

**`ProductModel`** — added `avgCost`.

Money/qty arrive as strings (Decimal JSON) — parse only for display/preview.

## 22. Flutter Providers

- `inventoryProvider` — StateNotifier; debounced search 300ms; stale-response requestId guard; filters (status, low_stock, sort); `adjust(payload)` returns display-ready error message or null; refresh/page setters.
- `movementsProvider` — global or per-product journal; type filter; pagination.
- `productStockDetailProvider` — AsyncValue detail load/clear.
- All use `apiClientProvider().dio` + locale from `localeProvider`.
- Permission via `hasPermissionProvider('inventory_view' | 'inventory_adjust')`.

## 23. Flutter Widgets Detail

- `StockScreen` is ConsumerStatefulWidget with TabController; loads inventory + movements in initState microtask.
- Layout mode from `MediaQuery.sizeOf(context).width` → `stockLayoutModeFor` (works with RTL).
- Header hides icon/value chip on narrow; toolbar stacks filters on narrow.
- Table columns: name (+category wide), quantity (colored by status), avg_cost, stock_value, actions (adjust icon).
- Cards on narrow show subtitle with quantity · avg_cost · stock_value.
- Detail: wide = side panel; other = stacked under list; shows recent movements.
- `AdjustDialog` / `showAdjustDialog` returns submitted payload or null on cancel; calls `inventoryProvider.adjust`.

## 24. Localization Keys (Complete Phase 7 List)

See §11 for the full key list. Parity across ar/fr/en verified by `test/unit/constants_test.dart` (“all locales have same keys”) and existing localization suites.

## 25. Responsive & RTL Behavior

- Breakpoints use full window width (not content width) so RTL does not break mode selection.
- Tests set `tester.view.devicePixelRatio = 1.0` with physicalSize 600×500 → 1920×1080.
- Arabic default locale; Stock nav uses warehouse icon (avoids label collision with `inventory`/`stock` both “المخزون” in Arabic).
- No ClipRect; overflow asserted via `tester.takeException()` isNull.

## 26. Security & RBAC Summary

- Every Phase 7 endpoint behind `require_permission` with inventory scopes.
- Cashier has neither inventory scope (seed map).
- No new env vars; no secrets in source; structured errors without stack traces to clients.
- Adjust requires authenticated user recorded on movement `user_id`.
- Sort/filter fields allowlisted — no raw SQL identifiers from clients.

## 27. Performance Considerations

- Inventory list uses indexed product columns + page queries; `total_stock_value` is a single aggregate.
- Movement journal uses `ix_inventory_movements_movement_date` for default sort.
- Detail panel loads variants/purchase units/recent movements on demand (not with list).
- Flutter debounces search (300ms) and drops stale responses via requestId.
- Repos never load full tables; count + page only.

## 28. Manual Verification Checklist (HUMAN — PENDING)

Run on a **fresh build** against live backend at 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080 with **ar / fr / en**:

1. [ ] Log in as Admin → **Stock** appears in nav rail (localized label + warehouse icon).
2. [ ] Stock list shows quantity, avg cost (PMP), stock value; total stock value chip on wide.
3. [ ] Search + status filter + low-stock filter + refresh work; empty/error/loading states.
4. [ ] Click a row → detail panel (wide) or stacked detail shows PMP, cost, value, packaging, variants, recent movements.
5. [ ] Adjust → increase with unit_cost → qty and PMP update per formula (spot-check 1@100 + 3@200 → 175); snackbar success; movement appears in journal with unit_cost + avg_after.
6. [ ] Adjust increase without reason → success (journal reason = "Manual stock increase"); decrease/set without reason → validation error; with reason → success.
7. [ ] Decrease does **not** change PMP; over-decrease (below zero) rejected with clear message.
8. [ ] Set quantity to absolute value works; set to 0 then reseed with cost updates PMP.
9. [ ] Movement journal tab: filter by type, refresh, pagination; PMP column visible when present.
10. [ ] Packaging-aware receive (if purchase unit configured): whole packages only; PMP uses package unit_cost / multiplier.
11. [ ] Product create with initial qty+cost → inventory shows avg_cost = cost without extra adjust.
12. [ ] Product edit PUT does **not** change stock quantity (quantity field not editable / ignored).
13. [ ] Cashier (or user without inventory_view): no Stock in nav; without inventory_adjust: no adjust buttons; direct StockScreen shows permission denied if reached.
14. [ ] Arabic RTL: all labels localized, no overflow, no hardcoded English; French/English LTR correct.
15. [ ] Responsive: narrow uses cards; medium/wide table; no RenderFlex overflow at all five sizes.

**Do not mark Phase 7 APPROVED until all items above are checked by a human.**

## 29. Acceptance Criteria (Roadmap Phase 7)

- [ ] Stock can be adjusted — **automated: yes; manual: pending §28**
- [ ] Movements recorded correctly — **automated: yes; manual: pending §28**
- [ ] Low stock detected — **automated: yes (filter + status); manual: pending §28**
- [ ] History viewable — **automated: yes; manual: pending §28**

Roadmap feature checklist mapping:

| Feature | Status |
|---|---|
| Stock levels view | ✅ API + UI |
| Manual stock adjustment | ✅ increase (reason optional) / decrease / set (reason required) |
| Stock entry dialog | ✅ AdjustDialog (base units + package API path; **no unit selector**) |
| Movement history | ✅ global + per-product journal |
| Low stock alerts | ✅ threshold filter + row status color (push notifications out of scope) |
| Stock valuation | ✅ per product + total_stock_value |
| Inventory service | ✅ InventoryService |
| Stock adjustment logic | ✅ packaging/variant-aware (base path used by UI) |
| Movement recording | ✅ immutable journal |
| Low stock detection | ✅ isLowStock / low_stock filter |
| Unit selector in adjust | ❌ **Removed in Phase 7 final** — base units only; Phase 6 units live in Products |

## 30. Phase 7 Status Summary & Stop Line

**Automated verification: GREEN**

| Check | Result |
|---|---|
| Backend tests | **462 passed** |
| Flutter tests | **260 passed** |
| Flutter analyze | clean |
| Flutter Windows build | success |
| Alembic head on dev DB | f1a2b3c4d5e6 |
| Live smoke `_smoke_37.py` | PASSED |

**Human manual verification: PENDING (§28)**  
**Phase 7 final (base units + UX redesign): automated green — NOT committed until manually tested.**  
**Phase 7 APPROVED: NO — requires human sign-off.**  
**Phase 8 (POS), Phase 10 (packs), Phase 11 (purchasing): NOT STARTED — STOP.**

## 31. Base-Unit-Only Adjust (Phase 7 Final Scope)

**Final decision:** Inventory adjustment uses **base units only**. The temporary unit-selector feature (selling/purchase entry units in AdjustDialog) was **removed**.

| Concern | Final state |
|---|---|
| AdjustDialog | Base-unit quantity only; `suffixText`/helper shows base unit label; new-stock preview in base units |
| Payload | `product_id`, optional `variant_id`, `operation`, `quantity`, `reason`, `note`, `unit_cost` — **no** `selling_unit_id` / `purchase_unit_id` |
| `InventoryAdjustRequest` | `selling_unit_id` **removed**; `purchase_unit_id` retained for packaging API |
| Service | `_adjust_selling_unit` **removed**; paths = variant \| purchase_unit (API) \| base (UI) |
| Localization | `entry_unit`, `whole_packages_required`, `conversion_preview` **removed** from ar/fr/en |
| Keys | `adjust-unit-selector`, `adjust-unit-option-*`, `adjust-conversion-preview` **removed** |
| Phase 6 units | **Untouched** — selling/purchase units, unit CRUD, product editor, DB tables |
| Packaging domain | **Untouched** — `receive_packages`, `sell_base_units`, `base_unit_cost_from_package` |
| PMP / WAC / movements / valuation / RBAC | **Untouched** |

### 31.1 UX redesign (same phase)

- Header: title `المخزون` + subtitle `إدارة المخزون وقيمة المنتجات`; contextual `stock-header-adjust` only when product selected.
- KPI cards ~88px (wide/medium) / compact chips (narrow): total value, product count, low, out.
- Single rounded toolbar with dominant search + status + low-stock filter + refresh.
- Card/table hybrid: status pills, hover/selected rows, barcode.
- Detail: side panel (WIDE ≥1200), stacked (MEDIUM 800–1199 / NARROW <800).
- Journal badges: positive=success, negative=error, neutral=info; LTR numerics with explicit `+`.
- No hardcoded colors — `AppColors` / theme tokens only.
- Zero overflow asserted at 600×500, 800×600, 1024×768, 1366×768, 1920×1080.

### 31.2 Tests (base-unit final)

- Backend: `TestBaseUnitAdjustments` (base ops, insufficient 422, **`selling_unit_id` not accepted**, package receive, purchase-unit decrease).
- Flutter: no unit selector keys; base-unit label; preview 17.000 / set→30.000; payload without unit ids; narrow 600×500 no overflow.
- Full suites: **462 backend + 260 Flutter**, analyze clean, Windows build OK.

### 31.3 Phase 8 NOT STARTED

POS checkout / scan-to-cart wiring is **out of scope**. Stop here.
