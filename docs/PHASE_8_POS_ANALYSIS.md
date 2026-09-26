# Phase 8 POS Core — Reverse-Engineering Analysis & Implementation Specification

**Date:** 2026-09-24  
**Status:** STEP 1 COMPLETE — analysis only; **16 product decisions RECORDED** (no production code, no migrations, no Flutter POS, no Phase 9)  
**Decisions recorded:** 2026-09-24 — see §18
**Source of truth:** legacy `python_app/` (monolithic Tkinter/CustomTkinter desktop app)  
**Target:** `new_app/` (Flutter + FastAPI + PostgreSQL)  
**Existing schemas reused:** Phase 2 `sales` / `sale_lines` / `sale_payments`; Phase 4 RBAC; Phase 5/6 catalog units/variants/packaging; Phase 7 inventory journal + PMP

> **STOP LINE:** This document is the only deliverable of Step 1.  
> Implementation requires human approval of this specification first.  
> **§18: 16 product decisions recorded 2026-09-24. No production implementation until recorded — now satisfied; still awaiting go-ahead for Step 2.**

---

## 1. Legacy POS Architecture

### 1.1 Runtime shape

| Role | Path | Notes |
|---|---|---|
| Entry | `python_app/main.py` | Instantiates `gui.main_window.MainWindow`; license check commented out |
| Monolithic GUI + POS glue | `python_app/gui/main_window.py` (~17,326 lines) | Contains cart, checkout, hold/restore, discounts, printing |
| Sale persistence | `python_app/modules/sales.py` → `SalesManager.create_invoice` | **Active** (imported at main_window.py:32) |
| DB layer | `python_app/database/db_manager.py` | MySQL/MariaDB via pymysql + SQLite-compat shim; pooled connections |
| Support modules | `modules/{products,customers,debts,inventory,packs,favorites,reports}.py` | Thin SQL wrappers |
| Config | `config/db_config.json`, `config/app_settings.json` | Connection + print/debt/PIN/low-stock settings |
| **Dead code** | `gui/sale_window.py`, `modules/sales_v21.py` | Never imported — not part of live behavior |

### 1.2 Layering (legacy)

```
Tkinter/CustomTkinter event handlers (MainWindow methods)
        ↓
Manager modules (products / customers / debts / favorites / packs / inventory)
        ↓
SalesManager.create_invoice  ← single MySQL transaction for sale core
        ↓
DatabaseManager (pooled pymysql, autocommit=False)
```

- There is **no service layer, no API, no ORM**. SQL is embedded in manager methods.
- UI and domain logic are interleaved in `MainWindow` (cart state, pricing, stock checks all in GUI class).
- Post-commit side effects (cost capture, item discounts, audit, debt ledger, print) run **outside** the sale transaction.

### 1.3 Dead / orphan code (do not port)

| File | Why orphan |
|---|---|
| `gui/sale_window.py` | Simpler cart; no importer anywhere in `python_app` |
| `gui/add_product_window.py` | No importer |
| `modules/sales_v21.py` | Older `create_invoice` without variants/packs/device_name; no importer |

### 1.4 Key live entry points (verified)

| Concern | Method | File:line |
|---|---|---|
| Open POS | `show_pos` | main_window.py:8337 |
| Search debounce + Enter | `pos_search_preview` | :8980 |
| Resolve + add | `add_to_cart` | :9677 |
| Click-path add | `add_product_to_cart` | :10102 |
| Variant add | `_add_variant_to_cart` / picker | :9726 / :9791 |
| Weighted dialog | `_add_weighted_product_dialog` | :9978 |
| Cart display | `update_cart_display` | :10184 |
| Qty change | `update_cart_quantity` | :10422 |
| Remove / clear | `remove_from_cart` / `clear_cart` | :10473 / :10478 |
| Invoice discount | `edit_sale_discount` | :8652 |
| Item discount | `_open_item_discount_dialog` | :6269 |
| Customer pick | `select_customer` | :9600 |
| Hold | `hold_current_sale` | :8804 |
| Restore | `restore_held_sale` | :8823 |
| Payment modal | `complete_sale` / `confirm_payment` | :10487 / :10745 |
| Persist sale | `SalesManager.create_invoice` | sales.py:47 |
| PDF / print | `_create_invoice_pdf` / `print_invoice_80mm` | :11619 / :11931 |
| Shortcuts | `bind_shortcuts` | :2410 |

---

## 2. POS Workflow (verified from code — not assumed)

### 2.1 Primary sale sequence

```
1. Open POS  (F1 / sidebar → show_pos)
   └─ Default preserve_cart=False → wipes cart, total, customer, sale_discount

2. Search / scan
   └─ Scanner is keyboard input into pos_search + Enter (no dedicated scanner API)
   └─ Typing → pos_search_preview → 250 ms debounce → render_pos_products
   └─ Enter → add_to_cart() immediately (returns "break")

3. Resolve product  (add_to_cart :9677)
   a. Exact variant barcode → _add_variant_to_cart → clear search → DONE
   b. Else search_product(term)  (LIKE %term% on name OR barcode, ORDER BY name, no SQL LIMIT)
   c. Prefer exact barcode match, else exact name match, else products[0]
   d. If product has variants → force _show_variant_picker → clear → DONE
   e. Else add_product_to_cart(target)

4. add_product_to_cart  (:10102)
   a. If variants exist → force variant picker (even if parent stock = 0)
   b. If stock <= 0 → toast "المنتج غير متوفر في المخزون"
   c. If weighted unit → _add_weighted_product_dialog (qty OR price entry)
   d. Piece product → merge into existing cart row (+1, capped at stock) or append new line

5. Cart operations
   ├─ − / + : update_cart_quantity (step by unit; packs re-validate components)
   ├─ 🏷 : item discount dialog (fixed / percent, PIN if > threshold)
   ├─ × : remove_from_cart
   └─ مسح السلة : clear_cart (confirm)

6. Optional: invoice-level discount (F7 / تعديل)
   └─ fixed or percent; PIN if final > pin_discount_threshold (default 500)

7. Optional: customer selection (F6 / تغيير / payment-modal picker)
   └─ Default = cash customer (selected_customer = None → "زبون نقدي")

8. Payment  (F8 / الدفع → complete_sale)
   ├─ Method: cash | card | partial | credit  (default cash)
   ├─ cash/card: paid prefilled = total; must be >= total
   ├─ partial: paid < total (forced path)
   ├─ credit: paid forced to 0; requires customer
   ├─ Live summary: change = max(0, paid−total); debt = max(0, total−paid)
   └─ confirm_payment validates → builds items payload → create_invoice

9. Persist  (SalesManager.create_invoice — one MySQL transaction)
   ├─ Validate inputs, recompute totals, debt, change
   ├─ Reject debt without customer
   ├─ Generate invoice_number INV-YYYYMMDD-HHMMSS-mmm
   ├─ INSERT sales
   ├─ Per item: INSERT sale_items → guarded stock UPDATE → INSERT inventory_movements
   ├─ If debt: UPDATE customers.balance += debt
   └─ commit  (rollback on any error)

10. Post-commit (NOT atomic with sale)
    ├─ _capture_sale_costs → sale_items.cost
    ├─ _persist_item_discounts → sale_items.item_discount
    ├─ log_action("sale_completed") → audit_log
    ├─ If debt: debt_manager.record_debt → debt_transactions (separate tx)
    └─ Print hook (ask_before_print → auto_print_invoice gates)

11. UI reset → show_pos() clears cart → toast success / change / debt
```

### 2.2 Alternative workflows (all verified)

