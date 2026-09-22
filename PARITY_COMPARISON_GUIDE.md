# PARITY COMPARISON GUIDE

Areas requiring careful forensic comparison between Python and Flutter implementations.

---

## 1. POS / Sales Flow

### Python (gui/main_window.py ~5000 lines)
- Cart is an in-memory list of dicts: `[{product_id, name, price, quantity, discount, total}]`
- Sale calculation done inline: subtotal = sum(items), discount applied, total = subtotal - discount
- Stock deduction: `UPDATE products SET quantity = quantity - %s WHERE id = %s`
- Variant sales: deducts from `product_variants.quantity` (not parent)
- Debt creation: `UPDATE customers SET balance = balance + %s` + `INSERT INTO debt_transactions`
- Invoice number: generated as `INV-YYYYMMDD-HHMMSS-XXXX`
- Idempotency: NOT implemented (can create duplicate sales on retry)
- Payment modes: cash, card, partial, credit (inline logic)
- Pack expansion: component products deducted individually

### Flutter (pos_controller.dart + sale_repository.dart)
- Cart is `List<CartItem>` in PosState (Riverpod Notifier)
- Sale calculation: client sends items + paid_amount + discount; backend calculates total
- Stock deduction: BACKEND handles (FastAPI pos_service.py)
- Variant sales: backend handles (only deduct parent when no variant)
- Debt creation: backend handles (customer balance update)
- Invoice number: BACKEND generates
- Idempotency: client sends `idempotency_key`; backend deduplicates
- Payment modes: cash, card, partial, credit (payment_dialog.dart)
- Pack expansion: backend handles (component deduction)

### Risk Areas
- [ ] Cart calculation: Python does client-side, Flutter sends raw items to backend
- [ ] Stock deduction location: Python = client, Flutter = server
- [ ] Idempotency: Python has none, Flutter has backend idempotency keys
- [ ] Pack expansion: Python = client inline, Flutter = backend
- [ ] Variant stock deduction: verify both deduct from correct table
- [ ] Debt calculation: verify both compute `debt_amount = max(0, total - paid_amount)`

---

## 2. Void Sale Behavior

### Python
- `UPDATE sales SET status = 'void' WHERE id = ?`
- Stock restored: `UPDATE products SET quantity = quantity + %s` (for each item)
- If variant sale: also restores variant quantity
- Customer balance: reverses `paid_amount` (known bug: should reverse `debt_amount`)

### Flutter
- Calls `POST /api/v1/pos/sales/{id}/void`
- Backend handles all reversal logic
- Backend fix: reverses `debt_amount = max(0, total - paid_amount)` (correct)
- Backend fix: variant void only restores variant OR parent (not both)

### Risk Areas
- [ ] Python has known bug: reverses `paid_amount` instead of `debt_amount`
- [ ] Python may have double stock restoration for variant voids
- [ ] Flutter backend has correct fixes; Flutter client just calls API
- [ ] **PARITY RISK: HIGH** — Python void behavior differs from Flutter

---

## 3. Inventory Management

### Python (modules/inventory.py + gui/main_window.py)
- `InventoryManager.get_all_products_with_stock()`: JOIN products + product_variants
- `InventoryManager.adjust_stock()`: direct `UPDATE products SET quantity = %s`
- `InventoryManager.get_low_stock_products()`: `WHERE quantity <= threshold`
- `InventoryManager.get_inventory_movements()`: from `inventory_movements` table
- `InventoryManager.add_stock_entry()`: INSERT movement + UPDATE quantity
- No floor check on negative inventory (known bug)

### Flutter
- `inventory_repository.dart` → `POST /api/v1/inventory/adjust`
- Backend has floor check: rejects if `new_qty < 0`
- Backend logs movements in `inventory_movements` table
- Flutter gets products from `GET /api/v1/inventory/products`

### Risk Areas
- [ ] Python allows negative inventory (bug); Flutter backend rejects it
- [ ] Movement creation: Python = inline, Flutter = backend
- [ ] Stock entry: verify both update quantity and log movement
- [ ] **PARITY RISK: MEDIUM** — Negative inventory behavior differs

---

## 4. Product Management

### Python (modules/products.py)
- `ProductManager.add_product()`: INSERT with barcode, name, price, cost, quantity, unit, category_id
- `ProductManager.search_products()`: LIKE query on name and barcode
- `ProductManager.get_product_by_barcode()`: exact barcode match
- Variants: separate `product_variants` table, CRUD inline in main_window.py
- Categories: `categories` table, CRUD via ProductManager

### Flutter (product_repository.dart)
- `POST /api/v1/pos/products` → backend creates product
- `GET /api/v1/pos/products` → list all
- `GET /api/v1/pos/products/barcode/{barcode}` → barcode lookup
- Variants: `GET /api/v1/pos/products/{id}/variants`, `POST /api/v1/pos/products/{id}/variants`
- Categories: `GET /api/v1/pos/categories`, `POST /api/v1/pos/categories`

