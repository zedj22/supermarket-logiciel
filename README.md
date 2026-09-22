# FEATURE COVERAGE

Navigation map showing which Python and Flutter files implement each retail feature.

| # | Feature | Python Files | Flutter Files | Notes |
|---|---------|-------------|---------------|-------|
| 1 | **Login / Authentication** | `gui/main_window.py` (inline PIN system), `security/license.py` | `features/authentication/login_page.dart`, `core/auth/session_controller.dart` | Python: single-user mode, no formal login. Flutter: full auth with JWT tokens |
| 2 | **Dashboard** | `gui/main_window.py` (ReportsManager calls), `modules/reports.py` | `features/dashboard/dashboard_page.dart`, `features/dashboard/dashboard_controller.dart` | Python: embedded in main_window reports tab. Flutter: dedicated page |
| 3 | **Products** | `gui/main_window.py` (Products tab), `modules/products.py` | `features/products/products_page.dart`, `core/repositories/product_repository.dart` | Both support full CRUD + search |
| 4 | **Categories** | `gui/main_window.py` (Categories tab), `modules/products.py` | `core/repositories/category_repository.dart`, `features/products/categories_page.dart` (orphaned) | Python: separate tab. Flutter: categories managed within products page |
| 5 | **Variants** | `gui/main_window.py` (inline variant CRUD), `modules/products.py` | `features/products/products_page.dart`, `core/repositories/product_repository.dart`, `pos/widgets/variant_picker_dialog.dart` | Python: inline in main_window. Flutter: separate API + POS picker |
| 6 | **Packs** | `gui/main_window.py` (Packs tab), `modules/packs.py` | `features/packs/packs_page.dart`, `core/repositories/pack_repository.dart` | Both support bundle packs with component products |
| 7 | **Favorites** | `gui/main_window.py` (Favorites tab), `modules/favorites.py` | `core/repositories/favorite_repository.dart`, `pos/widgets/product_grid.dart` | Python: hybrid auto+manual. Flutter: manual toggle + auto-popular |
| 8 | **POS** | `gui/main_window.py` (POS tab, ~5000 lines) | `features/pos/pos_page.dart`, `features/pos/pos_controller.dart`, 8 widgets | Python: monolithic in main_window. Flutter: decomposed into controller + widgets |
| 9 | **Weighted Products** | `gui/main_window.py` (weight entry dialog) | `pos/widgets/weight_dialog.dart` | Both support kg/g/l/ml units with decimal quantities |
| 10 | **Cart** | `gui/main_window.py` (in-memory list, cart UI) | `pos/widgets/cart_panel.dart`, `pos_controller.dart` (PosState) | Python: tkinter Listbox/treeview. Flutter: Riverpod state + widget tree |
| 11 | **Customers** | `gui/main_window.py` (Customers tab), `modules/customers.py` | `features/customers/customers_page.dart`, `core/repositories/customer_repository.dart` | Both support CRUD + search |
| 12 | **Customer Debt** | `gui/main_window.py` (debt tracking), `modules/debts.py` | `core/repositories/customer_repository.dart` (debt endpoints) | Python: DebtManager with separate table. Flutter: via customer API endpoints |
| 13 | **Sales** | `modules/sales.py` (SalesManager), `gui/main_window.py` | `core/repositories/sale_repository.dart`, `features/sales/sales_history_page.dart` | Python: direct DB. Flutter: via API. Both track invoices, items, payments |
| 14 | **Sale Details** | `gui/main_window.py` (sale detail view) | `features/sales/invoice_details_page.dart` | Python: dialog in main_window. Flutter: dedicated page with receipt |
| 15 | **Returns** | `gui/main_window.py` (return logic inline) | `core/repositories/sale_repository.dart` (return endpoints) | Python: inline in main_window. Flutter: via API |
| 16 | **Voids** | `gui/main_window.py` (void logic inline) | `features/sales/sales_history_page.dart`, `sale_repository.dart.voidSale()` | Python: inline in main_window. Flutter: via API POST /void |
| 17 | **Inventory** | `gui/main_window.py` (Inventory tab), `modules/inventory.py` | `features/inventory/inventory_page.dart`, `features/inventory/inventory_controller.dart`, 3 widgets | Python: single manager class. Flutter: controller + repository + dialogs |
| 18 | **Stock Entry** | `gui/main_window.py` (stock entry dialog) | `features/inventory/widgets/stock_entry_dialog.dart` | Both support adding stock with product search |
| 19 | **Inventory Count** | `gui/main_window.py` (physical count) | `features/inventory/widgets/inventory_count_dialog.dart` | Both support physical inventory counting |
| 20 | **Inventory Movements** | `gui/main_window.py` (movement history) | `features/inventory/widgets/movement_history_dialog.dart` | Both track and display stock movements |
| 21 | **Suppliers** | `gui/main_window.py` (supplier management inline) | `features/suppliers/suppliers_page.dart`, `core/repositories/supplier_repository.dart` | Python: inline in main_window. Flutter: dedicated page + repository |
| 22 | **Purchases** | `gui/main_window.py` (purchase management inline) | `features/purchases/purchases_page.dart`, `features/purchases/purchase_editor_page.dart`, `features/purchases/purchase_details_page.dart` | Python: inline in main_window. Flutter: 3 dedicated pages |
| 23 | **Purchase Payments** | `gui/main_window.py` (payment recording) | `core/repositories/supplier_repository.dart` (payment endpoints) | Both support partial and full supplier payments |
| 24 | **Reports** | `gui/main_window.py` (Reports tab), `modules/reports.py` | `features/reports/reports_page.dart`, `features/reports/reports_controller.dart`, `core/repositories/report_repository.dart` | Python: basic reports. Flutter: 12 report tabs with advanced analytics |
| 25 | **Expenses** | `gui/main_window.py` (expense tracking inline) | `features/expenses/expenses_page.dart` | Python: inline in main_window. Flutter: dedicated page |
| 26 | **Printing** | `gui/main_window.py` (receipt generation inline), `os.startfile()` | `core/services/receipt_pdf_generator.dart`, `core/services/print_service.dart` | Python: tkinter Canvas + Windows print. Flutter: PDF generation + printing package |
| 27 | **Receipts** | `gui/main_window.py` (receipt format inline) | `core/models/receipt_data.dart`, `core/services/receipt_pdf_generator.dart` | Python: text-based receipt. Flutter: PDF receipt with Arabic RTL |
| 28 | **Settings** | `gui/main_window.py` (Settings tab), `config/app_settings.json`, `config/db_config.json` | `features/settings/settings_page.dart`, `core/config/config_stores.dart`, `core/config/server_config.dart` | Python: JSON file config. Flutter: SharedPreferences + Riverpod |
| 29 | **Localization** | `gui/main_window.py` (`self.t()` method, `_TRANSLATIONS` dict), `locales/translations_new_additions.json` | `core/localization/app_localizations.dart` | Both: AR/FR/EN. Python: dict-based. Flutter: inline Dart class |
| 30 | **Networking / Multi-PC** | `utils/network_discovery.py` | `core/network/network_config.dart`, `core/network/discovery_service.dart`, `core/network/discovery_responder.dart`, `core/network/pairing_service.dart`, `core/network/connection_monitor.dart` | Python: basic UDP discovery. Flutter: full LAN networking with pairing |
| 31 | **Authentication / Authorization** | `gui/main_window.py` (PIN-based), `security/license.py` | `core/auth/session_controller.dart`, `features/authentication/login_page.dart` | Python: simple PIN. Flutter: JWT token + role-based access |
| 32 | **Tests** | `tests/test_b2b_day*.py` (B2B only, out of scope) | 17 test files in `flutter_app/test/` | Python: no retail-specific tests. Flutter: comprehensive unit tests |