| Workflow | Trigger | Behavior |
|---|---|---|
| **Weighted product** | Unit in weighted set → dialog | Enter qty **or** amount; qty×price; round qty 6 dp, amount 2 dp; stock cap |
| **Variant by barcode** | Enter on variant barcode | Direct add with variant stock check; no parent picker |
| **Variant by click/Enter** | Parent has variants | Forced picker (even if parent stock 0); OOS rows disabled |
| **Weighted variant** | Variant unit weighted | Variant qty dialog + Return |
| **Pack (bundle)** | Pack row at top of list | Pack line with components; stock validated per component at add, qty change, and pre-checkout |
| **Hold / restore** | F9 / F10 | In-memory only; unlimited holds; one-shot restore; confirm replace if cart non-empty |
| **Independent return** | POS header ↩ | Search product → qty/amount → INSERT returns/return_items → **unguarded stock increase** |
| **Invoice history / reprint / void** | POS header 🧾 | List by device; reprint 80mm/A4; void restores stock, sets status=void — **no PIN** |
| **Favorites** | Star / auto top-N | Manual + auto (30-day rolling, top 10, display cap 15); OOS hidden |

### 2.3 Keyboard shortcuts (verified — `bind_shortcuts` :2410)

| Key | Action | Scope |
|---|---|---|
| F1 | Open POS (`show_pos` default **wipes cart**) | global |
| F2 | Products page | global |
| F3 | Add-product form | global |
| F4 / Ctrl+F | Focus current search | global |
| F5 | Refresh current page (**POS refresh also wipes cart**) | global |
| F6 | Customer select | POS only |
| F7 | Invoice discount | POS only |
| F8 | Payment / complete sale | POS only |
| F9 | Hold sale | POS only |
| F10 | Held carts modal | POS only |
| F12 | Clear cart (confirm) | POS only |
| Esc | Close top window / clear POS search | global |
| Ctrl+N | Add product | global |
| Enter / KP_Enter in search | `add_to_cart` | POS |

**Barcode scanner:** no dedicated handler — scanner types into `pos_search` then sends Enter. Hardware/suffix behavior is **UNVERIFIED** at runtime.

---

## 3. Product Lookup

### 3.1 Legacy queries (verified)

| Path | Query | Notes |
|---|---|---|
| Name/barcode partial | `WHERE p.name LIKE ? OR p.barcode LIKE ?` with `%term%` both sides; `ORDER BY p.name`; **no SQL LIMIT** | products.py:42–53; collation `utf8mb4_unicode_ci` → case-insensitive |
| Exact product barcode helper | `WHERE barcode = ?` | products.py:62 — **not called from live POS** |
| Exact variant barcode | `WHERE v.barcode = %s LIMIT 1` → 9-tuple | db_manager.py:1714 — called first on Enter |
| All products | same columns, `ORDER BY p.name` | products.py:28 |
| Exact-match preference | casefold input vs barcode OR name; first win else products[0] | main_window.py:9699–9710 |

### 3.2 Barcode normalization

- Only `.strip()` on input + casefold equality for exact preference.
- **No** zero-padding, checksum, EAN-13 validation, or digit-length normalization.
- Duplicated barcodes: product barcode unique at DB; variant barcode unique — first exact match wins in search loop (order by name → **UNVERIFIED** which wins if two names share a barcode casefold — DB uniqueness should prevent it).

### 3.3 Category / favorites / stock filters

| Feature | Behavior |
|---|---|
| Category filter | Combo AND'd with status + search (`_match_category_filter` :9097) |
| Stock status chips | **`product.low_stock_threshold`** per product (DECIDED §18.10) — not hard-coded 5 |
| Favorites strip | Manual pins first (cap), then auto top-N by 30-day sales; **qty≤0 hidden**; rendered on open/star toggle only |
| Sort | In-memory by name/price/stock via column headers; default SQL ORDER BY name |
| Pagination | **Client-side**, page size 40 (`pos_list_page_size`) |
| Packs in list | Active packs **always prepended**, ignore search term |
| Out-of-stock rows | Rendered disabled |

### 3.4 Debounce

| Surface | Debounce |
|---|---|
| POS search | **250 ms** (`pos_search_preview`) |
| Products page | 250 ms — **shares same `search_after_id` slot** as POS (cross-cancel **UNVERIFIED**) |
| Customers page | 120 ms |
| Customer picker in payment modal | **immediate per keystroke**, takes `customers[0]` silently |
| Returns product search | 150 ms |

### 3.5 User-facing errors / fallbacks

| Case | Behavior |
|---|---|
| Empty search + Enter | return (no-op) |
| No products | toast `"المنتج غير موجود"` |
| DB error on search | toast `"خطأ في البحث: …"` |
| Multiple results | uses exact-or-first (no chooser dialog on Enter path) |
| Variants exist | **forced picker** (not fallback to parent) |
| Archived products | included in search (no archived filter on POS list path — product rows from `search_product` have no archive clause) — **UNVERIFIED impact** |

### 3.6 New-app counterpart (already built for Phase 8)

| Legacy need | New endpoint (exists) | Contract |
|---|---|---|
| Exact scan resolve | `GET /api/v1/products/barcode-lookup?barcode=` | Lookup order **selling_unit → variant → product**; returns kind, ids, prices, qty, multiplier; `found: bool`; permission `product_view` |
| Name/barcode search | `GET /api/v1/products/search?q=&barcode=&limit=` | Exact barcode short-circuit; limit 1..50; permission `product_view` |
| Catalog browse | `GET /api/v1/products?search=&category_id=&status=&sort_by=&page=&page_size=` | Paginated; permission `product_view` |

**Gap vs legacy:** no favorites API/table in `new_app` yet (roadmap Phase 8 feature). Archived-product exclusion and client-side pack prepend are design decisions for implementation.

---

## 4. Cart Model

### 4.1 Legacy cart line (product) — main_window.py:10143–10145

```python
{
  "id": int,              # products.id
  "name": str,            # display; variant lines: "Parent (Variant)"
  "price": float,         # unit price snapshot at add-time
  "quantity": float,      # 1.0 default; weighted fractional
  "total": float,         # max(0, price*qty - item_discount)
  "unit": str,            # unit string at add-time
  "item_discount": float, # fixed DZD, default 0.0
  # optional:
  "variant_id": int,      # only on variant lines
}
```

### 4.2 Variant line

Same as product line **plus** `"variant_id"` (main_window.py:9782, 9935). Name = `"Parent (Variant)"`.

### 4.3 Pack line (`_pack_cart_line` :7184–7194)

```python
{
  "is_pack": True,
  "pack_id": int,
  "id": -int(pack_id),    # negative id sentinel
  "name": str,
  "price": float,         # pack list price
  "quantity": float,
  "unit": "باقة",
  "total": price*qty,
  "components": [
    {"product_id": int, "name": str, "unit_qty": float, "unit_price": float},
    ...
  ]
}
# NOTE: no item_discount key (discount getters use .get(..., 0))
```

### 4.4 Cart-level state

| Field | Type | Init |
|---|---|---|
| `self.cart` | `list[dict]` | `[]` |
| `self.total` | float | 0.0 |
| `self.selected_customer` | tuple \| None | None; row = `(id, name, phone, balance)` |
| `self.sale_discount` | float | 0.0 (invoice-level DZD) |
| `self.held_sales` | list | `[]` in-memory only |
| `self.pos_filter` | str | `"all"` |
| `self.pos_sort_col` / `pos_sort_col_dir` | — | sort state |
| `self.pos_list_page` | int | page; size 40 |

### 4.5 Snapshot vs live

| Data | Behavior |
|---|---|
| `price`, `unit`, `name` | **Snapshotted at add-time** into cart line |
| Stock quantity | **Re-read live** on qty change, pack validate, weighted dialog, backend checkout |
| Product existence | Re-read at checkout (backend `SELECT` product) |
| Discounts | Stored on cart line / cart-level until submit |
| Backend items payload | Only `product_id`, `quantity`, `price`, optional `variant_id` / pack fields — **item_discount folded into single invoice discount arg** (not per-line on wire) |

### 4.6 GUI→backend payload (`confirm_payment` :10793–10806)

