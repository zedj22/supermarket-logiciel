# Phase 10 Implementation — Packs / Bundles

**PHASE 10: APPROVED / CLOSED** — Technical verification **PASS** —
Human QA **PASS** — Git commit **created** (single commit
`phase-10: complete packs`). **No known blocker remains**; Phase 11
(Purchases & Suppliers) has **not** been started.

Final automated verification (closing round — core + PACK UX/DOMAIN fix
round + 100%-margin bugfix round):

| Gate | Command | Result |
|---|---|---|
| Backend suite | `python -m pytest tests -q` | **681 passed**, 3 warnings |
| Backend pack tests | `pytest tests/unit/test_packs.py` | **78 passed** |
| Backend migration tests | `pytest tests/integration/test_migrations.py` | **37 passed** (real PostgreSQL) |
| PG concurrency | `pytest tests/integration/test_pack_concurrency.py` | **passed** (real PostgreSQL) |
| Flutter suite | `flutter test` | **877 passed** (822 baseline + 55 new) |
| Analyzer | `flutter analyze` | **No issues found** |
| Windows build | `flutter build windows --debug` | **PASS** (`supermarket_pos.exe`) |
| Migration | `alembic current` / `alembic heads` | `c9d0e1f2a3b4 (head)` — applied to the dev DB (single head) |

Human QA: **PASSED** (full checklist of §8 executed by the reviewer).

Profit preview disposition: the `estimated_cost / estimated_profit /
estimated_margin_percent` preview is **display-only** — never persisted,
never used for pricing, totals, stock, valuation or reports. It is
**accepted for Phase 10 as-is** and will be **revalidated after Phase 11
(Purchases & Suppliers)**, once purchases/supplier receipts establish the
complete PMP / `avg_cost` workflow. The profitability system is explicitly
**not** to be reopened or redesigned during Phase 10.

Baseline before this phase: `d679eabbcc164fbbc47eb121801ef7d6e3dc3de7`
(`phase-9: complete customers debts payments`), alembic head `c8d4e5f6a1b2`.

Decision record: `docs/PHASE_10_PACKS_ANALYSIS.md` — GATE 1…14 all
**RESOLVED**. This report describes what was actually built.

---

## 1. Objective & Scope

Deliver packs (bundles) end-to-end:

- Pack CRUD: create, read, paginated list/search/filter, partial update, soft
  archive — with component lists (base products only, quantity in base units
  per 1 pack).
- Read-only availability endpoint (component stock vs. requested quantity).
- POS: pick an active pack, quantity, availability pre-flight, one pack cart
  line (badge + component snapshot), checkout persisted through the unchanged
  `SaleService` payment/debt/discount pipeline.
- Inventory: guarded per-component decrement + `PACK_COMPONENT` movements in
  the same transaction as the sale.
- AR/FR/EN localization, RBAC reuse, tests, migration, this report.

Out of scope (unchanged from the roadmap): returns/voids (**Phase 12**),
reports/dashboard/PMP pack costing (**Phase 14**), purchases/suppliers,
PDF, LAN, offline queue, tax changes, split-payment redesign.

---

## 2. Decision gates → what shipped

| Gate | Resolution | Shipped behavior |
|---|---|---|
| 1 | base product only | `PackItem.product_id` → `products.id`; variants/selling units rejected (`VALIDATION_ERROR`) |
| 2 | base units per pack | `quantity: NUMERIC(18,3), > 0` |
| 3 | fixed price, ≥ 0 | no auto discount; `sum_of_parts` returned as an informational field only |
| 4 | `products.quantity` | Phase 7 stock source of truth + `allow_negative_stock` escape hatch |
| 5 | `PACK_COMPONENT` | one `inventory_movements` row per component line |
| 6 | summary + components | summary line: `product_id NULL`, `pack_id` set, charged; component lines: `pack_id` set, `line_total` 0 (uncharged) |
| 7 | no historical rewrite | editing/deleting a pack never touches past `sale_lines` |
| 8 | saleable = active & not archived | `is_active AND archived_at IS NULL`; `DELETE` = soft archive (`archived_at = now()`) |
| 9 | PMP untouched | sales never move PMP; pack cost is not first-class |
| 10 | Phase 8 discount rules | discounts apply to the pack summary line only |
| 11 | no new scopes | pack CRUD reuses `product_view`/`product_create`/`product_update`/`product_archive`; POS sale uses `pos_sale` |
| 12 | implemented pagination wins | `GET /api/v1/packs` returns the standard `{items,total,page,page_size,pages}` envelope |
| 13 | packs are holdable | `HoldCartItem.pack_id` with the same "exactly one target" validator |
| 14 | guarded decrement | per-component `UPDATE … WHERE quantity >= :need`, `rowcount == 0` → `PACK_STOCK_INSUFFICIENT`, row locks held to commit |