### Risk Areas
- [ ] Barcode handling: verify both do exact match then LIKE fallback
- [ ] Variant creation: Python = direct DB, Flutter = API
- [ ] Product deletion: Flutter backend cleans up favorites + variants (Python may not)
- [ ] Category deletion: verify FK handling in both

---

## 5. Customer / Debt Management

### Python (modules/customers.py + modules/debts.py)
- `CustomerManager.add_customer()`: INSERT with name, phone, address
- `DebtManager.add_debt_transaction()`: INSERT with customer_id, amount, type, reference
- `DebtManager.get_customer_balance()`: SUM of debt transactions
- Balance updated: `UPDATE customers SET balance = balance + %s`

### Flutter (customer_repository.dart)
- `POST /api/v1/pos/customers` → create
- `GET /api/v1/pos/customers/{id}/debt` → get balance
- `POST /api/v1/pos/customers/{id}/debt/pay` → record payment

### Risk Areas
- [ ] Balance calculation: Python = stored column, Flutter = backend computed
- [ ] Debt payment: verify both reduce customer balance correctly
- [ ] Customer deletion: Flutter backend blocks if balance > 0 (Python may not)
- [ ] **PARITY RISK: MEDIUM** — Balance handling may differ

---

## 6. Packs / Bundles

### Python (modules/packs.py)
- `PacksManager.create_pack()`: INSERT pack + INSERT pack_items
- Pack sale: expands components, deducts each component's stock
- Pack price: set at pack level, overrides component prices

### Flutter (pack_repository.dart + pos_controller.dart)
- `POST /api/v1/pos/packs` → create pack with items
- Pack sale: backend expands components and deducts stock
- Pack price: set at pack level

### Risk Areas
- [ ] Pack expansion: Python = client, Flutter = backend
- [ ] Component stock deduction: verify both deduct correct quantities
- [ ] Pack void: verify both restore component stock

---

## 7. Reports

### Python (modules/reports.py)
- `get_dashboard_stats()`: aggregate queries for today's stats
- `get_sales_by_period()`: date range filtering
- `get_top_products()`: JOIN sale_items + products, ORDER BY quantity
- `get_low_stock_products()`: WHERE quantity <= threshold
- `get_profit_report()`: revenue - COGS calculation

### Flutter (report_repository.dart)
- `GET /api/v1/reports/financial` → full financial report
- `GET /api/v1/reports/top-products` → with COGS and date filtering
- `GET /api/v1/reports/categories` → category-level profit
- `GET /api/v1/reports/slow-moving` → products with low sales velocity
- `GET /api/v1/reports/margin-warnings` → below-cost and near-cost items
- `GET /api/v1/reports/crowd-prediction` → traffic-based predictions

### Risk Areas
- [ ] COGS calculation: Python may not include COGS in all reports
- [ ] Top products: Flutter has date filtering + COGS; Python may not
- [ ] Financial report: Flutter has more metrics than Python
- [ ] Export: Flutter supports CSV/Excel/PDF; Python may not
- [ ] **PARITY RISK: LOW** — Flutter has more features; Python is subset

---

## 8. Printing / Receipts

### Python (gui/main_window.py)
- Receipt generated as text string
- Printed via `os.startfile(path, "print")` on Windows
- Receipt format: store name, items list, totals, footer
- No PDF generation

### Flutter (receipt_pdf_generator.dart + print_service.dart)
- Receipt generated as PDF (80mm thermal or A4)
- Uses `pdf` package for generation
- Uses `printing` package for print/preview/save
- Arabic RTL layout support
- Receipt includes: store name, items, totals, footer, barcode

### Risk Areas
- [ ] Receipt format: Python = text, Flutter = PDF
- [ ] Print method: Python = Windows only, Flutter = cross-platform
- [ ] Arabic support: Python = basic, Flutter = RTL PDF
- [ ] **PARITY RISK: LOW** — Different implementations, same output intent

---

## 9. Settings

### Python
- `config/app_settings.json`: store_name, store_phone, invoice_footer, paper_size, theme, language
- `config/db_config.json`: host, port, user, password, database
- Settings loaded at startup, saved on change
- `database/db_manager.py` provides `load_db_config()` / `save_db_config()`

### Flutter
- `ServerConfig` data class with JSON serialization
- Persisted via SharedPreferences
- Settings: store_name, store_phone, invoice_footer, paper_size, theme_mode, language, allow_debt, low_stock_threshold, auto_print, ask_before_print

### Risk Areas
- [ ] Settings keys: verify naming consistency
- [ ] allow_debt: Flutter has explicit setting; Python may not
- [ ] low_stock_threshold: Flutter has configurable threshold; Python may use hardcoded value
- [ ] auto_print / ask_before_print: Flutter-specific settings

---

## 10. Localization