```python
{
  "product_id": item["id"],
  "quantity": ...,
  "price": ...,
  # optional:
  "variant_id": ...,
  # pack:
  "is_pack": True, "pack_id": ..., "components": [...]
}
# invoice_discount = sale_discount + sum(item_discount)  → single "discount" argument
```

**New schema note:** Phase 2 `sale_lines` already has first-class `line_discount`, snapshot fields (`product_name/sku/barcode/unit`), `unit_cost` — richer than legacy. Phase 8 should send **per-line discounts** on the wire (see §11) rather than folding into one number.

---

## 5. Pricing / Discount Rules

### 5.1 Formulas (VERIFIED)

**Cart display (`update_cart_display` :10192–10194):**

```
line.total        = max(0, price * qty - item_discount)
subtotal          = Σ line.total
displayed_discount = min(sale_discount, subtotal)
self.total        = max(0, subtotal - displayed_discount)
```

**Backend (`create_invoice` sales.py:87–106):**

```
total                 = Σ price * quantity          # gross; item_discount NOT subtracted here
total_after_discount  = max(0, total - discount)    # discount = combined arg
debt                  = max(0, total_after_discount - paid)
change                = max(0, paid - total_after_discount)
```

**Combining (main_window.py:10808–10813):**

```
invoice_discount = sale_discount + Σ item_discount
```

**Algebraic consistency (VERIFIED):**

```
GUI:    Σ(price·qty − item_disc) − sale_discount
Backend: Σ(price·qty) − (sale_discount + Σ item_disc)
≡ equal
```

**Stored:** `sales.total` = **gross**; `sales.discount` = combined; net = `max(0, total − discount)`.

### 5.2 Invoice-level discount (`edit_sale_discount` :8652)

| Rule | Detail |
|---|---|
| Modes | fixed DZD / percent |
| Percent | `final = subtotal * (value/100)`, value ∈ [0, 100] |
| Fixed | `final = value`, must be ≤ subtotal |
| Negative | rejected |
| PIN gate | if `final > settings.pin_discount_threshold` (default **500**), `require_pin(..., "any")` |
| Rounding | **does not round** `final_amount` before store (**possible sub-cent drift — UNVERIFIED**) |

### 5.3 Item-level discount (`_open_item_discount_dialog` :6269)

| Rule | Detail |
|---|---|
| Base | line subtotal `price * qty` |
| Modes | fixed / percent (same formulas) |
| Caps | fixed ≤ line subtotal; percent ≤ 100 |
| PIN | same threshold gate, role `"any"` |
| Store | `item_discount = round(final, 2)`; `total = max(0, subtotal − final)` |
| Persist | **post-commit** `UPDATE sale_items SET item_discount` (:6402), failures swallowed |

### 5.4 Zero / negative price

| Case | Behavior |
|---|---|
| Zero price product | **Allowed** at cart (DECIDED §18.8); **negative price rejected** (§18.9) |
| Negative price | Backend rejects `price < 0` (sales.py:96–97) |
| Negative discount | Rejected GUI + backend |
| Discount > subtotal | GUI clamps display; backend `max(0, …)` |

### 5.5 Pack pricing

- Pack line charged at fixed `packs.price`.
- Component `sale_items` rows store component unit price & extended amounts for cost/stock tracking; pack summary row carries charged amount.
- Savings vs sum-of-components displayed only where UI shows it — **no auto discount formula — UNVERIFIED whether any UI computes pack savings**.

### 5.6 Price levels / wholesale

- **None.** Grep found no `price_level` / wholesale concept. Price is always product or variant price at add-time.

---

## 6. Stock Rules

### 6.1 Legacy matrix (VERIFIED)

| Case | Cart-time | Checkout-time (backend) |
|---|---|---|
| Zero stock | Blocked at add; card disabled | N/A if never added |
| Insufficient | Pre-check `qty > stock + 1e-9` | `available < quantity` → ValueError; guarded `UPDATE … WHERE quantity >= ?` rowcount guard |
| Negative | Never allowed | Guarded update prevents; `change_stock` refuses `new_qty < 0` |
| Variant | Live variant stock re-read; cap vs **variant** qty | Guarded **variant UPDATE only** (DECIDED §18.1–2 — no parent decrement) |
| Weighted | Fractional, 6 dp, `+1e-9` tolerance | Same as normal product |
| Packs | Per-component `unit_qty × pack_qty` vs stock (−1e-9); re-checked at qty change and pre-checkout | Per-component re-check + guarded decrement |
| Selling units | **Display/step only** — no per-unit stock conversion in legacy POS | N/A |
| Decrement timing | **Never at cart add** (soft only) | **Inside create_invoice tx, per item after sale_items INSERT, before commit** |
| Plain-line revalidation at confirm | — | **No GUI pre-check** for plain products (only packs); backend still safe |

### 6.2 Variant double-decrement — DECIDED (§18.1–2)

- Legacy `create_invoice` decrements `product_variants` (sales.py:273–280) **and** falls through to generic `UPDATE products` (sales.py:307–319) — legacy behavior.
- **Phase 8 rule (approved):** variant sale decrements **variant quantity only**. Parent `products.quantity` is **NOT** decremented for a variant sale.

### 6.3 Comparison with Phase 7 architecture

| Legacy | Phase 7 new architecture | POS implication (do not implement yet) |
|---|---|---|
| `products.quantity` guarded UPDATE | `products.quantity` + **immutable** `inventory_movements` | POS must write `movement_type='sale'` rows inside same tx |
| No avg_cost on sale | `products.avg_cost` PMP; sales **must not** change PMP | POS sale = decrease only; never touch avg_cost |
| Free-text movement reason `"بيع - INV…"` | Typed `StockMovementType.SALE` + `source_document_type/id` | Use enum + link to `sales.id` |
| No `unit_cost` / `avg_cost_after` on movement | Phase 7 columns exist | Optional snapshot on sale movement (**decision**) |
| Read-modify-write stock | Optimistic / guarded update + `DocumentModel.version` | Use guarded UPDATE or version bump |
| `sale_items.cost` post-commit | `sale_lines.unit_cost` exists in schema | Snapshot cost **inside** sale tx (improvement) |
| `item_discount` post-commit | `sale_lines.line_discount` exists | Persist **inside** sale tx (improvement) |
| Debt ledger separate tx | `debt_ledger_entries` + `customers.balance` projection | Phase 8: interface only; full debt UX is Phase 9 |
| No `payment_method` column | `sales.payment_method` + `sale_payments[]` | Persist method (cash/card/partial/credit) |

### 6.4 What POS must call/use (inventory)

1. **Stock read** for cart validation: product.quantity / variant.quantity / packaging state (Phase 6).
2. **Stock decrement** inside sale transaction with rowcount/version guard.
3. **`inventory_movements` insert** with `movement_type='sale'`, qty before/after, reason, source sale id, user, device.
4. **Do not** call `POST /inventory/adjust` for POS sales — that is manual adjust path; POS has its own service transaction that reuses repository movement recording patterns.
5. **Packs (Phase 10):** component explode + `movement_type` per component (legacy uses same `sale` reason text with pack label; new enum has `PACK_COMPONENT` — **decision for Phase 10**).
6. **Selling-unit scan:** quantity in base units after multiplier conversion (`selling_to_base`); price from `effective_unit_price`. Prefer **base-unit cart lines** with metadata (Phase 7 lesson: avoid unit-selector complexity at checkout — **PROPOSED**).

---

## 7. Hold / Restore

### 7.1 Legacy behavior (VERIFIED)

| Aspect | Finding |
|---|---|
| Storage | **In-memory only** — `self.held_sales = []` (main_window.py:77). **No DB table, no file.** Lost on exit/crash. |
| Fields | `{cart: [line dicts], customer: tuple\|None, discount: float, time: "%H:%M"}` |
| Multiple holds | Unlimited list append |
| Ownership | **None** — no user/device attribution |
| Timestamps | Display-only time string; no date/id |
| Restore | Confirm replace if active cart non-empty; **pops** held entry (one-shot); copies cart/customer/discount back |
| Delete | Explicit confirm + pop |
| Stock reservation | **None** — stock may be gone by restore time |
| Shortcuts | F9 hold, F10 restore modal |