---

## External Dependencies Not Included

### FastAPI Backend (backend/)
The Flutter application communicates with a FastAPI REST API backend located at `backend/` in the original project. This backend is a **separate application** that:
- Handles all database operations for the Flutter client
- Implements business logic (stock deduction, debt tracking, etc.)
- Provides authentication (JWT tokens)
- Manages device authorization
- Generates reports and exports

**Key backend files not included:**
- `backend/app/api/v1/pos.py` — POS endpoints (products, sales, customers, etc.)
- `backend/app/api/v1/reports.py` — Report endpoints
- `backend/app/api/v1/inventory.py` — Inventory endpoints
- `backend/app/api/v1/auth.py` — Authentication endpoints
- `backend/app/services/pos_service.py` — POS business logic
- `backend/app/repositories/` — All database repositories
- `backend/app/db/schema.py` — Database schema DDL

**Note:** The Flutter app cannot function without this backend. For a complete parity comparison, the backend should also be included.

### Python B2B Module (modules/b2b/, gui/b2b/, documents/)
B2B (Business-to-Business) functionality is a separate feature set including:
- B2B customer profiles with fiscal fields (NIF/NIS/RC/AI)
- B2B documents (invoices, delivery notes, etc.)
- Tax calculation engine (TVA, timbre)
- Document rendering (PDF/DOCX)
- Payment tracking

This is **excluded** from the comparison package per instructions ("Do not include B2B-only functionality unless it is actually shared with the retail workflow").

---

## Uncertainty About File Usage

| File | Uncertainty | Reason |
|------|-------------|--------|
| `modules/sales_v21.py` | **Included but may be unused** | Legacy SalesManager version. Not imported by active code, but may contain behavioral differences worth comparing |
| `gui/main_window.py` | **B2B tabs referenced** | main_window.py imports B2B page classes. The B2B code is excluded but the imports exist in the file |
| `features/products/categories_page.dart` | **Orphaned** | Not imported by any file in the Flutter app. Included for completeness |
| `server/server.py` | **Legacy Flask API** | Small Flask server for mobile access. May not be actively used |
| `config/settings.json` | **Not included** | Exists in data/ directory but unclear if actively used by the Tkinter app |

---

## Package Ready for External Forensic Comparison

This package contains all source files necessary to perform a complete Python-vs-Flutter behavioral comparison of the Supermarket Pro retail/POS/ERP application.

**To use this package:**
1. Start with `README.md` for the feature coverage map
2. Use `MANIFEST.md` to understand every file's purpose
3. Follow `PYTHON_DEPENDENCY_MAP.md` and `FLUTTER_DEPENDENCY_MAP.md` for feature-level paths
4. Use `PARITY_COMPARISON_GUIDE.md` to identify high-risk comparison areas
5. Verify file integrity with `FILE_HASHES.txt`

**Key findings for the comparing engineer:**
- Python has known bugs (void balance reversal, double stock deduction) that are fixed in Flutter backend
- Flutter has more advanced features (12 report tabs, full networking, PDF receipts)
- Python is single-user; Flutter has full authentication
- Stock deduction happens client-side in Python, server-side in Flutter
- The FastAPI backend (not included) is the authoritative source for Flutter's business logic
