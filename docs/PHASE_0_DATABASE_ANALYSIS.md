# Phase 0 — Database Analysis

## Legacy data access

`DatabaseManager` reads `config/db_config.json`, connects through PyMySQL with `autocommit=False`, creates the database/tables, and provides a small idle pool. `CompatConnection` and `translate_sql` convert `?`, `AUTOINCREMENT`, selected PRAGMA and SQLite constructs to MySQL. The schema is not migration-managed: base create-table calls, ALTER repair snippets, manager `ensure_table`, and GUI `_ensure_*_schema` methods all participate. Connections/rollbacks are manually managed and many query errors are converted to empty results.

## Legacy table inventory

| Table | Purpose / key relationships | Important fields / constraints |
|---|---|---|
| products | catalogue/stock | id; name, barcode, price, cost, quantity, unit, expiry/image; category_id is used outside base schema |
| customers | receivables | id; name/contact/address, balance, debt_ceiling |
| sales | sale header | customer_id FK; invoice_number; total, discount, paid, change, date/device/status |
| sale_items | historical lines | sale_id/product_id FKs; variant_id repaired later; quantity/price/total; pack_id used but base schema lacks it |
| product_variants | child stock/price | product_id FK CASCADE; name, unique barcode, quantity, nullable price |
| categories | product grouping | lazily created by GUI; product relation used by `products.py` |
| packs / pack_items | bundle definitions | GUI-created; pack item product/components |
| inventory_movements | stock journal | product_id, quantity_change, reason, date; missing enforced source/actor FK |
| returns / return_items | return headers/lines | invoice/sale/customer references; item quantities/price/total; incomplete FK enforcement |
| suppliers | payables master | name/contact/balance |
| purchases / purchase_items | purchasing documents | supplier FK; unique invoice; amounts/discount/date; item product/variant refs |
| expenses | expense record | title/category/amount/drawer/device/date/note |
| debt_transactions | customer ledger | manager-created; customer/type(debt/payment)/amount/note/reference/date |
| product_favorites | manual/auto POS favourites | unique product_id; manual flag |
| authorized_devices | LAN pairing requests | unique (device_name, ip); status/date |
| connected_devices | license/device presence | unique device_id, serial, last_seen, active |
| license | local activation record | unique serial, device ID, dates, active |
| users | GUI-created PIN identities | login/role/hash fields; exact historical schema must be migration-captured |
| audit_log | GUI-created audit record | created/user/action/details fields; referenced by indexes |

Known indexes include sales date/customer/device; sale item sale/product/variant; inventory product; return header/item; product/customer name; variants; audit created/user; expense date/device; supplier name; purchase supplier/date/device; purchase item refs. Foreign-key coverage is incomplete, and defaults/nullability are inconsistent.

## Relationship map

```
category 1—* product 1—* variant
customer 1—* sale 1—* sale_item *—1 product/optional variant
customer 1—* debt_transaction
supplier 1—* purchase 1—* purchase_item *—1 product/optional variant
sale 0—* return 1—* return_item *—1 product
pack 1—* pack_item *—1 product
product 1—* inventory_movement / favourite
```

## Target PostgreSQL blueprint

Use UUID or bigint IDs consistently; `timestamptz`, `numeric(18,3)`, `boolean`, check constraints, explicit `ON DELETE RESTRICT` for historical relations, and `created_at/updated_at/version` where appropriate. Core tables: `users, roles, permissions, user_roles, devices, settings, categories, products, product_variants, product_images, packs, pack_items, customers, suppliers, sales, sale_lines, sale_payments, debt_ledger_entries, returns, return_lines, purchases, purchase_lines, supplier_ledger_entries, inventory_movements, expenses, audit_events, print_jobs, export_jobs, backups`.

Sale/purchase/return lines must snapshot name/SKU/unit/price/cost/tax/discount so reports survive product changes. Add document state, source document IDs on movements, actor/device IDs, idempotency key/unique request key, and soft-archive fields for masters. Index product barcode unique, normalized name/search, active/category; stock lookups; all document date/status/device/customer/supplier keys; movement source/product/time; ledger customer/time; and return source line.

Alembic revisions replace every runtime schema creation/repair path. A pre-migration discovery dump must compare real deployed schemas to this static inventory, because lazy historical objects and previous ALTER failures are possible.
