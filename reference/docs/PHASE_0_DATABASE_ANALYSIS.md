# PHASE 0 — Database Analysis

## Overview

- **Engine**: MySQL/MariaDB (via pymysql)
- **Compatibility Layer**: SQLite-style SQL → MySQL translation in `db_manager.py`
- **Connection Pool**: Custom `_ConnectionPool` class (max 8 idle connections)
- **ORM**: None — raw SQL throughout

## Database Tables

### 1. `products`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| barcode | VARCHAR(64) UNIQUE | Yes | NULL | Optional, auto-generated if empty |
| name | VARCHAR(255) NOT NULL | No | — | |
| price | DOUBLE NOT NULL | No | — | Selling price |
| cost | DOUBLE | Yes | NULL | Purchase cost price |
| quantity | DOUBLE | Yes | 0 | Current stock |
| unit | VARCHAR(32) | Yes | 'قطعة' | Piece, kg, liter, etc. |
| expiry_date | VARCHAR(32) | Yes | NULL | Stored as string |
| image_path | TEXT | Yes | NULL | File path to image |
| created_at | DATETIME | Yes | CURRENT_TIMESTAMP | |

**Missing**: `category_id` column — referenced in `products.py` JOIN but NOT in `create_tables`. Category system exists in GUI but schema doesn't have it in `products` table creation.

### 2. `customers`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| name | VARCHAR(255) NOT NULL | No | — | |
| phone | VARCHAR(64) | Yes | NULL | |
| address | TEXT | Yes | NULL | |
| balance | DOUBLE | Yes | 0 | Debt balance (positive = customer owes) |
| debt_ceiling | DOUBLE | Yes | 0 | Max allowed debt (0 = unlimited) |
| created_at | DATETIME | Yes | CURRENT_TIMESTAMP | |

### 3. `sales`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| invoice_number | VARCHAR(64) UNIQUE | No | — | Format: `INV-YYYYMMDD-HHMMSS-XXX` |
| customer_id | INT | Yes | NULL | FK → customers(id) |
| total | DOUBLE | Yes | NULL | Final paid amount |
| discount | DOUBLE | Yes | 0 | Combined discount |
| paid_amount | DOUBLE | Yes | NULL | Amount paid |
| change_amount | DOUBLE | Yes | NULL | Change given |
| sale_date | DATETIME | Yes | CURRENT_TIMESTAMP | |
| device_name | VARCHAR(100) | Yes | 'PC1' | Which PC made the sale |
| status | VARCHAR(20) | Yes | 'completed' | 'completed' or 'void' |

### 4. `sale_items`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| sale_id | INT | Yes | NULL | FK → sales(id) |
| product_id | INT | Yes | NULL | FK → products(id) |
| variant_id | INT | Yes | NULL | FK → product_variants(id) |
| quantity | DOUBLE | Yes | NULL | |
| price | DOUBLE | Yes | NULL | Unit price at time of sale |
| total | DOUBLE | Yes | NULL | quantity × price |

**Missing**: `pack_id` column — referenced in `sales.py` pack handling but NOT in schema creation.

### 5. `product_variants`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| product_id | INT NOT NULL | No | — | FK → products(id) CASCADE |
| variant_name | VARCHAR(100) NOT NULL | No | — | e.g., "Size L", "Red" |
| barcode | VARCHAR(64) UNIQUE | Yes | NULL | |
| quantity | DOUBLE | Yes | 0 | Stock for this variant |
| price | DOUBLE | Yes | NULL | Override price (NULL = use product price) |
| created_at | DATETIME | Yes | CURRENT_TIMESTAMP | |

### 6. `license`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| serial_number | VARCHAR(128) UNIQUE | No | — | Format: `SM-XXXXXXXX-XXXX` |
| device_id | VARCHAR(128) | Yes | NULL | MD5 hash of platform info |
| activated_date | VARCHAR(32) | Yes | NULL | |
| expiry_date | VARCHAR(32) | Yes | NULL | |
| is_active | INT | Yes | 0 | 0=unused, 1=activated |

### 7. `connected_devices`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| device_name | VARCHAR(255) | Yes | NULL | |
| device_id | VARCHAR(128) UNIQUE | No | — | |
| serial_number | VARCHAR(128) | Yes | NULL | |
| last_seen | VARCHAR(32) | Yes | NULL | |
| is_active | INT | Yes | 1 | |

### 8. `authorized_devices`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT AUTO_INCREMENT PRIMARY KEY | No | — | |
| device_name | VARCHAR(100) NOT NULL | No | — | |
| ip_address | VARCHAR(45) NOT NULL | No | — | |
| status | VARCHAR(20) | Yes | 'pending' | 'pending', 'approved', 'denied' |
| requested_at | TIMESTAMP | Yes | CURRENT_TIMESTAMP | |

**Unique constraint**: `(device_name, ip_address)`

### 9. `product_favorites`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| product_id | INT NOT NULL | No | — | FK → products(id) CASCADE |
| is_manual | TINYINT | Yes | 0 | 0=auto, 1=manual/starred |
| added_at | DATETIME | Yes | CURRENT_TIMESTAMP | |

**Unique constraint**: `(product_id)`

