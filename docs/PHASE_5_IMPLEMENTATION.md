# Phase 5 Implementation — Products & Categories

**Date:** 2026-09-23
**Status:** ✅ Phase 5 Complete (automated verification green) — manual verification pending (checklist below)
**Backend Tests:** 282 passed, 0 failed (224 existing + 58 new)
**Flutter Tests:** 176 passed, 0 failed (123 existing + 17 original Phase 5 + 18 UI-refinement + 8 final-redesign + 10 color-polish)
**Flutter Analyze:** No issues found
**Flutter Build:** `√ Built build\windows\x64\runner\Debug\supermarket_pos.exe`

> **Scope note:** This phase implements Products & Categories ONLY.
> **Phase 6 (Variants/Units/Weighted Products) was NOT started.**

---

## 1. Objective

Deliver complete product and category management end-to-end:

- Product CRUD with validation, barcode uniqueness, category assignment, and soft-archive (never hard delete).
- Category CRUD with unique names, active-product counts, and soft-archive.
- Product search (name/barcode text + exact barcode), pagination, category filter, archive-status filter, and server-side sorting.
- Flutter desktop UI: product list with debounced search, product create/edit form, manage-categories dialog, all localized in ar/fr/en and permission-gated.
- Tests for CRUD, search, pagination, validation, authorization, and localization.

## 2. Existing Architecture Before Phase 5

| Layer | Status |
|---|---|
| DB schema (Phase 2) | `products`, `categories` tables already exist: barcode unique + nullable, `image_path` String(500), `low_stock_threshold`, `expiry_date`, `numeric_money/quantity` NUMERIC(18,3), `archived_at` on both tables — **no migration needed** |
| Backend foundation (Phase 3) | DI, Pydantic schemas, `BaseService.transaction()`, `BaseRepository`, structured errors, pagination conventions (`page`/`page_size`, DEFAULT 40, MAX 100) |
| Auth/RBAC (Phase 4) | JWT + `require_permission(scope)` + seeded `PermissionScope` enum (`product_view/create/update/archive`, `category_view/manage`) |
| Flutter (Phase 4) | Riverpod shell with permission-gated nav rail, `AppStrings.t(key, locale)` for ar/fr/en, `hasPermissionProvider` |
| Products screen | Placeholder only (`Text('Products - Phase 2')`) |

**Migration assessment:** none required — Phase 2 schema is sufficient.

## 3. Architecture After Phase 5

```
HTTP Request
    ↓
RequestIDMiddleware → FastAPI Router (/api/v1/products|categories)
    ↓
Depends(require_permission(PermissionScope.X))   ← 401 / 403
    ↓
Pydantic request schema (StrictBaseModel, Decimal money/qty)
    ↓
ProductService / CategoryService (BaseService.transaction(),
                                  ConflictError / BusinessRuleError / ValidationError)
    ↓
ProductRepository / CategoryRepository (server-side pagination,
                                        sort allowlist, bounded search,
                                        grouped-subquery product counts)
    ↓
SQLAlchemy Session (Depends(get_db), shared by get_current_user)
    ↓
Response: model → to_*_response() → Pydantic → JSON (Decimal → float)
```

Flutter: `ProductsScreen` → `productsProvider` (StateNotifier, 300 ms debounce, stale-response guard) → Dio `ApiClient` → backend.

## 4. Files Created/Modified

### New files

| File | Purpose |
|---|---|
| `new_app/backend/app/schemas/catalog.py` | `CategoryResponse/Create/Update/List`, `ProductResponse/Create/Update/List/Search`; blank-name validators, unit allowlist, barcode/sku strip, `image_path` extension check (`BARCODE_MAX_LENGTH=50`, `ALLOWED_IMAGE_EXTENSIONS`) |
| `new_app/backend/app/repositories/catalog.py` | `ProductRepository` (list/search/low-stock/barcode_exists, `PRODUCT_SORT_FIELDS` allowlist, `DEFAULT_SEARCH_LIMIT=20`, `MAX_SEARCH_LIMIT=50`), `CategoryRepository` (list_with_counts, name_exists, `CATEGORY_SORT_FIELDS`) |
| `new_app/backend/app/services/catalog.py` | `CategoryService`, `ProductService` — uniqueness checks, category-usable rule, `exclude_unset` partial updates, soft archive |
| `new_app/backend/app/api/v1/products.py` | 7 product endpoints + `to_product_response()` (adds `category_name`) |
| `new_app/backend/app/api/v1/categories.py` | 5 category endpoints + `to_category_response()` (adds `product_count`, `is_archived`); `DEFAULT_CATEGORY_PAGE_SIZE=100` |
| `new_app/backend/tests/unit/test_products_categories.py` | 58 tests (see §12) |
| `new_app/lib/features/products/models.dart` | `ProductModel`, `CategoryModel` (Decimal → String for lossless display) |
| `new_app/lib/features/products/products_providers.dart` | `productsProvider`, `categoriesProvider` — debounced search, filters, mutation methods returning display-ready error or null |
| `new_app/lib/features/products/products_screen.dart` | Full list UI: search, status/category filters, table, pagination, permission-gated actions |
| `new_app/lib/features/products/product_form_dialog.dart` | Create/edit form with inline validation |
| `new_app/lib/features/products/categories_dialog.dart` | Manage-categories dialog (list/create/edit/archive) |
| `new_app/test/widget/products_screen_test.dart` | 11 widget tests |
| `new_app/test/unit/products_localization_test.dart` | 6 localization tests |

### Modified files

| File | Change |
|---|---|
| `new_app/backend/app/api/dependencies.py` | **Fix:** `get_current_user` now uses `Depends(get_db)` (was opening its own `_factory` session, bypassing DI and test `get_db` overrides) |
| `new_app/backend/app/api/v1/router.py` | Registered products (`/products`) and categories (`/categories`) routers |
| `new_app/backend/app/{schemas,repositories,services}/__init__.py` | Barrel exports |
| `new_app/lib/core/strings.dart` | 26 new Phase 5 keys × ar/fr/en |
| `new_app/lib/features/products/products_screen.dart` | Placeholder → full screen |
| `new_app/lib/router/app_router.dart` | Products nav destination gated on `product_view`; dynamic rail index math |

