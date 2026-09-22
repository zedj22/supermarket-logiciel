# PYTHON DEPENDENCY MAP

## Runtime Dependency Graph

```
main.py
  └── gui.main_window.MainWindow (17,326 lines)
        ├── database.db_manager.DatabaseManager
        │     └── pymysql (MySQL/MariaDB)
        ├── database.db_manager.load_db_config
        ├── database.db_manager.save_db_config
        ├── database.db_manager.test_connection
        ├── database.db_manager.get_active_config
        ├── database.db_manager.set_active_config
        ├── modules.products.ProductManager
        │     └── database.db_manager
        ├── modules.sales.SalesManager
        │     └── database.db_manager
        ├── modules.customers.CustomerManager
        │     └── database.db_manager
        ├── modules.reports.ReportsManager
        │     ├── database.db_manager
        │     ├── modules.sales.SalesManager
        │     ├── modules.products.ProductManager
        │     └── modules.customers.CustomerManager
        ├── modules.debts.DebtManager
        │     └── database.db_manager
        ├── modules.inventory.InventoryManager
        │     └── database.db_manager
        ├── modules.packs.PacksManager
        │     └── database.db_manager
        ├── modules.favorites.FavoritesManager
        │     └── database.db_manager
        ├── gui.sale_window.SaleWindow
        │     ├── modules.products
        │     ├── modules.sales
        │     └── modules.customers
        ├── gui.add_product_window.AddProductWindow
        │     └── modules.products
        ├── utils.network_discovery (lazy import)
        │     └── socket, threading, json
        ├── security.license.LicenseManager
        │     └── database.db_manager
        └── config/app_settings.json
```

## Feature Paths

### Login / Authentication
```
main.py → gui/main_window.py → security/license.py → database/db_manager.py
  - No formal login screen in Tkinter app (single-user mode)
  - License check on startup (currently commented out for testing)
  - Staff management via PIN system (users table)
```

### POS / Sales
```
gui/main_window.py (POS tab)
  → product search via ProductManager.search_products()
  → cart logic (in-memory list)
  → SalesManager.create_sale()
    → INSERT INTO sales (invoice_number, total, paid_amount, etc.)
    → INSERT INTO sale_items (product_id, quantity, price, etc.)
    → UPDATE products SET quantity = quantity - sale_qty (for each item)
    → INSERT INTO inventory_movements
    → UPDATE customers SET balance = balance + debt_amount (if credit sale)
    → INSERT INTO debt_transactions (if credit sale)
```

### Products
```
gui/main_window.py (Products tab)
  → ProductManager.get_all_products()
  → ProductManager.add_product(name, barcode, price, cost, quantity, unit, category_id)
  → ProductManager.update_product(product_id, ...)
  → ProductManager.delete_product(product_id)
  → ProductManager.search_products(query)
  → ProductManager.get_product_by_barcode(barcode)
  → database/db_manager.py → MySQL queries
```

### Categories
```
gui/main_window.py (Categories tab)
  → ProductManager.get_all_categories()
  → ProductManager.add_category(name)
  → ProductManager.update_category(category_id, name)
  → ProductManager.delete_category(category_id)
```

### Variants
```
gui/main_window.py
  → product_variants table (embedded in main_window.py)
  → CREATE TABLE IF NOT EXISTS product_variants (id, product_id, barcode, name, price, cost, quantity, unit)
  → CRUD operations inline in main_window.py
```

### Packs
```
gui/main_window.py (Packs tab)
  → PacksManager.get_all_packs()
  → PacksManager.create_pack(name, price, items: [{product_id, quantity}])
  → PacksManager.update_pack(pack_id, ...)
  → PacksManager.delete_pack(pack_id)
  → PacksManager.get_pack_items(pack_id)
  → database/db_manager.py → MySQL queries
```

### Favorites
```
gui/main_window.py (Favorites tab)
  → FavoritesManager.get_favorites()
  → FavoritesManager.toggle_favorite(product_id)
  → FavoritesManager.is_favorite(product_id)
  → FavoritesManager.get_popular_products(limit)
  → database/db_manager.py → MySQL queries
  → Hybrid auto (sales frequency) + manual favorites
```

### Customers / Debts
```
gui/main_window.py (Customers tab)
  → CustomerManager.get_all_customers()
  → CustomerManager.add_customer(name, phone, address)
  → CustomerManager.update_customer(customer_id, ...)
  → CustomerManager.delete_customer(customer_id)
  → CustomerManager.search_customers(query)
  → DebtManager.add_debt_transaction(customer_id, amount, type, reference)
  → DebtManager.get_debt_history(customer_id)
  → DebtManager.get_customer_balance(customer_id)
  → database/db_manager.py → MySQL queries
```

### Inventory
```
gui/main_window.py (Inventory tab)
  → InventoryManager.get_all_products_with_stock()
  → InventoryManager.adjust_stock(product_id, new_quantity, reason)
  → InventoryManager.get_low_stock_products(threshold)
  → InventoryManager.get_out_of_stock_products()
  → InventoryManager.get_expiring_products(days)
  → InventoryManager.get_inventory_movements(product_id, limit)
  → InventoryManager.add_stock_entry(product_id, quantity, cost, supplier)
  → database/db_manager.py → MySQL queries
```

### Reports
```
gui/main_window.py (Reports tab)
  → ReportsManager.get_dashboard_stats()
    → total_sales_today, total_profit_today, products_count, customers_count
  → ReportsManager.get_sales_by_period(start, end)
  → ReportsManager.get_top_products(limit, start, end)
  → ReportsManager.get_low_stock_products(threshold)
  → ReportsManager.get_sales_summary(start, end)
  → ReportsManager.get_profit_report(start, end)
  → database/db_manager.py → MySQL aggregate queries
```

### Settings
```
gui/main_window.py (Settings tab)
  → load_db_config() / save_db_config()
  → DatabaseManager.set_store_settings(name, phone, footer, paper_size)
  → DatabaseManager.get_store_settings()
  → config/app_settings.json
  → config/db_config.json
```

### Printing
```
gui/main_window.py
  → receipt generation (inline in main_window.py)
  → Uses tkinter Canvas for receipt preview
  → os.startfile() for printing on Windows
  → receipt format: store name, items, totals, footer
```

### Localization
```
gui/main_window.py
  → self.t(key) method for translations
  → _TRANSLATIONS dict (inline, ~600 keys)
  → locales/translations_new_additions.json (external dictionary)
  → Languages: Arabic (ar), French (fr), English (en)
  → RTL support for Arabic
```

### Networking / Multi-PC
```
utils/network_discovery.py
  → UDP broadcast on port 50000 for server discovery
  → TCP parallel scan for device detection
  → get_local_ip(), broadcast_discovery(), scan_subnet()
```