---

## 3. Backend

### 3.1 New files

| File | Role |
|---|---|
| `app/api/v1/packs.py` | router: `GET/POST /packs`, `GET/PUT/DELETE /packs/{id}`, `GET /packs/{id}/availability` |
| `app/repositories/pack.py` | persistence only (Phase 7 non-negotiable: no business rules in repositories) |
| `app/schemas/pack.py` | request/response contracts (`PackComponentRequest`, `PackCreateRequest`, `PackUpdateRequest`, `PackResponse`, `PackDetailResponse`, `PackListResponse`, `PackAvailabilityResponse`) |
| `app/services/pack.py` | validation, audit rows, soft archive, availability aggregation |
| `migrations/versions/2026_09_26_1200_d1e2f3a4b5c6_0012_phase10_packs_sale_line_target.py` | extends `sale_lines.target_type` / adds the pack target guard (revision `d1e2f3a4b5c6`, down_revision `c8d4e5f6a1b2`) |
| `migrations/versions/2026_09_27_1200_b7c8d9e0f1a2_0013_phase10_pack_component_selling_unit.py` | fix round: adds `pack_items.selling_unit_id` (FK → `product_selling_units`, `ON DELETE SET NULL`, indexed) + the `selling_unit_name` / `selling_unit_multiplier` snapshots (revision `b7c8d9e0f1a2`, down_revision `d1e2f3a4b5c6`) |
| `tests/unit/test_packs.py` | 71 unit tests (53 core + 18 fix round) |
| `tests/integration/test_pack_concurrency.py` | concurrent component decrement race on real PostgreSQL |

`app/api/v1/router.py` registers the pack router (`+2` lines).

### 3.2 Endpoints

- `GET /api/v1/packs?page=&page_size=&search=&status=` — pagination envelope,
  `status=active|archived|all`, search on name/barcode, ordered by
  `created_at DESC`. Requires `product_view`.
- `POST /api/v1/packs` — 201 + full pack object. Requires `product_create`.
  Validates: non-empty name, `price >= 0` (decimal string), ≥ 1 component,
  each `quantity > 0`, no duplicate `product_id`, component products must
  exist, be base products and not archived.
- `GET /api/v1/packs/{id}` — list object plus resolved `components[]`.
- `PUT /api/v1/packs/{id}` — partial update (any subset); when `components`
  is present it replaces the whole set (same validation). Requires
  `product_update`.
- `DELETE /api/v1/packs/{id}` — soft archive (GATE 8); idempotent. Requires
  `product_archive`.
- `GET /api/v1/packs/{id}/availability?quantity=N` — read-only:
  `saleable`, `max_pack_quantity`, per-component
  `{required_quantity, available_quantity, ok}` and localized `errors[]`.
  Never mutates state.

All decimals are serialized as **JSON strings** (`"250.0"`) — no floats
anywhere on the contract.

### 3.3 Pack sale integration (`app/services/sale.py`, +466/-… lines)

`items[]` now accepts exactly one of `product_id` / `pack_id`:

- **Read-only phase (before the transaction):** `_resolve_line` for product
  lines (unchanged) and `_resolve_pack_line` for pack lines, which expands a
  pack into `[summary, comp1..compN]` and **aggregates component demand
  across all pack lines** in the sale. A pack that is inactive/archived
  raises `PACK_INACTIVE` (422) before anything is written.
- **Totals** are computed over the *charged* lines only (component lines are
  `line_total = 0`); discounts/`pos_discount`/`pos_credit` permission gates,
  idempotency key and the payment pipeline are untouched.
- **One transaction**, order preserved:
  1. `_enforce_debt_ceiling` (Phase 9 rule, still first),
  2. guarded decrement for every component line (`rowcount == 0` →
     `PACK_STOCK_INSUFFICIENT` with the shortage list),
  3. `INSERT sales`,
  4. `INSERT sale_lines` (summary: `product_id NULL`, `pack_id` set,
     charged; components: `pack_id` set, `line_total` 0),
  5. `INSERT inventory_movements` type `PACK_COMPONENT` per component,
  6. `INSERT sale_payments`,
  7. customer balance + `DebtLedgerEntry` when a debt remains.
  Any exception → full rollback and a structured error envelope.