## 5. API Endpoints

### Products

| Method | Path | Permission | Notes |
|---|---|---|---|
| GET | `/api/v1/products` | `product_view` | `page`, `page_size` (default 40, max 100), `limit` alias, `search`, `category_id`, `status=active\|archived\|all`, `sort_by`/`sort_order` allowlist |
| GET | `/api/v1/products/search` | `product_view` | `q`, `barcode` (exact, takes precedence), `include_archived`, `limit` ≤ 50; active-only by default |
| GET | `/api/v1/products/low-stock` | `product_view` | Per-product `low_stock_threshold` or `threshold` override |
| GET | `/api/v1/products/{id}` | `product_view` | 404 `NOT_FOUND` |
| POST | `/api/v1/products` | `product_create` | 201; 409 duplicate barcode; 422 validation/archived category |
| PUT | `/api/v1/products/{id}` | `product_update` | Partial (`exclude_unset`); 409/404/422 |
| DELETE | `/api/v1/products/{id}` | `product_archive` | **Soft archive** (sets `archived_at`); idempotent; 200 returns archived object |

Route order: `/search` and `/low-stock` are registered before `/{product_id}`.

### Categories

| Method | Path | Permission | Notes |
|---|---|---|---|
| GET | `/api/v1/categories` | `category_view` | Paginated, default `page_size=100`, default `status=all`; includes `product_count` |
| GET | `/api/v1/categories/{id}` | `category_view` | 404 |
| POST | `/api/v1/categories` | `category_manage` | 201; 409 duplicate name |
| PUT | `/api/v1/categories/{id}` | `category_manage` | Partial; 409 duplicate name |
| DELETE | `/api/v1/categories/{id}` | `category_manage` | **Soft archive**; product `category_id` references preserved |

Error contract (structured, from `app/core/exceptions.py`): 401 `UNAUTHORIZED`, 403 `FORBIDDEN` (`permission_denied`), 404 `NOT_FOUND`, 409 `CONFLICT`, 422 `VALIDATION`/`BUSINESS_RULE` — all with `code`, `message_key`, `message`, `details`, `request_id`.

## 6. Validation

**Schema level (Pydantic):**

- `name`: required, 1–200 (products) / 1–100 (categories), blank-after-strip rejected.
- `price`, `cost`, `quantity`, `low_stock_threshold`: `Decimal`, `ge=0`, `max_digits=18`, `decimal_places=3` (matches NUMERIC(18,3); never binary float for persisted values).
- `barcode` ≤ 50, `sku` ≤ 50, `description` ≤ 5000: empty string → `None`.
- `unit`: must be a `ProductUnit` enum value (`piece|kg|gram|liter|milliliter|meter|pack`).
- `image_path`: ≤ 500 chars, extension in `.png/.jpg/.jpeg/.webp/.bmp`.
- `expiry_date`: ISO date or null.
- Query params: `status` pattern `^(active|archived|all)$`, `sort_order` `^(asc|desc)$`, `sort_by` allowlists — invalid → 422.

**Service level:**

- Duplicate barcode (create or update to a new value) → `ConflictError` 409.
- Duplicate category name → `ConflictError` 409.
- `category_id` on a **new** product: must exist (422) and must not be archived (`BusinessRuleError` 422, message "Cannot assign a product to an archived category").
- Existing products keep their `category_id` when the category is archived (historical integrity).

**Flutter form level (inline, non-authoritative):** name required; price/cost/quantity/threshold must parse as ≥ 0 numbers; expiry must parse as a date. Backend remains authoritative; server messages are shown inline on failure.

## 7. Authorization

Scopes come from the Phase 4 `PermissionScope` enum and seed (`app/core/seed.py`):

| Scope | admin | manager | cashier |
|---|---|---|---|
| `product_view` | ✓ | ✓ | ✓ |
| `product_create` / `product_update` / `product_archive` | ✓ | ✓ | — |
| `category_view` | ✓ | ✓ | ✓ |
| `category_manage` | ✓ | ✓ | — |

**Key decision:** the API blueprint says products may be created by "admin, cashier", but the Phase 4 seed grants `product_create` only to admin/manager. **Seed policy is authoritative** — cashiers can *view* products (POS needs it) but cannot create/edit/archive; this is documented here as the deliberate supersession of the blueprint line.

**Flutter gating:**

- Nav rail "Products" destination visible only with `product_view` (`ScaffoldWithNav.productViewScope`); screen itself re-checks and shows `permission_denied` if opened directly.
- Add Product button: `product_create`; edit + cost column: `product_update`; archive: `product_archive`; Manage Categories: `category_manage`.
- **Cost column is hidden from cashiers** (they lack `product_update`) — cost data never renders for view-only roles.

Unauthenticated → 401 `UNAUTHORIZED`; wrong scope → 403 `FORBIDDEN`. All enforced server-side (`require_permission`) — UI gating is convenience, not security.

## 8. Service Layer & Business Rules

`app/services/catalog.py`:

- Both services extend `BaseService`; every write runs inside `self.transaction()` (rollback on error, tested by Phase 3 suite).
- **Archive-only deletion:** `archive()` sets `archived_at` once (idempotent); no hard delete path exists for products/categories — historical sales/purchases keep their FK references.
- Partial update: `request.model_dump(exclude_unset=True)` → only provided fields change.
- `_ensure_category_usable`: parent category must exist; archived categories reject *new* assignments only.
- Structured logging (`structlog`) on create/update/archive with entity IDs — no PII/secrets logged.

## 9. Repository Layer & Queries

