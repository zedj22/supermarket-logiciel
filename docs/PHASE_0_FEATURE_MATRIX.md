# Phase 0 — Feature Matrix

| Feature | Old behavior / relevant code | Data | Problem | Target / decision | Priority / phase |
|---|---|---|---|---|---|
| Startup/config | `main.py`, `MainWindow`, db config | JSON | license disabled, silent DB init failure | explicit bootstrap/health state | P0 / 1,3 |
| Auth/users | GUI user schema/PIN dialogs | users/audit | UI-centric, no timeout/lockout | RBAC API + audit | P0 / 4 |
| Products/categories/images | forms, `products.py` | products/categories | schema split, path handling | paged catalogue, archive | P0 / 5 |
| Variants/weights | POS/form methods | variants | float quantities | typed units/NUMERIC | P0 / 6 |
| Inventory | `inventory.py`, sales/purchases/returns | movements/products | incomplete source fields | immutable movement service | P0 / 7 |
| POS/payment | `complete_sale`, `sales.py` | sales/items | post-commit side effects | one command transaction | P0 / 8–9 |
| Customers/debts | managers/UI | customers/debt ledger | divergent balance/ledger | ledger projection | P0 / 9 |
| Packs | `packs.py`, POS | packs/items | base schema mismatch | aggregate availability | P1 / 10 |
| Suppliers/purchases | DB/UI | suppliers/purchases | destructive deletion | reversible documents | P1 / 11 |
| Returns/voids | GUI + DB manager | returns/sales | weak reconciliation | source-line limits/approval | P0 / 12 |
| Expenses | DB/UI | expenses | no immutable audit | category/approval/audit | P1 / 13 |
| Reports/dashboard | DB queries/UI charts | documents/movements | repeated scans/formula ambiguity | query service/snapshots | P1 / 14 |
| Print/export | ReportLab/openpyxl/csv | jobs/files | UI-bound/blocking | backend jobs/templates | P1 / 15 |
| LAN/devices | discovery + direct DB | devices/config | exposed DB/direct clients | authenticated API LAN | P0 / 16 |
| Settings/backup | GUI + mysqldump flow | JSON/files | secret/plain backup concerns | secure config/verified backup | P0 / 17 |
| i18n/theme | MainWindow dict/theme | JSON | hardcoded/missing RTL | ARB/design tokens | P0 / 1,17 |