`app/models/sale.py` gained the pack target column/constraint (+13 lines) and
`app/schemas/sale.py` gained `SaleLineRequest.pack_id`, `HoldCartItem.pack_id`
(+61 lines) with the "exactly one target" validator.

### 3.4 Error catalog (codes introduced by Phase 10)

| Code | HTTP | When |
|---|---|---|
| `PACK_INACTIVE` | 422 | selling a pack that is inactive or archived |
| `PACK_STOCK_INSUFFICIENT` | 422 | aggregated component demand exceeds stock; `details = {line_index, pack_id, pack_name, requested_packs, shortages:[{product_id, product_name, required, already_requested, available}]}` |
| `PACK_COMPONENT_DUPLICATE` | 422 | same `product_id` twice in a component list |
| `VALIDATION_ERROR` | 422 | `quantity <= 0`, `price < 0`, empty components, both/neither target, `variant_id` supplied |
| `NOT_FOUND` | 404 | unknown pack id (existing convention, `details.pack_id`) |
| `CONFLICT` | 409 | lost row race on a component decrement (existing) |

Deliberately not introduced: `PACK_NOT_FOUND`, `PACK_COMPONENT_INVALID`,
`PACK_COMPONENT_QUANTITY_INVALID` (covered by existing envelopes — see the
analysis doc §7).

### 3.5 Fix round — component selling units + profitability estimate (backend)

**Issue 1 — a component may pin one of the product's Phase 6 selling units.**

- Wire contract: `PackComponentRequest.selling_unit_id` (nullable). When it
  is set, `quantity` means **quantity in that unit**; the service converts
  once with the existing Phase 6 rule `base = quantity x multiplier`
  (`app/domain/unit_conversions.py::selling_to_base`, quantized to
  `QTY_QUANTUM = 0.001`). Without `selling_unit_id` the legacy meaning
  (base units) is unchanged.
- **GATE 2 is preserved by construction**: `pack_items.quantity` still
  stores BASE units per pack (stock, availability, sale deduction and
  `sum_of_parts` math are untouched, and no legacy row was rewritten). The
  three new nullable columns only remember *how the manager entered it*:
  `selling_unit_id` (FK `pack_items_selling_unit_id_fkey` →
  `product_selling_units.id`, `ON DELETE SET NULL`, indexed) plus the
  `selling_unit_name` / `selling_unit_multiplier` **snapshots**, so a later
  catalog change can never reinterpret an existing pack.
- Validation (reuses the existing envelopes, no new error codes):
  unknown unit → `NOT_FOUND` 404; unit belonging to another product →
  `VALIDATION_ERROR` 422; archived unit → `BusinessRuleError` 422; a unit
  that resolves to `base <= 0` → `VALIDATION_ERROR` 422.
- Responses: `PackComponentResponse` gained
  `selling_unit_id / selling_unit_name / selling_unit_multiplier /
  unit_quantity / base_quantity / avg_cost`; `PackComponentAvailability`
  gained the same unit fields plus `required_unit_quantity` (the
  `required_*` / `available_quantity` base values stay authoritative —
  availability and the sale always deduct the stored base quantity).

**Issue 2 — informational profitability preview from the live PMP.**

- `PackDetailResponse` gained `estimated_cost`, `estimated_profit`,
  `estimated_margin_percent`:
  `cost = Σ(base_quantity × avg_cost)`, `profit = price − cost`,
  `margin = profit / price × 100` (quantized to `Decimal("0.01")`),
  `margin = null` when `price == 0` (never divide by zero).
- `avg_cost` is the Phase 7 authoritative PMP (set to `cost` at product
  creation, `app/services/catalog.py`, default `0`). Nothing is persisted
  and nothing about pricing/stock uses it — display only (GATE 3/9).

**Issue 3 — edit hydration.** `GET /packs/{id}` (the only endpoint that
returns `components[]`) now also returns the unit identity + `unit_quantity`
+ `avg_cost`, which is what the edit dialog hydrates from.

Migration `2026_09_27_1200_b7c8d9e0f1a2_0013_phase10_pack_component_selling_unit.py`
(revision `b7c8d9e0f1a2`) is purely additive — three nullable columns, one
FK and one index; `downgrade` drops them all. `tests/integration/test_migrations.py`
was repointed to the new head (single head, downgrade → `0001_initial` →
re-upgrade, empty autogenerate diff).