- **Pagination:** count query + page query with `OFFSET/LIMIT`; never full-table loads. Page math (`pages`) done in the endpoint via `_pages()`.
- **Sort allowlists:** `PRODUCT_SORT_FIELDS` / `CATEGORY_SORT_FIELDS` — client input never reaches `getattr` unchecked; unknown values fall back to `name`/`sort_order`. Tie-breaker `Product.id`/`Category.name` for stable paging.
- **Search:** `LIKE %term%` on `name OR barcode` (case-insensitive), bounded by `MAX_SEARCH_LIMIT=50`; exact-barcode branch short-circuits for POS scan path and takes precedence over text.
- **Category product counts:** one query — grouped subquery (`COUNT` of ACTIVE products `GROUP BY category_id`) `LEFT JOIN` categories. No per-category count queries (regression-tested: query count is constant as categories grow; no standalone `SELECT count(*) FROM products` in the list path).
- **Category data on products:** loaded via the models' existing `lazy="selectin"` relationships (constant batched statements, not N+1).
- **Low stock:** `quantity <= low_stock_threshold` (or `threshold` override), active-only, ordered by quantity asc.

## 10. Flutter UI

**`ProductsScreen`** (ConsumerStatefulWidget, shell-provided Scaffold):

- Header: localized title, **Manage Categories** (gated), **Add Product** (gated), refresh.
- Filters: search `TextField` (key `products-search-field`, 300 ms debounce via `ProductsNotifier.setSearch`), status dropdown (`active|archived|all`), category dropdown (active categories + "All").
- Body: loading spinner → error+retry → `products-empty` → `DataTable` (name+thumbnail, barcode, category, price, **cost** [gated], quantity, unit, edit/archive actions [gated]). Thumbnails use `Image.file` + `cacheWidth` when a local `image_path` exists.
- Footer: total count, `page / pages`, prev/next (`IconButton`s disabled at bounds).
- Stale-response guard: monotonic `_requestId` discards out-of-order list responses (debounce races).
- Archive flow: confirmation dialog (`archive_product_confirm`) → `DELETE` → success/error SnackBar.

**`ProductFormDialog`:** name, barcode, SKU, price, cost (gated), quantity, low-stock threshold, unit dropdown, category dropdown (loaded `status=active`; "No Category" option), description, image path, expiry date (YYYY-MM-DD). Inline validation before submit; server error shown under the fields (`product-form-error`); success closes dialog + localized SnackBar.

**`CategoriesDialog`:** list with active product counts and archived chips; create/edit name form (duplicate name → 409 message inline); archive with confirmation. "No Category" never appears in the product dropdown (archived excluded via `activeItems`).

**Providers:** Riverpod `StateNotifier`s watching `apiClientProvider.dio`; mutation methods return `String?` error (null = success) so dialogs can render failures without a second state channel; locale resolved lazily (`ref.read`) so language changes never recreate notifiers.

## 11. Localization

26 new keys added to `lib/core/strings.dart` in **all three** maps (ar/fr/en kept in sync), including: `categories`, `create_category`, `edit_category`, `archive_category_confirm`, `category_created/updated/archived`, `manage_categories`, `add_product`, `edit_product`, `archive_product_confirm`, `product_created/updated/archived`, `cost`, `unit`, `description`, `expiry_date`, `image_path`, `low_stock_threshold`, `sku`, `all`, `archived`, `no_category`, `prev`, `next`.

Unit units (`piece`, `kg`, …) are displayed as technical enum values (not translated) — consistent across locales. Arabic RTL flows through Flutter's standard localization pipeline (Phase 4 fix); no hardcoded direction.

## 12. Tests

### Backend — `tests/unit/test_products_categories.py` (58 new; suite total 282)

| Area | Coverage |
|---|---|
| Authentication | list/create require JWT (401); invalid token rejected |
| List/pagination | empty list shape; create+get round-trip; 404; page/page_size/pages math; `limit` alias |
| Search/filter/sort | search param; `/search` by name and exact barcode; bounded limit; category filter; price desc; name asc |
| Validation | missing/blank name, negative price/cost/quantity, invalid category, bad date, bad image extension, bad unit → 422 |
| Conflicts | duplicate barcode create/update → 409 structured `CONFLICT`; multiple NULL barcodes allowed |
| Update/archive | partial update persists unmet fields; negative rejected; archive → excluded from active list, visible as `archived`/`all`, retrievable by id; idempotent; invalid `status` → 422 |
| Low stock | only below-threshold active product returned |
| Categories | CRUD, blank name 422, duplicate name 409, product_count excludes archived products, archive + `status=active` exclusion, archived category rejects new product (422), existing product keeps reference, 404 |
| Permissions | cashier: list ok, create/update/archive product → 403, list categories ok, create/archive category → 403; manager: can create product/category; structured `FORBIDDEN` contract |
| Integrity | barcode/name unique at DB level; N+1 regression — query count constant across category growth, no per-category product count query |

Fixtures: StaticPool in-memory SQLite, `seed_roles_and_permissions`, real `AuthService.setup_first_admin`/`create_user`, real login for JWTs, `app.dependency_overrides[get_db]` (enabled by the `get_current_user` DI fix).

### Flutter — 17 new (suite total 140)

`test/widget/products_screen_test.dart` (11):

1. Loads via `GET /api/v1/products`, lists products/category/barcode/total, query params `page=1&status=active`, categories loaded.
2. Cost column visible with `product_update`.
3. Add dialog: validation blocks empty submit (no POST); valid payload POSTs and closes.
4. Debounce: 1 request initially, none at +100 ms, exactly one search request after 300 ms with `search=apple`.
5. Status filter → `status=archived`.
6. Manage Categories dialog opens and lists categories.
7. Create category → `POST /categories` with `{'name': 'Dairy'}`.
8. Archive product → confirmation text → `DELETE /products/{id}`.
9. Edit opens form pre-filled (`Apple Juice`).
10. No `product_view` → no nav, no product request.
11. `product_view` without create/update/archive → no Add/Manage buttons, no row action keys.

`test/unit/products_localization_test.dart` (6): all 26 keys exist non-key/non-empty in ar/fr/en; ar↔en and fr↔en actually differ for a majority; unknown locale falls back to the key.

## 13. Verification Results

