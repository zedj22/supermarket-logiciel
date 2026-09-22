# Phase 2 Implementation — Database Models & Migrations

## Overview

Phase 2 implements the complete SQLAlchemy 2.x ORM model layer and Alembic migrations for the supermarket POS application. All 23 domain tables are defined, tested, and verified against PostgreSQL 18.6.

## Summary

| Item | Result |
|---|---|
| Domain models created | 23 tables |
| Enums defined | 10 enums (27 permission scopes) |
| Migration chain | `0001_initial` → `73355bdf31d4` (0002) → `a1b2c3d4e5f6` (0003) |
| PostgreSQL tables | 23 (applied successfully) |
| Downgrade/upgrade | Verified cycle |
| Unit tests | 93 passed |
| Integration tests | 10 passed (PostgreSQL via `supermarket_pro_test`) |
| **Total tests** | **103 passed, 0 failed** |
| Compile check | 0 errors |

## Model Architecture

### Base Classes (`app/db/base.py`)

| Class | Purpose |
|---|---|
| `Base` | SQLAlchemy `DeclarativeBase` root |
| `UUIDMixin` | UUID primary key (`uuid.uuid4` default, `gen_random_uuid()` PG server default) |
| `TimestampMixin` | `created_at` / `updated_at` with `func.now()` |
| `VersionMixin` | Optimistic concurrency `version` integer |
| `ArchiveMixin` | Soft-archive `archived_at` nullable datetime |
| `BaseModel` | UUID + Timestamps (for association tables) |
| `DocumentModel` | UUID + Timestamps + Version (for business documents) |
| `MasterModel` | UUID + Timestamps + Archive (for master data) |

### Helper Functions

| Function | Returns | Purpose |
|---|---|---|
| `numeric_money()` | `MappedColumn(Numeric(18,3))` | Monetary values |
| `numeric_quantity()` | `MappedColumn(Numeric(18,3))` | Stock quantities |
| `text_column()` | `MappedColumn(Text)` | Unlimited text |

## Tables (23)

### Auth / RBAC (5 tables)

| Table | Key Relationships |
|---|---|
| `users` | → user_roles |
| `roles` | → user_roles, role_permissions |
| `permissions` | → role_permissions |
| `user_roles` | users ↔ roles (M2M, unique constraint) |
| `role_permissions` | roles ↔ permissions (M2M, unique constraint) |

### Catalog (5 tables)

| Table | Key Relationships |
|---|---|
| `categories` | Self-referential parent/child hierarchy |
| `products` | → categories, → product_variants, → pack_items |
| `product_variants` | → products (CASCADE delete), unique (product_id, name) |
| `packs` | → pack_items |
| `pack_items` | → packs (CASCADE), → products (RESTRICT), → variants (RESTRICT) |

### Customers / Suppliers (2 tables)

| Table | Key Relationships |
|---|---|
| `customers` | → sales, → debt_ledger_entries, → returns |
| `suppliers` | → purchases |

### Sales (3 tables)

| Table | Key Relationships |
|---|---|
| `sales` | → customers (SET NULL), → users (SET NULL), → sale_lines, → sale_payments |
| `sale_lines` | → sales (RESTRICT), → products (RESTRICT), → variants (RESTRICT), → packs (RESTRICT) |
| `sale_payments` | → sales (RESTRICT) |

### Purchases (2 tables)

| Table | Key Relationships |
|---|---|
| `purchases` | → suppliers (RESTRICT), → users (SET NULL), → purchase_lines |
| `purchase_lines` | → purchases (RESTRICT), → products (RESTRICT), → variants (RESTRICT) |

### Returns (2 tables)

| Table | Key Relationships |
|---|---|
| `returns` | → sales (RESTRICT), → customers (SET NULL), → return_lines |
| `return_lines` | → returns (RESTRICT), → products (RESTRICT), → variants (RESTRICT), → sale_lines (RESTRICT) |

### Debt (1 table)

| Table | Key Relationships |
|---|---|
| `debt_ledger_entries` | → customers (RESTRICT), → sales (SET NULL), → users (SET NULL) |

### Expenses (1 table)

| Table | Key Relationships |
|---|---|
| `expenses` | → users (SET NULL) |

### Inventory (1 table)

| Table | Key Relationships |
|---|---|
| `inventory_movements` | → products (RESTRICT), → variants (RESTRICT), → users (SET NULL) |

### Audit (1 table)

| Table | Key Relationships |
|---|---|
| `audit_logs` | → users (SET NULL) |

## Design Decisions

