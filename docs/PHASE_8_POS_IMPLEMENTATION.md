# Phase 8 Implementation — Backend POS Core + Flutter POS UI (Steps 2–3)

**Date:** 2026-09-24  
**Status:** ✅ CLOSED — automated verification PASS; human QA PASS (15/15); **committed** as `phase-8: complete POS core`  
**Spec:** `docs/PHASE_8_POS_ANALYSIS.md` (§18 — 16 binding decisions)  
**Scope:** Backend atomic sale checkout/holds/favorites/history + customer search; Flutter POS/Checkout UI  
**Out of scope:** Phase 12 (returns/voids), Phase 10 (packs), customer CRUD management API, PDF/printing (Phase 15 scope — text print only in UX FIX #4)

> **Phase 8 approved and closed** (§23.8). Phase 9 may start in a separate task.

---

## 1. Architecture

```
HTTP POST /api/v1/sales
    ↓
RequestIDMiddleware → FastAPI (sales_router / pos_router)
    ↓
Depends(require_permission(POS_SALE))  →  401 / 403
    ↓
Pydantic CreateSaleRequest (StrictBaseModel; client_request_id required)
    ↓
SaleService.create_sale
    ├── resolve lines (read-only; server price wins)  →  price_overrides[]
    ├── compute totals (Decimal; line_discount ≠ invoice_discount)
    ├── RBAC: pos_discount if any discount > 0; pos_credit_sale if debt > 0
    ├── ONE transaction:
    │     guarded stock decrement (rowcount; variant-only)
    │     sales + sale_lines
    │     inventory_movements type=sale (source_document_id=sale_id)
    │     sale_payments
    │     customer.balance + DebtLedgerEntry (if debt > 0)
    └── re-read after commit → SaleCreateResponse
    ↓
Structured error envelope {error:{code,message,request_id}}
```

**Files:**

| Layer | Path |
|---|---|
| Models | `app/models/pos.py` (PosHold, ProductFavorite); `app/models/sale.py` (+client_request_id) |
| Migration | `migrations/versions/2026_09_24_1000_a9b0c1d2e3f4_0009_phase8_pos_core.py` |
| Schemas | `app/schemas/sale.py` |
| Repository | `app/repositories/sale.py` |
| Service | `app/services/sale.py` |
| API | `app/api/v1/pos.py`; registered in `app/api/v1/router.py` |
| Tests | `tests/unit/test_pos_sale.py` |

---

## 2. API Endpoints

| Method | Path | Permission | Notes |
|---|---|---|---|
| POST | `/api/v1/sales` | `pos_sale` (+`pos_discount` if discount, +`pos_credit_sale` if debt) | Atomic checkout; `X-Device-ID` optional header |
| GET | `/api/v1/sales` | `pos_sale` | Paginated history (page, page_size ≤ 100) |
| GET | `/api/v1/sales/by-invoice/{n}` | `pos_sale` | Reprint lookup |
| GET | `/api/v1/sales/{sale_id}` | `pos_sale` | By UUID |
| POST | `/api/v1/pos/cart/validate` | `pos_sale` | Stateless re-check; no mutation |
| POST | `/api/v1/pos/holds` | `pos_sale` | Snapshot only |
| GET | `/api/v1/pos/holds` | `pos_sale` | Optional `device_id` filter |
| GET | `/api/v1/pos/holds/{id}` | `pos_sale` | |
| POST | `/api/v1/pos/holds/{id}/restore` | `pos_sale` | Revalidate stock/prices; no reserve |
| DELETE | `/api/v1/pos/holds/{id}` | `pos_sale` | 204 |
| GET | `/api/v1/pos/favorites` | `pos_sale` | |
| POST | `/api/v1/pos/favorites` | `pos_sale` | Idempotent add |
| DELETE | `/api/v1/pos/favorites/{product_id}` | `pos_sale` | Idempotent remove |

**Note:** Step 2 brief listed `GET /customers/search` — deferred to Step 3 because no `/customers` API exists yet in backend (credit tests seed `Customer` rows directly). Documented as known limitation.

---

## 3. Request/Response Contracts

### CreateSaleRequest (required fields)

```json
{
  "client_request_id": "uuid-or-unique-string ≤100 chars",
  "payment_method": "cash|card|partial|credit",
  "items": [
    {
      "product_id": "uuid",
      "variant_id": null,
      "selling_unit_id": null,
      "quantity": "2.000",
      "unit_price": null,
      "line_discount": "0.000"
    }
  ],
  "invoice_discount": "0.000",
  "paid": "0.000",
  "customer_id": "uuid|null",
  "device_id": "optional"
}
```

### SaleCreateResponse

- `id`, `invoice_number`, `total`, `subtotal`, `paid`, `change`, `debt`
- `payment_method`, `idempotent_replay`, `price_overrides[]`
- `lines[]` (unit_price, qty, discounts, totals, stock_before/after)
- `payments[]`

**Decimal serialization:** money/qty as strings in JSON (Flutter parses with Decimal/num).

---

## 4. Transaction Boundary

Single `BaseService.transaction()` around ALL of:

1. Guarded stock UPDATE (`WHERE quantity >= ?`, rowcount check)
2. INSERT `sales`
3. INSERT `sale_lines`
4. INSERT `inventory_movements` (`type=sale`, `source_document_id=sale_id`)
5. INSERT `sale_payments`
6. UPDATE `customers.balance` + INSERT `DebtLedgerEntry` (only if debt > 0)

Any exception → full rollback → structured error. **Never** commit partial sale.

Idempotency race: unique index on `sales.client_request_id`; IntegrityError → rollback → re-fetch winner → return with `idempotent_replay=true`.

---

## 5. Pricing Policy (server authoritative)

- Client may send `unit_price` for weighted/custom price; **server always resolves** from product/variant/selling-unit catalog.
- Mismatch is **non-fatal**: reported in `price_overrides[]` so cashier can see; sale uses server price.
- Zero price (`0`) is valid (free item). Negative price → 422 ValidationError.
- Price/stock revalidated at checkout (not trusted from cart snapshot).

---

## 6. Discounts

- `line_discount` per line (absolute or % — schema uses absolute money for Phase 8; percent conversion is UI concern).
- `invoice_discount` on header — **separate field**, applied after line discounts (per §18 decision: keep fields separate; do not merge).
- Totals: `subtotal = Σ line_gross`; `discount = line_discounts + invoice_discount`; `total = max(0, subtotal - discount)`.
- RBAC: if any discount > 0 → require `pos_discount` (admin/manager/cashier have it; enforced only when actually used).

---

## 7. Stock Behavior

- Guarded UPDATE with `rowcount == 1` else ConflictError (concurrent sale).
- **Variant line:** decrement `product_variants.quantity` ONLY — parent `products.quantity` untouched (§18).
- `allow_negative_stock=false` (default): WHERE `quantity >= qty`.
- Captures `stock_before`/`stock_after` per resolved line (multi-line same product handled).
- Archived product → BusinessRuleError 422 before any stock mutation.
- Sales **never** call `POST /inventory/adjust`; movements written directly in same tx.

---

## 8. Variant Stock

- `variant_id` set → resolve variant; `quantity_base = selling_to_base(qty, variant/selling_unit)`.
- Stock check + decrement on variant row only.
- Wrong variant ownership (variant not of product) → ValidationError.
- Tests: `test_h_i_variant_sale_decrements_variant_only` asserts parent quantity unchanged.

---

## 9. Payments & Debt

| method | paid | debt rule |
|---|---|---|
| cash | ≥ total → change = paid − total | debt must be 0 |
| card | = total | debt must be 0 |
| partial | 0 < paid < total | debt = total − paid; customer_id required |
| credit | paid = 0 | debt = total; customer_id required |

- Credit/partial without customer → ValidationError.
- Debt path: `customer.balance += debt` + `DebtLedgerEntry(entry_type="sale", reference_sale_id)` **same transaction**.
- `pos_credit_sale` required when debt > 0.

---

## 10. Holds

- Table `pos_holds`: user_id, device_id, customer_id, cart_snapshot JSON, invoice_discount, note.
- **Snapshot only — NO stock reserve** (§18). Restore revalidates stock/prices; may fail with ConflictError if stock gone.
- Delete idempotent-friendly (404 if missing).

---

## 11. Favorites

- Table `product_favorites`: (product_id, user_id) unique.
- Manual add/remove only — **no auto-ranking**, must not block core POS (checkout does not touch favorites).
- Idempotent: add existing → 200 same; remove missing → 204/ok.

---

## 12. RBAC

| Scope | Who | Enforced |
|---|---|---|
| `pos_sale` | admin, manager, cashier | All POS endpoints (dependency) |
| `pos_discount` | admin, manager, cashier | Service: only if discount > 0 |
| `pos_credit_sale` | admin, manager, cashier | Service: only if debt > 0 |

No new permissions invented — reuses Phase 4 scopes already seeded.

---

## 13. Idempotency

- `client_request_id` **required** on CreateSaleRequest (min_length=1, max=100).
- Fast path: SELECT by key before tx → return original + `idempotent_replay=true`.
- Race: unique index `ix_sales_client_request_id`; IntegrityError → rollback → re-fetch → replay response.
- Stock decremented **once** only (verified by test_w).

---

## 14. Validation Summary

| Case | Result |
|---|---|
| empty items | 422 |
| unit_price < 0 | 422 |
| qty ≤ 0 | 422 |
| insufficient stock | 409 ConflictError |
| archived product | 422 |
| missing product/variant | 404 |
| credit without customer | 422 |
| discount without pos_discount | 403 |
| debt without pos_credit_sale | 403 |
| duplicate client_request_id | 200/201 same sale id, replay=true |

---

## 15. Bug Fixes Found During Step 2

| ID | Symptom | Root cause | Fix |
|---|---|---|---|
| **BUG-001** | 500 `Decimal - float` on sale | ORM post-sync evaluate: `Product.quantity - float(qty)` | Use pure Decimal in UPDATE; `synchronize_session=False` via `execution_options` |
| **BUG-002** | Discount/credit always 403 | Service raised AuthorizationError whenever discount/debt present, **without** checking `user.has_permission` | Check permission; raise only if missing |
| **BUG-003** | Forced failures returned DATABASE_ERROR | `BaseService.transaction()` mapped **all** non-AppError via `translate_db_error` → DatabaseError | Only SQLAlchemyError → DatabaseError; other exceptions re-raised → unhandled → INTERNAL_ERROR |
| **BUG-004** | Rollback tests re-raised to pytest | TestClient default `raise_server_exceptions=True` | POS test client uses `raise_server_exceptions=False` |
| **BUG-005** | Autogenerate wanted to drop `ix_pos_holds_created_at` | Migration created index not on model (TimestampMixin has no index) | Removed index from migration |
| **BUG-006** | Stale HEAD asserts (Phase 6/7 tests) | Expected `f1a2b3c4d5e6` after adding 0009 | Updated HEAD_REV to `a9b0c1d2e3f4` |
| **BUG-007** | 3 stale HEAD asserts after adding 0010 | `TestPhase6SellingUnitsMigration` / `TestPhase6PurchasePackagingMigration` / `TestPhase7InventoryPMPMigration` pinned `HEAD_REV = a9b0c1d2e3f4` | Updated HEAD_REV to `b7c3d4e5f6a1` (integration 33 passed) |

---

## 16. Exception Policy

- **No** `except: pass` in POS service/api (audit: `except` blocks re-raise or convert to AppError with log).
- ValidationError/BusinessRuleError/ConflictError/NotFoundError/AuthorizationError → structured 4xx.
- SQLAlchemyError inside tx → DatabaseError (500 envelope, no raw SQL leak).
- Unexpected exceptions (RuntimeError etc.) → rollback, re-raise → FastAPI handler → `INTERNAL_ERROR` 500 (not mislabeled DATABASE_ERROR).
- IntegrityError on idempotency key → ConflictError **or** winner replay (logged).

---

## 17. Tests

`tests/unit/test_pos_sale.py` — **62 tests**, checklist A–AI:

| Group | Coverage |
|---|---|
| A–C | normal multi-line, zero-price |
| G–I | guarded stock, variant-only decrement |
| J–L | line / invoice / both discounts |
| M–P | cash/card/partial/credit payment matrix |
| R–S | debt balance + ledger atomic |
| U–V | rollback payment / debt failure (forced) |
| W | idempotent duplicate |
| X–AD | archived, structured errors, missing product, PMP unchanged, movement links, price override |
| AE–AG | holds list/restore/no-reserve |
| + | favorites, cart validate, barcode-style product lookup via API |
| AH | UX FIX #11 sale line snapshots: base / variant / selling unit capture, server-derived names (client-supplied ignored), rename + multiplier + archive survival, both-fields 422 rejection + both snapshots on one row, legacy NULL rows, rollback leaves no rows, idempotent replay does not duplicate |
| AI | UX FIX #12 (FIX #1) `unit_summary_from_lines`: empty / unit-less input → `null`, per-unit summation in first-seen order, 3-group cap + `+N`, trailing-zero trimming, plus an API test proving `GET /sales` and `GET /sales/{id}` carry `unit_summary` without touching totals |

Run: `python -m pytest tests/unit/test_pos_sale.py -q` → 62 passed.

---

## 18. Performance

- Single transaction; guarded UPDATE (no SELECT-then-UPDATE race window beyond row lock).
- No N+1 on checkout path (lines resolved once; movements batched per line).
- Index: unique `client_request_id` (idempotency fast path).
- No PDF/print in tx (print deferred to Flutter Step 3, async).

---

## 19. Known Limitations / Deferred

| Item | Reason | Phase |
|---|---|---|
| Line discount percent vs absolute UI helper | Absolute money in schema; payment dialog accepts absolute | Step 3 (absolute only) |
| Void / return | P12 | Phase 12 |
| Packs in cart | P10 | Phase 10 |
| Offline queue / sync | Not in Phase 8 | Later |
| PDF invoice generation | Not in Phase 8 | Later |
| Customer CRUD management UI | Only search picker for credit sales | Phase 9 |

### Step 3 — customer search (added)

| Item | Status |
|---|---|
| `GET /api/v1/customers/search` + `GET /api/v1/customers` | Done (`app/api/v1/customers.py`, `app/schemas/party.py`) |
| Permission `customer_view` | Enforced |
| Tests `tests/unit/test_customers_search.py` | **5 passed** |

---

## 20. Verification (automated)

### Backend (from `new_app/backend`, sequential)

```
python -m compileall app          → OK
python -m pytest tests/unit/test_pos_sale.py -q  → 62 passed
python -m pytest tests/unit/test_customers_search.py -q  → 5 passed
python -m pytest tests -q         → 529 passed, 0 failed, 3 warnings (pre-existing SAWarning)
python -m alembic current         → b7c3d4e5f6a1 (head)
```

### Flutter (from `new_app`)

```
flutter analyze                   → No issues found
flutter test                      → 653 passed, 0 failed
flutter build windows --debug     → √ Built build\windows\x64\runner\Debug\supermarket_pos.exe
```

| Metric | Value |
|---|---|
| Backend total | **529 passed, 0 failed** |
| POS suite | **62 passed** |
| Customer search | **5 passed** |
| Flutter total | **653 passed, 0 failed** |
| Flutter analyze | **clean** |
| Flutter windows debug build | **success** |
| New migration | **0010** `b7c3d4e5f6a1` |
| Git | **NOT committed** (snapshot at Step 2 — final state in §22 / §23.8) |

---

## 21. Step 3 — Flutter POS UI

### 21.1 Files created

| File | Role |
|---|---|
| `new_app/lib/features/pos/pos_models.dart` | `PaymentMethod`, `CartLine`, `PosCustomer`, `HoldModel`, `FavoriteModel`, `PriceOverrideModel`, `CheckoutResult`, `SaleHistoryItem`, `CartTotals`, `PaymentMath` |
| `new_app/lib/features/pos/pos_providers.dart` | `posDeviceIdProvider`, `PosCartNotifier` (idempotent checkout + holds), `PosSearchNotifier`, `CustomerSearchNotifier`, `HoldsNotifier`, `FavoritesNotifier`, `SaleHistoryNotifier` |
| `new_app/lib/features/pos/pos_screen.dart` | Main POS screen: responsive layout, shortcuts, product grid, cart panel |
| `new_app/lib/features/pos/payment_dialog.dart` | Cash/card/partial/credit payment UI |
| `new_app/lib/features/pos/customer_picker_dialog.dart` | Customer search picker (F6) |
| `new_app/lib/features/pos/holds_dialog.dart` | Held sales list + restore/delete |
| `new_app/lib/features/pos/invoice_discount_dialog.dart` | Invoice-level discount (F7) |
| `new_app/lib/features/pos/sale_history_dialog.dart` | Sale history (F11): list rows → Sale Detail → Print/Reprint/Copy invoice/Refresh/Close (UX FIX #4 Part B) |
| `new_app/lib/features/pos/sale_detail_dialog.dart` | **NEW** — Sale Detail dialog, receipt text builder, print preview, print actions (UX FIX #4 Part B) |
| `new_app/lib/features/pos/print_service.dart` | **NEW** — `PrintService` abstraction + `WindowsPrintService` (temp .txt → PowerShell `Out-Printer`), `printServiceProvider` |
| `new_app/lib/features/pos/pos_option_picker.dart` | **NEW (UX FIX #6)** — Reusable `PosOptionPickerDialog`: card-based option list, arrow/Enter/number-key navigation, selected-state badge, localized hint + Cancel/Select-and-add actions |

### 21.2 Files modified

| File | Change |
|---|---|
| `new_app/lib/core/strings.dart` | ~80 POS localization keys × ar/fr/en (+ 4 UX FIX #6 keys: `select_and_add`, `picker_keyboard_hint`, `select_unit_hint`, `select_variant_hint`; + 7 UX FIX #7 keys: `cart_title`, `cart_no_items`, `lines_word`, `units_word`, `currency`, `qty_decrease`, `qty_increase`); removed 12 duplicate keys |
| `new_app/lib/features/products/variant_picker.dart` | Rewritten onto `PosOptionPickerDialog` (UX FIX #6) |
| `new_app/lib/features/products/selling_unit_picker.dart` | Rewritten onto `PosOptionPickerDialog`; base option first (UX FIX #4/#6) |
| `new_app/lib/router/app_router.dart` | `/pos` → `PosScreen`; nav rail POS entry gated on `pos_sale` |
| `new_app/backend/app/api/v1/customers.py` | **NEW** — `GET /search`, `GET ""` |
| `new_app/backend/app/schemas/party.py` | **NEW** — `CustomerResponse`, `CustomerListResponse` |
| `new_app/backend/app/api/v1/router.py` | Registered `/customers` prefix |

### 21.3 Architecture

```
PosScreen (ConsumerStatefulWidget)
  ├── CallbackShortcuts (F4–F12)
  ├── posSearchProvider   → GET /api/v1/products/search?q&limit=40
  ├── favoritesProvider   → GET/POST/DELETE /api/v1/pos/favorites
  ├── posCartProvider     → client cart; POST /api/v1/sales (idempotent)
  ├── customerSearchProvider → GET /api/v1/customers/search
  ├── holdsProvider       → GET/POST/DELETE /api/v1/pos/holds, restore
  └── saleHistoryProvider → GET /api/v1/sales
```

**Responsive layout** (`posLayoutModeFor`):
- **Wide ≥ 1100**: favorites sidebar + product grid + cart panel (380px)
- **Medium 800–1099**: product grid + cart panel (340px)
- **Narrow < 800**: stacked workspace; cart is a full-height drawer when open (toggle button), workspace returns when closed

### 21.4 POS workflow

1. **Search/scan** (F4 or barcode scanner types + Enter) → product card
2. **Tap product** → add decision tree (see §21.9): direct add if no choices; else variant and/or selling-unit picker → add `CartLine` to cart
3. **Edit line**: qty / line discount / remove
4. **Customer** (F6) → picker → set for credit/partial
5. **Invoice discount** (F7, requires `pos_discount`)
6. **Payment** (F8) → choose method → validate with `PaymentMath` → `POST /sales` with `client_request_id` UUID (reuse on retry; clear cart only on 2xx)
7. **Hold** (F9) / **Held sales** (F10) / **History** (F11)
8. **Clear** (F12) → confirmation required (`clear-cart-confirm`); Escape never clears cart

### 21.5 Keyboard shortcuts

| Key | Action |
|---|---|
| F4 | Focus search |
| Enter | Add product / submit scan |
| F6 | Customer picker |
| F7 | Invoice discount |
| F8 | Payment dialog |
| F9 | Hold sale |
| F10 | Held sales |
| F11 | Sale history |
| F12 | Clear cart (confirm) |
| + | Add 1 unit to the last active cart line (never exceeds stock) — works from the numpad, from the main row, and while the search or a cart qty field has focus |
| - | Remove 1 unit from the last active cart line (never below 1) — same three sources as `+` (main row, numpad subtract) and claimed in the same two fields; the character is never inserted there |
| * | Quantity **input** dialog for the last active cart line: the confirmed value **replaces** the quantity, never multiplies (`24 → * → 3 = 3`) — works from the main row, the numpad multiply key, and while the search or a cart qty field has focus (the character is never inserted there) |
| Escape | Close dialog only (never clears cart) |

**Add → focus (Phase 8 FIX #1):** a successful add leaves the keyboard on the line it wrote — the just-added (or merged) line becomes active *and* its quantity field takes focus, so `+` keeps working without the mouse. A rejected add (stock / invalid quantity) never moves focus.

### 21.6 API endpoints used by Flutter

| Method | Path | Permission |
|---|---|---|
| GET | `/api/v1/products/search` (`q`, `barcode`, `limit`) | `product_view` |
| GET | `/api/v1/products/{id}` | `product_view` |
| GET | `/api/v1/products/{id}/variants` | `product_view` |
| GET | `/api/v1/customers/search` (`q`) | `customer_view` |
| POST | `/api/v1/sales` | `pos_sale` (+`pos_discount`, `pos_credit_sale`) |
| GET | `/api/v1/sales` | `pos_sale` |
| GET/POST | `/api/v1/pos/favorites` | `pos_sale` |
| DELETE | `/api/v1/pos/favorites/{product_id}` | `pos_sale` |
| GET/POST | `/api/v1/pos/holds` | `pos_sale` |
| GET/DELETE | `/api/v1/pos/holds/{id}` | `pos_sale` |
| POST | `/api/v1/pos/holds/{id}/restore` | `pos_sale` |

### 21.7 Tests added

| File | Count | Coverage |
|---|---|---|
| `test/unit/pos_cart_test.dart` | 21 | CartLine, PaymentMethod, PaymentMath, model JSON, price override response, **PosCatalogViewMode key contract**, **unit presentation snapshot (UX FIX #3)** |
| `test/unit/pos_localization_test.dart` | 6 | POS keys × ar/fr/en (incl. override dialog + **catalog_view_grid/list** + **base_price** + **sale_detail/print keys**), real translations |
| `test/widget/pos_screen_test.dart` | 141 | Responsive 600–1920, cart/pay UI, F12 confirm, i18n, RTL, permission snackbar, price override dialog, **add decision tree ×5**, **view mode ×4**, **image fallback ×3**, **responsive catalog toggle ×4**, **lookup safety ×6**, **cart selling unit presentation ×10**, **base-unit option ×7**, **sale detail/print ×13**, **print preview ×3**, **segmented grid/list ×6**, **responsive sizes ×5**, **picker localization ar/fr/en ×3 (UX FIX #6)**, **totals panel & pay ×11**, **cart header/empty/line controls ×8**, **themes ×3 + RTL/LTR ×3 (UX FIX #7)**, **responsive cart totals ×5**, **selling-unit totals invariant ×1 (UX FIX #7)**, **final cart sizing ×24 (UX FIX #8)** |
| `test/widget/pos_option_picker_test.dart` | 13 | **UX FIX #6** — card badges/titles, first-selected, ArrowDown/Right/Up, Enter, digit1/digit3, confirm/cancel buttons, digit-guard vs EditableText, keyboard hint labels, no overflow at 800×600 with 6 options, Arabic RTL labels |
| **Flutter POS total** | **157** | |
| **Full Flutter suite** | **441** | all green |

Widget keys for automation: `pos-screen`, `pos-search-field`, `pos-cart-empty`, `pos-cart-empty-icon`, `pos-cart-empty-f4`, `pos-cart-header`, `pos-cart-counts`, `pos-cart-actions`, `pos-cart-panel`, `pos-cart-lines`, `pos-totals-panel`, `pos-total-label`, `pos-total-value`, `pos-subtotal-value`, `pos-discount-value`, `pos-pay-button`, `pos-product-grid`, `pos-product-list`, `pos-product-{id}`, `pos-product-name-{id}`, `pos-product-price-{id}`, `pos-view-mode-toggle`, `pos-view-mode-grid`, `pos-view-mode-list`, `pos-lookup-error`, `pos-lookup-error-message`, `pos-lookup-error-retry`, `cart-line-*`, `cart-line-summary-{key}`, `cart-line-base-qty-{key}`, `cart-line-base-price-{key}`, `cart-line-qty-{key}`, `cart-line-qty-dec-{key}`, `cart-line-qty-inc-{key}`, `cart-line-discount-{key}`, `cart-line-total-{key}`, `cart-line-remove-{key}`, `pos-discount-button`, `pos-hold-button`, `pos-holds-button`, `pos-history-button`, `pos-select-customer`, `clear-cart-confirm`, `payment-dialog`, `payment-method-*`, `payment-paid-input`, `payment-submit`, `customer-picker-dialog`, `holds-dialog`, `sale-history-dialog`, `invoice-discount-dialog`, `toggle-cart`, `price-override-dialog`, `price-override-explanation`, `price-override-client-*`, `price-override-server-*`, `price-override-acknowledge`, `variant-picker`, `selling-unit-picker`, `selling-unit-base`, `sale-row-{id}`, `sale-row-meta-{id}`, `sale-row-total-{id}`, `sale-detail-dialog`, `sale-detail-invoice`, `sale-detail-body`, `sale-detail-error`, `sale-detail-line-{i}`, `sale-detail-line-total-{i}`, `sale-detail-status`, `sale-detail-date`, `sale-detail-subtotal`, `sale-detail-discount`, `sale-detail-total`, `sale-detail-paid`, `sale-detail-debt`, `sale-detail-payment`, `sale-detail-customer`, `sale-detail-technical`, `sale-copy-invoice`, `sale-detail-refresh`, `sale-reprint`, `sale-print`, `sale-detail-close`, `print-preview-dialog`, `print-preview-body`, `print-preview-confirm`, `print-error`, `pos-option-picker-hint`, `pos-option-picker-cancel`, `pos-option-picker-confirm`, `pos-option-selected`, `pos-option-badge-{n}`, `{optionKey}-title/price/secondary`, `{dialogKey}-subtitle`, `pos-product-meta-{id}`, `pos-product-add-{id}`.

### 21.8 Price override confirmation (review fix)

When `POST /api/v1/sales` returns non-empty `price_overrides[]`:

1. `_afterCheckoutSuccess` shows `PriceOverrideDialog` (`barrierDismissible: false`) **before** the success snackbar.
2. Dialog lists for each override: **product name** (enriched client-side from cart line before clear), **client/displayed price** (`requested_unit_price`), **server price** (`applied_unit_price`), and an explanation that the final sale uses the server price.
3. Cashier must tap **I acknowledge and continue** (`price-override-acknowledge`); Escape/barrier cannot dismiss.
4. Overrides are never hidden — empty list skips the dialog; non-empty always blocks until ack.
5. Backend pricing policy unchanged (server still wins; response shape unchanged).
6. Same `client_request_id` is not regenerated for the attempt (checkout already completed; id cleared only on success with the cart).
7. Cart is cleared **only because checkout succeeded** (`PosCartState(lastResult: result)`), never as a reaction to seeing overrides. Cart stays intact while the payment dialog is open and until the server returns 2xx.
8. Existing success flow after ack: success snackbar → search/favorites reload.

Files: `lib/features/pos/price_override_dialog.dart` (new), `pos_models.dart` (`productName`, `withProductName`, `withPriceOverrides`), `pos_providers.dart` (name enrichment before clear), `pos_screen.dart` (`_afterCheckoutSuccess`), `strings.dart` (5 keys × ar/fr/en).

### 21.9 UX FIX #6 — Professional POS UI (option picker, catalog, layout)

**Reusable option picker (`pos_option_picker.dart`):**

- `PosOptionCard {optionKey, title, price, secondary, enabled}` + `PosOptionPickerDialog(title, subtitle?, options, dialogKey, onConfirm(int))`.
- Card grid: number badge (`pos-option-badge-{n}`), title (`{key}-title`), price (`{key}-price`), secondary line; selected card shows check icon (`pos-option-selected`).
- Keyboard: **Arrow keys** move selection (vertical follows column count; Left/Right also move); **Enter** confirms selected (`pos-option-picker-confirm` = "Select and add"); **digits 1–9** (and numpad) select **and** confirm immediately — digit handling is disabled while an ancestor `EditableText` has focus (`_editableTextHasFocus`); **Escape** cancels.
- Dialog does **not** pop itself — callers pop in `onConfirm`/`onCancel` (variant picker → variant result; selling-unit picker → base or unit pick).
- Preserves existing keys: `variant-picker`, `variant-{id}`, `selling-unit-picker`, `selling-unit-base`, `selling-unit-{id}`, empty/error states.
- Grid uses fixed `mainAxisExtent` (92/96) to avoid overflow at 1-column narrow layouts; hint row (`pos-option-picker-hint`) shows localized keyboard help (`picker_keyboard_hint` / `select_unit_hint` / `select_variant_hint`).

**Segmented Grid/List toggle:**

- Custom segmented control (`pos-view-mode-toggle`) replaces two loose IconButtons; keys `pos-view-mode-grid` / `pos-view-mode-list` preserved; still does not reload catalog; persists `pos_catalog_view_mode`.

**Product card / list redesign:**

- Grid card (`_gridCard`): image or text-first hero (`_heroName`, single `pos-product-name-{id}`), price, stock pill, favorite heart; compact add affordance.
- List row (`_listTile`): thumbnail + name + `pos-product-meta-{id}` (price · unit · stock) + `pos-product-add-{id}` action; RTL-safe.

**Cart / totals / top-bar polish:**

- Cart footer: `Material(elevation: 4)` totals block; primary **PAY** button height 52; compact secondary action buttons; values use theme colors only.

**Focus management:**

- After variant/selling-unit pickers close, focus returns to search field (`_searchFocusFocusNode` / `pos-search-field`) so scan-and-type continues uninterrupted; number-key guard keeps text fields editable.

**Responsive behavior (tested):**

- Wide ≥1100 / medium 800–1099 / narrow <800 unchanged in structure; new tests cover 600×500, 800×600, 1024×768, 1366×768, 1920×1080 with no RenderFlex overflow; narrow cart open/close verified via `toggle-cart` before switching view modes.

### 21.9a UX FIX #2 — POS product catalog (focused correction)

**Add-to-cart decision tree (no choice = no dialog; lookup failure ≠ empty):**

| Case | Lookups | Behavior |
|---|---|---|
| A | **empty successful** variants + **empty successful** selling units | Direct add: qty 1, base unit, catalog price, no dialog |
| B | empty variants, active selling units | Selling-unit picker → quantity dialog → add |
| C | multiple active variants | Variant picker (multi). Single active variant **auto-selects** (no dialog) |
| D | after variant chosen | Empty units success → direct add with `variantId`; units exist → selling-unit picker |
| E | **any lookup API failure** | **NO direct add**, **NO cart mutation**; localized error snackbar + **Retry** (`pos-lookup-error`, `pos-lookup-error-retry`); product stays out of cart until lookups succeed |

Lookups: `GET /api/v1/products/{id}/variants` (`page_size=50`) and `GET /api/v1/products/{id}/selling-units` (`include_archived=false`); both return `{items,total}` on **2xx**.

**Safety rule (checkout):** HTTP **2xx with `items: []`** means “no choices” → continue with direct-add logic. **Network error / timeout / 401 / 403 / 404 / 409 / 422 / 5xx** (or any non-success / parse failure) is **never** treated as empty: `_ChoicesLookup.fail` → localized message (`network_error_retry`, `backendErrorMessage`, or mapped status key) + `retry` action that re-invokes `_addProduct`. Active (`!is_archived`) items only. Lookups never reload the catalog list. Backend pricing/checkout/idempotency unchanged.

**Grid / List view mode:**

- `PosCatalogViewMode {grid, list}` via `posCatalogViewModeProvider` (`PosCatalogViewNotifier`).
- Default **grid**. Toggle is a **segmented control** (`pos-view-mode-toggle` wrapping `pos-view-mode-grid` / `pos-view-mode-list`) beside the search field — presentation only; **does not reload** the catalog.
- Persisted in SharedPreferences key **`pos_catalog_view_mode`** (`grid`/`list`); restored async on notifier construction.
- Narrow layout: cart drawer replaces the workspace when open (covers the toggle) — close cart first to switch view mode.

**Image / text-first cards:**

- `ProductModel.imagePath` is a local absolute file path; `_tryProductImage` uses `File.existsSync()` (+ `Image.file` with `errorBuilder`).
- Missing / empty / invalid path → **text-first** card: large centered name (`pos-product-name-{id}`), price (`pos-product-price-{id}`), stock, favorite — never a blank placeholder.
- Valid existing file → image area in grid card / 40px thumbnail in list row; name/price/stock/favorite retained. Decode failure falls back via `errorBuilder`.

**List view:** compact `ListView.separated` (`pos-product-list`), RTL-safe `AlignmentDirectional`/`Directionality`.

Files: `pos_providers.dart` (`kPosCatalogViewModeKey`, enum, notifier, provider), `pos_screen.dart` (`_addProduct` decision tree, `_ChoicesLookup`, `_lookupErrorMessage`, `_showLookupError`, `_fetchActiveVariants`, `_fetchActiveSellingUnits`, `_ViewModeToggle`, `_ProductCatalog`, `_tryProductImage`, `_heroName`), `strings.dart` (`catalog_view_grid`, `catalog_view_list` × ar/fr/en; reuses existing `retry` / error keys).

Tests: 5 decision-tree cases + **empty success → direct add**, **variants failure (500 + network) → no mutation + error/retry**, **empty units → direct add**, **units failure → no mutation + error/retry**, **retry recovers → then add**; 4 view-mode cases; 3 image cases; responsive catalog toggle at 600×500 / 800×600 / 1366×768 / 1920×1080.

### 21.10 Cart selling unit presentation (UX FIX #3)

**Rule:** when a cart line was added with a selling unit, show **both** the selected selling unit + its selling price **and** the base unit + base unit catalog price (informational only). Never create an extra base-unit cart line; totals still use selling-unit price only.

Layout per cart line (`_CartLineTile`):

```
name
[qty TextField] [ 1 Box × 550            ] 550.00   ← summary (bodyMedium w600): "{qty} {selectedUnit} × {unitPrice}"
                 [ 10 Piece               ]          ← base qty  (qty × multiplier) {baseUnit}
                 [ Base price: 60 / Piece ]          ← base price (info only) {basePrice} / {baseUnit}
[discount TextField row]
```

**Model (`CartLine`):**

- `baseUnitPrice` (String?) — snapshot of `variant?.price ?? product.price` at add time (or product price on direct add).
- `unitMultiplier` (String?) — selling-unit multiplier; `null` on direct base add (so base-info block hidden — Rule A).
- Both are **display-only**: included in `copyWith`, **not** in `toJson` (API contract unchanged); `fromJson` unchanged (hold restore without them → base info hidden, graceful).
- Totals **unchanged**: `lineTotal = qty * unitPrice`; `PosCartState.totals` untouched. `2 Box × 550 = 1100`, never `20 × 60 = 1200`.

**Base-info block shown iff:** `sellingUnitId != null && unitMultiplier != null && baseUnitPrice != null && baseQty > 0`.

**Labels:** selected unit via `AppStrings.unitLabel(line.unitName, loc)` (free text `Box` falls back raw; `piece` → Piece/Pièce/قطعة); base unit via `unitLabel(line.productUnit, loc)`. Localization key `base_price` ×3 locales (en `Base price`, fr `Prix de base`, ar `السعر الأساسي`).

**Widget keys:** `cart-line-summary-{key}`, `cart-line-base-qty-{key}`, `cart-line-base-price-{key}` (existing `cart-line-total-{key}` etc. unchanged). Helpers `_fmtQty` / `_fmtPrice` format whole numbers without decimals.

Files: `pos_models.dart` (`baseUnitPrice`, `unitMultiplier`, copyWith), `pos_screen.dart` (`_addCartLine` new params, `_CartLineTile` rebuild, `_fmtQty`/`_fmtPrice`), `strings.dart` (`base_price` ×3).

Tests: 10 widget cases (base product no base-block; selling unit summary + base qty + base price; 1 Box→10 Piece; 2 Box→20 Piece; total 1100≠1200 + base price independent; variant+Box base=variant price; Arabic RTL; French; English; no extra base-unit line) + 1 unit test (snapshot survives copyWith; toJson omits `base_unit_price`/`unit_multiplier`; total uses selling-unit price).

### 21.11 Selling-unit base option (UX FIX #4 Part A)

**Rule:** when a product (or chosen variant) has a selling unit with units configured, the selling-unit picker **always shows the product's BASE unit as the first synthetic option** in addition to all active selling units — never a fake DB record.

**Rule:** when a product (or chosen variant) has a selling unit with units configured, the selling-unit picker **always shows the product's BASE unit as the first synthetic option** in addition to all active selling units — never a fake DB record.

- `SellingUnitPickResult = { sellingUnitId, unitName, unitPrice, quantity, unitMultiplier, isBaseUnit }`.
- Base option: `sellingUnitId = null`, `unitName = product.unit` (or seeded from configured `isBaseUnit` unit's name when `productUnit` is null), `unitPrice = productPrice` (or variant price when a variant was chosen), `isBaseUnit = true`.
- `pos_screen._addProduct` maps base pick → `sellingUnitId: null`, `unitName: product.unit`, `unitMultiplier: null`, `unitPrice: pick.unitPrice` (catalog/variant price). Selling-unit pick → real DB id, its multiplier, its selling price.
- Quantity dialog for base uses synthetic `SellingUnitModel(id: kSellingUnitBaseKey, multiplier '1', isBaseUnit: true, sellingPrice = productPrice)`.
- Configured units with `isBaseUnit = true` are filtered out of the picker list (their name seeds the synthetic label when needed) — no duplicate base rows.
- Bare picker (no unit, no price, no items) still shows `selling-unit-picker-empty` (Phase 6 empty-state test preserved).
- **Totals unchanged**: base line total = qty × base price; selling line total = qty × selling price (UX FIX #3 presentation rules still apply).

Tests: base shown first; base price 60; selling price 550; base pick → `sellingUnitId null` + `unitPrice '60'` + `unitName 'piece'` + `unitMultiplier null`; selling pick → its id; variant price 12 on base; Arabic `base_unit` label.

### 21.12 Sale history → detail → print (UX FIX #4 Part B)

**Sale History (`sale_history_dialog.dart`):** richer rows — invoice · date · payment method · customer indicator · status · total (`sale-row-{id}`, `sale-row-meta-{id}`, `sale-row-total-{id}`). Tap row → `showSaleDetailDialog(saleId, invoiceNumber)` → on close, reload list. Refresh + pagination preserved.

**Sale Detail (`sale_detail_dialog.dart`):** fetches `GET /api/v1/sales/{id}` (permission `pos_sale`) → `SaleDetail` model (`pos_models.dart`: `SaleDetailLine`, `SalePayment`, `SaleDetail` mirroring `SaleResponse` from `backend/app/schemas/sale.py`). Shows: invoice number, status, date, lines (qty × unit · price · line total), subtotal, invoice discount, total, paid, debt, payment method, customer, technical section (secondary ID). Actions: **Print / Reprint** (`sale-print` / `sale-reprint`), **Copy invoice** (`sale-copy-invoice` → snackbar `invoice_copied`), **Refresh**, **Close**.

**Print flow:** Print/Reprint → **print preview** dialog (`print-preview-dialog`, `print-preview-body`, `print-preview-confirm`) showing receipt text from `buildReceiptText(SaleDetail, locale)` → confirm → `printService.printText`. `PrintService` is abstract (`WindowsPrintService`: write temp `.txt` → `powershell.exe … Out-Printer` → cleanup); injectable via `printServiceProvider` for tests.

**Print failure:** `PrintServiceException` → localized `print_failed` (+message) shown as `print-error` on the detail dialog; **never** show success snackbar; sale remains intact (print runs outside the sale transaction); retry via Print/Reprint again.

**Known limitation:** cashier user is not persisted by the API; raw UUIDs only in secondary technical section. Line display data comes entirely from the historical snapshots stored on `sale_lines` (see §21.12b) — no catalog lookup at read time.

Tests: row → detail; invoice; lines; discount; totals; payment; customer; print/reprint buttons; print failure localized + no success snackbar + printer not called; failed print sale intact; copy invoice snackbar; close; print preview receipt data; unit + price in preview; totals unaltered.

### 21.12b UX FIX #11 — Sale line historical snapshots

**Problem:** Sale History / Sale Detail / receipt re-read today's catalog (product name, variant name, selling unit name/multiplier). Renaming, re-pricing, changing a multiplier or archiving a product retroactively changed how old receipts looked.

**Backend (`new_app/backend`):**

| Item | Value |
|---|---|
| Migration | `migrations/versions/2026_09_24_1400_b7c3d4e5f6a1_0010_phase8_sale_line_snapshots.py` (revision **`b7c3d4e5f6a1`**, down_revision `a9b0c1d2e3f4`) |
| Columns on `sale_lines` | `variant_name` `String(100)` NULL, `selling_unit_name` `String(50)` NULL, `selling_unit_multiplier` `Numeric(18,3)` NULL |
| Behavior | Additive upgrade (3 `op.add_column`), fully reversible downgrade; **no FK** on the new columns so snapshots survive rename / multiplier change / archive |
| Capture | `SaleService.create_sale` fills the three fields **server-side** from the already-resolved `ln.variant` / `ln.selling_unit` — never from the client body (client `SaleLineRequest` has no name fields; unknown keys are ignored by `StrictBaseModel`) |
| Domain rule unchanged | A line still carries `variant_id` **or** `selling_unit_id`, never both → 422 with `selling_unit_id` (asserted by test 4; both snapshots shown by inserting a row directly) |
| Base-unit sale | All three columns `NULL` (no variant, no selling unit) |
| Response | `SaleLineResponse` gains the same three nullable fields; populated by `_to_create_response` (`to_decimal(...) if ... is not None else None`) |
| Legacy rows | Rows written before 0010 keep `NULL` → API returns `null` → UI falls back to the previous presentation |

**Flutter (`new_app`):**

- `SaleDetailLine` (`pos_models.dart`): nullable `variantName`, `sellingUnitName`, `sellingUnitMultiplier` (decimal kept as a string, matching the other money/qty fields) + `baseQuantity` getter (`quantity × multiplier`, `null` when either is unparseable).
- `sale_detail_dialog.dart` line tile: product name → stored variant (key `sale-detail-line-variant-{i}`) → `qty unit × price DA` (key `sale-detail-line-qty-{i}`) → when a selling unit is stored: `Base: {qty} {unit}` (key `sale-detail-line-base-{i}`); line total key unchanged (`sale-detail-line-total-{i}`), outer tile key `sale-detail-line-{i}` unchanged.
  - The selling-unit label is the **raw stored name** (like a product name); only the base-unit label is localized (`AppStrings.unitLabel` / `base`).
- `buildReceiptText`: `Product (Variant)  qty unit  price  total`, plus a `Base: 48 piece` row for selling-unit lines; totals still come from the server snapshot (never recomputed). *(The label was `Base Unit:` until UX FIX #12 shortened it to `Base:`.)*
- `strings.dart`: new key `variant` (ar `المتغير`, fr `Variante`, en `Variant`) added to `posKeys` in `test/unit/pos_localization_test.dart`.

**Tests:**

| Suite | Added |
|---|---|
| `backend/tests/unit/test_pos_sale.py` | **+9** `TestSaleLineSnapshots`: base / variant / selling-unit capture, both-fields rejection + both snapshots on one row, client-supplied names ignored, rename + multiplier change + archive survival, legacy NULL rows, rollback leaves no rows, idempotent replay does not duplicate (file 53 passed at that point; **62** after UX FIX #12) |
| `new_app/test/unit/sale_line_snapshots_test.dart` | **+12** model parsing (legacy/variant/variant-unit/JSON-number multiplier/ignored keys) + receipt text (base, variant, selling unit, Arabic, fractional base qty, totals untouched) |
| `new_app/test/widget/pos_screen_test.dart` | **+4** snapshot rendering (base/variant/selling unit), **Sale Detail does not call catalog APIs** (path-recording via new `recordPaths` param on `_mockDio`), legacy line without snapshot keys, Arabic labels with raw stored names |
| `new_app/test/unit/pos_localization_test.dart` | `variant`, `base_unit`, `selling_unit` added to `posKeys` |

**Verification (at UX FIX #11; current totals in §20 / §22):** backend `compileall` OK, `pytest tests -q` → 520 passed / 0 failed, `alembic current` → `b7c3d4e5f6a1 (head)` (applied on the dev Postgres, additive + reversible); Flutter analyze clean, `flutter test` → 556 passed / 0 failed, `flutter build windows --debug` → success.

### 21.13 UX FIX #7 — Cart and totals visual redesign

**Dedicated totals panel (`_PosTotalsPanel`, key `pos-totals-panel`):**

- Elevated rounded card at the cart bottom: Subtotal (muted neutral) → Invoice discount (amber `AppColors.warning`) → divider → **TOTAL** (dominant) → full-width **PAY** button.
- TOTAL label 16–18 px semibold (`pos-total-label`); value 32–40 px w800 in `colorScheme.primary` (`pos-total-value`, e.g. `800.00 DA`); scales down on short viewports (600×500 / 800×600) via `MediaQuery` height so the sticky footer never overflows.
- PAY button height 52 (44 on very short viewports), icon + `payment_shortcut` + amount + `currency` (`DA`); disabled when cart empty or checkout pending (muted disabled colors); spinner while `checkoutPending`.
- Subtotal/discount values use theme outline / `AppColors.warning` only — no hardcoded colors outside `AppColors`.

**Cart header & empty state:**

- Header (`pos-cart-header`): `🛒` + `cart_title` + `pos-cart-counts` (`N lines · M units`, or `cart_no_items` when empty) + compact clear (`pos-clear-cart`).
- Empty state: `pos-cart-empty-icon` (🛒) + `cart_empty` + `cart_empty_hint` (`pos-cart-empty`) + F4 hint (`pos-cart-empty-f4` = `search_focus`).

**Line tiles:**

- Qty `[-]` (`cart-line-qty-dec-{key}`) / `+` (`cart-line-qty-inc-{key}`) icon buttons around the still-editable qty field (`cart-line-qty-{key}`); decrement disabled at qty ≤ 1; tooltips from `qty_decrease` / `qty_increase`.
- Compact line discount field (`cart-line-discount-{key}`, label `line_discount`); line total on the name row; compact remove icon with `remove_line` tooltip.
- UX FIX #3 presentation unchanged: `cart-line-summary-{key}` (`qty Unit × price`), optional `cart-line-base-qty-{key}` / `cart-line-base-price-{key}` (informational only).

**Secondary actions & scrolling:**

- Compact outlined buttons (`pos-cart-actions`): Discount F7, Hold F9, Holds F10, History F11 (height ≤ 40; Hold disabled when empty).
- **Only** `pos-cart-lines` (or empty state) scrolls inside `Expanded`; header, customer row, stock errors, actions, and totals panel stay fixed.

**Responsive / themes / RTL:**

- Wide ≥1100 / medium 800–1099 / narrow <800 unchanged; no RenderFlex overflow at 600×500, 800×600, 1024×768, 1366×768, 1920×1080 with lines present.
- Dark/light/grey via `AppTheme` — layered `cardColor` surfaces for dark mode.
- RTL-safe: `AlignmentDirectional`, `EdgeInsetsDirectional`; Arabic/French/English labels tested.

**New localization keys (× ar/fr/en):** `cart_title`, `cart_no_items`, `lines_word`, `units_word`, `currency` (`DA`), `qty_decrease`, `qty_increase`.

**Tests (+31 in `pos_screen_test.dart` → file total 117):** totals panel zero values; pay enable/disable; pay label+amount+currency; subtotal/total updates; invoice discount amber; TOTAL primary color + prominence; label fontSize 14–18; pay height; secondary actions compact; hold gate; header counts format; empty state (icon/title/hint/F4); qty ± controls; direct qty edit; line discount → totals; compact remove tooltip; only-lines-scroll structure; dark/light/grey themes; Arabic RTL + French/English LTR; responsive 5 sizes with lines; selling-unit total invariant (2×550 = 1100, one line, base info kept).

**Files:** `pos_screen.dart` (`_CartPanel`, `_PosTotalsPanel`, `_CartLineTile`), `strings.dart` (7 keys ×3), `test/widget/pos_screen_test.dart`, `test/unit/pos_localization_test.dart` (new keys listed).

### 21.13b UX FIX #8 — Final cart sizing correction

**Root cause of prior 800×600 overflow:** workspace `Column` non-flex children (search `Row`) totaled 628px vs viewport 600px → product grid collapsed to height 0 at y=628. `_SearchField` defaulted to `MainAxisSize.max` and expanded under unbounded height; `_ViewModeToggle` segments were unconstrained and could claim ~350px, squeezing search TextField to 15px which then wrapped the barcode hint into a 600px-tall Column.

**Workspace search row fix (`pos_screen.dart`):**

- `_SearchField` Column: `mainAxisSize: MainAxisSize.min` + hint `maxLines: 1` / `TextOverflow.ellipsis`.
- Search row: `Expanded` wraps search with `BoxConstraints(minWidth: 180)`; `_ViewModeToggle` wrapped in `ConstrainedBox(maxWidth: 160)`.
- Toggle segments: `Flexible` + `maxLines: 1` ellipsis so labels shrink under cap instead of overflowing the toggle Row.
- Result at 800×600: search ≥180px wide, toggle ≤160px, workspace non-flex ≈84px, `pos-product-grid` gets full remaining height (516px), no RenderFlex overflow.

**Cart width (`posCartWidthFor` pure function):**

| Viewport | Width |
|---|---|
| ≥1400 | **480** |
| 1100–1399 | **440** |
| 800–1099 | **400** |
| <800 | full-width drawer (unchanged) |

Floors: ≥420 wide / ≥380 medium; catalog workspace remains ≥300px at all tested sizes.

**Cart chrome sizing (readable minimums, never shrink fonts to fit):**

- Header `pos-cart-header` height 72 (64 compact `mediaH < 700`); title 20–22 w700; counts 14–15; clear button 44×44.
- Customer row `pos-customer-row` height 52 (48 compact); name 15 w600; select button ≥44.
- Secondary actions `pos-cart-actions`: **2-column grid** (not Wrap), height 44–46 (44 short/compact), icon 18–20, spacing 8–10.
- Line tile min height 96/88 plain, 112/100 selling-unit; name 15–16 w600 2-line ellipsis; qty buttons 44×44; qty field ≥48 font 15–16; line total 16–17 w700; line discount height 38 font 13.5 with `AppColors.warning` when >0.
- Totals: Subtotal/Discount 14–15; TOTAL label 18–20 semibold; TOTAL value responsive — 46/42 (cap 48) normal, 40 medium, 36 short (`mediaH < 560`); never <36 on normal desktop.
- PAY full-width height 60 / 56 / 50 (short); font 15–17 bold; icon 20–22; spinner + `processing` while pending.
- Layout order unchanged: Header → Customer → Scrollable lines → Secondary Actions → Totals → PAY; only `pos-cart-lines` scrolls.

**Files:** `pos_screen.dart` (`posCartWidthFor`, `_CartPanel`, `_CartLineTile`, `_PosTotalsPanel`, `_SearchField`, `_ViewModeToggle`, workspace search row), `test/widget/pos_screen_test.dart` (`final cart sizing (UX FIX #8)` ×24).

**Tests (+24 → file 141, suite 441):** cart width pure functions + floors at 1024/1366/1920; header title/counts/height; clear ≥44; customer 48–52; product name ≥16; qty controls; line total 16–18; line discount 36–40 + warning; line min heights; totals fonts + TOTAL 36–48; pay full-width font/icon; only-lines-scroll; 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080; Arabic RTL / French / English; dark/light/grey; totals math unchanged; segmented control still tappable.

### 21.13c Final POS Polish — FIX #9

Five discrete polish fixes plus out-of-stock marking (no redesign; pricing/payment/idempotency/stock logic untouched):

1. **Snackbar never covers PAY** — `showPosSnackBar` (`pos_providers.dart`) now uses `BehaviorFlowBehavior.floating` with `margin: EdgeInsets.only(bottom: footerHeight + 16)` where footer = totals+PAY panel height (140 short / 160 medium / 176 normal; the width<800 branch was removed so the wide cart and the narrow drawer share one footer rule). All ~19 ad-hoc `ScaffoldMessenger.showSnackBar` call sites in `pos_screen.dart`, `holds_dialog.dart`, `sale_detail_dialog.dart`, `pos_providers.dart` were converted to `showPosSnackBar`.
2. **Cart product name always visible** — cart line name is 17px (short) / 18px (normal) at `FontWeight.w700`, never truncated below 16px for long names; `key: cart-line-name-{key}` preserved.
3. **Grid/List toggle clarity** — `_ViewModeToggle` wrapped in `ConstrainedBox(minWidth: 190)` (**no maxWidth**: the 190–220 spec range is a minimum width, not a cap — an earlier `maxWidth: 220` caused a 136px RenderFlex overflow and 150 test failures). Segments: horizontal padding 10, icon 18, gap 4, fontSize 13, `TextOverflow.clip`; full labels shown without ellipsis at 1366, icons-only compact mode when workspace is tight.
4. **Held-sales count badge** — `heldCount` flows `_CartPanel` → Material `Badge` on `pos-holds-button`; `onHolds` reloads the hold list after the dialog closes so the badge tracks restore/delete.
5. **Restore removes hold (frontend)** — `HoldsNotifier._restore` pops the dialog with `true` (caller/`ref.listen(posCartProvider)` shows the success snackbar with `key: Key('hold_restored')` — no snackbar from inside the dialog context); backend `SaleService.restore_hold` now deletes the hold **only when `not errors`** (failed restore keeps the hold for retry).
6. **OOS cannot be added** — `_addProduct` early-returns with localized `cannot_add_out_of_stock` snackbar (ar/fr/en added to `strings.dart` + `pos_localization_test.dart`) before any option picker or cart mutation.
7. **OOS marked red** — `_stockLine` renders `out_of_stock` in `AppColors.error`.
8. **OOS disabled visuals** — grid card: red border, reduced elevation, muted image, `InkWell(onTap: null)`; list row: red `out_of_stock` label, disabled add button (`IconButton` disabled) with the row InkWell also `null`.
9. **OOS variants/units disabled** — `variant_picker.dart` disables OOS variant cards (available variants stay usable); an OOS product never opens the selling-unit picker.

**Files:** `pos_screen.dart`, `pos_providers.dart`, `holds_dialog.dart`, `sale_detail_dialog.dart`, `variant_picker.dart`, `strings.dart`, `backend/app/services/sale.py`, `backend/tests/unit/test_pos_sale.py`, `test/widget/pos_screen_test.dart`, `test/unit/pos_localization_test.dart`.

**Tests (+36 → file 177, suite 477):** group `final POS polish (FIX #9)` — snackbar/PAY no-overlap at 600×500 → 1920×1080 (snackbar rect measured minus its transparent margin) + floating fully on-screen; cart name 17/18 w700, ≥16 long, selling-unit + variant lines; toggle ≥190 (no upper bound), segments ≥90, fontSize 13–15, mode switch without reload, Arabic labels; badge shown/empty/after-delete/after-F9/after-restore(0); restore loads cart + closes dialog + removes hold, failed restore keeps hold + error + retry; OOS red badge/tap snackbar/ar+fr+en badge text/list red+disabled/still-adds-when-available/OOS variant disabled/unit picker blocked/cannot-add on disabled path/error-colored stock line/red border; regressions: cart widths, totals+PAY floors, secondary actions 2×44–48, permission snackbar via `showPosSnackBar`, totals math unchanged. Backend: `test_ae` (restore deletes hold, DELETE→404), `test_af`/`test_ag` (failed restore keeps hold).

**FIX #9A — compact feedback toast:** POS feedback notifications are compact floating toasts (`PosToast` + `showPosToast` in `pos_toast.dart`) with adaptive width (≤440, `available−32` when narrow) and a footer-safe vertical offset; they never cover TOTAL/PAY. Rounded 12, semantic color per kind (success/error/warning/info), 3 s duration (4.5 s errors), fade+slide entry 180 ms, close button on errors, and a new toast replaces the visible one (never stacks). Initial right-aligned placement was corrected to bottom-center by FIX #10 below.

**FIX #10 - final polish corrections:** The toast now uses bottom-center positioning (`bottomCenter`-style symmetric margins) above the fixed footer, so it never touches the screen edges, TOTAL or PAY. A successful hold restore removes the hold from the active held list and immediately refreshes the held-count badge (a failed restore — including `ok: false` responses — keeps the hold, keeps the count, shows an error and stays open for retry). Hold snapshots store the full display information in the existing `cart_snapshot` JSON (product name, variant name, unit name, product unit, base price, multiplier), so restored carts show product names and selected unit information directly from the snapshot without any catalog lookup.

**FIX #10B — restored cart names + toast lower position:** Root cause traced empirically against the real database: a live hold created by the old client stored only the 7 legacy keys (`product_id`, `variant_id`, `selling_unit_id`, `quantity`, `unit_price`, `line_discount`, `barcode`) — the display fields were **never sent** (classification A; the backend schema's `extra="ignore"` would additionally drop them, gate B). Fix: `CartLine.toJson()` now emits the full 14-field hold snapshot with explicit nulls, while the checkout payload moved to `CartLine.toSaleJson()` — **`POST /api/v1/sales` payload is unchanged** (display fields are never sent to checkout); backend `HoldCartItem` carries the display fields as optional str (old snapshots/restores still validate); `CartLine.fromJson()` reconstructs name/variant/unit/base metadata into the cart line — restored carts show names straight from the snapshot, no catalog lookup. Restore error handling: HTTP 200 + valid payload is always success (no generic system error); unexpected exceptions are `debugPrint`-logged instead of swallowed; known HTTP errors map through `backendErrorMessage`/`isConnectionError`; `ok:false` responses surface the backend's own validation reasons. The compact toast's bottom offset was lowered from `footer + 16` to `footer + 6` (bottom-center, width/colors/animation unchanged) — as low as possible while TOTAL/PAY stay clear. Verified live (real uvicorn + real PostgreSQL, temporary API session, no PIN/JWT logged): `eau / 1 fardeau ×6 @270` and `luis / variant s @2000` holds → 48/48 checks (all 14 keys stored, display fields round-trip on restore, `ok:true`, hold deleted exactly once → 404 after, list empty); a probe of the already-running dev backend (`:8000`) confirmed it accepts and returns display fields — the remaining live blocker was a stale Flutter build still posting the 7-key payload. **Toast bottom offset (adaptive clearance):** the compact card sits at `24 px` from the bottom **only when** the bottom-centered card ends before the cart side panel's left edge (`posToastClearsCartFor` in `pos_toast.dart`); on narrow viewports (< 800) *and* on medium/wide ones where the cart sits directly under the card (800×600, 1024×768) it keeps the footer-safe `footer + 6` offset, so TOTAL/PAY are never covered (1366×768 → 24 px, cart left 926 vs card right 903). The shared viewport rules moved to the new `new_app/lib/features/pos/pos_layout.dart` (`PosLayoutMode`, `posLayoutModeFor`, `posCartWidthFor`), re-exported by `pos_screen.dart`, so `pos_toast.dart` needs no screen import. Two stale test expectations were aligned with this rule (the never-cover PAY/TOTAL assertions stay; a low 24 px card is accepted when it is horizontally clear of the cart, the same rule the FIX #9 snackbar check already used).

### 21.14 Known limitations (Step 3)

- No PDF invoice generation (Phase 15); text print only (UX FIX #4: OS default printer via temp file).
- No void/return (Phase 12); no packs (Phase 10).
- Customer picker is search-only (no create/edit customer form).
- Price override: mandatory post-checkout confirmation dialog (see §21.8); no pre-submit live price preview.
- Narrow cart drawer is full-height toggle (not bottom sheet) to avoid overflow at 600×500.
- Product images are local filesystem paths only (no remote URL fetch in POS catalog).
- Manual runtime on real barcode scanner / printer **UNVERIFIED** (needs hardware).
- Base unit price on a selling-unit cart line is informational only (shown, never used in totals or checkout payload).
- Flutter builds compiled **before FIX #10B** still post the legacy 7-key hold payload, so holds they create store no display fields and restore with unnamed lines — rebuild/restart the POS app to pick up the snapshot fix.

### 21.15 Manual test checklist (human)

- [ ] Login as cashier with `pos_sale` → open POS from nav rail
- [ ] Search + barcode scan add lines; variant/unit pickers open **only when choices exist** (simple product = instant add)
- [ ] Toggle grid/list; restart app → view mode restored
- [ ] Product without image shows large name text (not empty box)
- [ ] Cash payment: paid ≥ total → change; cart clears; sale in history
- [ ] Price override (client unit_price ≠ server): dialog shows product, both prices, explanation; ack required; then success snackbar
- [ ] Price override without ack: cannot dismiss via barrier/Escape
- [ ] Partial payment with customer: debt recorded
- [ ] Credit payment requires customer
- [ ] Hold → restore → same lines
- [ ] **FIX #10B:** F9 hold (incl. selling unit / variant) → F10 restore shows product name, unit name, base qty + base price from the snapshot; hold gone from list (badge −1); toast sits just above the cart footer with TOTAL/PAY fully visible
- [ ] F12 clear requires confirm; Escape does not clear
- [ ] Arabic RTL POS screen; French; English
- [ ] Resize 600×500 / 800×600 / 1366×768 / 1920×1080 — no overflow (grid and list)
- [ ] Discount button hidden/snackbar without `pos_discount`
- [ ] Lookup failure (network down) on tap-to-add → localized error snackbar + Retry; no silent cart mutation; Retry succeeds after connectivity returns
- [ ] Cart line with selling unit shows selected unit × unit price + base qty + "Base price: X / Base"; line total = qty × selling-unit price only (no extra base-unit line)
- [ ] Selling-unit picker always shows base unit first (with catalog/variant price) plus configured selling units; base pick adds line at base price; selling pick at unit price
- [ ] Sale history row → Sale Detail: invoice, lines, subtotal/discount/total/paid/debt, payment, customer
- [ ] Print/Reprint → print preview → confirm → text sent to default printer; success snackbar only on success
- [ ] Print failure (no printer): localized `print_failed` error, no success snackbar, sale still in history, Retry works
- [ ] Copy invoice number → snackbar; Refresh reloads detail; Close returns to list
- [ ] Arabic RTL Sale Detail / print preview; French; English
- [ ] **UX FIX #6:** Option picker (variant / selling unit) shows card grid with number badges, price, selected check; arrow keys move selection; Enter confirms; digits 1–9 quick-select; Escape cancels; hint row localized
- [ ] **UX FIX #6:** Segmented Grid/List toggle switches catalog without reload; mode survives restart; on narrow, close cart drawer before toggling
- [ ] **UX FIX #6:** Resize 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080 — no overflow in grid and list, option picker, cart footer
- [ ] **UX FIX #6:** After choosing variant/unit, focus returns to search field for next scan; text inputs remain typeable while picker open (digit guard)
- [ ] **UX FIX #6:** Arabic RTL option picker + French + English labels and hint
- [ ] **UX FIX #7:** Cart header shows 🛒 title + `N lines · M units` (empty: `لا توجد منتجات`); empty state shows icon + cart_empty + hint + F4
- [ ] **UX FIX #7:** Totals card: Subtotal muted, Discount amber, TOTAL large primary + `DA`, PAY full-width with icon + amount + F8; PAY disabled when empty
- [ ] **UX FIX #7:** Qty [-]/[+] buttons and direct field edit; compact line discount; compact remove with tooltip
- [ ] **UX FIX #7:** Only cart lines scroll — header, actions, totals, PAY stay fixed while list scrolls
- [ ] **UX FIX #7:** Secondary actions F7/F9/F10/F11 compact (height ≤ 40); Hold disabled when empty
- [ ] **UX FIX #7:** Dark / light / grey themes; Arabic RTL + French + English; resize 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080 — no overflow with lines in cart
- [ ] **UX FIX #8:** Cart width widens with viewport (480 / 440 / 400 / drawer); catalog still usable (≥300px)
- [ ] **UX FIX #8:** Header 64–76px readable; customer row 48–52; secondary actions 2-column grid height 44–46
- [ ] **UX FIX #8:** Cart lines ≥90px (selling-unit ≥100); product name ≥16; qty buttons 40–44; line total 16–18
- [ ] **UX FIX #8:** TOTAL 36–48px never clipped; PAY ≥56 full-width with spinner+processing; only lines scroll
- [ ] **UX FIX #8:** Search field stays ≥180px at 800×600 (no squeeze by Grid/List toggle); no workspace overflow
- [ ] **UX FIX #8:** Resize 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080 with lines — no overflow, no clipped controls
- [ ] **UX FIX #12 (FIX #1):** open Sale History → every row shows the sold units (`2 Box · 48 Piece`) under the invoice; sale without unit data shows no extra line; Arabic/French show the same row in their own unit labels
- [ ] **UX FIX #12 (FIX #1):** receipt + Sale Detail line show `Base: 48 piece` (short label), still localized, totals unchanged
- [ ] **UX FIX #12 (FIX #2):** press `+` while the search field is focused, while a cart qty field is focused, and after typing a quantity by hand → each time the **active** line gains exactly 1; `+` inside a dialog text field (payment, discount, multiplier) is still ignored
- [ ] **UX FIX #12 (FIX #3):** type `10*24` in a cart qty field → line becomes `240`; `10*`, `*24`, `0`, `-2` never corrupt the cart; `Enter` on a bad expression toasts the localized message and rolls the field back
- [ ] **UX FIX #12 (FIX #4):** set a quantity above stock → `pos-qty-stock-error` toast appears **while typing** and the field rolls back; selling-unit lines are checked in base units; a second line of the same product is rejected as soon as the two lines would exceed stock; reducing an over-stock line always works
- [ ] **UX FIX #12 (FIX #5):** kill the backend → every POS error toast is in the active language (English detail may appear as the secondary line only); 401 / 403 / 409 / 422 each show their own localized message
- [ ] **UX FIX #12 (FIX #7):** cart layout, totals panel, PAY button, toast design, grid/list, pickers and adaptive toast placement are unchanged from UX FIX #11 (approved design preserved)

---

### 21.16 UX FIX #12 — Final POS human-QA corrections

Seven items reported after human QA of the shipped POS. Nothing here changes the approved visual design (cart layout, totals, PAY, toasts, grid/list, pickers, adaptive toast rule all untouched), and UX FIX #11's snapshot architecture is preserved.

| # | Report | Root cause | Fix |
|---|---|---|---|
| 1 | Sale History rows show no sold units | The list row only rendered invoice / date / total / payment / status; unit facts exist per line but were never aggregated for the row | Computed `unit_summary` (backend, additive) + `SaleHistoryItem.unitSummaryText()` (client grouping) |
| 2 | `+` unreliable | The shortcut claimed focus only when **no** `EditableText` was focused, so focusing the search field or a qty field swallowed it | Focus rule: `+` also claims focus while the `pos-search-field` or a `cart-line-qty-*` field is focused (`_focusIsPosQuantityInput`) |
| 3 | Quantity expressions (`10*24`) not accepted | Each path did its own `double.tryParse` → expression input was silently dropped | One shared parser (`core/quantity_expression.dart`) used by cart typing, `+`, `*` dialog and the add-flow quantity dialog |
| 4 | Out-of-stock only found at checkout | Stock was validated per line in the UI, never as a total across the cart | Cross-line guard: same product+variant bucket summed in exact scaled math before the mutation is written |
| 5 | Some toasts arrive in English | Raw `backendErrorMessage(e)` / literals were used as toast headlines | `posApiError` / `posApiMessage`: localized headline (401/403/409/422/network/other) + backend text only as `detail:` |
| 6 | Quantity logic spread over files | Five different mutation paths | `pos_quantity.dart` is the single funnel (`parseQuantityExpression` → `canApplyQuantityChange` → apply) |
| 7 | `Base Unit:` too long | Label key `base_unit` | New short key `base` (ar `أساسي`, fr `Base`, en `Base`) |

**Quantity rules (shared, exact):**

- Arithmetic is done on **×1000 scaled integers** (backend `Numeric(18,3)` domain) — `0.1*3` is `0.3`, `2.7 + 1` is `3.7`, never `3.6999999999999996`.
- Grammar: one plain decimal or `a*b`. Accepted: `10`, `2.5`, `0.500`, `10*24`, `10 * 24`. Rejected: `*`, `10*`, `*24`, `10**24`, `10*0`, `0`, `-2`, `10*-4`, `abc`, `1,5`, `1.5.5`, `+5`, `1e3`, empty → `invalid_quantity_expression` (or `quantity_too_large` above 999999).
- Plain numbers keep the cashier's typed text; expressions store the computed product.
- Stock guard: reject iff `otherLines(same bucket) + requested > availableStock` **and** `requested > current` (reducing an over-stock line is always allowed; unknown stock never blocks). Selling-unit lines are converted with their multiplier first.
- Client guard is early and advisory — the backend checkout `UPDATE` remains authoritative.

**Sale History units (FIX #1):**

- Backend: `unit_summary: str | None` added to `SaleResponse`, built by `unit_summary_from_lines()` from display data only (never feeds totals/stock). **No migration** — additive response field.
- Client: `SaleHistoryLine` + `SaleHistoryItem.unitSummaryText(loc)` groups quantities by `AppStrings.unitLabel(sellingUnitName ?? productUnit, loc)` in first-seen order, sums them, joins with ` · `, caps at 3 groups then `+N`; falls back to the API `unit_summary` when the payload has no lines.
- Row: key `sale-row-units-{id}` above the existing `sale-row-meta-{id}`; ListTile is `isThreeLine` (row 88px) so nothing is clipped.

**Files changed:**

| Area | Files |
|---|---|
| New | `lib/core/quantity_expression.dart`, `lib/features/pos/pos_quantity.dart`, `lib/features/pos/pos_error_message.dart`, `test/unit/pos_quantity_test.dart`, `test/unit/pos_toast_localization_test.dart` |
| POS screen | `pos_screen.dart` (focus rules, shared handlers, localized lookup error), `pos_providers.dart` (`setActiveLine`, active-line fallback, localized `_message`), `pos_qty_shortcuts.dart`, `qty_multiplier_dialog.dart`, `holds_dialog.dart`, `customer_picker_dialog.dart`, `sale_history_dialog.dart`, `sale_detail_dialog.dart` |
| Models / strings | `pos_models.dart` (`SaleHistoryLine`, `unitSummaryText`), `core/strings.dart` (`invalid_quantity_expression`, `quantity_too_large`, `base` in ar/fr/en) |
| Add flow | `lib/features/products/quantity_dialog.dart` (same parser + stock rule) |
| Backend | `app/schemas/sale.py` (`SaleResponse.unit_summary`), `app/services/sale.py` (`_display_qty`, `unit_summary_from_lines`) |
| Tests | `pos_screen_test.dart` (+11), `pos_localization_test.dart` (+3 keys), `sale_line_snapshots_test.dart` (Base label), `test_pos_sale.py` (+9) |

**Verification:** backend `compileall` OK, `pytest tests -q` → **529 passed** / 0 failed, `alembic current` → `b7c3d4e5f6a1 (head)` (**no new migration**); Flutter analyze clean, `flutter test` → **616 passed** / 0 failed (suite total at that stage; current total in §22), `flutter build windows --debug` → success.

### 21.17 PHASE 8 FIX #1 — add auto-focus + global `+`

Isolated fix: after a successful add the resulting line owns the keyboard, and `+` reaches the shortcut from every source a Windows layout can produce it. No change to `*`, expression parsing, payment, holds, checkout, printing or the backend; no second shortcut system was added.

| # | Report | Root cause | Fix |
|---|---|---|---|
| 1 | After adding a product the cashier must click the qty field (or nothing useful happens) before the line can be edited / incremented | `_addCartLine` wrote the cart and left focus where it was (search field or nothing); the provider marked the line active (`lastActiveKey`) but its qty field never received keyboard focus | `_PosScreenState._qtyFocusRequest` (`ValueNotifier<String?>`) + `_requestQtyFocus(line.key)` on a successful `applyAddingLine`; the matching `_CartLineTile` claims the request during build and focuses its `FocusNode` in a post-frame callback |
| 2 | `+` fell through to the text input on the main keyboard | The matcher accepted only `character == '+'` and `numpadAdd`; when the platform delivers **no character** for Shift + `=`, nothing matched, so the event was unhandled and the text input *inserted* a `+` instead of incrementing | One matcher, `PosQtyShortcutActivator._isPlusEvent`: `+` character, numpad add, or the layout's `=` key **while a Shift is held and the event carries no character**. Plain `=` and any layout that really types another character there are never hijacked |
| 3 | Found while writing the required merge test: adding a product already in the cart gave `1 + 1 = 3.0` | `applyAddingLine` computed the merged total exactly, then `PosCartNotifier.addLine` merged it a **second** time (and stringified a double) | The existing-line branch now calls `updateLine(key, quantity: mergedTotal)` — the exact scaled total is *set*, not re-added. The new-line branch still uses `addLine` |

**Focus contract**

- Active line (`lastActiveKey`) and keyboard focus are two separate things: the notifier keeps the active line, `_qtyFocusRequest` moves the focus.
- Focus is requested **only when the add succeeded** — a stock or parse rejection keeps the cashier exactly where they were.
- New line and merged line behave identically: the request names the line key, so focus lands on whichever line absorbed the add.
- `_CartLineTile` now carries `key: ValueKey(line.key)` — tile state (controllers, focus node) follows the *line*, not the list position.
- The request is consumed by the tile during build and applied post-frame; anything unclaimed at the end of that frame (off-screen line, cart hidden) is dropped, so focus is never stolen later.

**Files changed:** `pos_screen.dart` (`_qtyFocusRequest`, `_requestQtyFocus`, `_addCartLine` success hook, `_CartPanel`/`_CartLineTile` threading, tile `ValueKey`), `pos_qty_shortcuts.dart` (`_isPlusEvent`), `pos_quantity.dart` (merge branch sets instead of re-adding), `test/widget/pos_screen_test.dart` (+11).

**Tests (+11, group `Phase 8 FIX #1 add focus and global +`):** add focuses that line's qty field · `+` right after the add · repeated `+` · `+` from the search field increments **and never inserts `+`** · second product becomes the focused active line · repeat add merges and focuses the merged line · hand-typed qty + focus change still targets the last active line · empty cart · `+` typed inside a dialog field never touches the cart · stock guard on the auto-focused line · a rejected add never steals focus.

**Known limitation — reported, deliberately NOT fixed here:** when focus leaves the POS subtree entirely (cashier clicks empty page chrome), `FocusManager` parks it on the **route's modal scope**, which sits *above* the `CallbackShortcuts` Focus — from there F4–F12, `+`, `-` and `*` are not on the dispatch path and do nothing until focus re-enters a POS field. This is pre-existing and not specific to `+` (it hits F4–F12 too); fixing it means changing the shortcut/focus architecture, which was out of scope for this isolated fix **and for FIX #2 (§21.18, the `-` shortcut) and FIX #3 (§21.19, the `*` dialog)** — it remains open.

**Verification:** Flutter analyze clean, `flutter test` — **627 passed** / 0 failed (616 + 11), `flutter build windows --debug` — success. Backend untouched: **529 passed**, `alembic current` `b7c3d4e5f6a1 (head)` (no new migration). Nothing committed.

---

### 21.18 PHASE 8 FIX #2 — global `-` decrement

Isolated fix: `-` removes one unit from the last active cart line from every keyboard context, mirroring the verified `+` architecture of §21.17. The existing decrement path and the cart's minimum rule were **reused, not duplicated**; `+`, `*`, quantity expressions, payment, holds, checkout, printing and the backend are untouched, and no second shortcut system was added.

**Root cause report (§14 of the task)**

| # | Report | Root cause | Fix |
|---|---|---|---|
| 1 | `-` never decreased a quantity (the cashier had to click the line's decrease button) | No `PosQtyShortcutKind` existed for `-`: the enum carried only `increment`/`multiply` and the `CallbackShortcuts` map bound those two, so a `-` press had no handler and fell through to whatever had focus | New `PosQtyShortcutKind.decrement` in the **same** activator + one more entry in the **same** `CallbackShortcuts` map (`PosQtyShortcutActivator(decrement): _decrementActiveLine`) — one shortcut system, three keys |
| 2 | Which key event represents `-` on Windows here | Three sources per layout: (a) the key event's **`character == '-'`** (US main row, AZERTY unshifted `-`, any layout that produces the glyph); (b) the dedicated **`numpadSubtract`** key; (c) the main-row **`LogicalKeyboardKey.minus`** when the platform delivers **no character** at all — without (c) the press is unhandled and the focused text input *inserts* a `-`. AZERTY's `-` on `digit6` reaches us only through (a) | `PosQtyShortcutActivator._isMinusEvent`: character → numpad → characterless `minus`. Key down + key **repeat** (holding `-` repeats), key up ignored — same shape as `_isPlusEvent` |
| 3 | Why a focused field must not consume `-` | A `TextField` with focus handles unbound keys itself and would write `-` into the search / quantity text | `accepts` gives `decrement` the **exact same focus gate as `increment`**: `!editableTextHasFocus() \|\| _focusIsPosQuantityInput()` — claimed in the POS search field and cart qty fields (never inserted), ignored in any other text field (dialogs, pickers keep normal typing) |
| 4 | Which existing decrement method is reused | The cart line's decrease button already implements the step: `_CartLineTileState._bumpQty(-1)` | Its computation was extracted once into `_qtyStepText(quantity, delta)` (`pos_screen.dart`) and is now called by **both** `_bumpQty` and the new `_decrementActiveLine`; the result then flows through the same `applyLineQuantity` funnel (`_updateLineQty` / cart buttons / `+` / `*` all share it) |
| 5 | How the active line is resolved | Same as `+`/`*`: `PosCartState.lastActiveKey` → `lastActiveLine`, set by `addLine`/`updateLine`/`setActiveLine` (tap a line, focus its qty field, or the most recent add) | `_decrementActiveLine` reads `lastActiveLine`; `updateLine` rewrites `lastActiveKey` for that key, so the active line is preserved; empty cart → the same `cart_empty` toast as `+` |
| 6 | How dialogs are protected | Dialog routes sit above the base route, so their focus scope owns the key — the `CallbackShortcuts` never sees it | No flags, no checks, no changes: proven by TEST 9 (cart untouched, dialog stays open) |
| 7 | Prior minimum-quantity behavior (unchanged) | The decrease button is `onPressed: qty <= 1 ? null : _bumpQty(-1)`, and `_bumpQty` returns when the step would reach `<= 0` — a line at `1` silently stays `1` (never `0`, never removed) | The shortcut returns from `_qtyStepText(...) == null` for the very same computation: **silent, no toast, quantity stays 1** (`pos-qty-invalid` / `out_of_stock` / `empty-cart` never fire) |

**Architecture notes**

- No stock check is needed when reducing (the shared guard already allows shrinking an over-stock line); `applyLineQuantity` still parses, validates and writes through the single funnel.
- Quantity text is exact scaled math (`×1000`): `5 → 4`, `3.7 → 2.7`, never `2.6999999999999997`.
- Focus contract from FIX #1 is untouched: `_qtyFocusRequest` / `ValueKey(line.key)` / post-frame focus remain exactly as shipped; when the qty field *is* focused, `_CartLineTile.didUpdateWidget` syncs its controller text after the shortcut writes the cart.
- The matcher is character-first, so any Windows layout that types `-` works; a layout whose minus key types something else is never hijacked (it keeps its key).

**Files changed:** `pos_qty_shortcuts.dart` (`PosQtyShortcutKind.decrement`, shared `accepts` case, `matchesEvent` + `_isMinusEvent`, `debugDescribeKeys`), `pos_screen.dart` (`_decrementActiveLine`, shared `_qtyStepText`, `_bumpQty` now calls it, one binding entry, shortcut comment), `test/widget/pos_screen_test.dart` (+11).

**Tests (+11, group `Phase 8 FIX #2 global - decrement`):** basic 5 → 4 · repeated −1 per press · search focused (decrements, `-` never inserted) · qty field focused (decrements, field shows `4`, never `-`) · no TextField focused · multiple lines (only the active line moves, `lastActiveKey` preserved) · select B then focus search → only B · minimum quantity (line stays `1`, button still disabled, no toast) · `-` inside the open `*` dialog leaves the cart untouched · `-` then `+` round-trip on one line · numpad subtract.

**Verification matrix (§15)**

| # | Scenario | Result |
|---|---|---|
| 1 | Basic decrement (5 → 4) | **PASS** |
| 2 | Repeated presses (5 → 4 → 3 → 2) | **PASS** |
| 3 | Search field focused — decrements, search text has no `-` | **PASS** |
| 4 | Qty field focused — decrements, field never receives `-` | **PASS** |
| 5 | No TextField focused | **PASS** |
| 6 | Multiple lines — only the active line changes | **PASS** |
| 7 | Active line preserved after selecting B, then search focus | **PASS** |
| 8 | Minimum quantity = existing button behavior (stays 1) | **PASS** |
| 9 | Dialog isolation — cart unchanged, dialog open | **PASS** |
| 10 | `+` regression on the same active line (`-` then `+`) | **PASS** |
| 11 | Numpad `-` decrements | **PASS** |

**Verification:** Flutter analyze clean, `flutter test` — **638 passed** / 0 failed (627 + 11), `flutter build windows --debug` — success. Backend untouched: **529 passed**, `alembic current` `b7c3d4e5f6a1 (head)` (no new migration). Nothing committed.

**Manual QA (to be run by a human — not executed here):** 1) cart with a line at 5, click empty chrome, press `-` → **expected: nothing happens** (documented open limitation of §21.17, focus must re-enter a POS field first); 2) add a product → its qty field takes focus → press `-` → the line decrements by exactly 1; 3) type in the search field, press `-` → line decrements, no `-` appears in the search box; 4) press numpad `-` → same; 5) line at quantity 1 → press `-` → stays 1, no toast, line not removed; 6) open `*`, press `-` → dialog and cart unchanged; 7) two lines, tap the first, press `-` → only the first line changes.

### 21.19 PHASE 8 FIX #3 — `*` quantity input dialog (replaces, never multiplies)

Isolated fix: `*` opens a quantity **input** dialog for the last active cart line and the confirmed number **replaces** the current quantity (`24 → * → 3 = 3`), never `current × entered`. The shared quantity funnel, stock validation, active-line state, `+`, `-`, quantity expressions (`10*24`), payment, holds, checkout, Sale History and the backend are untouched; no second shortcut system and no second parser were added.

**Root cause report (§16 of the task)**

| # | Report | Root cause | Fix |
|---|---|---|---|
| 1 | `*` **multiplied** (`24 → * → 3` produced `72`) instead of setting the quantity the cashier typed | The dialog's confirm returned `current × entered` and `_multiplyActiveLine` wrote that product through `applyLineQuantity` — the semantics were designed as a factor entry (`PosQtyShortcutKind.multiply`, handler named `_multiplyActiveLine`, title key `multiply_quantity`) | `showQuantityInputDialog` / `QuantityInputDialog` now pop **`posScaledText(entered)`** — the typed number *is* the new quantity, no multiplication exists anywhere in the path; handler renamed `_setActiveLineQuantity` (`pos_screen.dart`), kind renamed `PosQtyShortcutKind.quantityEntry`. Same file, same widget keys (`qty-multiplier-*`) so the FIX #1/FIX #2 dialog tests keep addressing them |
| 2 | Dialog title / field label still said "multiply" | `multiply_quantity` (ar/fr/en) was the dialog title key and `quantity` only labelled the row | `multiply_quantity` **removed** from `strings.dart` (3 locales); title now uses the new key **`enter_quantity`** ("Enter quantity" / "Entrez la quantité" / "أدخل الكمية"), field label `quantity`; `posKeys` in `pos_localization_test.dart` updated to `enter_quantity` so the three localization tests keep covering it |
| 3 | §4: the field must start with the current quantity and show what will happen | The dialog invited factor entry, so the seed and preview were meaningless as a *replacement* workflow | Field seeds `posScaledText(current)` in `initState`; live preview row `qty-multiplier-preview` renders `'$_currentText → $next'` (`24 → 3`), `—` while the entry is empty/invalid |
| 4 | `*` did nothing while the POS search field or a cart qty field had focus (and the character was inserted instead) | `accepts` granted the `_focusIsPosQuantityInput()` exception only to `increment`/`decrement`; `multiply` fell into the "editable text has focus → never accept" branch | **One shared `accepts` case** for `increment` + `decrement` + `quantityEntry`: `!editableTextHasFocus() \|\| _focusIsPosQuantityInput()` — claimed in the two POS fields (never inserted), ignored in every other text field (dialogs/pickers keep normal typing) |
| 5 | Which key events represent `*` on Windows, and how the dialog opens exactly once | Three sources: the `'*'` character (Shift+8 / main row, any layout), the dedicated `numpadMultiply` key, and `LogicalKeyboardKey.asterisk` when the platform delivers **no character**; a repeat event would open a second dialog | `matchesEvent(quantityEntry)`: **KeyDown only** (no `KeyRepeat`, no key-up), then character → `asterisk` → `numpadMultiply`. `triggers` stays `null` (character-based matching) |
| 6 | Confirmation must reuse the existing validation — `0`, `-2`, `abc`, empty and over-stock rejected, no second parser | The dialog cannot validate itself: the cart already owns `posScaled` (regex `^(\d+)(?:\.(\d{1,3}))?$`, exact ×1000), `kPosQuantityMax`, `posQtyStockError` and the cart-wide guard | On submit: `posScaled(text)` → reject `null`/`<= 0` (`enter_quantity`) → reject `> kPosQuantityMax × kPosQtyScale` (`quantity_too_large`) → `posQtyStockError(quantity, availableStock, unitMultiplier)` (single-line stock rule) → pop canonical text; the **cart-wide** guard runs again inside `applyLineQuantity` when the value is written. No input formatter is attached (same as the Phase 6 `QuantityDialog`): the field accepts what is typed and the shared rule decides |
| 7 | Active line, empty cart and dialog isolation must behave exactly like `+`/`-` | Same architecture: `PosCartState.lastActiveKey` → `lastActiveLine`; dialog routes sit above the base route so their focus scope owns the keyboard | `_setActiveLineQuantity` resolves `lastActiveLine`, shows `cart_empty` toast + returns when the cart is empty, and feeds the returned text into the same `applyLineQuantity` funnel; while the dialog is open the background `CallbackShortcuts` never sees `+`/`-`/`*` (TEST 15: cart untouched, no second dialog) |

**Architecture notes**

- Filename `qty_multiplier_dialog.dart` and all `qty-multiplier-*` widget keys were **kept deliberately**: §21.16 and the FIX #1/FIX #2 tests reference them; only the behaviour, title key and public API names changed.
- The dialog autofocuses its field, so it — not the POS shortcut layer — owns the keyboard while open; Enter submits (`onSubmitted`), Escape/Cancel pops `null` → no mutation.
- `+` and `-` keep their exact behavior after a `*` set (TEST 13/14: `24 → * → 3 → + → 4`, `… → - → 2`).
- Decimal replacement works: `posScaledText` returns canonical text (`2.5` stays `2.5`, never float noise); a selling-unit line still resolves stock in base units through `posQtyStockError`.

**Files changed:** `qty_multiplier_dialog.dart` (rewritten in place: `showQuantityInputDialog`, `_QuantityInputDialogState`, seeded field, replacement `_submit`), `pos_qty_shortcuts.dart` (enum `quantityEntry`, shared `accepts` case, `matchesEvent` + key sources, `debugDescribeKeys`), `pos_screen.dart` (`_setActiveLineQuantity`, binding `PosQtyShortcutKind.quantityEntry`, header comment), `strings.dart` (`multiply_quantity` removed, `enter_quantity` added), `core/quantity_expression.dart` + `features/pos/pos_quantity.dart` (stale "multiplier dialog" comment only), `test/unit/pos_localization_test.dart`, `test/widget/pos_screen_test.dart` (+15).

**Tests (+15, group `Phase 8 FIX #3 * quantity input dialog`):** `24 → * → 3 = 3` (no multiplication) · `3 → * → 10 = 10` · `10 → * → 2.5 = 2.5` (decimal) · field seeded with the current quantity · `*` from the search field opens the dialog and never inserts `*` · `*` from the focused qty field does the same · only the active line changes (A = 2, B = 24 → 3) · Cancel keeps 24 · `0` rejected (dialog stays open) · `-2` rejected · `abc` rejected · stock guard rejects 12 with 10 in stock · `+` regression (`*` sets 3 → `+` = 4) · `-` regression (`*` sets 3 → `-` = 2) · dialog isolation (`+`/`-`/`*` never touch the background cart, no second dialog). The older group `POS quantity shortcuts (+ and *)` was updated to the new semantics and its 28 tests pass unchanged in count.

**Verification matrix (§17)**

| # | Scenario | Result |
|---|---|---|
| 1 | `24 → * → 3 = 3` (replace, never multiply) | **PASS** |
| 2 | `3 → * → 10 = 10` | **PASS** |
| 3 | Decimal entry `10 → * → 2.5 = 2.5` | **PASS** |
| 4 | Field starts with the current quantity | **PASS** |
| 5 | `*` from the search field — dialog opens, `*` never inserted | **PASS** |
| 6 | `*` from the focused cart qty field — dialog opens, never inserted | **PASS** |
| 7 | Only the active line is replaced (two lines) | **PASS** |
| 8 | Cancel / Escape — quantity unchanged | **PASS** |
| 9 | `0` rejected — dialog stays open, quantity unchanged | **PASS** |
| 10 | `-2` rejected | **PASS** |
| 11 | `abc` rejected | **PASS** |
| 12 | Stock guard rejects over-stock, quantity unchanged | **PASS** |
| 13 | `+` regression after `*` set | **PASS** |
| 14 | `-` regression after `*` set | **PASS** |
| 15 | Dialog isolation — `+`/`-`/`*` never touch the background cart or open a second dialog | **PASS** |

**Verification:** Flutter analyze clean, `flutter test` — **653 passed** / 0 failed (638 + 15), `flutter build windows --debug` — success. Backend untouched: **529 passed**, `alembic current` `b7c3d4e5f6a1 (head)` (no new migration). Nothing committed.

**Manual QA (§15 — to be run by a human, NOT executed here):** 1) line at 24, press `*` → dialog opens with **24 already in the field**, caret at end, no `*` typed anywhere; 2) type `3`, press Enter (or Confirm) → the line reads **3** (never 72), totals recompute, `+` then gives 4; 3) press Escape / Cancel → quantity still 24; 4) clear the field, press Enter → localized `enter_quantity` error, dialog stays open; 5) enter `0`, `-2`, `abc` → same rejection, cart untouched; 6) line with 3 in stock, enter `12` → localized `out_of_stock` error, quantity stays 3; 7) focus the search field, press `*` → dialog opens and the search box has no `*`; 8) focus a cart qty field, press `*` → same; 9) press numpad `*` → same; 10) press `*`, then `+`/`-`/`*` again → dialog and background cart unchanged (no second dialog); 11) two lines, tap the first, `*`, set 5 → only that line changes; 12) empty cart, press `*` → `cart_empty` toast, no dialog; 13) switch to Arabic/French → title "أدخل الكمية" / "Entrez la quantité".