```
Backend:
  python -m compileall app          → 0 errors
  pytest tests                      → 282 passed, 0 failed (4 pre-existing warnings)

Flutter:
  flutter analyze                    → No issues found
  flutter test                       → 140 passed, 0 failed
  flutter build windows --debug      → √ Built build\windows\x64\runner\Debug\supermarket_pos.exe
```

### Manual verification checklist (MUST be done by a human on a fresh build)

1. `cd new_app/backend && python -m uvicorn app.main:app --reload`
2. `cd new_app && flutter run -d windows`
3. Login as **Admin** → Products appears in the nav rail → open it → list loads.
4. **Add Product**: fill name + price → save → row appears; leave name empty → inline error, no request.
5. Duplicate barcode → backend 409 message shown in the form.
6. Assign a category, then Manage Categories → archive that category → adding a *new* product to it fails with the archived-category message; the existing product still shows the category.
7. Search "app" → results update once after typing stops (no request per keystroke).
8. Edit a product (change price) → table reflects it after save.
9. Archive a product → confirmation → disappears from `active` filter; visible under `archived`/`all`.
10. Switch locale ar/fr/en → all new labels translated; Arabic layout RTL.
11. Login as **Cashier** → Products nav visible (view), **no** Add/Manage buttons, **no** cost column; `curl` PUT/POST with a cashier token → 403.

## 14. Known Limitations, Deferred Decisions & Phase Completion

### Known limitations (deliberate, Phase 5 scope)

1. **No image file picker/upload.** `image_path` is a validated local-path text field (`image_path` extension allowlist enforced server-side); thumbnails render via `Image.file` when the path exists. Roadmap's "image upload / image picker" needs a file-picker dependency and/or multipart endpoint — **deferred**, no new Flutter dependencies were added in this phase.
2. **Variants / `variants_count`** (blueprint product payload) belong to Phase 6 — not implemented.
3. **Blueprint `limit` vs `page_size`:** both accepted on `GET /products` (`limit` aliases `page_size`) for blueprint compatibility; internally always `page_size`.
4. **Blueprint "cashier may create products" superseded by Phase 4 seed** (see §7) — documented decision, not a bug.
5. Category `parent_id` is accepted and validated (exists, not self) but the UI exposes only flat categories (no parent picker); hierarchy UI deferred.
6. Decimal values serialize to JSON numbers (FastAPI default) — Flutter stores them as strings for display; precision within NUMERIC(18,3) is preserved through Decimal on the backend.

### Deferred decisions

- Image storage strategy (local upload dir vs static serving) — revisit with a real file-picker phase.
- Product variants, packs, unit conversion — Phase 6/10.
- `GET /products/{id}` blueprint "with variants" detail shape — Phase 6.

### Phase completion checklist

- [x] Product CRUD with validation (create/read/update/archive)
- [x] Category CRUD with counts + archive
- [x] Barcode management (unique, optional, exact-match lookup)
- [ ] Image upload — **deferred** (path field only; see limitations)
- [x] Product search with pagination
- [x] Category filtering
- [x] Backend tests: 58 new, 282 total, 0 failed
- [x] Flutter tests: 17 new, 140 total, 0 failed
- [x] `flutter analyze`: clean
- [x] `flutter build windows`: success
- [ ] Manual verification checklist (human, fresh build) — **pending**
- [x] Report written (`docs/PHASE_5_IMPLEMENTATION.md`)
- [x] **Phase 6 NOT started**

**STOP — Phase 5 complete. Do NOT start Phase 6.**

---

## 15. Phase 5 UI Refinement — Responsive Design, UX Polish & Image Picker

**Date:** 2026-09-23
**Trigger:** RenderFlex overflow at `products_screen.dart:72` (Row overflowed 90/241px at `BoxConstraints(0.0<=w<=275.5, 0.0<=h<=Infinity)` when the products content box was squeezed by the nav rail + padding). Corrective pass: responsive breakpoints, adaptive table/cards, modern dense UI, subtle animations, real Windows image picker replacing the `image_path` text field, responsive dialogs, and regression tests. **No ClipRect/suppression, no per-width screen duplication, no backend authorization changes, no Phase 6 features.**

### 15.1 Overflow root cause (before)

The header was a hard `Row(title | Spacer | Manage Categories | Add Product)` and the toolbar was a hard `Row(search(320) | status | category | Spacer | refresh)`. Inside the shell (`NavigationRail` + `VerticalDivider`) + `Padding(24)`, the content box at constrained widths (e.g. ~275px) could not fit the minimum intrinsic widths of those Rows → classic RenderFlex overflow. No `LayoutBuilder`, no breakpoints, fixed `SizedBox(width: 480/360)` dialogs.

### 15.2 Responsive solution & breakpoints

`productsLayoutModeFor(width)` maps **full window width** (`MediaQuery.sizeOf(context).width`, not the post-rail content box, so documented breakpoints match real window sizes):

| Mode | Width | Behavior |
|---|---|---|
| **WIDE** | ≥ 1200 | Full `DataTable` (all permitted columns: name+thumb, barcode, category, price, cost*, quantity, unit, actions). Single-row header + single-row toolbar. |
| **MEDIUM** | 800–1199 | Compact toolbar via `Wrap` (search/filters/refresh reflow into multiple runs). Reduced table columns (drops `category` and `unit`; keeps name, barcode, price, cost*, quantity, actions — all still horizontally scrollable). Header stacks title above wrapping action buttons. |
| **NARROW** | < 800 | Adaptive product **cards** (`ListView` of `Card`s) — no table. Cards show name, barcode, category, price, quantity, unit, cost*, status chip, thumbnail, and authorized edit/archive actions. Header + toolbar fully stacked/`Wrap`. |

\* **Cost column / cost card line remains gated on `product_update`** in all three layouts (existing Phase 5 permission rule preserved; cashiers never see cost). Nav remains gated on `product_view` (`ScaffoldWithNav.productViewScope`).

Verified at **600×500, 800×600, 1024×768, 1366×768, 1920×1080** and Arabic RTL (default locale) — no overflow exceptions.

### 15.3 Toolbar redesign

