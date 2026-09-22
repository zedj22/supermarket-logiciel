# MANIFEST

Complete inventory of all files in the comparison package.

## Python Files

| # | Source File | Copied Path | Category | Feature | Why Included |
|---|-------------|-------------|----------|---------|--------------|
| 1 | `main.py` | `python_app/main.py` | Core Runtime | Entry Point | Application entry point; imports MainWindow + LicenseManager |
| 2 | `requirements.txt` | `python_app/requirements.txt` | Configuration | Dependencies | Declares all Python package dependencies |
| 3 | `config/db_config.json` | `python_app/config/db_config.json` | Configuration | Database | MySQL/MariaDB connection settings |
| 4 | `config/app_settings.json` | `python_app/config/app_settings.json` | Configuration | Settings | Store name, phone, invoice footer, paper size, theme, language, thresholds |
| 5 | `database/__init__.py` | `python_app/database/__init__.py` | Supporting Runtime | Database | Package marker |
| 6 | `database/db_manager.py` | `python_app/database/db_manager.py` | Core Runtime | Database | Central database abstraction. Connection pooling, query translation, schema DDL. 2,222 lines |
| 7 | `gui/__init__.py` | `python_app/gui/__init__.py` | Supporting Runtime | GUI | Package marker |
| 8 | `gui/main_window.py` | `python_app/gui/main_window.py` | Core Runtime | POS/Sales/Inventory/Products/Customers/Reports/Settings | THE main application window. 17,326 lines. Contains all retail UI tabs, POS workflow, cart logic, product management, customer management, debt tracking, inventory management, reports, settings, localization, printing integration |
| 9 | `gui/sale_window.py` | `python_app/gui/sale_window.py` | Feature-Specific | Sales | Standalone sale dialog window |
| 10 | `gui/add_product_window.py` | `python_app/gui/add_product_window.py` | Feature-Specific | Products | Add product dialog |
| 11 | `modules/__init__.py` | `python_app/modules/__init__.py` | Supporting Runtime | Business Logic | Package marker |
| 12 | `modules/products.py` | `python_app/modules/products.py` | Feature-Specific | Products | ProductManager CRUD for products table |
| 13 | `modules/sales.py` | `python_app/modules/sales.py` | Feature-Specific | Sales | SalesManager: invoice creation, stock deduction, debt tracking, sales queries |
| 14 | `modules/customers.py` | `python_app/modules/customers.py` | Feature-Specific | Customers | CustomerManager CRUD for customers table |
| 15 | `modules/reports.py` | `python_app/modules/reports.py` | Feature-Specific | Reports | ReportsManager: dashboard stats, sales by period, top products, low stock |
| 16 | `modules/debts.py` | `python_app/modules/debts.py` | Feature-Specific | Debts | DebtManager: debt transaction recording and history |
| 17 | `modules/inventory.py` | `python_app/modules/inventory.py` | Feature-Specific | Inventory | InventoryManager: stock movements, low/expired/out-of-stock alerts |
| 18 | `modules/packs.py` | `python_app/modules/packs.py` | Feature-Specific | Packs | PacksManager: product bundles/combo packs |
| 19 | `modules/favorites.py` | `python_app/modules/favorites.py` | Feature-Specific | Favorites | FavoritesManager: hybrid auto+manual product favorites |
| 20 | `modules/sales_v21.py` | `python_app/modules/sales_v21.py` | Feature-Specific | Sales | Legacy older SalesManager version; may contain behavioral differences worth comparing |
| 21 | `security/__init__.py` | `python_app/security/__init__.py` | Supporting Runtime | Security | Package marker |
| 22 | `security/license.py` | `python_app/security/license.py` | Feature-Specific | Licensing | LicenseManager: device fingerprinting, serial generation, activation |
| 23 | `server/__init__.py` | `python_app/server/__init__.py` | Supporting Runtime | Server | Package marker |
| 24 | `server/server.py` | `python_app/server/server.py` | Feature-Specific | API | Flask REST API for mobile/client access |
| 25 | `utils/network_discovery.py` | `python_app/utils/network_discovery.py` | Feature-Specific | Networking | UDP broadcast + TCP scan for LAN server discovery |
| 26 | `locales/translations_new_additions.json` | `python_app/locales/translations_new_additions.json` | Configuration | Localization | Translation dictionary (Arabic keys -> en/fr values) |