---

## 22. Final verification summary

| Suite | Result |
|---|---|
| Backend | **529 passed** |
| Flutter | **713 passed, 0 failed** |
| flutter analyze | **clean** |
| flutter build windows | **success** |
| Alembic | **b7c3d4e5f6a1 (head)** |
| Git | **committed — `phase-8: complete POS core`** |

> Totals updated by §23 (final closure pass). The table above was 653 at the end of §21.19.

### Human review checklist (before commit)

> Human QA executed all 15 closure scenarios: **15/15 PASS** (§23.7). Phase 8 is **APPROVED and CLOSED** (§23.8); this checklist is retained as the review record.

- [ ] Review this doc + `PHASE_8_POS_ANALYSIS.md` §18 decisions still match intent
- [ ] Spot-check `SaleService.create_sale` transaction + rollback tests
- [ ] Confirm no silent except in new files
- [ ] Confirm migration 0009 on a fresh DB upgrade + downgrade
- [ ] **UX FIX #11:** confirm migration 0010 upgrade + downgrade on a fresh DB; after a sale, `sale_lines.variant_name` / `selling_unit_name` / `selling_unit_multiplier` hold the values captured at checkout (NULL for base-unit sales)
- [ ] **UX FIX #11:** rename a product / variant, change a selling-unit multiplier, archive them → Sale Detail, history and reprint still show the names, unit and price captured at sale time (no catalog API call in the browser network log)
- [ ] **UX FIX #11:** sale with a variant shows the stored variant name; sale with a selling unit shows `qty Unit × price DA` plus `Base: qty unit`; legacy pre-0010 sale still opens and renders
- [ ] **UX FIX #12:** confirm no new migration was added (`alembic current` still `b7c3d4e5f6a1`) and `unit_summary` is absent from older responses without breaking the client
- [ ] **UX FIX #12:** run the seven human-QA scenarios in §21.15 (history units row, `+` focus rules, `10*24`, immediate out-of-stock, localized toasts, shared quantity funnel, unchanged design)
- [ ] Walk manual test checklist §21.15
- [ ] **Phase 8 FIX #1:** add a product from the catalog -> its qty field takes keyboard focus and `+` increments that line immediately; add the same product again -> merged line keeps focus; `+` never appears inside the search field
- [ ] **Phase 8 FIX #1:** an out-of-stock / rejected add leaves the caret where it was; a dialog still swallows `+` (no cart change)
- [ ] **Phase 8 FIX #1 known limitation (§21.17):** after clicking empty page chrome the F-keys, `+`, `-` and `*` do nothing until a POS field is focused again - still open (FIX #2 was the `-` shortcut, not this focus guard)
- [ ] **Phase 8 FIX #2 (§21.18):** run the seven manual `-` scenarios (main row, numpad, search focus, qty focus, minimum quantity, dialog isolation, two lines); `-` never appears in any text field and a line at 1 stays at 1 with no toast
- [ ] **Phase 8 FIX #3 (§21.19):** run the thirteen manual `*` scenarios (seeded field, `24 → * → 3 = 3` replace, Escape/Cancel, `0`/`-2`/`abc`/over-stock rejections, search focus, qty focus, numpad `*`, dialog isolation, two lines, empty cart, Arabic/French title); `*` never appears in any text field and no multiplication ever happens
- [ ] Approve commit — **do not start Phase 9 without approval**