---

## 4. Flutter

### 4.1 New files

| File | Lines | Role |
|---|---|---|
| `lib/features/packs/pack_models.dart` | 271 | `PackComponentModel` (+ unit identity, `unitQuantity`, `baseQuantity`, `avgCost`), `PackModel` (`isSaleable`, `components`, `sumOfParts`, `estimated_*`), `PackComponentAvailabilityModel` (+ unit fields, `requiredUnitQuantity`), `PackAvailabilityModel` (`saleable`, `maxPackQuantity`, `errors`), `PackPickResult` |
| `lib/features/packs/packs_providers.dart` | 368 | `packApiCodeMessage`, `PackQuery`, `PacksState`, `PacksNotifier` (search/status/page/page_size, `load`, `fetchDetail`, `fetchAvailability`, `create`, `update`, `archive`), `packsProvider`, `packPickerProvider` |
| `lib/features/packs/packs_screen.dart` | 836 | permission-gated list screen (see 4.2) |
| `lib/features/packs/pack_form_dialog.dart` | 930 | create/edit dialog (unit selector, conversion preview, live estimate) + base-product picker (`/products/search?q=&limit=40`) |
| `lib/features/packs/pack_detail_dialog.dart` | 356 | components table (with stored unit conversion) + availability pre-flight with a quantity field |
| `lib/features/pos/pack_picker_dialog.dart` | 316 | POS picker → `Future<PackPickResult?>` |

### 4.2 Packs screen (`/packs`)

- Route `packs` in `lib/router/app_router.dart`, gated on `product_view`;
  nav destination added next to Products in **all three** nav-rail code paths
  (destinations, selected index, `onDestinationSelected`) so the shell stays
  consistent. No destination and no screen for users without `product_view`.
- Header (`packs-header-title`/`-subtitle`), `packs-add-button` (needs
  `product_create`), toolbar `packs-search-field` / `packs-status-filter` /
  `packs-refresh-button`, table ≥ 800 px wide / cards below, row keys
  `pack-row-*` / `pack-edit-*` / `pack-archive-*`, footer
  `packs-page-size` / `packs-prev-page` / `packs-next-page` / `packs-total`.
- Archive → confirm dialog → `DELETE` → `showPosToast` success.
- Form validation: name required, price ≥ 0, ≥ 1 component, duplicate
  components rejected client-side too (`pack_form_duplicate`).

### 4.3 POS integration

- **`pos_models.dart`**: `CartLine.productId` is now `String?`; added
  `packId`, `componentsSummary`, `isPack`, and `key` =
  `pack:$packId` (else `productId|variantId|sellingUnitId` — a pack key can
  never collide with a product key). `toJson`/`fromJson` carry `pack_id` and
  `components_summary`; `toSaleJson` emits `pack_id` **or** `product_id`,
  never both (GATE 6). `PriceOverrideModel` gained `packId` and an
  `identity` getter (`pack:$packId` else `productId`).
- **`pos_screen.dart`**: `pos-packs-button` in the search row opens the
  picker; `_addPack()` inserts one cart line with `productUnit: 'pack'`,
  `unitName: 'pack'`, `availableStock: pick.maxPackQuantity`; the cart tile
  shows a pack badge (`cart-line-pack-badge-*`) and the component snapshot
  line (`cart-line-pack-components-*`).
- **`pack_picker_dialog.dart`**: search over active packs
  (`packPickerProvider`, `page_size 50`), `pack-option-*` rows, quantity
  field `pack-picker-qty`, and a **read-only availability pre-flight** before
  insertion — `!saleable` → `pack_not_saleable`, `max < qty` →
  `pack_stock_insufficient`, both shown on `pack-picker-error-line` with the
  dialog staying open.
- **`pos_quantity.dart`**: `posSameStockBucket` buckets pack lines by the
  same `packId` only and never mixes them with product lines.
- **`pos_providers.dart`**: price-override product names resolve by line
  index and by `line.key` so pack overrides label correctly.
- **`price_override_dialog.dart`**: all widget keys use `o.identity`
  (product lines keep their legacy keys unchanged).
- **`pos_error_message.dart`**: maps `PACK_INACTIVE` and
  `PACK_STOCK_INSUFFICIENT`; the latter renders the localized headline plus
  the `pack_shortage_detail` line per shortage (placeholders `{product}`
  `{required}` `{available}`), preserving the envelope `code`.