### UUID Primary Keys
- All 23 tables use UUID primary keys (via `UUIDMixin`)
- Python-side default: `uuid.uuid4()`
- PostgreSQL server default: `gen_random_uuid()` (via `UUID_PK_SERVER_DEFAULT` in migration)
- Cross-dialect compatible: works with SQLite (tests) and PostgreSQL (production)

### NUMERIC(18,3) for Money/Quantity
- All monetary values use `NUMERIC(18,3)` — no binary floating point
- All stock quantities use `NUMERIC(18,3)` — supports fractional units (kg, liter)
- Matches Phase 0 architecture requirement

### Snapshot Pattern on Transaction Lines
- Sale lines, purchase lines, and return lines snapshot product name/SKU/barcode/unit/price/cost at time of transaction
- Historical records survive product changes
- Matches Phase 0 database analysis requirement

### Soft Archive on Master Data
- `MasterModel` includes `archived_at` nullable datetime
- Products, categories, customers, suppliers, packs, variants support soft-archive
- No destructive DELETE on entities with historical references

### Optimistic Concurrency on Documents
- `DocumentModel` includes `version` integer
- Sales, purchases, returns have version field for optimistic locking

### Ledger-Based Debt Model
- `debt_ledger_entries` is an immutable append-only ledger
- `customers.balance` is a cached projection (service layer maintains consistency)
- Entry types: sale (debt incurred), payment (debt reduced), adjustment

### Snapshot Pattern for Lines
- `sale_lines`, `purchase_lines`, `return_lines` capture product state at time of transaction
- Preserves: `product_name`, `product_sku`, `product_barcode`, `product_unit`, `unit_price`/`unit_cost`
- Historical reports survive product catalog changes

### Soft Delete (Archive) Pattern
- Master entities (products, categories, customers, suppliers, packs, variants) have `archived_at`
- No hard DELETE — business documents are append-only
- Corrections via reversals only

### append-Only Business Documents
- Sales, returns, purchases: no physical delete, only status changes (void)
- Void creates compensating entries rather than deleting records
- Meets business rule: "Sales, returns, purchases, voids and stock adjustments are append-only"

### Immutable Audit Trail
- `audit_logs` captures actor, action, entity, before/after state, IP, device
- Append-only — no updates or deletes

### No Cascading Deletes on Historical Records
- Historical records (sales, returns, purchases) use `RESTRICT` on delete
- Prevents accidental data loss
- Master data uses `SET NULL` on delete (preserve historical references)

## Enums (10)

| Enum | Values | Purpose |
|---|---|---|
| `UserRoleEnum` | admin, manager, cashier | Default role names |
| `PermissionScope` | 27 scopes | Granular RBAC permissions |
| `ProductUnit` | piece, kg, gram, liter, milliliter, meter, pack | Product unit types |
| `SaleStatus` | completed, void | Sale lifecycle |
| `PaymentMethod` | cash, card, credit, partial | Payment types |
| `ReturnReason` | defective, wrong_item, customer_change, expired, other | Return justification |
| `StockMovementType` | sale, sale_void, purchase, purchase_delete, return, adjustment, pack_component | Inventory journal |
| `ExpenseCategory` | rent, utilities, salary, maintenance, supplies, transport, other | Expense classification |
| `DeviceStatus` | pending, approved, rejected | LAN device pairing |
| `AuditAction` | create, update, delete, login, logout, void, return, payment, adjustment, backup, restore | Audit trail |

## Migration

### Revision: `a1b2c3d4e5f6` (head)

- **Chain**: `0001_initial` → `73355bdf31d4` (0002) → `a1b2c3d4e5f6` (0003)
- **0002** (`73355bdf31d4`): Creates all 23 domain tables
- **0003** (`a1b2c3d4e5f6`): Fixes 8 timestamp columns that had fixed literal defaults — all changed to `now()`
- **Downgrade**: Drops all 23 tables and indexes (back to 0001 baseline)

### Key Features
- `gen_random_uuid()` server default on all UUID PKs
- `func.now()` for all timestamp server defaults (verified — see correction below)
- Proper foreign key cascade rules (RESTRICT, SET NULL, CASCADE)
- Composite unique constraints on association tables
- Indexes on all foreign keys and frequently queried columns

### PostgreSQL Verification
```
alembic current → a1b2c3d4e5f6 (head)
alembic downgrade 0001_initial → success
alembic upgrade head → success
alembic heads → a1b2c3d4e5f6 (head) [single head, no branches]
```

## Tests

### Test Files