---

## 23. Phase 8 final human-QA closure (task FIX #3 + FIX #5)

Last automated pass before human sign-off. Scope was **only** the two remaining human-QA items — no shortcut, focus, merge, payment, checkout, hold, price-override, stock, print, customer, pack, return/void or backend-transaction work was touched.

### 23.1 Task FIX #3 — Sale History sold-unit display

Rows must show what was actually sold, derived from the sale's own historical line data, never from the current catalog.

- Source of truth: `SaleHistoryItem.lines` (snapshot per line: `quantity`, `product_unit`, `selling_unit_name`) with the API `unit_summary` only as a fallback for payloads without lines; rows with neither render without a units line.
- Formatter (reused, not re-invented): `SaleHistoryItem.unitSummaryText(loc)` in `pos_models.dart` — groups quantities by `AppStrings.unitLabel(sellingUnitName ?? productUnit, loc)`, first-seen order, sums equal units, joins with ` · `, caps at 3 groups then `+N`.
- Localization comes exclusively from `AppStrings.unitLabel(...)` (ar `2 علبة · 48 قطعة`, fr `2 Boîte · 48 Pièce`, en `2 Box · 48 Piece`) — no translated string is hardcoded in `sale_history_dialog.dart`.
- Sale Detail is unchanged: a selling-unit sale still shows `Base: 48 Piece` from its own snapshot; the history row never expands the multiplier (`2 Box` only).
- No catalog/variant/selling-unit API call is made when rendering history (asserted by test 10).