- **WIDE:** classic single `Row` (search → status → category → spacer → refresh).
- **MEDIUM/NARROW:** `Wrap(spacing: 12, runSpacing: 12)` so controls reflow into multiple runs instead of overflowing — equivalent of "Row1 search / Row2 filters / Row3 actions" without hard-coding row splits.
- Search field width steps down (320 → 240) below wide; all controls keep usable minimum widths; `isDense` inputs for denser modern feel.

### 15.4 Animation strategy (built-in Flutter only, 150–250ms)

- Body states (loading / error / empty / table / cards) wrapped in `AnimatedSwitcher(duration: 200ms, easeOut/easeIn, FadeTransition)` — subtle cross-fade when switching states or layout modes.
- No custom animation packages; no layout-mode "jump" beyond the fade.
- Dialog appearance uses Flutter's default route transition (no extra delay).

### 15.5 Product form dialog (sectioned & responsive)

Structure (two-column on wide dialog content ≥480px, single-column scrollable below — usable at 600×500):

1. **Product Information** — name, barcode, SKU, unit, category  
2. **Pricing** — price, cost* (gated), quantity, low-stock threshold  
3. **Additional Information** — description, expiry date  
4. **Product Image** — preview + choose/change/remove  
5. **Actions** — Cancel | Save (dialog actions bar)

`_fieldRow(narrow: …)` helper switches each field pair between `Row(Expanded…)` and stacked `Column` — one code path, no duplicated per-width widgets.

### 15.6 Image picker implementation

- **Package:** `file_picker: ^10.1.2` (small, well-supported, Windows open-dialog).
- **Abstraction:** `ProductImagePickerService` (`pickImage() → Future<String?>`, `isSupportedPath()`) in `lib/features/products/product_image_picker_service.dart`, provided via Riverpod `productImagePickerProvider`.
- **Real impl:** `FilePickerProductImageService` — native dialog filtered to `.png/.jpg/.jpeg/.webp/.bmp` (matches backend `ALLOWED_IMAGE_EXTENSIONS`); **cancel returns `null` (not an error)**; path re-validated against the allowlist even if the OS filter is bypassed.
- **Test impl:** `FakeImagePicker` injected in tests — **never opens a real dialog**.
- **UI:** preview box (`product-image-preview`), file name (`product-image-name`), Choose/Change (`product-image-choose`), Remove (`product-image-remove`), placeholder when empty/missing/invalid (`product-image-placeholder` — no crash). Raw `image_path` TextField **removed**.
- **Contract unchanged:** selected path still submitted as `image_path` in the existing POST/PUT JSON (local-first). Cancel does not clear an existing selection. Unsupported extension → inline error, path not applied.
- **Legacy parity:** mirrors `python_app/gui/main_window.py` filedialog workflow (`اختيار صورة` / `حذف الصورة` / `لا توجد صورة` placeholders).

### 15.7 Image preview behavior

| Situation | Render |
|---|---|
| No path | Placeholder icon + "No image" |
| Path set, file exists | `Image.file` cover thumbnail |
| Path set, file missing/unreadable | Placeholder (icon + label), **no exception** |
| Unsupported extension selected | Rejected before apply; error `unsupported_image`; placeholder remains |
| User cancels dialog | Selection unchanged; no error |

Missing/invalid paths on the **list thumbnails** (table cell + card) already fell back to `Icons.inventory_2_outlined` — retained and covered by a new test.

### 15.8 Localization (additive only)

11 new keys added to **all three** ar/fr/en maps in `lib/core/strings.dart` (existing 26 Phase 5 keys untouched; ar stays RTL, fr/en LTR):

`product_image`, `choose_image`, `change_image`, `remove_image`, `image_preview`, `selected_image`, `unsupported_image`, `no_image`, `product_information`, `pricing`, `additional_information`.

### 15.9 Categories dialog responsiveness

Fixed `SizedBox(width: 480, height: 360)` replaced with viewport-aware sizing (`MediaQuery`-based width/height clamps) so the dialog fits 600×500 and other small windows; inner create/edit name form width similarly clamped. Same keys/behavior (`categories-dialog`, `create-category-button`, `category-name-field`, etc.).

### 15.10 Files created/modified (refinement pass)

| File | Change |
|---|---|
| `new_app/pubspec.yaml` | **+ `file_picker: ^10.1.2`** |
| `new_app/lib/features/products/product_image_picker_service.dart` | **NEW** — `ProductImagePickerService` abstraction + `FilePickerProductImageService` + `productImagePickerProvider` |
| `new_app/lib/features/products/products_screen.dart` | LayoutBuilder + `productsLayoutModeFor` breakpoints; responsive header/toolbar; adaptive table vs cards; `AnimatedSwitcher` body; cost gating preserved |
| `new_app/lib/features/products/product_form_dialog.dart` | Sectioned responsive form; image picker section (preview/choose/replace/remove); `image_path` TextField removed |
| `new_app/lib/features/products/categories_dialog.dart` | Viewport-aware dialog sizing |
| `new_app/lib/core/strings.dart` | +11 keys × ar/fr/en |
| `new_app/test/widget/products_responsive_test.dart` | **NEW** — 18 regression tests (see §15.11) |

No backend files changed in this pass.

### 15.11 Tests added (18 new → suite total 158)

`test/widget/products_responsive_test.dart`:

**Responsive ProductsScreen (no overflow, correct mode):**
1. 600×500 → cards mode, no overflow  
2. 800×600 → table (medium) + wrapping toolbar, no overflow  
3. 1024×768 → table (medium), no overflow  
4. 1366×768 → table, no overflow  
5. 1920×1080 → table (wide), no overflow  
6. Arabic RTL 600×500 → cards, no overflow  
7. View-only (`product_view` only) at 600×500 → cards, **cost hidden**  
8. Layout helper unit: 600/799→narrow, 800/1199→medium, 1200/1920→wide  

**Dialogs at narrow (600×500):**  
9. Product form opens with image section + submits, no overflow  
10. Categories dialog opens/lists, no overflow  