| File | Tests | Coverage |
|---|---|---|
| `test_enums.py` | 14 | All enum values, member counts, serialization |
| `test_models.py` | 56 | Table existence, PKs, columns, FKs, constraints, indexes, CRUD, relationships |
| `test_migrations.py` | 10 | PostgreSQL upgrade/downgrade, autogenerate, structure verification |
| `test_database.py` | 3 | BaseModel UUIDMixin, TimestampMixin, get_db |
| `test_config.py` | 8 | Settings, Alembic configparser |
| `test_exceptions.py` | 2 | Error handlers |
| `test_health.py` | 5 | Health endpoints |
| **Total** | **103** | **103 passed, 0 failed** |

### Test Highlights
- 23 parametrized UUID PK tests (one per table)
- Numeric column type verification
- Foreign key relationship validation
- Unique constraint verification
- Model instantiation with SQLite in-memory
- Relationship navigation (UserRole → User/Role, RolePermission → Role/Permission)
- .roles and .permissions property testing
- **10 PostgreSQL integration tests** (upgrade/downgrade cycle, autogenerate, schema structure)
- Integration tests use dedicated `supermarket_pro_test` database (production untouched)

## Files Created/Modified

### New Files
```
backend/app/models/__init__.py       — Barrel export (all 23 models + enums)
backend/app/models/enums.py          — 10 domain enums
backend/app/models/user.py           — User, Role, Permission, UserRole, RolePermission
backend/app/models/catalog.py        — Category, Product, ProductVariant, Pack, PackItem
backend/app/models/party.py          — Customer, Supplier
backend/app/models/sale.py           — Sale, SaleLine, SalePayment
backend/app/models/purchase.py       — Purchase, PurchaseLine
backend/app/models/return_doc.py     — Return, ReturnLine
backend/app/models/debt.py           — DebtLedgerEntry
backend/app/models/expense.py        — Expense
backend/app/models/inventory.py      — InventoryMovement
backend/app/models/audit.py          — AuditLog
backend/migrations/versions/2026_09_22_1128_73355bdf31d4_0002_phase2_domain_models.py
backend/migrations/versions/2026_09_22_1200_a1b2c3d4e5f6_0003_fix_timestamp_defaults.py
backend/tests/unit/test_enums.py     — 14 enum tests
backend/tests/unit/test_models.py    — 56 model structure + CRUD tests
backend/tests/integration/test_migrations.py — 10 PostgreSQL migration tests
```

### Modified Files
```
backend/app/db/base.py               — UUID PK, mixins, helper functions
backend/migrations/env.py            — Import all models for autogenerate
backend/alembic.ini                  — timezone = UTC
backend/tests/unit/test_database.py  — Updated for UUID PK
```

## Deferred Decisions (Phase 0)

The following remain **UNVERIFIED** and require product owner approval before implementation:
1. Payment split behavior
2. Tax calculation
3. Currency rounding
4. Cash drawer effect
5. Negative stock policy
6. Pack + variant combination rules
7. Debt ceiling enforcement
8. Offline LAN transaction policy

## Final Verification and Schema Corrections

### Migration 0003 — Fixed Timestamp Defaults

During final verification, 8 timestamp columns were found to have **fixed literal string defaults** (`'now()'::timestamp`) instead of dynamic `now()` function calls. This was fixed in migration `0003_fix_timestamp_defaults` (`a1b2c3d4e5f6`):

| Table | Column | Before | After |
|---|---|---|---|
| `sales` | `sale_date` | `'now()'::timestamp` | `now()` |
| `purchases` | `purchase_date` | `'now()'::timestamp` | `now()` |
| `returns` | `return_date` | `'now()'::timestamp` | `now()` |
| `sale_payments` | `payment_date` | `'now()'::timestamp` | `now()` |
| `debt_ledger_entries` | `entry_date` | `'now()'::timestamp` | `now()` |
| `inventory_movements` | `movement_date` | `'now()'::timestamp` | `now()` |
| `expenses` | `expense_date` | `'now()'::timestamp` | `now()` |
| `audit_logs` | `action_at` | `'now()'::timestamp` | `now()` |

All 37 foreign keys verified present across all tables.

### Integration Test Configuration

- **Dedicated test database**: `supermarket_pro_test` — production `supermarket_pro` is never touched
- Integration tests run via Alembic subprocess calls with `DATABASE_URL` overridden to test DB
- `conftest.py` reads `.env` directly to obtain the original PostgreSQL URL before test-time override
- Autogenerate test cleans up generated files and stamps DB back to real head

### Final Test Counts

| Category | Count |
|---|---|
| Unit tests (SQLite) | 93 |
| Integration tests (PostgreSQL) | 10 |
| **Total passed** | **103** |
| **Failed** | **0** |
| Skipped | **0** |