**Automated coverage (10 tests, group `Phase 8 FIX #3 sale history sold units`):** 1 base-unit `5 Piece` · 2 selling unit `2 Box` (never `48`) · 3 mixed `2 Box · 48 Piece` · 4 four groups → `… +1` · 5 first-seen order · 6 Arabic · 7 French · 8 English · 9 legacy NULL-snapshot row still renders · 10 renamed/renamed-catalog still historical **and zero catalog requests**. Plus the earlier `UX FIX #12` row tests (summing, API fallback, no-unit row, Arabic) and backend `unit_summary_from_lines` tests.

### 23.2 Task FIX #5 — POS error-toast localization

Every POS toast headline is localized; raw backend English travels only in the `detail:` slot (second line), never as the headline.

- Single mapping layer `pos_error_message.dart`: `posApiError(error, loc)` → localized `message` + optional `detail`. Status map: **401** `session_expired_login`, **403** `permission_denied`/`permission_discount`/`permission_credit`, **409** `stock_conflict`, **422** `validation_error`, **connection failure** `network_error_retry`, **everything else** `api_error_retry` (or a caller `fallbackKey`) — all three locales, all keys pre-existing (no duplicate keys introduced).
- Producers audited: `pos_providers.dart` (`_message()` for cart/checkout, search, customers, holds, favorites, sale history), `pos_screen.dart` (lookup error, qty/stock errors, hold save, notices), `holds_dialog.dart` (restore failure + backend reasons as `detail:`), `sale_detail_dialog.dart` (sale load + copy/print), `payment_dialog.dart` (`cart.lastError`, localized).
- Toast architecture untouched: one `showPosToast` in `pos_toast.dart`, no second toast system, no ad-hoc `SnackBar` anywhere under `lib/features/pos/`. Position, width, footer clearance, colors, animation, duration, replacement, close button and RTL/LTR layout are unchanged (design test `the error toast keeps the approved compact design` passes).