### 10. `returns`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| invoice_number | VARCHAR(128) NOT NULL | No | — | |
| sale_id | INT | Yes | NULL | |
| customer_id | INT | Yes | NULL | |
| total_amount | DOUBLE | Yes | 0 | |
| device_name | VARCHAR(100) | Yes | 'Main' | |
| return_date | DATETIME | Yes | CURRENT_TIMESTAMP | |
| note | TEXT | Yes | '' | |

### 11. `return_items`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| return_id | INT NOT NULL | No | — | FK → returns(id) |
| product_id | INT NOT NULL | No | — | |
| quantity | DOUBLE | Yes | 0 | |
| price | DOUBLE | Yes | 0 | |
| total | DOUBLE | Yes | 0 | |

### 12. `expenses`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| title | VARCHAR(150) NOT NULL | No | — | |
| category | VARCHAR(50) NOT NULL | No | — | |
| amount | DOUBLE NOT NULL | No | — | |
| paid_from_drawer | TINYINT | Yes | 1 | 1=cash from drawer, 0=external |
| device_name | VARCHAR(100) | Yes | 'PC1' | |
| expense_date | DATETIME | Yes | CURRENT_TIMESTAMP | |
| note | TEXT | Yes | NULL | |

### 13. `suppliers`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| name | VARCHAR(255) NOT NULL | No | — | |
| phone | VARCHAR(64) | Yes | '' | |
| address | TEXT | Yes | NULL | |
| email | VARCHAR(100) | Yes | '' | |
| contact_person | VARCHAR(100) | Yes | '' | |
| balance | DOUBLE | Yes | 0 | Accounts payable |
| notes | TEXT | Yes | NULL | |

### 14. `purchases`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| supplier_id | INT | Yes | NULL | FK → suppliers(id) |
| invoice_number | VARCHAR(64) UNIQUE | No | — | Format: `PUR-YYYYMMDD-HHMMSS-XXX` |
| total_amount | DOUBLE | Yes | 0 | |
| paid_amount | DOUBLE | Yes | 0 | |
| discount | DOUBLE | Yes | 0 | |
| purchase_date | DATETIME | Yes | CURRENT_TIMESTAMP | |
| device_name | VARCHAR(100) | Yes | 'PC1' | |
| note | TEXT | Yes | NULL | |

### 15. `purchase_items`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| purchase_id | INT NOT NULL | No | — | FK → purchases(id) CASCADE |
| product_id | INT | Yes | NULL | FK → products(id) |
| variant_id | INT | Yes | NULL | |
| quantity | DOUBLE | Yes | 0 | |
| purchase_price | DOUBLE | Yes | 0 | |
| total | DOUBLE | Yes | 0 | |

### 16. `inventory_movements`
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| product_id | INT NOT NULL | No | — | |
| quantity_change | DOUBLE NOT NULL | No | — | Positive = add, negative = remove |
| reason | TEXT | Yes | NULL | |
| movement_date | TIMESTAMP | Yes | CURRENT_TIMESTAMP | |

### 17. `debt_transactions` (created by debts.py)
| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| id | INT PRIMARY KEY AUTO_INCREMENT | No | — | |
| customer_id | INT NOT NULL | No | — | |
| transaction_type | VARCHAR(20) NOT NULL | No | — | 'debt' or 'payment' |
| amount | DOUBLE NOT NULL | No | — | |
| note | TEXT | Yes | '' | |
| reference | TEXT | Yes | '' | Invoice number |
| transaction_date | DATETIME | Yes | CURRENT_TIMESTAMP | |

### 18. `audit_log` (created by GUI)
Referenced in index creation but schema defined in `_ensure_audit_schema` method.

### 19. `users` (created by GUI)
Referenced in index creation but schema defined in `_ensure_users_schema` method.

### 20. `categories` (created by GUI)
Referenced in products.py queries but schema defined in `_ensure_categories_schema`.

### 21. `packs` / `pack_items` (created by packs.py)
Referenced but schema defined in `_ensure_packs_schema`.

## Schema Issues

### Missing in create_tables but referenced elsewhere
- `products.category_id` — used in products.py JOIN
- `sale_items.pack_id` — used in sales.py pack sales
- `audit_log` table — created by GUI method
- `users` table — created by GUI method
- `categories` table — created by GUI method
- `packs` / `pack_items` tables — created by packs.py

### Inconsistent naming
- `balance` in customers = customer's debt (positive = owes money)
- `balance` in suppliers = accounts payable (positive = we owe supplier)
- Different semantic meaning for same column name

### Missing foreign keys
- `return_items.return_id` → no FK constraint defined
- `inventory_movements.product_id` → no FK constraint defined
- `debt_transactions.customer_id` → no FK constraint defined

### Data type concerns
- `expiry_date` stored as VARCHAR(32) instead of DATE
- `balance` as DOUBLE instead of DECIMAL (floating point precision issues)
- All monetary amounts use DOUBLE (should be DECIMAL)
- `is_active` as INT instead of BOOLEAN/TINYINT(1)

### Transaction handling
- `void_invoice`: Uses explicit BEGIN + commit/rollback
- `create_purchase_invoice`: Uses connection commit/rollback
- `create_invoice` (sales.py): Uses connection commit/rollback
- No consistent transaction pattern across all operations