**Image picker (mocked `FakeImagePicker`, real dialog never opened):**  
11. Choose action exists on empty form + placeholder  
12. Successful pick → preview + file name + remove button  
13. Cancel (null path) → no error, placeholder retained  
14. Replace → swaps file name first→second  
15. Remove → clears to placeholder, remove button gone  
16. Unsupported `.exe` → rejected, path not applied, no crash  
17. Edit product with existing (missing) image path → preview area + remove + placeholder, no crash  
18. Card thumbnail with missing path → inventory icon fallback, no crash  

All **140 pre-existing Flutter tests** still pass unchanged (original 11 products widget tests + 6 localization + others).

### 15.12 Verification results (refinement pass)

```
Backend:
  python -m compileall app          → 0 errors
  pytest tests                      → 282 passed, 0 failed (unchanged; no backend edits)

Flutter:
  flutter pub get                   → file_picker 10.3.10 resolved
  flutter analyze                    → No issues found
  flutter test                       → 158 passed, 0 failed (140 existing + 18 new)
  flutter build windows --debug      → √ Built build\windows\x64\runner\Debug\supermarket_pos.exe
```

### 15.13 Remaining image-storage limitation (documented, not a bug)

**Local-path only.** The picker stores/returns an absolute filesystem path; the backend validates the extension and stores it in `products.image_path` (String 500) as before. **No file is uploaded, copied, or served** — thumbnails render via `Image.file` only if that path exists on the **same machine**.  

**Multi-PC concern (future migration proposal):** if two terminals point at one backend, product images picked on PC-A will show placeholders on PC-B. Recommended future work (out of Phase 5 scope): multipart upload endpoint + shared static/upload directory (or object storage), replace `image_path` with a server-relative URL/id. **Not implemented now** — no cloud storage, no new backend endpoints in this pass.

### 15.14 Manual verification checklist additions (human, fresh build)

Run **in addition to** the §13 checklist, at each size + ar/fr/en:

1. `flutter run -d windows`, resize window to **600×500, 800×600, 1024×768, 1366×768, 1920×1080** → Products screen shows cards below 800, table at/above 800; **no red overflow stripes**.  
2. At 600×500: header title + Add/Manage buttons stack (no cut-off); toolbar controls wrap; all filters reachable.  
3. **Cost column/line hidden** for Cashier (view-only) at every size; visible for Admin.  
4. **Add Product** → sectioned form scrolls; **Choose image** opens Windows file dialog → pick a `.png` → preview + filename appear; **Cancel** dialog → no error, selection unchanged; **Remove** → placeholder; pick a non-image (if forced) → "Invalid image" error, path not set.  
5. Edit a product that has `image_path` but missing file → placeholder, no crash; Save still works.  
6. Switch ar/fr/en → new image/section labels translated; Arabic layout RTL; no overflow.  
7. Archive/create flows still work (SnackBars, confirmation dialogs).  

**Manual verification remains PENDING — Phase 5 is NOT marked manually-verified until a human completes this checklist on a fresh build.**

### 15.15 Phase 5 status after refinement

- [x] Product CRUD (backend, unchanged)  
- [x] Category CRUD (backend, unchanged)  
- [x] Responsive products list (wide/medium/narrow, 5 viewports + RTL)  
- [x] Overflow root cause fixed (no ClipRect, no error suppression)  
- [x] Adaptive table ↔ cards  
- [x] Responsive toolbar (Wrap reflow)  
- [x] Sectioned responsive product form  
- [x] Real image picker with preview/replace/remove (file_picker, mockable)  
- [x] Responsive categories dialog  
- [x] Subtle 150–250ms animations (AnimatedSwitcher)  
- [x] Backend tests: 282 passed (unchanged)  
- [x] Flutter tests: 158 passed (140 existing + 18 new)  
- [x] `flutter analyze`: clean  
- [x] `flutter build windows`: success  
- [x] Report updated (`docs/PHASE_5_IMPLEMENTATION.md` §15)  
- [ ] **Manual verification checklist (human) — still PENDING**  
- [x] **Phase 6 NOT started**  

---

## 16. Phase 5 Final Visual Redesign — Products Workspace

**Scope:** visual/UX only. No backend logic, permissions, auth, business rules, or Phase 6 features. Image picker kept. No ClipRect/error suppression. No hardcoded visible strings.

### 16.1 Previous visual problems

| Problem | Symptom |
|---|---|
| Table floated in empty space | Intrinsic-width content centered/small inside a huge content area after nav rail + padding — not a professional full-width workspace |
| Fragmented chrome | Page title/actions, toolbar, and table felt like unrelated widgets |
| Material `DataTable` sizing | Intrinsic column widths left gaps; hard to distribute flex |
| Thin states | Loading/empty/error felt detached from the workspace |
| Empty-state overflow | First-frame flash of empty state before `load()` could overflow short workspaces (RenderFlex, e.g. +14 px at 800×600, +24 px at 600×500 view-only) |
| Toolbar flex bug (fixed mid-pass) | `Expanded` search inside `Wrap` (medium/narrow) threw a parent-data RenderFlex error |

### 16.2 Layout redesign (structure)

```
Padding(page 16)
└─ Column (crossAxisAlignment: stretch)
   ├─ A. Page header          (wide: 72 px Row title|actions; else stacked + Wrap)
   ├─ spacer 12
   ├─ B. Unified toolbar      (Material surface, same column width)
   ├─ spacer 12
   └─ C. Expanded workspace   (Material Card-like surface, full remaining W+H)
      ├─ AnimatedSwitcher body (table | cards | loading | empty | error)
      └─ D. Pagination footer (48 px, attached top border)
```

- **Full-width solution:** outer `Column` + `CrossAxisAlignment.stretch` + `Expanded` workspace — no intrinsic `DataTable` width. Medium/narrow toolbar search uses `LayoutBuilder`-sized `SizedBox` (never `Expanded` inside `Wrap`).
- **Workspace key:** `products-workspace`; toolbar: `products-toolbar`.

### 16.3 Page header & toolbar