**Automated coverage:** widget group `Phase 8 FIX #5 POS error toast localization` (ar/fr/en × network/401/403/409/422/500 + design) · unit group `pos_error_message_test.dart` (status → key per locale, headline ≠ English, backend text only in `detail`, 403 refinements, FastAPI 422 list in the detail slot, key existence/translation) · `pos_toast_localization_test.dart` (static scan: no literal toast headline, every `AppStrings.t` key exists in ar/fr/en) · success-toast tests unchanged.

### 23.3 Changes made in this closure pass (2, both minimal)

| File | Change | Why |
|---|---|---|
| `test/widget/pos_screen_test.dart` | Arabic cart-line assertion `'1 Box × 550'` → `'1 ${AppStrings.unitLabel('Box', 'ar')} × 550'` | Stale expectation that contradicted `unitLabel` localization (Box → علبة) used by FIX #3 itself. **Expectation only — no production code changed.** |
| `lib/features/pos/payment_dialog.dart` | On checkout failure the localized headline (`payment-error`) now renders **above** the backend stock reason lines (`payment-stock-error`) | FIX #5 rule: backend text is secondary detail, never the first/primary error line. Display order only — payment logic untouched. |

### 23.4 Required final audit

| # | Audit | Result |
|---|---|---|
| 1 | Raw backend error used as a toast headline anywhere in POS | **NONE** — every `showPosToast(message:)` is `AppStrings.t(...)`, `posApiError().message`, `posApiMessage(...)` or a provider-localized string |
| 2 | Duplicate toast implementations | **NONE** — only `pos_toast.dart:144`; other `SnackBar`s in the app are pre-existing non-POS screens (out of scope) |
| 3 | Stale `multiply_quantity` references | **NONE** — zero hits in `lib/`, `test/` and backend |
| 4 | `unit_summary` additive only (never totals/stock) | **CONFIRMED** — computed at response build from persisted line snapshots, not persisted, not read by any stock/total path (3 references: builder, schema field, tests) |
| 5 | New database migration required | **NO** — the fixes are display + message-layer only |
| 6 | Alembic head unchanged | **`b7c3d4e5f6a1 (head)`** confirmed via `alembic heads` |