### 4.4 Localization

`lib/core/strings.dart` +86 lines: **27 new pack keys** added to `_arabic`,
`_french` and `_english` (keys: `packs, packs_subtitle, add_pack, edit_pack,
no_packs, no_packs_found, pack_name, pack_detail_title, components,
add_component, select_pack_product, sum_of_parts, pack_requires_components,
pack_component_duplicate, pack_created, pack_updated, pack_archived,
archive_pack_confirm, max_packs, pack_inactive, pack_stock_insufficient,
pack_picker_title, pack_picker_hint, pack_not_saleable, pack_badge,
enter_pack_quantity, pack_shortage_detail`). Arabic strings are real Arabic
script; the shortage pattern keeps all three placeholders in every locale.
`AppStrings.unitLabel('pack', loc)` resolves through the pre-existing `pack`
key — no new unit infrastructure.

Fix round added **4 more keys** to `_arabic` / `_french` / `_english`:
`estimated_cost`, `estimated_profit`, `estimated_margin`,
`estimate_pmp_note` (31 pack keys in total).

### 4.5 Fix round — unit selector, live estimate, hydration (Flutter)

- **`pack_form_dialog.dart`** (rewritten component row):
  - `_loadUnits(productId)` fetches `GET /api/v1/products/{id}/selling-units`
    (archived filtered out) once per product; a failed lookup never blocks
    the form (base unit only).
  - Per-row `DropdownButton` `pack-component-unit-$i` with options
    `pack-component-unit-option-{unitId|base}-$i`, base unit first
    (`is_base_unit`, else multiplier `1`, else the product's own `unit`).
    Products with no selling units render a static base-unit label — never
    an empty dropdown.
  - Conversion preview `pack-component-preview-$i`:
    `2 Box = 48 piece` (shown only when the multiplier ≠ 1).
  - The quantity field edits the quantity **in the selected unit**; the
    payload sends `{product_id, selling_unit_id, quantity}` with `quantity`
    still expressed in that unit (backend converts) — a null
    `selling_unit_id` keeps the legacy base-unit contract.
  - Live estimate box `pack-estimate` with `pack-estimated-cost` /
    `-profit` / `-margin` and `pack-estimate-note`; recomputes on price,
    quantity and unit changes; `sum_of_parts` now resolves components to
    base units before pricing them.
- **`packs_screen.dart`**: `_edit(pack)` now fetches
  `GET /packs/{id}` (`fetchDetail`) and opens the dialog with the DETAIL
  payload — the list row carries no components, so without this the edit
  dialog silently dropped every component row. A failed fetch shows the
  `pack-edit-error-toast` instead of an empty form.
- **`pack_models.dart`**: `PackComponentModel`
  (`sellingUnitId/Name/Multiplier`, `unitQuantity`, `baseQuantity`,
  `avgCost`, `hasSellingUnit`, `multiplier`), `PackComponentAvailabilityModel`
  (same unit fields + `requiredUnitQuantity`) with base-unit fallbacks for
  legacy payloads, and `PackModel.estimatedCost/Profit/MarginPercent`.
- **`pack_detail_dialog.dart`**: each availability row can render the
  stored conversion (`pack-availability-component-unit-$i`, e.g.
  `2 Box = 48 piece`) while the quantity/available columns stay in BASE
  units; the detail header shows `pack-detail-estimate` +
  `pack-detail-estimate-note` when the backend sent an estimate.
- **`pack_picker_dialog.dart`**: the cart `componentsSummary` and the list
  subtitle are now built from the **live availability payload**
  (`availability.components`) so they show the pinned unit
  (`Sugar (2 Box)`) instead of the component list of the list row.

---

## 5. Tests

### New (33 core + 21 fix round + 1 bugfix = 55)

| File | Tests | Covers |
|---|---|---|
| `test/unit/pack_models_test.dart` | 23 | pack/availability model parsing, `PackPickResult`, `packApiCodeMessage`, `CartLine` pack key/`toSaleJson`/`toJson`/`fromJson`/`copyWith`, `posSameStockBucket`, `PriceOverrideModel.identity`; fix round: pinned-unit components (base + unit quantities, `avg_cost`), legacy components (no unit identity → base), availability unit fields, `PackModel.estimated_*` (present and absent) |
| `test/unit/packs_localization_test.dart` | 5 | 31 keys × ar/fr/en, Arabic script, shortage placeholders |
| `test/widget/packs_screen_test.dart` | 7 | list load (`GET /packs`), empty state, archive confirm → `DELETE`, form validation, edit → `GET /packs/{id}` hydration by name with the pinned unit, two permission cases (no `product_view`, no `product_create`) |
| `test/widget/pack_form_dialog_test.dart` | 15 | fix round: unit selector + options, conversion preview (`2 Box = 48 piece`), payload with `selling_unit_id` + quantity-in-unit, base-unit-only product, live estimate (price/qty/unit changes, zero price → no margin), edit hydration (pinned unit + unit quantity, untouched PUT, legacy base quantity + null unit), detail conversion line, ar/fr/en labels, RTL rendering; bugfix: a priced component pair previews `420 / 80 / 16%` and never `100%` |
| `test/widget/pos_pack_cart_test.dart` | 4 | picker opens with active packs; adding a pack yields exactly one pack line with badge/summary/components and a `toSaleJson` carrying `pack_id` (no `product_id`); `saleable=false` and `max_pack_quantity < qty` both block before the cart |

### Existing suites that constrain this change (all green)

`test/widget/pos_screen_test.dart` (CartLine key/price-override
compatibility), `test/unit/pos_cart_test.dart`,
`test/widget/products_screen_test.dart`, `test/widget/auth_shell_test.dart`
(nav rail), `test/unit/constants_test.dart` (locale key parity), backend
`tests/unit/test_packs.py` (78), `tests/integration/test_pack_concurrency.py`,
`tests/integration/test_migrations.py` (updated for the new head).

### Bugfix round — 100% margin preview (15 new: 14 backend + 1 Flutter)

| File | Tests | Covers |
|---|---|---|
| `tests/unit/test_packs.py` → `TestPackProfitabilityBugfix` | 7 | the required estimate contract: **420 / 80 / 16** (avg_cost 240×1 + 180×1, price 500), **1020 / −20 / −2** (240×2 + 180×3, price 1000), price `0` → cost+profit kept and margin `null`, legacy component (`selling_unit_id` null) costs its base quantity, a selling-unit **multiplier change never re-prices** the pack (48×5 = 240 before and after 24→12), estimate reads the PMP and **never** `product.cost` (150 vs 60), and the end-to-end symptom: a component saved with a real cost is no longer previewed at 100% (0 → 240 → margin 52, `/products/search` agrees) |
| `tests/unit/test_inventory_pmp.py` → `TestPMPFollowsNominalCost` | 3 | `cost` edit reseeds the PMP while it still mirrors the nominal cost; a cost filled in after create seeds it; a receipt-owned PMP (1×100 + 3×200 = 175) is never rewritten by a cost edit |
| `tests/integration/test_migrations.py` → `TestPhase10AvgCostBackfillMigration` | 4 | head is `c9d0e1f2a3b4`; a legacy zero-PMP row is seeded from the nominal cost (and is idempotent); a PMP owned by an explicit receipt is left alone; a `cost = 0` row stays 0 |
| `test/widget/pack_form_dialog_test.dart` | 1 | the live preview reports **16%** for two priced components (420 cost / 80 profit) and is asserted to be **never `100%`** |

---

## 6. Verification log

Closing run (final, all gates green):

```
python -m pytest tests -q                      → 681 passed, 3 warnings in 277.77s
pytest tests/unit/test_packs.py                → 78 passed in 39.92s
pytest tests/unit/test_inventory_pmp.py        → 54 passed
pytest tests/integration/test_migrations.py    → 37 passed   [real PostgreSQL]
flutter test                                   → 877 passed in 01:25
flutter analyze                                → No issues found! (ran in 8.2s)
flutter build windows --debug                  → √ built …\Debug\supermarket_pos.exe
python -m alembic current                      → c9d0e1f2a3b4 (head)
python -m alembic heads                        → c9d0e1f2a3b4 (head)   [single head]
dev DB backfill                                → products WHERE cost > 0 AND avg_cost = 0: 7 → 0
```

---

## 7. Known limitations / deliberate deferrals

- Returns, exchanges and voids of pack lines: **Phase 12**.
- Pack cost, PMP impact, pack margin and any pack column in reports:
  **Phase 14** (GATE 9: pack cost is not first-class). The fix round's
  `estimated_cost/profit/margin` is an **informational preview computed
  from the live PMP** — it is never persisted, never used for pricing,
  totals, stock or reports, and it changes whenever a component's PMP
  changes.
- A component's selling unit is a *snapshot* (name + multiplier pinned at
  definition time): editing the catalog later does not reinterpret an
  existing pack, and the sale always deducts the stored base quantity.