### 7.2 Phase 8 design — DECIDED (§18.3–4)

- **Holds are server-side persisted** (new table; not in-memory). Minimum record: hold id, user_id, device_id, customer_id?, cart JSON (lines + discounts), created_at, note?
- **Holds do NOT reserve stock.** Validate stock at restore and again at checkout (match legacy).
- Legacy in-memory holds are **not** ported as the Phase 8 source of truth.

---

## 8. Payment Preparation

> Phase 8 must NOT implement full Payments/Customers/Debts (Phase 9).  
> Below: what legacy **prepares** at sale time vs what belongs to Phase 9.

### 8.1 Legacy payment methods (complete_sale)

| Method | `paid` behavior | Customer | Notes |
|---|---|---|---|
| `cash` | Prefill total; must be ≥ total | optional | Default |
| `card` | Same as cash | optional | **Not persisted** — no method column in legacy `sales` |
| `partial` | paid < total; debt = total − paid | required if debt>0 | |
| `credit` | paid forced 0; debt = total | **required** | Full debt |

Live summary: `change = max(0, paid−total)`, `debt = max(0, total−paid)`, `new_balance = existing + debt`.

### 8.2 Validation order (`confirm_payment` :10745)

1. credit without customer → error  
2. paid unparsable → error  
3. paid < 0 → error  
4. cash/card with paid < total → force partial path  
5. partial with paid ≥ total → force cash/card  
6. credit → paid = 0  
7. debt > 0 and `settings.allow_debt` off → block  
8. debt > 0 and no customer → block  
9. Pack component stock re-validation  
10. Backend re-validates debt/customer again  

### 8.3 Classification for Phase 8 vs Phase 9

| Concern | Classification |
|---|---|
| Method selection UI (cash/card/partial/credit) | **interface required by Phase 8** |
| Amount tendered / change display | **interface required by Phase 8** |
| paid / change / payment_method on sale header | **interface required by Phase 8** |
| Single `sale_payments` row matching method+amount | **interface required by Phase 8** (schema exists) |
| debt > 0 requires customer_id | **interface required by Phase 8** (legacy rule) |
| `customers.balance` += debt at sale | **interface required by Phase 8** (minimal write) **or** Phase 9 — **PROPOSED: Phase 8 writes balance + one debt_ledger entry atomically** to keep sale self-contained |
| Full customer CRUD UI | **Phase 9** |
| Debt history / payment recording UI / ceiling enforcement | **Phase 9** |
| `debt_ceiling` enforcement | Legacy **never enforces** — Phase 9 decision |
| Card gateway / terminal | **Not in legacy — Later / deferred** |
| `allow_debt` setting | Legacy app_settings — **PROPOSED Phase 8 config or hard-true until Phase 9 settings** |

### 8.4 Known legacy gaps to fix (not invent new features)

| Gap | Evidence | Recommendation |
|---|---|---|
| Payment method not stored | no column | Use new `sales.payment_method` + `sale_payments` |
| No double-submit guard | `sale_processing` dead flag | Client disable + **required** `client_request_id` idempotency key (§18.12) |
| Card ≡ cash in reports | no method field | Fixed by payment_method column |
| debt_ceiling unused | no code path | Leave to Phase 9 |

---

## 9. Sale Persistence

### 9.1 Records created (legacy — atomic set)

Inside **one** MySQL transaction (`create_invoice`):

| Order | Table | Operation |
|---|---|---|
| 1 | `sales` | INSERT — invoice_number, customer_id (NULL if cash), total=GROSS, discount=combined, paid_amount, change_amount, device_name; sale_date/status DB defaults |
| 2..n | `sale_items` | INSERT per line (pack summary `product_id NULL + pack_id`; pack components; variant lines carry `variant_id`) — **before** stock decrement for that line |
| 2..n | `product_variants` | guarded UPDATE −qty (variant lines) |
| 2..n | `products` | guarded UPDATE −qty (non-variant lines; **Phase 8: NOT for variant lines** §18.2) |
| 2..n | `inventory_movements` | INSERT −qty, reason `"بيع - INV…"` / `"بيع باقة - INV…"` |
| last | `customers` | UPDATE `balance += debt` if debt>0 & customer |
| — | **COMMIT** | |

**Return value:** `(True, invoice_number, total_after_discount, change)` or `(False, None, 0, 0)` + friendly error.

### 9.2 Post-commit (NOT atomic)

| Step | Table / artifact | Failure mode |
|---|---|---|
| `_capture_sale_costs` | `sale_items.cost` UPDATE | swallowed |
| `_persist_item_discounts` | `sale_items.item_discount` UPDATE | swallowed; dedupes by product_id |
| `log_action` | `audit_log` INSERT | swallowed |
| debt ledger | `debt_transactions` INSERT (own commit) | warning toast; **balance already raised** |
| PDF + printer | file / OS print | n/a |

### 9.3 Invoice numbering

```
INV-YYYYMMDD-HHMMSS-mmm   # mmm = millisecond 000–999
```

- `sales.invoice_number` UNIQUE. Collision → MySQL 1062 → friendly duplicate message.
- No per-device or sequential counter. Cross-device same-clock collision **UNVERIFIED** at scale.

### 9.4 New Phase 2 schema already prepared

| Legacy table | New table | Improvements already in schema |
|---|---|---|
| `sales` | `sales` | UUID PK, `subtotal`, `payment_method`, `user_id`, `device_id`, `version` optimistic lock, status enum completed\|void |
| `sale_items` | `sale_lines` | snapshot name/sku/barcode/unit, `unit_cost`, `line_discount`, `line_total` |
| `sale_payments` | `sale_payments` | method, amount, reference — split payments ready |
| `inventory_movements` | same + Phase 7 cols | movement_type enum, avg_cost_after, source_document_* |
| `customers` | `customers` | balance + debt_ceiling |
| debt_transactions | `debt_ledger_entries` | append-only; entry_type sale\|payment\|adjustment |
| invoice PDF | client-side later | Phase 8: return invoice_number + amounts; print hook stub |

**No migration required for Phase 8 core sale tables** — reuses Phase 2 tables as-is. **Required migrations:** holds table (server-side, §18.3) + `product_favorites` (§18.5).

---

## 10. Transaction Boundaries

### 10.1 Must be atomic (single DB transaction)

1. Insert `sales` header  
2. Insert all `sale_lines`  
3. Decrement stock (products / variants / pack components) with guard  
4. Insert `inventory_movements` rows  
5. Update `customers.balance` if debt (and ideally insert `debt_ledger_entries` entry)  
6. Insert `sale_payments` row(s)  

Any failure → full rollback → structured error to cashier.

### 10.2 Explicitly non-atomic in legacy (improve in Phase 8)

| Legacy post-commit | Phase 8 proposal |
|---|---|
| `sale_items.cost` after commit | Move **into** tx via `sale_lines.unit_cost` |
| `item_discount` after commit | Move **into** tx via `sale_lines.line_discount` |
| `audit_log` after commit | Keep post-commit or async (**acceptable**) |
| debt ledger separate | Move **into** tx with balance update |
| PDF/print | Stay outside tx |

### 10.3 Concurrency

- Legacy: guarded `UPDATE … WHERE quantity >= ?` + rowcount check; pooled conn `autocommit=False`.
- New: same guarded UPDATE pattern **or** `DocumentModel.version` optimistic lock on products (roadmap says “optimistic locking”).  
- **PROPOSED:** guarded UPDATE (simpler, matches Phase 7 adjust style) + optional version for high-contention.

### 10.4 Void (out of Phase 8 scope?)