### 23.5 Known limitation (documented, deliberately NOT fixed)

> If focus leaves the POS subtree entirely and lands on the route modal scope, **F4–F12 and `+` / `-` / `*` may stop dispatching until focus returns to a POS field.**

Pre-existing route-level focus guard (§21.17). Fixing it means changing the shortcut/focus architecture, which is out of scope for this task and for FIX #1/#2/#3 of Phase 8. **Shortcut architecture was not altered.**

### 23.6 Full automated verification (final run — counts are the actual command output)

| Command | Result |
|---|---|
| `flutter test` | **713 passed, 0 failed** (`All tests passed!`) |
| `flutter analyze` | **clean (No issues found)** |
| `flutter build windows --debug` | **success** — `build\windows\x64\runner\Debug\supermarket_pos.exe` |
| `python -m pytest tests -q` (from `new_app/backend`) | **529 passed**, 3 warnings, 0 failed |
| `alembic heads` | **b7c3d4e5f6a1 (head)** |

**Automated Verification: PASS**

### 23.7 Final human-QA matrix (15 scenarios — executed by the human: **15/15 PASS**)

**Sale History**

| # | Scenario | Result |
|---|---|---|
| 1 | Base-unit sale → row shows `5 Piece` | **PASS** |
| 2 | Selling-unit sale → row shows `2 Box` (detail still `Base: 48 Piece`) | **PASS** |
| 3 | Mixed units → `2 Box · 48 Piece` | **PASS** |
| 4 | Arabic row → `2 علبة · 48 قطعة` | **PASS** |
| 5 | French row → `2 Boîte · 48 Pièce` | **PASS** |
| 6 | English row → `2 Box · 48 Piece` | **PASS** |
| 7 | Rename product/unit after the sale → old sale still shows historical data (no catalog call) | **PASS** |

