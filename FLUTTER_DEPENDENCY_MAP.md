# FLUTTER DEPENDENCY MAP

## Runtime Dependency Graph

```
lib/main.dart
  └── lib/app.dart (MaterialApp.router)
        ├── core/config/app_providers.dart (Riverpod providers)
        │     ├── api/api_client.dart → api_exception.dart
        │     ├── config/server_config.dart
        │     ├── config/config_stores.dart → server_config.dart
        │     ├── network/network_config.dart
        │     ├── 10 repositories (all depend on api_client.dart)
        │     └── auth/session_controller.dart
        ├── core/routing/app_router.dart
        │     ├── auth/session_controller.dart
        │     └── all feature pages (15+)
        ├── core/localization/app_localizations.dart
        └── core/theme/app_theme.dart
```

## Feature Paths

### Login / Authentication
```
app_router.dart → redirect logic
  → device_setup_page.dart (if no server configured)
  → onboarding_page.dart (if no session)
  → login_page.dart (username + PIN)
  → session_controller.dart
    → ApiClient.post('/api/v1/auth/login')
    → Store token in SessionStore
    → Validate token on app start
```

### Dashboard
```
app_router.dart → dashboard_page.dart
  → dashboard_controller.dart
    → report_repository.dart.getFinancialReport(start, end)
      → ApiClient.get('/api/v1/reports/financial')
    → report_repository.dart.getTopProducts(limit, start, end)
      → ApiClient.get('/api/v1/reports/top-products')
  → KPI cards: gross_sales, net_profit, cogs, invoices_count
  → Revenue chart (DailyTimelineItem)
  → Top products list
```

### Products
```
app_router.dart → products_page.dart
  → product_repository.dart
    → ApiClient.get('/api/v1/pos/products')
    → ApiClient.post('/api/v1/pos/products')
    → ApiClient.put('/api/v1/pos/products/{id}')
    → ApiClient.delete('/api/v1/pos/products/{id}')
    → ApiClient.get('/api/v1/pos/products/barcode/{barcode}')
    → ApiClient.get('/api/v1/pos/products/{id}/variants')
  → app_providers.dart (productListProvider, productSearchProvider)
```

### Categories
```
app_providers.dart → categoryRepositoryProvider
  → category_repository.dart
    → ApiClient.get('/api/v1/pos/categories')
    → ApiClient.post('/api/v1/pos/categories')
    → ApiClient.put('/api/v1/pos/categories/{id}')
    → ApiClient.delete('/api/v1/pos/categories/{id}')
```

### Variants
```
products_page.dart → variant management UI
  → product_repository.dart.listVariants(productId)
    → ApiClient.get('/api/v1/pos/products/{id}/variants')
  → product_repository.dart.createVariant(productId, variant)
    → ApiClient.post('/api/v1/pos/products/{id}/variants')
  → pos/widgets/variant_picker_dialog.dart
    → Variant selection during POS sale
```

### Packs
```
app_router.dart → packs_page.dart
  → pack_repository.dart
    → ApiClient.get('/api/v1/pos/packs')
    → ApiClient.post('/api/v1/pos/packs')
    → ApiClient.put('/api/v1/pos/packs/{id}')
    → ApiClient.delete('/api/v1/pos/packs/{id}')
  → app_providers.dart (packListProvider)
```

### Favorites
```
pos_page.dart → product_grid.dart → favorites toggle
  → favorite_repository.dart
    → ApiClient.get('/api/v1/pos/favorites')
    → ApiClient.post('/api/v1/pos/favorites/toggle')
  → app_providers.dart (favoritesProvider)
```

### POS / Sales
```
app_router.dart → pos_page.dart
  → pos_controller.dart (PosController Notifier)
    ├── product_repository.dart (product search, barcode lookup)
    ├── category_repository.dart (category filter)
    ├── favorite_repository.dart (favorites filter)
    ├── pack_repository.dart (pack expansion)
    ├── customer_repository.dart (customer selection)
    ├── In-memory cart state (List<CartItem>)
    ├── hold/restore cart (in-memory held carts)
    ├── sale_repository.dart.createSale(SaleCreate)
    │   → ApiClient.post('/api/v1/pos/sales')
    │   → Backend: stock deduction, movement logging, debt tracking
    └── Returns PosState (cart items, totals, selected customer)
  → widgets:
    ├── cart_panel.dart (cart items, +/-, delete, totals)
    ├── product_grid.dart (product cards, add to cart)
    ├── payment_dialog.dart (cash/card/partial/credit)
    ├── customer_picker.dart (search and select)
    ├── hold_sales_dialog.dart (suspend/restore)
    ├── sale_success_dialog.dart (receipt, print)
    ├── variant_picker_dialog.dart (variant selection)
    └── weight_dialog.dart (weighted product qty)
```

### Customers / Debts
```
app_router.dart → customers_page.dart
  → customer_repository.dart
    → ApiClient.get('/api/v1/pos/customers')
    → ApiClient.post('/api/v1/pos/customers')
    → ApiClient.put('/api/v1/pos/customers/{id}')
    → ApiClient.delete('/api/v1/pos/customers/{id}')
    → ApiClient.get('/api/v1/pos/customers/search')
    → ApiClient.get('/api/v1/pos/customers/{id}/debt')
    → ApiClient.post('/api/v1/pos/customers/{id}/debt/pay')
  → app_providers.dart (customerListProvider)
```