Roadmap Phase 12 = Returns/Voids. Legacy void exists (`void_invoice`).  
**Phase 8:** do **not** implement void/return endpoints unless explicitly expanded.  
Map void → Phase 12 in matrix (§17).

---

## 11. New POS Architecture

### 11.1 Principles

1. Flutter never touches PostgreSQL — all via FastAPI.  
2. Reuse Phase 2 sale tables; Phase 4 scopes; Phase 5/6 catalog; Phase 7 inventory journal.  
3. Sale creation is **one service transaction**.  
4. Cart is **client state** until checkout (like legacy) — optional server-side validate endpoint.  
5. Base-unit quantities in cart lines (Phase 7 lesson); selling-unit scan resolves to base qty + metadata.  
6. Structured error envelope (existing `exceptions.py`).  
7. Permissions from existing `PermissionScope` — no new scopes unless PROPOSED below.

### 11.2 Flutter (new feature package `lib/features/pos/`)

| Component | Responsibility |
|---|---|
| `PosScreen` | Layout: header, search/scan, filters, favorites, product grid/list, cart panel, summary, actions |
| `pos_providers.dart` | Riverpod: cart state, search debounce, held sales, checkout command, barcode lookup reuse |
| `CartState` / `CartLine` | Immutable cart model + derived totals/discounts |
| `ProductSearchPanel` | Debounced search + category/stock filters + pagination |
| `FavoritesStrip` | Manual + auto favorites (Phase 8 — DECIDED §18.5) |
| `CartLineEditor` | Qty ±, weight dialog, item discount, remove |
| `VariantPicker` / `SellingUnitPicker` / `QuantityDialog` | **Reuse Phase 6 widgets** |
| `CustomerPicker` | Minimal: cash vs select existing customer (search) — full CRUD = Phase 9 |
| `DiscountDialogs` | Invoice + item; PIN reauth hook if over threshold |
| `PaymentDialog` | Method cash/card/partial/credit; tendered/change/debt preview; confirm |
| `HoldRestoreUI` | Hold list, restore, delete |
| `HoldRestoreUI` | Hold list, restore, delete |
| Keyboard shortcuts | Match legacy F6–F10, F12, Enter scan (desktop) |

Route: replace `/pos` Placeholder in `app_router.dart:79–84` with `PosScreen`.  
Nav rail: gate on `pos_sale` (or `product_view` — see §15).

### 11.3 FastAPI

| Layer | New files (proposed) |
|---|---|
| API | `app/api/v1/pos.py` or `sales.py` (+ register in `router.py`) |
| Schemas | `app/schemas/sale.py` (request/response) |
| Service | `app/services/sale.py` — `create_sale` transaction boundary |
| Repository | `app/repositories/sale.py` (optional; may live in service + inventory repo) |
| Favorites | `app/services/favorites.py` + schema/repo (Phase 8 — DECIDED §18.5) |
| Lookup | Reuse `BarcodeLookupService`, `ProductService.search` |

**Inventory integration:** Sale service calls guarded stock decrement + movement insert reusing patterns from `InventoryService` / packaging domain — **not** the public adjust endpoint.

### 11.4 Database

| Object | Action |
|---|---|
| `sales`, `sale_lines`, `sale_payments` | **Reuse as-is** (Phase 2) |
| `inventory_movements` | **Reuse** (Phase 7) |
| `customers`, `debt_ledger_entries` | **Reuse** minimal fields |
| `product_favorites` | **New migration — favorites in Phase 8** (DECIDED §18.5; must not block core POS) |
| Held sales table | **New only if server-side holds approved** (PROPOSED) |
| Packs | Phase 10 — Phase 8 API should accept pack lines only if packs UI exists; otherwise defer pack checkout |

**No migration in Step 1.** Implementation step will list any approved migrations.

---

## 12. New POS API Blueprint (propose only — do not implement)

Derived from legacy workflow + existing architecture. Paths under `/api/v1`.

### 12.1 Product lookup (reuse + thin POS wrappers if needed)

| Method | Path | Permission | Notes |
|---|---|---|---|
| GET | `/products/barcode-lookup` | `product_view` | **Exists.** Exact resolve: selling_unit → variant → product |
| GET | `/products/search` | `product_view` | **Exists.** Name/barcode, limit ≤50 |
| GET | `/products` | `product_view` | **Exists.** Browse + category + sort + page |
| GET | `/categories` | `category_view` | **Exists.** Filter chips |
| GET | `/pos/favorites` | `product_view` | **DECIDED §18.5** favorites in Phase 8 |
| POST | `/pos/favorites/{product_id}` | `product_view` | **DECIDED §18.5** toggle manual pin |
| DELETE | `/pos/favorites/{product_id}` | `product_view` | **DECIDED §18.5** |

*Alternative:* fold favorites under `/products/{id}/favorite`. Naming **PROPOSED**.

### 12.2 Cart validation (optional but recommended)

| Method | Path | Permission | Purpose |
|---|---|---|---|
| POST | `/pos/cart/validate` | `pos_sale` | Re-check stock/prices for cart lines before payment UI confirm; returns per-line ok/errors. Stateless. |

**Legacy equivalent:** pack re-validation + backend re-check at create.  
**Transaction boundary:** read-only (no writes).  
**Errors:** 422 business rule per line details.

*Could be skipped* if checkout re-validates everything (legacy does). **PROPOSED optional.**

### 12.3 Checkout (core)

**POST `/api/v1/sales`** — permission: `pos_sale`  
(and `pos_credit_sale` if `debt > 0` — **PROPOSED dual-scope check**)

**Request (proposed):**

```json
{
  "customer_id": "uuid|null",
  "items": [
    {
      "product_id": "uuid",
      "variant_id": "uuid|null",
      "selling_unit_id": "uuid|null",
      "quantity": 1.0,
      "unit_price": 100.0,
      "line_discount": 0.0
    }
  ],
  "invoice_discount": 0.0,
  "payment_method": "cash|card|partial|credit",
  "paid": 200.0,
  "device_id": "PC1",
  "note": null,
  "client_request_id": "uuid-idempotency-key"
}
```

**Response (proposed):**

```json
{
  "sale_id": "uuid",
  "invoice_number": "INV-…",
  "subtotal": 200.0,
  "discount": 50.0,
  "total": 150.0,
  "paid": 200.0,
  "change": 50.0,
  "debt": 0.0,
  "payment_method": "cash",
  "sale_date": "…"
}
```

**Validation:**

- items non-empty; quantity > 0; unit_price **≥ 0** (zero-price **allowed** §18.8; **negative price rejected** §18.9 → 422)  
- line_discount ≥ 0 and ≤ line gross; invoice_discount ≥ 0 and ≤ subtotal; **kept as separate fields** (§18.11)  
- paid ≥ 0  
- debt = max(0, total_after_discount − paid); if debt > 0 → customer_id required + `pos_credit_sale`  
- method consistency: cash/card → paid ≥ total; partial → paid < total; credit → paid = 0  
- stock available for each line (product / variant / selling-unit base conversion); variant lines check **variant stock only** (§18.1)  
- archived product → 422/404  

**Transaction boundary (DECIDED §18.13):** entire sale + stock + movements + sale_payments + customer balance/debt ledger are **atomic** (one DB transaction). No post-commit side effects for these. Failure → full rollback; no false success (§18.14–15).

**Error cases:** 401, 403 (`pos_sale` / `pos_credit_sale` / `pos_discount` if discount exceeds threshold policy), 404 product/customer, 409 concurrent stock (or 422 BUSINESS_RULE), 422 validation, 500.

**Idempotency (DECIDED §18.12):** `client_request_id` **required** — unique; replay returns the same sale (protects double F8). Missing/duplicate key → 409/422, never a second sale.

### 12.4 Hold / restore (DECIDED §18.3–4 — server-side, no stock reserve)