- **Header:** title (`products-header-title`) + subtitle (`products-header-subtitle`, wide/medium only); primary Add Product (`products-add-button`); secondary Manage Categories (`products-manage-categories-button`). Wide = fixed-height Row; medium/narrow = stacked + `Wrap`.
- **Toolbar (unified):** search (`products-search-field`, flexible/`Expanded` in wide Row — no hardcoded 320 px), clear (`products-search-clear`), status (`products-status-filter`), category (`products-category-filter`), refresh (`products-refresh-button`) **inside the toolbar** (not header). Dropdowns use `initialValue:`.

### 16.4 Table density (wide/medium)

- Custom flex-column table (`products-table` / `products-table-body`) instead of material `DataTable`.
- Columns: Product (thumb 32 + name [+ category subline when category col hidden]) flex 40, Barcode 16, Category 16 (wide only), Price 12, Cost 12 (**gated** `product_update`), Quantity 12, Unit 10 (wide only), Actions fixed 96 (edit/archive gated).
- Header strip 44 px; rows `_HoverRow` min 56 px, separators, hover highlight; numeric cells `AlignmentDirectional.centerEnd`; compact icon buttons + tooltips.
- **Narrow (<800):** adaptive cards (`products-cards`, `product-card-*`); cost chip gated.

### 16.5 Workspace states (inside workspace, not floating)

| State | Keys | Behavior |
|---|---|---|
| Loading | `products-loading` | Centered indicator + localized `loading` |
| Empty | `products-empty`, `products-empty-add` | Icon + text; Add only if `product_create`; **scrollable** (`SingleChildScrollView`) to avoid short-viewport overflow |
| Error | `products-error`, `products-retry` | Message + retry (re-calls load); **scrollable** |
| List | table/cards + `products-footer` | Footer: `products-total`, prev/next, `products-page-indicator` |

`AnimatedSwitcher` (200 ms fade) retained between body states.

### 16.6 Responsive behavior (unchanged breakpoints)

| Mode | Width | Chrome |
|---|---|---|
| WIDE | ≥ 1200 | Full table, single-row toolbar, Row header |
| MEDIUM | 800–1199 | Table (no category/unit cols), wrapping toolbar, stacked header |
| NARROW | < 800 | Cards, fixed-width search in Wrap, stacked header |

Breakpoints: `MediaQuery.sizeOf(context).width` (full window). Valid at 600×500, 800×600, 1024×768, 1366×768, 1920×1080 + Arabic RTL; zero RenderFlex overflow.

### 16.7 Dialog visual polish (light)

- `product_form_dialog.dart`: section headers now title + hairline `Divider` (matches workspace density). Behavior/image picker unchanged.
- `categories_dialog.dart`: tighter `AlertDialog` paddings; dense compact `ListTile`s. Behavior unchanged.

### 16.8 Tests added (8) — redesign regression

`test/widget/products_responsive_test.dart` group **Phase 5 final visual redesign**:

1. Wide workspace fills content width after nav rail (workspace ≈ toolbar column width)  
2. Medium: table + unified toolbar keys + footer  
3. Empty state + Add when permitted  
4. Empty state hides Add without `product_create`  
5. Error state + retry re-fetches  
6. Loading state key while fetch gated  
7. Search clear resets query  
8. Permission gates: no edit/archive/cost without `product_update`

`stubRequests` extended with optional `loginBody` + `productQueryLog`.

### 16.9 Verification results (final redesign pass)

```
Backend:
  python -m compileall app          → 0 errors
  pytest tests                      → 282 passed, 0 failed (unchanged)

Flutter:
  flutter analyze                    → No issues found
  flutter test                       → 166 passed, 0 failed (158 + 8 new)
  flutter build windows --debug      → √ Built build\windows\x64\runner\Debug\supermarket_pos.exe
```

### 16.10 Manual verification checklist additions (human, fresh build)

Run **in addition to** §13/§15 checklists, at 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080 + ar/fr/en:

1. Products content fills width after nav rail — table/workspace **not** a small centered island.  
2. Header + toolbar + workspace read as one surface; refresh is in the toolbar.  
3. Wide: all columns + hover rows; medium: reduced columns; narrow: cards.  
4. Cost column/chip hidden for view-only; edit/archive hidden without `product_update`.  
5. Empty list → empty state + Add (admin) / no Add (view-only); no overflow stripes.  
6. Kill backend or force API error → error + Retry works.  
7. Search → clear (×) resets; filters + pagination still work.  
8. Image picker still works end-to-end (choose/preview/remove).  

**Manual verification remains PENDING — Phase 5 is NOT marked manually-verified until a human completes this checklist on a fresh build.**

### 16.11 Phase 5 status after final visual redesign

- [x] Full-width product workspace (stretch + Expanded; custom flex table)  
- [x] Unified toolbar (search/filters/refresh) + compact page header  
- [x] Dense table (52–64 px rows, separators, hover, directional numerics)  
- [x] Workspace states (loading/empty/error+retry) inside workspace; empty/error scrollable (no short-viewport overflow)  
- [x] Pagination footer attached to workspace  
- [x] Responsive modes preserved (wide/medium/narrow + RTL, 5 viewports)  
- [x] Permission gates preserved (view/create/update/archive/category_manage)  
- [x] Image picker preserved (no `image_path` TextField regression)  
- [x] Backend tests: 282 passed (unchanged)  
- [x] Flutter tests: 166 passed (158 + 8 redesign)  
- [x] `flutter analyze`: clean  
- [x] `flutter build windows`: success  
- [x] Report updated (`docs/PHASE_5_IMPLEMENTATION.md` §16)  
- [ ] **Manual verification checklist (human) — still PENDING**  
- [x] **Phase 6 NOT started**  

---

## 17. Phase 5 Final Color & Visual Polish

**Date:** 2026-09-23  
**Scope:** Visual/UI-only polish of ProductsScreen + dialogs (semantic colors, status badges, category/unit pills, richer rows/cards, page-size footer, hover, typography). No backend logic, permissions, endpoints, or schema changes. Image picker untouched.

### 17.1 Semantic color system