- The pack detail dialog shows availability on demand; the POS picker does a
  second pre-flight at insertion and the server re-checks authoritatively at
  checkout — the client never trusts its own stock math.
- Archived/inactive packs stay visible in history and in the management list
  (filterable), but the picker only lists `status=active`.
- `allow_negative_stock` behaves exactly as in Phase 8 for components.
- No pack-specific permission scopes were added (GATE 11) — a user who can
  manage products can manage packs.

---

## 8. Human QA checklist (PASS)

**Result: PASSED** — all items below executed and accepted at close.

1. Products → Packs: create a pack (2+ components), edit price/components,
   archive it, switch the status filter — all in AR, FR and EN.
2. POS: `Packs` → search → pick a pack → set quantity → confirm the
   availability banner → add. Badge + component snapshot visible; quantity
   merges into one line; stock guard blocks over-selling.
3. Checkout a pack-only sale for cash, card and debt (with and without a
   customer ceiling) — verify the invoice line, the component stock drop in
   Products, and the `PACK_COMPONENT` movements.
4. Attempt to sell an archived pack (expect the localized `PACK_INACTIVE`
   headline) and an out-of-stock pack (expect `PACK_STOCK_INSUFFICIENT` with
   the shortage lines).
5. Permission checks: a user without `product_view` sees no Packs nav
   destination; `product_view` without `product_create` sees no `Add pack`.