| Method | Path | Permission | Purpose |
|---|---|---|---|
| POST | `/pos/holds` | `pos_sale` | Save current cart snapshot |
| GET | `/pos/holds` | `pos_sale` | List holds for user/device |
| GET | `/pos/holds/{id}` | `pos_sale` | Detail |
| DELETE | `/pos/holds/{id}` | `pos_sale` | Delete hold |
| POST | `/pos/holds/{id}/restore` | `pos_sale` | Return snapshot (or client GET+DELETE) |

**Decided:** holds **persisted server-side**; holds **do not reserve stock**; validate stock at restore + checkout. Requires migration for hold table.

### 12.5 Customer (minimal for Phase 8)

| Method | Path | Permission | Phase |
|---|---|---|---|
| GET | `/customers/search?q=` | `customer_view` | **Phase 8 minimal** (picker) |
| GET | `/customers` | `customer_view` | Phase 8 optional list; full UX Phase 9 |
| POST/PUT/DELETE `/customers`… | `customer_manage` | **Phase 9** |
| POST | `/customers/{id}/pay` | **Phase 9** |
| Debt history endpoints | | **Phase 9** |

**Checkout** may write `customers.balance` + one `debt_ledger_entries` row — no separate customer API required for that write (inside sale service).

### 12.6 Sale read (minimal Phase 8)

| Method | Path | Permission | Purpose |
|---|---|---|---|
| GET | `/sales` | **`pos_sale`** (DECIDED §18.6) | Minimal POS history / reprint |
| GET | `/sales/{sale_id}` | **`pos_sale`** | Detail for reprint |
| GET | `/sales/by-invoice/{invoice_number}` | **`pos_sale`** | Reprint by number |
| POST | `/sales/{sale_id}/void` | `pos_void` | **Phase 12** not Phase 8 |

### 12.7 Printing

- Phase 8: **return invoice payload**; Flutter may generate receipt later or call print service.  
- Legacy PDF is Python ReportLab — **not ported in Phase 8** unless requested.  
- **Print hook:** client-side no-op / stub after checkout success (interface required).

---

## 13. POS State Machine

```
                    ┌─────────────┐
                    │   EMPTY     │  cart = []
                    └──────┬──────┘
           add line / scan │
                           ▼
                    ┌─────────────┐
         edit qty/  │ HAS_ITEMS   │◄──── remove → back to EMPTY if last line
         discount   └──────┬──────┘
                           │ customer/method ready checks
                           ▼
                    ┌─────────────┐
                    │ READY_FOR_  │  non-empty; totals valid
                    │ CHECKOUT    │
                    └──────┬──────┘
                           │ open payment (F8)
                           ▼
                    ┌─────────────┐   validation fail
                    │ PAYMENT_    │──────────────────► HAS_ITEMS / READY
                    │ PENDING     │   (toast / field error)
                    └──────┬──────┘
                           │ confirm + POST /sales OK
                           ▼
                    ┌─────────────┐
                    │ COMPLETED   │ → clear cart → EMPTY
                    └─────────────┘

Side transitions:
  HAS_ITEMS / READY ──hold──► HELD ──restore──► HAS_ITEMS (replace confirm)
  HELD ──delete──► (removed)
  PAYMENT_PENDING ──stock conflict / 409/422──► READY_FOR_CHECKOUT (+ refresh stock)
  PAYMENT_PENDING ──network error──► PAYMENT_PENDING (retry; idempotency key)
  any ──clear cart (F12)──► EMPTY
  COMPLETED ──print hook──► EMPTY (print non-blocking)

Validation error substate: inline on PaymentDialog (not full-screen state)
Stock conflict: return to READY + line-level stock error
Cancelled payment: dismiss dialog → READY_FOR_CHECKOUT
```

**Not Phase 8 states:** VOIDED, RETURNED (Phase 12).

---

## 14. RBAC

### 14.1 Existing scopes (Phase 4 — already seeded)

| Scope | admin | manager | cashier |
|---|---|---|---|
| `pos_sale` | ✅ | ✅ | ✅ |
| `pos_credit_sale` | ✅ | ✅ | ✅ |
| `pos_discount` | ✅ | ✅ | ✅ |
| `pos_void` | ✅ | ✅ | ❌ |
| `pos_return` | ✅ | ✅ | ✅ |
| `product_view` | ✅ | ✅ | ✅ |
| `customer_view` / `customer_manage` | ✅ | ✅ | ✅ (cashier has both) |
| `inventory_view` | ✅ | ✅ | ❌ |

**No new scopes PROPOSED for Phase 8 core** unless:

| Idea | Scope? | Decision |
|---|---|---|
| Discount over threshold PIN | Reuse `POST /auth/reauth` + `pos_discount` | **PROPOSED: no new scope** |
| Hold/restore | `pos_sale` | **DECIDED §18.3** (server-side) |
| Favorites toggle | `product_view` | **DECIDED §18.5** (included; non-blocking) |
| Sale history / reprint | **`pos_sale`** | **DECIDED §18.6** |

### 14.2 Legacy vs new

| Legacy | New |
|---|---|
| PIN for discount > 500 (`require_pin` role any) | Flutter reauth dialog → `POST /auth/reauth` then allow discount; server enforces max discount policy if any |
| Login skippable; `current_user` may be None | **JWT required** — every POS call authenticated |
| Void without PIN | `pos_void` (admin/manager only) — Phase 12 |
| No UI role gating beyond PIN | Permission-gated nav + buttons via `hasPermissionProvider('pos_sale')` |
| Independent return no PIN | Phase 12 + `pos_return` |

**Cashier can complete normal sales** with existing seeds — matches legacy (any logged-in user can sell).

---

## 15. Performance Targets

| Target | Mapping | Bottleneck risks (legacy → new) |
|---|---|---|
| Product lookup p95 < 100ms | `GET /products/search` + `barcode-lookup`; indexes on barcode, name | Legacy: no SQL LIMIT on search → **new must keep limit ≤50**; LIKE %term% can't use btree — consider trigram/ilike strategy later (**UNVERIFIED need**) |
| First product page < 200ms | `GET /products?page_size=40` | Index on name; avoid loading images |
| Sale command < 500ms excl. print | `POST /sales` single tx | Rowcount-guarded updates; avoid N+1; connection pool; no PDF in tx |
| Navigation < 100ms | Flutter local state | Cart updates client-side only until checkout |

**Legacy bottlenecks identified:**

1. Full result set search without LIMIT  
2. Client-side pagination after loading all matches  
3. Post-commit multi-statement work on UI thread  
4. PDF generation synchronous after sale  
5. Stock re-read per qty click (OK) but no batch validate  

**New mitigations:** server pagination/limit, cart purely local, print async/stub, single tx checkout, barcode index.

---

## 16. Legacy → New Feature Matrix