### Sales History
```
app_router.dart → sales_history_page.dart
  → sales_history_controller.dart
    → sale_repository.dart.listSales(page, search)
      → ApiClient.get('/api/v1/pos/sales')
    → sale_repository.dart.getSaleByInvoice(invoiceNumber)
      → ApiClient.get('/api/v1/pos/sales/invoice/{number}')
    → sale_repository.dart.voidSale(saleId)
      → ApiClient.post('/api/v1/pos/sales/{id}/void')
  → invoice_details_page.dart
    → Full receipt display, reprint, void
```

### Purchases / Suppliers
```
app_router.dart → purchases_page.dart
  → purchase_repository.dart
    → ApiClient.get('/api/v1/pos/purchases')
    → ApiClient.post('/api/v1/pos/purchases')
    → ApiClient.get('/api/v1/pos/purchases/{id}')
    → ApiClient.delete('/api/v1/pos/purchases/{id}')
    → ApiClient.post('/api/v1/pos/purchases/{id}/pay')
  → supplier_repository.dart
    → ApiClient.get('/api/v1/pos/suppliers')
    → ApiClient.post('/api/v1/pos/suppliers')
    → ApiClient.put('/api/v1/pos/suppliers/{id}')
    → ApiClient.delete('/api/v1/pos/suppliers/{id}')
    → ApiClient.post('/api/v1/pos/suppliers/{id}/pay')
  → purchase_editor_page.dart
    → Product search, cart, supplier selection, payment
```

### Inventory
```
app_router.dart → inventory_page.dart
  → inventory_controller.dart
    → inventory_repository.dart
      → ApiClient.get('/api/v1/inventory/products')
      → ApiClient.get('/api/v1/inventory/stats')
      → ApiClient.post('/api/v1/inventory/adjust')
      → ApiClient.get('/api/v1/inventory/movements')
      → ApiClient.get('/api/v1/inventory/low-stock')
      → ApiClient.post('/api/v1/inventory/stock-entry')
  → widgets:
    ├── stock_entry_dialog.dart (add stock)
    ├── movement_history_dialog.dart (view movements)
    └── inventory_count_dialog.dart (physical count)
```

### Reports
```
app_router.dart → reports_page.dart
  → reports_controller.dart
    → report_repository.dart
      → ApiClient.get('/api/v1/reports/financial')
      → ApiClient.get('/api/v1/reports/sales-summary')
      → ApiClient.get('/api/v1/reports/top-products')
      → ApiClient.get('/api/v1/reports/categories')
      → ApiClient.get('/api/v1/reports/slow-moving')
      → ApiClient.get('/api/v1/reports/device-breakdown')
      → ApiClient.get('/api/v1/reports/voided-invoices')
      → ApiClient.get('/api/v1/reports/daily-timeline')
      → ApiClient.get('/api/v1/reports/hourly-revenue')
      → ApiClient.get('/api/v1/reports/traffic')
      → ApiClient.get('/api/v1/reports/margin-warnings')
      → ApiClient.get('/api/v1/reports/crowd-prediction')
      → ApiClient.get('/api/v1/reports/expenses')
      → ApiClient.get('/api/v1/reports/export/csv')
      → ApiClient.get('/api/v1/reports/export/excel')
      → ApiClient.get('/api/v1/reports/export/pdf')
  → 12 report tabs with date range selection
```

### Expenses
```
app_router.dart → expenses_page.dart
  → ApiClient.get('/api/v1/reports/expenses')
  → ApiClient.post('/api/v1/reports/expenses')
  → ApiClient.delete('/api/v1/reports/expenses/{id}')
  → Expense CRUD with date range filtering
```

### Settings
```
app_router.dart → settings_page.dart
  → app_providers.dart → config_stores.dart
    → ServerConfigStore.save(config) → SharedPreferences
    → SessionStore.save(token) → SharedPreferences
    → PreferencesStore.save(prefs) → SharedPreferences
  → Settings: store_name, store_phone, invoice_footer, paper_size,
    theme_mode, language, allow_debt, low_stock_threshold,
    auto_print, ask_before_print
```

### Printing / Receipts
```
pos/widgets/sale_success_dialog.dart
  → print_service.dart
    → receipt_pdf_generator.dart
      → ReceiptData.fromSaleDetail(saleDetail)
      → generate80mm() or generateA4()
      → Uses pdf package for PDF generation
      → Arabic RTL layout support
    → printing package for print/preview/save
  → Also used by invoice_details_page.dart for reprint
```

### Localization
```
core/localization/app_localizations.dart
  → AppLocalizations.of(context).translate(key)
  → ~600 translation keys x 3 languages (AR/FR/EN)
  → RTL support for Arabic
  → No .arb files; all translations inline in Dart
```

### Networking / Multi-PC
```
core/network/
  → network_config.dart
    → NetworkRole enum: server, client, local
    → NetworkConfig: host, port, deviceName, role
    → NetworkConfigStore: save/load from SharedPreferences
  → discovery_service.dart
    → UDP broadcast probe on port 50000
    → Subnet TCP sweep for server detection
  → discovery_responder.dart
    → UDP listener for Main PC mode
  → pairing_service.dart
    → ApiClient.post('/api/v1/devices/pair')
    → ApiClient.get('/api/v1/devices/status')
    → ApiClient.post('/api/v1/devices/{id}/approve')
  → connection_monitor.dart
    → Polls /health endpoint
    → Self-healing with LAN rediscovery
    → Unknown device rejection
```
