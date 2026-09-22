# PHASE 0 — API Blueprint

## Overview

All endpoints are under `/api/v1/`. The API is RESTful, uses JSON, and requires JWT authentication for all endpoints except login and health check.

## Authentication

### POST /api/v1/auth/login
**Purpose**: Authenticate user with PIN
**Request**:
```json
{
  "pin": "1234",
  "device_name": "PC1"
}
```
**Response**:
```json
{
  "token": "eyJ...",
  "user": {
    "id": 1,
    "name": "Admin",
    "role": "admin"
  }
}
```
**Errors**: 401 Invalid PIN, 404 User not found

### POST /api/v1/auth/verify
**Purpose**: Verify token validity
**Headers**: `Authorization: Bearer <token>`
**Response**: 200 OK or 401 Unauthorized

---

## Users

### GET /api/v1/users
**Purpose**: List all users
**Permissions**: admin
**Response**:
```json
[
  {
    "id": 1,
    "name": "Admin",
    "role": "admin",
    "created_at": "2026-01-01T00:00:00"
  }
]
```

### POST /api/v1/users
**Purpose**: Create user
**Permissions**: admin
**Request**:
```json
{
  "name": "Cashier 1",
  "pin": "5678",
  "role": "cashier"
}
```
**Response**: 201 Created with user object

### PUT /api/v1/users/{id}
**Purpose**: Update user
**Permissions**: admin

### DELETE /api/v1/users/{id}
**Purpose**: Delete user
**Permissions**: admin
**Restriction**: Cannot delete last admin

---

## Products

### GET /api/v1/products
**Purpose**: List products (paginated)
**Query params**: `page`, `limit`, `search`, `category_id`, `sort_by`, `sort_order`
**Response**:
```json
{
  "items": [
    {
      "id": 1,
      "barcode": "123456",
      "name": "Product Name",
      "price": 100.0,
      "cost": 80.0,
      "quantity": 50,
      "unit": "piece",
      "category_id": 1,
      "category_name": "Food",
      "image_path": "/images/product1.jpg",
      "expiry_date": "2027-01-01",
      "variants_count": 2
    }
  ],
  "total": 100,
  "page": 1,
  "pages": 3
}
```

### POST /api/v1/products
**Purpose**: Create product
**Permissions**: admin, cashier
**Request**:
```json
{
  "barcode": "123456",
  "name": "Product Name",
  "price": 100.0,
  "cost": 80.0,
  "quantity": 50,
  "unit": "piece",
  "category_id": 1,
  "expiry_date": "2027-01-01"
}
```
**Response**: 201 Created

### GET /api/v1/products/{id}
**Purpose**: Get product details
**Response**: Product object with variants

### PUT /api/v1/products/{id}
**Purpose**: Update product
**Permissions**: admin

### DELETE /api/v1/products/{id}
**Purpose**: Delete product
**Permissions**: admin

### GET /api/v1/products/search
**Purpose**: Search products
**Query params**: `q` (search term), `barcode` (exact barcode match)
**Response**: List of matching products

### GET /api/v1/products/low-stock
**Purpose**: Get low stock products
**Query params**: `threshold` (default from settings)

---

## Categories

### GET /api/v1/categories
**Purpose**: List categories
**Response**:
```json
[
  {
    "id": 1,
    "name": "Food",
    "product_count": 25
  }
]
```

### POST /api/v1/categories
**Purpose**: Create category
**Permissions**: admin

### PUT /api/v1/categories/{id}
**Purpose**: Update category
**Permissions**: admin

### DELETE /api/v1/categories/{id}
**Purpose**: Delete category
**Permissions**: admin
**Behavior**: Products moved to "Uncategorized"

---

## Variants

### GET /api/v1/products/{id}/variants
**Purpose**: List variants for a product
**Response**:
```json
[
  {
    "id": 1,
    "variant_name": "Size L",
    "barcode": "123456-L",
    "quantity": 20,
    "price": 110.0
  }
]
```

### POST /api/v1/products/{id}/variants
**Purpose**: Add variant
**Permissions**: admin

### PUT /api/v1/variants/{id}
**Purpose**: Update variant
**Permissions**: admin

### DELETE /api/v1/variants/{id}
**Purpose**: Delete variant
**Permissions**: admin

---

## Packs

### GET /api/v1/packs
**Purpose**: List packs
**Response**:
```json
[
  {
    "id": 1,
    "name": "Family Pack",
    "price": 500.0,
    "is_active": true,
    "components_count": 5,
    "sum_of_parts": 600.0
  }
]
```

### POST /api/v1/packs
**Purpose**: Create pack
**Request**:
```json
{
  "name": "Family Pack",
  "price": 500.0,
  "components": [
    {"product_id": 1, "quantity": 2},
    {"product_id": 2, "quantity": 3}
  ]
}
```

### GET /api/v1/packs/{id}
**Purpose**: Get pack details with components

### PUT /api/v1/packs/{id}
**Purpose**: Update pack

### DELETE /api/v1/packs/{id}
**Purpose**: Delete/deactivate pack