### Python (gui/main_window.py)
- `_TRANSLATIONS` dict embedded in main_window.py (~600 keys)
- `self.t(key)` method for translation lookup
- Languages: Arabic (ar), French (fr), English (en)
- RTL support via tkinter font configuration
- External: `locales/translations_new_additions.json`

### Flutter (app_localizations.dart)
- `AppLocalizations` class with ~600 keys
- Languages: Arabic (ar), French (fr), English (en)
- RTL support via Directionality widget
- All translations inline in Dart (no .arb files)

### Risk Areas
- [ ] Key names: verify consistency between Python `_TRANSLATIONS` and Flutter keys
- [ ] Missing translations: some keys may exist in one but not the other
- [ ] RTL handling: different mechanisms (tkinter vs Flutter)
- [ ] **PARITY RISK: MEDIUM** — Translation key mismatches possible

---

## 11. Error Handling

### Python
- tkinter messagebox for errors
- Database errors caught with try/except
- No structured error responses

### Flutter
- `ApiException` with `ApiErrorKind` enum
- `ErrorMapper` maps exceptions to localized user messages
- Structured error envelope from backend: `{error: {code, message, correlation_id}}`

### Risk Areas
- [ ] Error messages: Python = hardcoded strings, Flutter = localized
- [ ] Error granularity: Flutter has more specific error types
- [ ] Correlation IDs: Flutter tracks request IDs, Python does not

---

## 12. Authentication / Authorization

### Python
- Single-user mode (no login required)
- Staff management via PIN system (users table)
- License check on startup (device fingerprinting)
- No role-based access control for retail features

### Flutter
- Full JWT-based authentication
- Login page with username + PIN
- Token stored in SharedPreferences
- Role-based access: admin vs cashier
- Device authorization: only approved devices can access data

### Risk Areas
- [ ] Auth model: Python = none/single-user, Flutter = full auth
- [ ] Role restrictions: Flutter enforces admin-only for some features
- [ ] Device auth: Flutter has device pairing; Python does not
- [ ] **PARITY RISK: N/A** — Fundamentally different auth models

---

## 13. Database Schema

### Python (database/db_manager.py)
- MySQL/MariaDB via PyMySQL
- Tables: products, categories, sales, sale_items, customers, debt_transactions, inventory_movements, product_variants, packs, pack_items, favorite_items, users, sessions, settings
- Schema DDL embedded in db_manager.py `init_database()` method

### Flutter
- No direct database access
- All data via FastAPI backend REST API
- Backend uses same MySQL/MariaDB tables

### Risk Areas
- [ ] Schema differences: Python may have tables/columns that backend doesn't
- [ ] Data type differences: Python uses PyMySQL types, backend uses PyMySQL types
- [ ] Migration: Python has `tools/migrate_sqlite_to_mysql.py`

---

## 14. Networking / Multi-PC

### Python (utils/network_discovery.py)
- UDP broadcast on port 50000
- TCP parallel scan for device detection
- Basic discovery: `get_local_ip()`, `broadcast_discovery()`, `scan_subnet()`
- No device pairing or authorization

### Flutter (core/network/)
- Full LAN networking stack:
  - NetworkConfig with roles (server/client/local)
  - DiscoveryService (UDP + TCP sweep)
  - DiscoveryResponder (Main PC mode)
  - PairingService (register, approve, deny)
  - ConnectionMonitor (health polling + self-healing)

### Risk Areas
- [ ] Discovery protocol: Python = basic UDP, Flutter = UDP + TCP + pairing
- [ ] Device auth: Flutter has full pairing; Python has none
- [ ] **PARITY RISK: N/A** — Flutter has more features

---

## 15. Expense Tracking

### Python (gui/main_window.py)
- Inline in main_window.py
- Simple CRUD for expenses
- Linked to sales for daily profit calculation

### Flutter (expenses_page.dart)
- Dedicated page with CRUD
- Date range filtering
- Paid-from-drawer flag
- Linked to financial report

### Risk Areas
- [ ] Expense fields: verify consistency
- [ ] Drawer deduction: verify both handle paid_from_drawer correctly

---

## Summary of High-Risk Parity Areas

| Priority | Area | Risk | Reason |
|----------|------|------|--------|
| HIGH | Void sale behavior | `paid_amount` vs `debt_amount` reversal | Known Python bug |
| HIGH | Double stock deduction (variant sales) | Python may deduct both parent + variant | Known Python bug |
| MEDIUM | Negative inventory | Python allows, Flutter rejects | Different floor behavior |
| MEDIUM | Customer balance handling | Stored column vs computed | Different calculation approach |
| MEDIUM | Translation key consistency | May have mismatches | Different localization systems |
| LOW | Reports (COGS, advanced metrics) | Flutter has more features | Python is subset |
| LOW | Printing (format, method) | Text vs PDF | Different output format |
| N/A | Authentication | Single-user vs full auth | Fundamentally different |
| N/A | Networking | Basic vs full LAN | Flutter has more features |