| Token | Source | Usage |
|---|---|---|
| `AppColors.success` | `new_app/lib/core/colors.dart` | Active stock status badge/dot |
| `AppColors.warning` | same | Low-stock badge/qty emphasis |
| `AppColors.error` | same | Out-of-stock badge; archive action tint; error state |
| `theme.colorScheme.primary` | theme | Header icon box, Add button, refresh tint, hover accent |
| Category pill palette | deterministic hash of `categoryId ?? name` into 8 subdued colors | Category pills (no DB change) |

**Stock status derivation** (`productStockStatus`): archived wins; else `qty <= 0` → out; `qty <= lowStockThreshold` → low; else active. Labels reuse existing keys `active` / `low_stock` / `out_of_stock` / `archived`.

### 17.2 Widgets & keys

| Widget / key | Purpose |
|---|---|
| `_StatusBadge` / `product-status-{active\|low\|out\|archived}` | Pill badge with semantic color + dot |
| `_CategoryPill` / `product-category-pill-{label}` | Colored category chip (table + cards) |
| `_UnitPill` / `product-unit-{label}` | Unit chip on cards (and wide table) |
| `_metricBlock` | Label + value stack (price/qty/cost) with qty color by status |
| `_HoverRow` | Row hover with `AnimatedContainer` 150ms + primary tint |
| `products-header-title` / `products-header-subtitle` | Compact header (subtitle hidden on narrow) |
| `products-toolbar` / `products-search-field` / `products-status-filter` / `products-category-filter` / `products-sort-filter` / `products-refresh-button` | Unified toolbar |
| `products-table` / `products-cards` / `products-workspace` / `products-footer` | Workspace shells |
| `products-page-size` / `products-prev-page` / `products-next-page` / `products-page-indicator` / `products-total` | Footer pagination + page size (20/40/60/100, ≥800 only) |
| `product-edit-{id}` / `product-archive-{id}` / `products-add-button` | Permission-gated actions (tinted icons) |

### 17.3 Localization

12 polish keys added × ar/fr/en in `strings.dart` (parity enforced by `constants_test` + `products_localization_test`):  
`products_subtitle`, `status`, `sort`, `refresh`, `actions`, `page_size`, `no_products`, `no_products_hint`, `in_stock`, `sort_name`, `sort_price`, `sort_quantity`, `sort_newest`.

### 17.4 Responsive fixes in this pass

1. **Status column overflow (RTL/narrow table):** status column fixed width 112px; badge uses compact padding + `FittedBox.scaleDown` in the cell — eliminates RenderFlex overflow at ~41px content width.  
2. **Zero-height card list at 600×500:** compacted narrow header (title + actions on one wrapping row, denser buttons), denser filter dropdowns, tighter page padding/spacers, search width from layout constraints, footer 44px on narrow — restores visible card children (was 4px viewport).  
3. Page-size control gated at `MediaQuery ≥ 800` so narrow footer stays compact.

### 17.5 Tests (10 new → 176 total)

Group `Phase 5 final color & visual polish` in `products_responsive_test.dart`:

1. Wide table shows status badge + category pill + unit pill + subtitle + sort + page-size.  
2. Narrow cards show status/pills; no subtitle; no page-size.  
3. Status header + active labels via `AppStrings` (ar).  
4. Page-size change → `page_size: 20`, `page: 1` via `setPageSize`.  
5. Sort dropdown on wide only; selecting price asc sends `sort_by`/`sort_order`.  
6. Sort dropdown hidden on narrow.  
7. Arabic RTL narrow: localized status, subtitle off, product name present.  
8. Out-of-stock status key when qty = 0.  
9. Low-stock status key at threshold.  
10. Archived status wins over stock qty.

Plus existing localization keys extended (`phase5Keys`) and full regression of prior 166 tests.

### 17.6 Verification

```
flutter analyze                    → No issues found
flutter test                       → 176 passed, 0 failed
flutter build windows --debug      → √ Built build\windows\x64\runner\Debug\supermarket_pos.exe
python -m compileall app           → OK
python -m pytest tests             → 282 passed
```

### 17.7 Manual verification checklist additions (human, fresh build)

Run **in addition to** §13/§15/§16 checklists, at 600×500 / 800×600 / 1024×768 / 1366×768 / 1920×1080 + ar/fr/en:

1. Status badges: active (green), low (amber), out (red), archived (muted) — table **and** cards.  
2. Category pills show distinct subdued colors per category; unit pill on cards.  
3. Quantity cell/card metric colored by stock state (red out / amber low / default active).  
4. Hover rows tint lightly; action icons tinted (edit primary-tinted, archive red-tinted).  
5. Footer: total, page indicator, prev/next; page-size dropdown only ≥800 width.  
6. Wide-only: sort dropdown + header subtitle. Narrow: no subtitle, no sort, no page-size.  
7. Short viewport 600×500: card list shows product names (not a collapsed strip); no overflow.  
8. Arabic RTL: badges/pills/labels localized; no overflow.

**Manual verification remains PENDING — Phase 5 is NOT marked manually-verified until a human completes this checklist on a fresh build.**

### 17.8 Phase 5 status after final color polish

- [x] Semantic colors (success/warning/error) on status + quantity  
- [x] Status badges + category pills + unit pills (table + cards)  
- [x] Richer rows/cards (metrics panel, denser hover, tinted actions)  
- [x] Typography hierarchy (header subtitle, metric labels, mono barcode)  
- [x] Hover polish (150ms animated tint)  
- [x] Page-size footer (UI-only `setPageSize`, resets page to 1)  
- [x] Responsive modes preserved (wide/medium/narrow + RTL, 5 viewports, zero overflow)  
- [x] Permission gates + image picker unchanged  
- [x] Backend tests: 282 passed (unchanged)  
- [x] Flutter tests: 176 passed (166 + 10 polish)  
- [x] `flutter analyze`: clean  
- [x] `flutter build windows`: success  
- [x] Report updated (`docs/PHASE_5_IMPLEMENTATION.md` §17)  
- [ ] **Manual verification checklist (human) — still PENDING**  
- [x] **Phase 6 NOT started**  

**STOP — Phase 5 final color & visual polish complete. Do NOT start Phase 6.**