### GET /api/v1/packs/{id}/availability
**Purpose**: Check component stock availability

---

## Sales (POS)

### POST /api/v1/sales
**Purpose**: Create sale (complete transaction)
**Request**:
```json
{
  "customer_id": 1,
  "items": [
    {
      "product_id": 1,
      "quantity": 2,
      "price": 100.0,
      "variant_id": null,
      "is_pack": false,
      "pack_id": null,
      "components": [],
      "item_discount": 0
    }
  ],
  "discount": 50.0,
  "paid_amount": 200.0,
  "device_name": "PC1"
}
```
**Response**:
```json
{
  "success": true,
  "invoice_number": "INV-20260922-143052-123",
  "total": 150.0,
  "change": 50.0,
  "debt": 0.0
}
```
**Transaction**: Atomic (all or nothing)

### GET /api/v1/sales
**Purpose**: List sales (paginated)
**Query params**: `page`, `limit`, `date_from`, `date_to`, `device_name`, `status`

### GET /api/v1/sales/{id}
**Purpose**: Get sale details with items

### POST /api/v1/sales/{id}/void
**Purpose**: Void sale
**Permissions**: admin
**Transaction**: Atomic (restores stock, adjusts balances)

### GET /api/v1/sales/{invoice_number}
**Purpose**: Get sale by invoice number

---

## Returns

### POST /api/v1/returns
**Purpose**: Create return
**Request**:
```json
{
  "invoice_number": "INV-20260922-143052-123",
  "sale_id": 1,
  "customer_id": 1,
  "items": [
    {
      "product_id": 1,
      "quantity": 1,
      "price": 100.0
    }
  ],
  "note": "Defective product",
  "device_name": "PC1"
}
```
**Transaction**: Atomic (restores stock)

### GET /api/v1/returns
**Purpose**: List returns
**Query params**: `device_name`, `page`, `limit`

---

## Customers

### GET /api/v1/customers
**Purpose**: List customers (paginated)
**Query params**: `page`, `limit`, `search`

### POST /api/v1/customers
**Purpose**: Create customer
**Request**:
```json
{
  "name": "Customer Name",
  "phone": "0550123456",
  "address": "Address",
  "debt_ceiling": 5000.0
}
```

### GET /api/v1/customers/{id}
**Purpose**: Get customer details
**Response**:
```json
{
  "id": 1,
  "name": "Customer Name",
  "phone": "0550123456",
  "balance": 1500.0,
  "debt_ceiling": 5000.0
}
```

### PUT /api/v1/customers/{id}
**Purpose**: Update customer

### DELETE /api/v1/customers/{id}
**Purpose**: Delete customer
**Restriction**: Cannot delete if has outstanding debt

---

## Debts

### GET /api/v1/customers/{id}/debts
**Purpose**: Debt history for customer
**Response**:
```json
[
  {
    "id": 1,
    "transaction_type": "debt",
    "amount": 500.0,
    "note": "Sale on credit",
    "reference": "INV-20260922-143052-123",
    "transaction_date": "2026-09-22T14:30:52"
  }
]
```

### POST /api/v1/customers/{id}/pay
**Purpose**: Record debt payment
**Request**:
```json
{
  "amount": 500.0,
  "note": "Partial payment"
}
```
**Transaction**: Atomic (updates balance + records transaction)

### GET /api/v1/debts/summary
**Purpose**: Total debts across all customers
**Response**:
```json
{
  "total_debt": 15000.0,
  "customers_with_debt": 12
}
```

---

## Suppliers

### GET /api/v1/suppliers
**Purpose**: List suppliers

### POST /api/v1/suppliers
**Purpose**: Create supplier

### GET /api/v1/suppliers/{id}
**Purpose**: Get supplier details

### PUT /api/v1/suppliers/{id}
**Purpose**: Update supplier

### DELETE /api/v1/suppliers/{id}
**Purpose**: Delete supplier
**Restriction**: Cannot delete if has outstanding balance

---

## Purchases

### POST /api/v1/purchases
**Purpose**: Create purchase invoice
**Request**:
```json
{
  "supplier_id": 1,
  "items": [
    {
      "product_id": 1,
      "quantity": 100,
      "purchase_price": 80.0,
      "variant_id": null
    }
  ],
  "discount": 500.0,
  "paid_amount": 5000.0,
  "device_name": "PC1",
  "note": "Monthly restock"
}
```
**Transaction**: Atomic (creates purchase, updates stock, adjusts supplier balance)

### GET /api/v1/purchases
**Purpose**: List purchases
**Query params**: `search`, `device_name`, `page`, `limit`

### GET /api/v1/purchases/{id}
**Purpose**: Get purchase details with items

### DELETE /api/v1/purchases/{id}
**Purpose**: Delete purchase
**Transaction**: Atomic (restores stock, adjusts supplier balance)

---

## Expenses

### GET /api/v1/expenses
**Purpose**: List expenses
**Query params**: `date_from`, `date_to`, `device_name`

### POST /api/v1/expenses
**Purpose**: Create expense

### DELETE /api/v1/expenses/{id}
**Purpose**: Delete expense

---