| Legacy feature | Legacy file/function | New destination | Phase |
|---|---|---|---|
| POS screen init | `show_pos` | Flutter `PosScreen` | **8** |
| Search debounce 250ms | `pos_search_preview` | Flutter provider timer + `GET /products/search` | **8** |
| Enter/scan add | `add_to_cart` | Flutter + `GET /products/barcode-lookup` then search fallback | **8** |
| Exact barcode preference | casefold loop | Server: barcode-lookup first; search exact short-circuit (exists) | **8** |
| Variant barcode direct add | `get_variant_by_barcode` | barcode-lookup `kind=variant` | **8** |
| Variant picker | `_show_variant_picker` | Reuse Phase 6 `variant_picker.dart` | **8** |
| Weighted dialog | `_add_weighted_product_dialog` | Flutter qty/price dialog | **8** |
| Selling unit display/step | `_is_weighted_unit` / step | Phase 6 unit labels + base qty | **8** |
| Product card click add | `_product_card_v4` / row handlers | Flutter list/grid onTap | **8** |
| Category filter | combo + `_match_category_filter` | `GET /products?category_id` or client filter | **8** |
| Stock status chips (hard 5) | `render_pos_products` | Client filter using `low_stock_threshold` from product (**improve**) | **8** |
| Sort name/price/stock | `_pos_toggle_sort` | `sort_by` query (exists) | **8** |
| Pagination 40 | client slice | server page_size=40 | **8** |
| Favorites manual+auto | `modules/favorites.py` | New favorites API/table | **8** (DECIDED §18.5 — non-blocking) |
| Packs in POS list | pack rows top | Phase 10 pack API + UI | **10** |
| Pack cart line + validate | `_pack_cart_line` / `_validate_pack_in_cart` | Phase 10 | **10** |
| Cart display/summary | `update_cart_display` | Flutter cart state derived totals | **8** |
| Qty ± with stock cap | `update_cart_quantity` | Flutter local + stock from lookup | **8** |
| Remove / clear | `remove_from_cart` / `clear_cart` | Flutter | **8** |
| Invoice discount + PIN | `edit_sale_discount` | Dialog + reauth; `invoice_discount` on POST /sales | **8** |
| Item discount + PIN | `_open_item_discount_dialog` | Dialog; `line_discount` on lines | **8** |
| Customer select | `select_customer` | Minimal picker `GET /customers/search` | **8** minimal; CRUD **9** |
| Payment methods UI | `complete_sale` | PaymentDialog | **8** |
| paid/change/debt calc | `confirm_payment` | Client preview + server authority | **8** |
| create_invoice tx | `SalesManager.create_invoice` | `SaleService.create_sale` | **8** |
| Stock guarded decrement | sales.py UPDATE | Sale service + inventory movement | **8** |
| inventory_movements on sale | sales.py INSERT | typed `sale` movement + source sale id | **8** |
| customers.balance += debt | sales.py | inside sale tx + debt_ledger entry | **8** minimal / history **9** |
| debt_transactions separate | `record_debt` | merge into sale tx as `debt_ledger_entries` | **8** |
| Hold/restore in-memory | `hold_current_sale` | Client-only **or** server holds **PROPOSED** | **8** decision |
| Invoice number format | `INV-…` | Server-generated (same or UUID-safe) | **8** |
| Print PDF 80mm/A4 | `_create_invoice_pdf` | Stub hook; PDF later | **8 hook only** / print later |
| Invoice history UI | `show_invoices_history_dialog` | `GET /sales` list + detail | **8 minimal** / full later |
| Void invoice | `void_invoice` | Phase 12 | **12** |
| Independent return | `show_independent_return_dialog` | Phase 12 | **12** |
| Debt pay | `pay_debt` | Phase 9 | **9** |
| Customer CRUD UI | customers page | Phase 9 | **9** |
| debt_ceiling | stored unused | Phase 9 decide enforcement | **9** |
| Settings allow_debt / pin threshold / print flags | `app_settings.json` | Phase 8 minimal defaults; settings UI later | **8 partial / settings later** |
| Keyboard shortcuts F6–F12 | `bind_shortcuts` | Flutter Shortcuts/Focus | **8** |
| Audit log sale_completed | `log_action` | Optional `audit_logs` insert post-tx | **8 optional** |
| Device name | `_get_device_name` | `device_id` on sale + login device_name | **8** |
| Barcode scan hardware | implicit keyboard | Flutter text field autofocus | **8** |
| Offline / network monitor | legacy reconnect modal | Out of scope / later | **Later** |
| License check | commented out | N/A | **Deferred** |
| Reports top products etc. | `modules/reports.py` | Phase 14 | **14** |
| Purchases | `create_purchase_invoice` | Phase 11 | **11** |
| Packs CRUD | `modules/packs.py` | Phase 10 | **10** |

**No silent omissions:** every POS-related legacy feature above has a destination.

---

## 17. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Legacy variant parent double-decrement ambiguity | High | **DECIDED:** variant sale decrements variant only; parent not touched (§18.1–2) |
| Folding item discounts into one invoice number loses per-line data | Medium | **DECIDED:** `line_discount` + `invoice_discount` remain separate (§18.11) |
| Holding sales only in memory loses work | Medium | **DECIDED:** server-side persisted holds; no stock reserve (§18.3–4) |
| No payment method in legacy → bad reports | Medium | Use new `payment_method` + `sale_payments` |
| Debt balance vs ledger divergence (legacy) | High | **DECIDED:** single atomic tx for balance + ledger + stock + sale (§18.13) |
| Double-submit checkout | Medium | Disable button + **required** `client_request_id` idempotency (§18.12) |
| LIKE %term% performance at scale | Medium | limit 50; index barcode; monitor |
| Packs not ready (Phase 10) but legacy POS shows packs | Medium | **DECIDED:** packs excluded from Phase 8 UI (§18.7) |
| Favorites table missing in new schema | Low | **DECIDED:** favorites in Phase 8 but must not block core POS (§18.5) — migration if needed |
| Selling-unit cart complexity (Phase 7 lesson) | High | Convert to base qty at add; store `selling_unit_id` as metadata only |
| Archived products in legacy search | Low | New: exclude archived by default |
| Print stack (ReportLab) not in Flutter | Low | Return invoice JSON; print later |
| Concurrent stock races | Medium | Guarded UPDATE / version; return 409/422 with line detail |
| PIN threshold config missing in new settings | Low | Hardcode default 500 until settings phase **PROPOSED** |
| Invoice number collision across devices | Low | Keep millisecond + unique constraint; consider UUID suffix |

---

## 18. Unverified Decisions — RECORDED (2026-09-24)

**Product owner decisions below are now the binding specification for Step 2. No production implementation until recorded — they are now recorded.**

| # | Decision | Resolution |
|---|---|---|
| 1 | **Variant parent stock semantics** | Variant sale decrements **variant quantity only**. |
| 2 | **Variant vs parent double-decrement** | Parent `products.quantity` is **NOT** decremented for a variant sale. |
| 3 | **Hold persistence** | Holds are **server-side persisted** (new table; not in-memory). |
| 4 | **Hold stock reservation** | Holds **do NOT reserve stock**. Validate at restore and checkout only. |
| 5 | **Favorites scope** | **Included in Phase 8**, but must **not block core POS** (feature-flag / progressive; core checkout ships regardless). |
| 6 | **Sale history permission** | **`pos_sale`** for minimal POS history / reprint (not `report_financial`). |
| 7 | **Pack checkout in Phase 8** | **Packs excluded from Phase 8**; deferred to **Phase 10**. |
| 8 | **Zero-price product checkout** | **Allowed** (price = 0 OK). |
| 9 | **Negative price** | **Rejected** (422 validation). |
| 10 | **Low-stock status threshold** | Uses **`product.low_stock_threshold`** (per product), not hard-coded 5. |
| 11 | **Discount fields** | **`line_discount` and `invoice_discount` remain separate** fields (not folded into one header discount). |
| 12 | **Idempotency** | **Idempotency key required** for checkout (`client_request_id` mandatory). |
| 13 | **Transaction atomicity** | Sale + stock + payments + debt ledger are **atomic** (one transaction; rollback on any failure). |
| 14 | **Error handling** | **No silent exception handling.** Failures surface as explicit errors. |
| 15 | **Success contract** | **No false success.** Response success only after commit confirmed. |
| 16 | **Implementation gate** | **No production implementation until these decisions are recorded** — now satisfied by this section. |

### Still open / hardware / lower priority (not blockers for Step 2 start)