6. Hold/restore a cart containing a pack; confirm the restored line keeps its
   badge and checkout works.
7. Fix round — component units: add a component, pick one of the product's
   selling units (e.g. `Box ×24`), enter `2`, and confirm the preview
   `2 Box = 48 piece`; save, reopen the pack and confirm the unit and the
   quantity `2` are still selected (not `48`).
8. Fix round — estimate: change price / quantity / unit and watch
   `Estimated cost`, `Estimated profit`, `Estimated margin` update live;
   set the price to `0` and confirm the margin row disappears (no
   `Infinity`/`NaN`); verify the note says it is a PMP estimate.
9. Fix round — legacy pack: open a pack created before the fix round and
   confirm its component rows still show their product names and base
   quantities (nothing dropped, nothing rescaled).
10. Bugfix — profitability preview: pick a component that has a real cost
    (e.g. `lait` / `jnina`) and confirm the preview is **not** `100%`
    (cost = its PMP, margin = profit/price); a component that genuinely has
    no cost still previews 100% by definition.

---

## 9. File inventory

**Backend (new):** `app/api/v1/packs.py`, `app/repositories/pack.py`,
`app/schemas/pack.py`, `app/services/pack.py`,
`migrations/versions/2026_09_26_1200_d1e2f3a4b5c6_0012_phase10_packs_sale_line_target.py`,
`migrations/versions/2026_09_27_1200_b7c8d9e0f1a2_0013_phase10_pack_component_selling_unit.py`,
`migrations/versions/2026_09_27_1300_c9d0e1f2a3b4_0014_phase10_avg_cost_backfill.py`,
`tests/unit/test_packs.py`, `tests/integration/test_pack_concurrency.py`.

**Backend (modified):** `app/api/v1/router.py`, `app/models/catalog.py`
(`PackItem` unit columns), `app/models/sale.py`, `app/schemas/pack.py`,
`app/schemas/sale.py`, `app/services/pack.py` (unit validation/conversion,
snapshot persistence, detail estimate, availability unit fields),
`app/services/sale.py`, `app/services/catalog.py` (bugfix: a `cost` edit
reseeds a PMP that still mirrors the nominal cost),
`tests/integration/test_migrations.py`, `tests/unit/test_inventory_pmp.py`.

**Flutter (new):** `lib/features/packs/{pack_models,packs_providers,packs_screen,pack_form_dialog,pack_detail_dialog}.dart`,
`lib/features/pos/pack_picker_dialog.dart`,
`test/unit/{pack_models_test,packs_localization_test}.dart`,
`test/widget/{packs_screen_test,pos_pack_cart_test,pack_form_dialog_test}.dart`.