## Inventory

### GET /api/v1/inventory
**Purpose**: Stock levels for all products
**Query params**: `low_stock` (boolean), `page`, `limit`

### POST /api/v1/inventory/adjust
**Purpose**: Manual stock adjustment
**Request**:
```json
{
  "product_id": 1,
  "quantity_change": 10,
  "reason": "Stock count correction"
}
```
**Transaction**: Atomic (updates stock + records movement)

### GET /api/v1/inventory/movements
**Purpose**: Movement history
**Query params**: `product_id`, `page`, `limit`

### GET /api/v1/inventory/movements/{product_id}
**Purpose**: Movements for specific product

---

## Reports

### GET /api/v1/reports/financial
**Purpose**: Financial report
**Query params**: `date_from`, `date_to`, `device_name`
**Response**:
```json
{
  "gross_sales": 50000.0,
  "discounts": 2000.0,
  "returns_total": 1000.0,
  "net_sales": 47000.0,
  "paid_cash": 40000.0,
  "outstanding_debt": 7000.0,
  "cogs": 30000.0,
  "net_profit": 17000.0,
  "profit_margin_pct": 36.2,
  "expenses_total": 5000.0,
  "invoice_count": 150,
  "items_sold": 500
}
```

### GET /api/v1/reports/products
**Purpose**: Product performance
**Query params**: `date_from`, `date_to`

### GET /api/v1/reports/categories
**Purpose**: Profit by category
**Query params**: `date_from`, `date_to`

### GET /api/v1/reports/daily
**Purpose**: Daily timeline
**Query params**: `date_from`, `date_to`

### GET /api/v1/reports/hourly
**Purpose**: Hourly revenue
**Query params**: `date_from`, `date_to`

### GET /api/v1/reports/peak-hours
**Purpose**: Peak hours analysis
**Query params**: `lookback_days`

### GET /api/v1/reports/slow-moving
**Purpose**: Slow moving products
**Query params**: `days`, `threshold`

### GET /api/v1/reports/voided
**Purpose**: Voided invoices
**Query params**: `date_from`, `date_to`

---

## Dashboard

### GET /api/v1/dashboard
**Purpose**: Dashboard KPIs
**Response**:
```json
{
  "total_products": 500,
  "total_customers": 120,
  "stock_value": 250000.0,
  "today_sales": 15000.0,
  "low_stock_count": 12,
  "customers_with_debt": 15,
  "total_debt": 25000.0,
  "recent_sales": [...],
  "top_products": [...],
  "alerts": [...]
}
```

---

## Devices

### GET /api/v1/devices
**Purpose**: List connected devices

### POST /api/v1/devices/pair
**Purpose**: Request device pairing

### POST /api/v1/devices/{id}/approve
**Purpose**: Approve device pairing
**Permissions**: admin

### POST /api/v1/devices/{id}/deny
**Purpose**: Deny device pairing
**Permissions**: admin

---

## Settings

### GET /api/v1/settings
**Purpose**: Get all settings
**Response**:
```json
{
  "store_name": "Supermarket Pro",
  "store_phone": "0550123456",
  "store_address": "123 Main St",
  "invoice_footer": "Thank you",
  "default_paper": "80mm",
  "allow_debt": true,
  "low_stock_threshold": 5,
  "theme_mode": "dark",
  "language": "ar"
}
```

### PUT /api/v1/settings
**Purpose**: Update settings
**Permissions**: admin

---

## Backups

### POST /api/v1/backups
**Purpose**: Create backup
**Permissions**: admin
**Response**:
```json
{
  "id": 1,
  "filename": "backup_20260922_143052.sql",
  "size": 1024000,
  "created_at": "2026-09-22T14:30:52"
}
```

### GET /api/v1/backups
**Purpose**: List backups

### POST /api/v1/backups/{id}/restore
**Purpose**: Restore from backup
**Permissions**: admin
**Transaction**: Full database restore

---

## Health

### GET /api/v1/health
**Purpose**: Health check
**Response**:
```json
{
  "status": "healthy",
  "database": "connected",
  "version": "1.0.0",
  "uptime": 86400
}
```

---

## Error Response Format

All errors follow this format:
```json
{
  "error": {
    "code": "STOCK_INSUFFICIENT",
    "message": "Insufficient stock for product 'Milk'",
    "details": {
      "product_id": 1,
      "requested": 10,
      "available": 5
    }
  }
}
```

### Error Codes
| Code | HTTP Status | Description |
|------|-------------|-------------|
| AUTH_INVALID_PIN | 401 | Invalid PIN |
| AUTH_TOKEN_EXPIRED | 401 | Token expired |
| AUTH_FORBIDDEN | 403 | Insufficient permissions |
| NOT_FOUND | 404 | Resource not found |
| VALIDATION_ERROR | 422 | Invalid input |
| STOCK_INSUFFICIENT | 409 | Not enough stock |
| CONFLICT | 409 | Resource conflict |
| DATABASE_ERROR | 500 | Database error |
| NETWORK_ERROR | 502 | Network error |
| PRINTER_ERROR | 503 | Printer unavailable |