## Flutter Files

| # | Source File | Copied Path | Category | Feature | Why Included |
|---|-------------|-------------|----------|---------|--------------|
| 1 | `pubspec.yaml` | `flutter_app/pubspec.yaml` | Configuration | Dependencies | Flutter project config, dependencies, SDK constraints |
| 2 | `lib/main.dart` | `flutter_app/lib/main.dart` | Core Runtime | Entry Point | App entry point; creates ProviderScope, runs app |
| 3 | `lib/app.dart` | `flutter_app/lib/app.dart` | Core Runtime | App Shell | MaterialApp.router: theme, locale, router configuration |
| 4 | `lib/core/api/api_client.dart` | `flutter_app/lib/core/api/api_client.dart` | Core Runtime | API | Centralized HTTP client for FastAPI backend |
| 5 | `lib/core/api/api_exception.dart` | `flutter_app/lib/core/api/api_exception.dart` | Supporting Runtime | API | ApiErrorKind enum + ApiException class |
| 6 | `lib/core/auth/session_controller.dart` | `flutter_app/lib/core/auth/session_controller.dart` | Core Runtime | Authentication | SessionController: login/logout, token persistence |
| 7 | `lib/core/config/app_providers.dart` | `flutter_app/lib/core/config/app_providers.dart` | Core Runtime | DI/Providers | Central Riverpod provider definitions for entire app |
| 8 | `lib/core/config/config_stores.dart` | `flutter_app/lib/core/config/config_stores.dart` | Supporting Runtime | Config | Persistence abstractions (SharedPreferences + InMemory) |
| 9 | `lib/core/config/server_config.dart` | `flutter_app/lib/core/config/server_config.dart` | Supporting Runtime | Config | ServerConfig data class with JSON serialization |
| 10 | `lib/core/errors/error_mapper.dart` | `flutter_app/lib/core/errors/error_mapper.dart` | Supporting Runtime | Errors | Maps ApiException to user-facing localized error messages |
| 11 | `lib/core/localization/app_localizations.dart` | `flutter_app/lib/core/localization/app_localizations.dart` | Core Runtime | Localization | Trilingual localization (AR/FR/EN), ~600 keys, RTL support |
| 12 | `lib/core/models/models.dart` | `flutter_app/lib/core/models/models.dart` | Core Runtime | Models | All domain models: Product, Category, Variant, Pack, Customer, Sale, etc. |
| 13 | `lib/core/models/receipt_data.dart` | `flutter_app/lib/core/models/receipt_data.dart` | Supporting Runtime | Printing | ReceiptData and ReceiptItem for PDF generation |
| 14 | `lib/core/network/connection_monitor.dart` | `flutter_app/lib/core/network/connection_monitor.dart` | Feature-Specific | Networking | Connection health monitor with self-healing LAN rediscovery |
| 15 | `lib/core/network/discovery_responder.dart` | `flutter_app/lib/core/network/discovery_responder.dart` | Feature-Specific | Networking | UDP discovery responder for Main PC mode |
| 16 | `lib/core/network/discovery_service.dart` | `flutter_app/lib/core/network/discovery_service.dart` | Feature-Specific | Networking | LAN server discovery (UDP broadcast + TCP sweep) |
| 17 | `lib/core/network/network_config.dart` | `flutter_app/lib/core/network/network_config.dart` | Supporting Runtime | Networking | NetworkConfig model, role enum, hostname/IP detection |
| 18 | `lib/core/network/pairing_service.dart` | `flutter_app/lib/core/network/pairing_service.dart` | Feature-Specific | Networking | Device pairing service (register, check, approve/deny) |
| 19 | `lib/core/repositories/category_repository.dart` | `flutter_app/lib/core/repositories/category_repository.dart` | Feature-Specific | Categories | CRUD for categories via API |
| 20 | `lib/core/repositories/customer_repository.dart` | `flutter_app/lib/core/repositories/customer_repository.dart` | Feature-Specific | Customers | CRUD for customers, debt management via API |
| 21 | `lib/core/repositories/favorite_repository.dart` | `flutter_app/lib/core/repositories/favorite_repository.dart` | Feature-Specific | Favorites | List/add/remove favorites via API |
| 22 | `lib/core/repositories/inventory_repository.dart` | `flutter_app/lib/core/repositories/inventory_repository.dart` | Feature-Specific | Inventory | Inventory products, stats, stock adjustments, movements |
| 23 | `lib/core/repositories/pack_repository.dart` | `flutter_app/lib/core/repositories/pack_repository.dart` | Feature-Specific | Packs | CRUD for packs via API |
| 24 | `lib/core/repositories/product_repository.dart` | `flutter_app/lib/core/repositories/product_repository.dart` | Feature-Specific | Products | CRUD for products, search, barcode, variants via API |
| 25 | `lib/core/repositories/purchase_repository.dart` | `flutter_app/lib/core/repositories/purchase_repository.dart` | Feature-Specific | Purchases | CRUD for purchase invoices via API |
| 26 | `lib/core/repositories/report_repository.dart` | `flutter_app/lib/core/repositories/report_repository.dart` | Feature-Specific | Reports | All report endpoints: financial, timeline, products, exports |
| 27 | `lib/core/repositories/sale_repository.dart` | `flutter_app/lib/core/repositories/sale_repository.dart` | Feature-Specific | Sales | Create/list/void sales via API |
| 28 | `lib/core/repositories/supplier_repository.dart` | `flutter_app/lib/core/repositories/supplier_repository.dart` | Feature-Specific | Suppliers | CRUD for suppliers, payment recording via API |
| 29 | `lib/core/routing/app_router.dart` | `flutter_app/lib/core/routing/app_router.dart` | Core Runtime | Routing | GoRouter configuration, all routes, redirect logic |
| 30 | `lib/core/services/print_service.dart` | `flutter_app/lib/core/services/print_service.dart` | Feature-Specific | Printing | Print/preview/save service using printing package |
| 31 | `lib/core/services/receipt_pdf_generator.dart` | `flutter_app/lib/core/services/receipt_pdf_generator.dart` | Feature-Specific | Printing | PDF receipt generator (80mm thermal + A4) |
| 32 | `lib/core/theme/app_theme.dart` | `flutter_app/lib/core/theme/app_theme.dart` | Supporting Runtime | Theme | Material 3 design system, light/dark themes |
| 33 | `lib/core/utils/debounce.dart` | `flutter_app/lib/core/utils/debounce.dart` | Supporting Runtime | Utils | Trailing Debouncer for search inputs |
| 34 | `lib/core/utils/formatters.dart` | `flutter_app/lib/core/utils/formatters.dart` | Supporting Runtime | Utils | Date parsing/formatting helpers |
| 35 | `lib/core/utils/money.dart` | `flutter_app/lib/core/utils/money.dart` | Supporting Runtime | Utils | Exact-decimal money handling |
| 36 | `lib/core/widgets/app_states.dart` | `flutter_app/lib/core/widgets/app_states.dart` | Supporting Runtime | Widgets | Reusable UI: LoadingState, ErrorStateView, EmptyStateView |
| 37 | `lib/shared/models/auth_models.dart` | `flutter_app/lib/shared/models/auth_models.dart` | Supporting Runtime | Models | AuthUser, AuthSession models |
| 38 | `lib/shared/models/report_models.dart` | `flutter_app/lib/shared/models/report_models.dart` | Supporting Runtime | Models | All report models: FinancialReport, TopProductItem, etc. |
| 39 | `lib/shared/models/server_models.dart` | `flutter_app/lib/shared/models/server_models.dart` | Supporting Runtime | Models | HealthStatus, StoreConfig, ClientConfig models |
| 40 | `lib/features/splash/splash_page.dart` | `flutter_app/lib/features/splash/splash_page.dart` | Feature-Specific | UI | Splash/loading screen |
| 41 | `lib/features/device_setup/device_setup_page.dart` | `flutter_app/lib/features/device_setup/device_setup_page.dart` | Feature-Specific | Networking | First-run device setup (Main/Secondary/Single PC) |
| 42 | `lib/features/onboarding/onboarding_page.dart` | `flutter_app/lib/features/onboarding/onboarding_page.dart` | Feature-Specific | Networking | Server connection onboarding |
| 43 | `lib/features/authentication/login_page.dart` | `flutter_app/lib/features/authentication/login_page.dart` | Feature-Specific | Authentication | Login page with username + PIN |
| 44 | `lib/features/shell/main_shell.dart` | `flutter_app/lib/features/shell/main_shell.dart` | Core Runtime | UI Shell | Responsive shell (sidebar + topbar) |
| 45 | `lib/features/shell/nav_items.dart` | `flutter_app/lib/features/shell/nav_items.dart` | Supporting Runtime | Navigation | Navigation data model + navSections definition |
| 46 | `lib/features/shell/placeholder_page.dart` | `flutter_app/lib/features/shell/placeholder_page.dart` | Feature-Specific | UI | Placeholder for unbuilt features |
| 47 | `lib/features/shell/widgets/sidebar.dart` | `flutter_app/lib/features/shell/widgets/sidebar.dart` | Feature-Specific | Navigation | Navigation sidebar with sectioned menu |
| 48 | `lib/features/shell/widgets/top_bar.dart` | `flutter_app/lib/features/shell/widgets/top_bar.dart` | Feature-Specific | Navigation | Top bar with connection indicator, user info, logout |
| 49 | `lib/features/dashboard/dashboard_page.dart` | `flutter_app/lib/features/dashboard/dashboard_page.dart` | Feature-Specific | Dashboard | Dashboard with KPI cards, revenue chart, top products |
| 50 | `lib/features/dashboard/dashboard_controller.dart` | `flutter_app/lib/features/dashboard/dashboard_controller.dart` | Feature-Specific | Dashboard | Dashboard data controller |
| 51 | `lib/features/pos/pos_page.dart` | `flutter_app/lib/features/pos/pos_page.dart` | Feature-Specific | POS | Main POS screen: product search, barcode, cart |
| 52 | `lib/features/pos/pos_controller.dart` | `flutter_app/lib/features/pos/pos_controller.dart` | Feature-Specific | POS | PosController: search, cart ops, hold/restore, sale execution |
| 53 | `lib/features/pos/widgets/cart_panel.dart` | `flutter_app/lib/features/pos/widgets/cart_panel.dart` | Feature-Specific | POS | Cart panel: items list, totals, action buttons |
| 54 | `lib/features/pos/widgets/product_grid.dart` | `flutter_app/lib/features/pos/widgets/product_grid.dart` | Feature-Specific | POS | Product grid: product cards with add-to-cart |
| 55 | `lib/features/pos/widgets/payment_dialog.dart` | `flutter_app/lib/features/pos/widgets/payment_dialog.dart` | Feature-Specific | POS | Payment dialog: cash/card/partial/credit modes |
| 56 | `lib/features/pos/widgets/hold_sales_dialog.dart` | `flutter_app/lib/features/pos/widgets/hold_sales_dialog.dart` | Feature-Specific | POS | Held sales dialog: view and restore suspended carts |
| 57 | `lib/features/pos/widgets/customer_picker.dart` | `flutter_app/lib/features/pos/widgets/customer_picker.dart` | Feature-Specific | POS | Customer picker dialog with search |
| 58 | `lib/features/pos/widgets/sale_success_dialog.dart` | `flutter_app/lib/features/pos/widgets/sale_success_dialog.dart` | Feature-Specific | POS/Printing | Sale success: receipt display, print/preview options |
| 59 | `lib/features/pos/widgets/variant_picker_dialog.dart` | `flutter_app/lib/features/pos/widgets/variant_picker_dialog.dart` | Feature-Specific | POS/Variants | Variant picker for multi-variant products |
| 60 | `lib/features/pos/widgets/weight_dialog.dart` | `flutter_app/lib/features/pos/widgets/weight_dialog.dart` | Feature-Specific | POS/Weighted | Weight/quantity entry for weighted products |
| 61 | `lib/features/products/products_page.dart` | `flutter_app/lib/features/products/products_page.dart` | Feature-Specific | Products | Products management page with CRUD, search, variants |
| 62 | `lib/features/products/categories_page.dart` | `flutter_app/lib/features/products/categories_page.dart` | Feature-Specific | Categories | Categories management page (ORPHANED - not imported by router) |
| 63 | `lib/features/customers/customers_page.dart` | `flutter_app/lib/features/customers/customers_page.dart` | Feature-Specific | Customers | Customers management page with CRUD, search, debt view |
| 64 | `lib/features/packs/packs_page.dart` | `flutter_app/lib/features/packs/packs_page.dart` | Feature-Specific | Packs | Pack (bundle) management page with CRUD |
| 65 | `lib/features/suppliers/suppliers_page.dart` | `flutter_app/lib/features/suppliers/suppliers_page.dart` | Feature-Specific | Suppliers | Supplier management page with CRUD, payments |
| 66 | `lib/features/sales/sales_history_page.dart` | `flutter_app/lib/features/sales/sales_history_page.dart` | Feature-Specific | Sales | Sales history page with search, infinite scroll, void |
| 67 | `lib/features/sales/sales_history_controller.dart` | `flutter_app/lib/features/sales/sales_history_controller.dart` | Feature-Specific | Sales | Sales history data controller |
| 68 | `lib/features/sales/invoice_details_page.dart` | `flutter_app/lib/features/sales/invoice_details_page.dart` | Feature-Specific | Sales | Invoice details dialog with receipt, reprint, void |
| 69 | `lib/features/purchases/purchases_page.dart` | `flutter_app/lib/features/purchases/purchases_page.dart` | Feature-Specific | Purchases | Purchases list page with search, summary stats |
| 70 | `lib/features/purchases/purchase_editor_page.dart` | `flutter_app/lib/features/purchases/purchase_editor_page.dart` | Feature-Specific | Purchases | Purchase invoice editor with product search, cart, supplier |
| 71 | `lib/features/purchases/purchase_details_page.dart` | `flutter_app/lib/features/purchases/purchase_details_page.dart` | Feature-Specific | Purchases | Purchase details page with view, delete, pay |
| 72 | `lib/features/reports/reports_page.dart` | `flutter_app/lib/features/reports/reports_page.dart` | Feature-Specific | Reports | Reports page with 12 tabs and export options |
| 73 | `lib/features/reports/reports_controller.dart` | `flutter_app/lib/features/reports/reports_controller.dart` | Feature-Specific | Reports | Reports data controller |
| 74 | `lib/features/expenses/expenses_page.dart` | `flutter_app/lib/features/expenses/expenses_page.dart` | Feature-Specific | Expenses | Expenses page with CRUD and range filtering |
| 75 | `lib/features/inventory/inventory_page.dart` | `flutter_app/lib/features/inventory/inventory_page.dart` | Feature-Specific | Inventory | Inventory page with stock overview, search, stats |
| 76 | `lib/features/inventory/inventory_controller.dart` | `flutter_app/lib/features/inventory/inventory_controller.dart` | Feature-Specific | Inventory | Inventory data controller |
| 77 | `lib/features/inventory/widgets/stock_entry_dialog.dart` | `flutter_app/lib/features/inventory/widgets/stock_entry_dialog.dart` | Feature-Specific | Inventory | Stock entry dialog with product search |
| 78 | `lib/features/inventory/widgets/movement_history_dialog.dart` | `flutter_app/lib/features/inventory/widgets/movement_history_dialog.dart` | Feature-Specific | Inventory | Movement history dialog |
| 79 | `lib/features/inventory/widgets/inventory_count_dialog.dart` | `flutter_app/lib/features/inventory/widgets/inventory_count_dialog.dart` | Feature-Specific | Inventory | Inventory count/audit dialog |
| 80 | `lib/features/settings/settings_page.dart` | `flutter_app/lib/features/settings/settings_page.dart` | Feature-Specific | Settings | Settings page: store info, printing, appearance, language |
| 81 | `test/api_client_test.dart` | `flutter_app/test/api_client_test.dart` | Relevant Test | API | ApiClient URL building, headers, error handling, retries |
| 82 | `test/app_localizations_test.dart` | `flutter_app/test/app_localizations_test.dart` | Relevant Test | Localization | Trilingual key resolution, RTL detection |
| 83 | `test/app_smoke_test.dart` | `flutter_app/test/app_smoke_test.dart` | Relevant Test | Routing | Widget test: redirect to onboarding when no server |
| 84 | `test/money_test.dart` | `flutter_app/test/money_test.dart` | Relevant Test | Utils | parseDecimal precision, formatMoney, formatQuantity |
| 85 | `test/phase14_void_fix_test.dart` | `flutter_app/test/phase14_void_fix_test.dart` | Relevant Test | Sales/Voids | Void sale contract, SaleResponse void status |
| 86 | `test/phase16_discovery_responder_test.dart` | `flutter_app/test/phase16_discovery_responder_test.dart` | Relevant Test | Networking | Discovery responder |
| 87 | `test/phase16_networking_test.dart` | `flutter_app/test/phase16_networking_test.dart` | Relevant Test | Networking | NetworkConfig, NetworkRole, InMemoryNetworkConfigStore |
| 88 | `test/phase16_pairing_test.dart` | `flutter_app/test/phase16_pairing_test.dart` | Relevant Test | Networking | PairingResult, DeviceRequestEntry parsing |
| 89 | `test/pos_controller_test.dart` | `flutter_app/test/pos_controller_test.dart` | Relevant Test | POS | PosController state management, cart operations |
| 90 | `test/printing_phase12_test.dart` | `flutter_app/test/printing_phase12_test.dart` | Relevant Test | Printing | ReceiptData mapping, weighted product handling, payment modes |
| 91 | `test/purchases_suppliers_test.dart` | `flutter_app/test/purchases_suppliers_test.dart` | Relevant Test | Purchases/Suppliers | Supplier/Purchase model parsing, cart totals |
| 92 | `test/reports_models_test.dart` | `flutter_app/test/reports_models_test.dart` | Relevant Test | Reports | Report model parsing, financial calculations |
| 93 | `test/reports_phase11_test.dart` | `flutter_app/test/reports_phase11_test.dart` | Relevant Test | Reports | Margin warnings, crowd prediction, ReportsRange |
| 94 | `test/sales_phase14_test.dart` | `flutter_app/test/sales_phase14_test.dart` | Relevant Test | Sales | SaleResponse/SaleDetail parsing, filtering |
| 95 | `test/server_config_test.dart` | `flutter_app/test/server_config_test.dart` | Relevant Test | Config | ServerConfig URL building, JSON round-trip |
| 96 | `test/settings_phase13_final_fix_test.dart` | `flutter_app/test/settings_phase13_final_fix_test.dart` | Relevant Test | Settings | allowDebt, lowStockThreshold, credit sale behavior |
| 97 | `test/settings_phase13_test.dart` | `flutter_app/test/settings_phase13_test.dart` | Relevant Test | Settings | ServerConfig defaults, validation, localization keys |