3. **Archived products on POS search** — legacy appears to include them. **UNVERIFIED** intended behavior (default: exclude archived).  
5. **Pack savings display** — no formula found. **UNVERIFIED** (moot until Phase 10).  
6. **`sale_discount` rounding** — not rounded to 2 dp in legacy. **UNVERIFIED** drift impact (new: round to 2 dp).  
11. **Barcode scanner suffix/timing** — hardware-dependent. **UNVERIFIED.**  
12. **`allow_debt` setting** in new app — not present. **PROPOSED default true.**  
14. **Customer balance write in Phase 8 vs Phase 9** — **PROPOSED Phase 8 writes on credit/partial sale** (required by #13 atomicity).  
15. **Print** — Phase 8 hook only vs full PDF. **PROPOSED hook only.**  
16. **Void/return from POS header** — Phase 12; hide buttons in Phase 8 or show disabled. **PROPOSED hide.**

---

## 19. Proposed Phase 8 Implementation Sequence

> Awaiting approval to start Step 2. All 16 §18 decisions are now recorded — ready for coding when approved.

### Step 2 — Backend POS Core
1. Schemas: `CreateSaleRequest` (with required `client_request_id`) / response; hold + favorites schemas.  
2. `SaleService.create_sale` — **single atomic transaction**: sales + sale_lines (`line_discount` separate from header `invoice_discount`) + stock guard (**variant-only for variant lines**) + inventory_movements + sale_payments + debt ledger/balance if needed. **No silent exceptions; no false success.**  
3. Idempotency: `client_request_id` **required** — replay returns same sale.  
4. Routes: `POST /sales`, `GET /sales`, `GET /sales/{id}`, `GET /sales/by-invoice/{n}` (all history/reprint → `pos_sale`), holds CRUD/restore, favorites endpoints, `GET /customers/search`.  
5. Validation: unit_price ≥ 0 (zero OK, negative 422); low-stock status from `product.low_stock_threshold`.  
6. Migration: **holds table** + **favorites table** (favorites must not block core POS).  
7. Unit tests: totals, discounts, stock conflicts (variant-only), credit-without-customer, payment method matrix, movement rows, idempotency, permissions, no-packs-in-Phase-8.

### Step 3 — Flutter POS Screen
1. Replace `/pos` placeholder.  
2. Cart state + totals matching verified formulas (separate line/invoice discounts).  
3. Search/scan via barcode-lookup + search; debounce 250ms.  
4. Variant/weighted/selling-unit add paths (reuse Phase 6 pickers); **no pack UI** (Phase 10).  
5. Cart editor, discounts + reauth PIN.  
6. Minimal customer picker.  
7. Payment dialog + checkout → `POST /sales` with required idempotency key; disable double-submit.  
8. Hold/restore UI → server-side holds (no stock reserve).  
9. Favorites strip (included; must not block core POS).  
10. Shortcuts F6–F10, F12; responsive + RTL tests; zero overflow.  
11. Widget/unit tests per roadmap.

### Step 4 — Verification
1. `python -m pytest tests` (sequential).  
2. `flutter test` / `flutter analyze` / `flutter build windows`.  
3. Manual checklist (scan, weighted, variant, discount PIN, partial/credit, stock conflict, hold).  
4. Report; **do not start Phase 9**.

---

## 20. Deliverable Checklist (Step 1)

| # | Section | Status |
|---|---|---|
| 1 | Legacy POS architecture | ✅ §1 |
| 2 | POS workflow | ✅ §2 |
| 3 | Product lookup | ✅ §3 |
| 4 | Cart model | ✅ §4 |
| 5 | Pricing | ✅ §5 |
| 6 | Discounts | ✅ §5 |
| 7 | Stock behavior | ✅ §6 |
| 8 | Hold/restore | ✅ §7 |
| 9 | Payment boundary | ✅ §8 |
| 10 | Sale persistence | ✅ §9 |
| 11 | Transaction boundaries | ✅ §10 |
| 12 | New POS architecture | ✅ §11 |
| 13 | API blueprint | ✅ §12 |
| 14 | POS state machine | ✅ §13 |
| 15 | RBAC | ✅ §14 |
| 16 | Performance | ✅ §15 |
| 17 | Legacy → new mapping | ✅ §16 |
| 18 | Risks | ✅ §17 |
| 19 | Unverified decisions | ✅ §18 — **16 decisions RECORDED 2026-09-24** |
| 20 | Proposed Phase 8 sequence | ✅ §19 |

---

## Appendix A — Files Inspected

### Legacy (`python_app/`)
- `main.py`
- `gui/main_window.py` (primary — POS, cart, payment, hold, print, PIN, shortcuts)
- `gui/sale_window.py` (dead)
- `gui/add_product_window.py` (dead)
- `modules/sales.py`, `sales_v21.py` (dead)
- `modules/products.py`, `customers.py`, `debts.py`, `inventory.py`, `packs.py`, `favorites.py`, `reports.py`
- `database/db_manager.py`
- `config/db_config.json`, `config/app_settings.json`
- `locales/translations_new_additions.json` (spot)

### New app (`new_app/`)
- Backend: `app/api/v1/{router,auth,users,products,categories,inventory}.py`
- `app/services/{base,auth,catalog,inventory}.py`
- `app/schemas/{common,auth,catalog,inventory}.py`
- `app/models/{enums,user,catalog,party,sale,inventory,debt,...}.py`
- `app/domain/{unit_conversions,packaging,valuation}.py`
- `app/core/{seed,exceptions,security,config}.py`
- `app/api/dependencies.py`
- Migrations 0001–0008 (esp. 0002 domain models, 0005–0007 units, 0008 inventory)
- Flutter: `lib/router/app_router.dart`, `lib/network/api_client.dart`, products/stock features, auth permission helpers, `lib/core/strings.dart`

### Docs
- `docs/PHASE_0_ROADMAP.md` (Phase 8/9 scope)
- `docs/PHASE_0_API_BLUEPRINT.md` (sketch sales endpoints)
- `docs/PHASE_0_POS_WORKFLOW.md` (prior workflow sketch — **code-verified where it conflicts**)
- `docs/PHASE_0_DATABASE_ANALYSIS.md`, `PHASE_0_FEATURE_MATRIX.md`
- `docs/PHASE_5/6/7_IMPLEMENTATION.md`

**Note:** `PHASE_0_POS_WORKFLOW.md` says barcode-only fast path and “exactly 1 result → add; multiple → dialog” — **live `add_to_cart` uses exact-or-first, not a multi-result dialog**. Live code wins.

---

## Appendix B — Legacy Workflows Discovered

1. Primary piece-product sale (search/scan → cart → pay → print)  
2. Weighted product sale (qty or amount entry)  
3. Variant sale via variant barcode  
4. Variant sale via forced picker  
5. Weighted variant sale  
6. Hold → restore / delete  
7. Invoice-level discount (± PIN)  
8. Item-level discount (± PIN)  
9. Partial payment / full credit with customer  
10. Cash/card full payment  
11. Customer select from POS, payment modal, or customers page  
12. Pack sale (Phase 10)  
13. Independent product return (Phase 12)  
14. Invoice history reprint / void (Phase 12 void)  
15. Favorites toggle + auto refresh  

---

## Appendix C — Critical Rules Observed

- **No production implementation in this step.**  
- **No migrations. No Flutter POS. No Phase 9.**  
- Existing working phases unchanged.  
- Evidence-based; **UNVERIFIED** where ambiguous; **§18 decisions are binding.**  
- **STOP after this report** (Step 1). Implementation only after explicit approval of this spec.

---

## Appendix D — End Report Summary

### Files inspected
See Appendix A.

### Legacy workflows discovered
See Appendix B (15 flows).

### Ambiguities found
§18 — **16 decisions RECORDED 2026-09-24** (variant stock, holds, favorites, packs, discounts, idempotency, atomicity, errors). Lower-priority items remain marked UNVERIFIED (archived search, scanner hardware, print scope, void buttons).

### Proposed POS architecture
§11 — Flutter cart-local + FastAPI `SaleService` single atomic transaction + Phase 2/4/5/6/7 reuse; barcode-lookup already prepared; server-side holds; required idempotency key.

### Proposed implementation phases
§19 — Step 2 Backend POS Core → Step 3 Flutter POS → Step 4 Verification → human approval → only then consider Phase 9.

**STATUS: STEP 1 COMPLETE — 16 DECISIONS RECORDED. AWAITING APPROVAL TO START STEP 2. DO NOT IMPLEMENT YET.**