**Error localization**

| # | Scenario | Result |
|---|---|---|
| 8 | Backend disconnected → Arabic `حدث خطأ في الاتصال` | **PASS** |
| 9 | Backend disconnected → French `Erreur de connexion` | **PASS** |
| 10 | Backend disconnected → English `Connection error` | **PASS** |
| 11 | 401 → localized headline | **PASS** |
| 12 | 403 → localized headline | **PASS** |
| 13 | 409 → localized headline | **PASS** |
| 14 | 422 → localized headline | **PASS** |
| 15 | Backend detail appears only as secondary detail line | **PASS** |

**Human QA: PASS (15/15).**

### 23.8 Phase 8 closure status

```
Automated Verification: PASS
Human QA:              PASS
Git Commit:            PENDING -> COMPLETED by the single commit
                       `phase-8: complete POS core` that contains this file
```

All 15 human-QA scenarios passed, so per the Phase 8 closure rule:

- **Phase 8 = APPROVED and CLOSED**
- ready for Git commit (this document is committed with it; `Git Commit` moves PENDING → COMPLETED in that commit)
- ready for Phase 9 (Phase 9 is **not** started by this commit)

**Known limitation carried forward (unchanged, §21.17 / §23.5):** if focus leaves the POS subtree entirely and lands on the route modal scope, F4–F12 and `+ / - / *` may stop dispatching until focus returns to a POS field. Shortcut architecture was not altered.