**Flutter (modified):** `lib/core/strings.dart`,
`lib/features/packs/{pack_models,packs_screen,pack_form_dialog,pack_detail_dialog}.dart`,
`lib/features/pos/{pos_models,pos_providers,pos_quantity,pos_error_message,pos_screen,price_override_dialog}.dart`,
`lib/router/app_router.dart`.

**Docs:** `docs/PHASE_10_PACKS_ANALYSIS.md` (decision record),
`docs/PHASE_10_IMPLEMENTATION.md` (this file).

---

## 10. Bugfix round — the profitability preview showed a 100% margin

**Symptom.** The pack profitability preview (`Estimated cost` /
`Estimated profit` / `Estimated margin`) reported **margin = 100%** even
when the component products carried a real cost.

### Trace (component row → preview)

```
pack_items.quantity                          6.000   base units, GATE 2 (unchanged)
  → PackRepository.component_rows(pack)            selectinload(component_product)
  → PackService.to_detail_response(pack)
        base        = to_money(item.quantity)      6.000
        avg_cost    = to_money(product.avg_cost)   0.000    <- defect
        cost       += quantize_money(base * avg_cost)  0.000
        profit      = price - cost               100.000
        margin      = profit / price * 100             100.00
  → JSON {estimated_cost, estimated_profit, estimated_margin_percent}
  → PackModel.estimated*            → pack_detail_dialog
  → pack_form_dialog._estimatedCost (same avg_cost inputs) → live preview
```

Formula (unchanged — this is the contract the regression tests pin):

```
estimated_cost           = SUM(pack_items.quantity * products.avg_cost)
estimated_profit         = pack.price - estimated_cost
estimated_margin_percent = profit / price * 100    (null when price = 0)
```

Decimal only; money quantized to NUMERIC(18,3), the percentage to 0.01.
`products.cost`, selling prices and selling-unit multipliers are **never**
inputs of the estimate.

### Root cause — data, not the formula

Migration `0008` (Phase 7) added `products.avg_cost` with
`NOT NULL DEFAULT 0` and **never backfilled it** from `products.cost`, so
every product row created before 2026-09-23 13:00 reported a PMP of `0`
while `cost` held a real value. On this dev DB: `lait` (150), `jnina`
(200), `fromage` ×2 (190), `Smoke PU Product` (6), `#35 Smoke Product` ×2
(8) — **7 of 21 products**. A pack built from those components computes
`estimated_cost = 0` → `profit = price` → exactly **100.00%**.

Second (latent) path: `ProductService.update` copied `cost` straight
through `setattr`, so a cost entered after creation (the product form
resends `cost` on every save) never reached the PMP.

Evidence on the dev DB (`before → after alembic upgrade head`):
`SELECT count(*) FROM products WHERE cost > 0 AND avg_cost = 0` → **7 → 0**.

### Fix (display untouched)

1. **`migrations/versions/2026_09_27_1300_c9d0e1f2a3b4_0014_phase10_avg_cost_backfill.py`**
   — seeds `avg_cost = cost` where `avg_cost = 0 AND cost > 0` **and** no
   positive `adjustment` / `package_receive` movement carrying an explicit
   `unit_cost` owns the average (sales, package breaks and cost-less
   adjustments only *read* the PMP, so they never block the seed).
   Idempotent; `downgrade` is a no-op — this is data, not schema.
2. **`app/services/catalog.py::ProductService.update`** — while the average
   still **mirrors** the nominal cost (`avg_cost == cost`, i.e. no receipt
   has ever priced this stock) a `cost` edit reseeds it, exactly the rule
   `create` already applies; once receipts own the average a cost edit never
   rewrites it.

No Flutter change and nothing added to hide the number: the preview still
reads `products.avg_cost` only. A component whose PMP is genuinely `0`
(e.g. stock received without a cost) still previews 100% — that is the
arithmetic of a free component, not this bug.

### Regression tests

15 new (14 backend + 1 Flutter) — detailed in §5:
`TestPackProfitabilityBugfix` (7: 420/80/16, 1020/−20/−2, price 0 → null,
legacy null unit, multiplier change never re-prices, PMP ≠ `cost`,
cost-edit repair of the 100% symptom),
`TestPMPFollowsNominalCost` (3), `TestPhase10AvgCostBackfillMigration` (4)
and one widget test asserting `16%` and never `100%`.

---

**State:** APPROVED / CLOSED — Technical verification PASS / Human QA PASS /
single git commit created. **Phase 10 complete, no known blocker.**
Phase 11 (Purchases & Suppliers) **not started**.
