# Phase 0 — Architecture

## Legacy architecture and responsibilities

`main.py` is the desktop entry point. `MainWindow` is a 15k+ LOC god object. It constructs `DatabaseManager`, `SalesManager`, `CustomerManager`, `DebtManager`, `ProductManager`, `InventoryManager`, `PacksManager`, and `FavoritesManager`, but still contains much of their actual workflow orchestration and raw SQL.

| Layer | Actual components | Finding |
|---|---|---|
| Desktop UI | CustomTkinter `MainWindow`, `SaleWindow`, `AddProductWindow` | UI state and business/database code intertwined |
| Feature managers | `modules/*.py` | uneven; some useful transaction code, some thin wrappers |
| Data access | `DatabaseManager` | connection/config/schema/migrations/reports/purchases/returns mixed |
| Compatibility | `translate_sql`, `CompatConnection`, cursor/pool | SQLite syntax translated to MySQL; brittle and unnecessary in target |
| LAN | `network_discovery.py`, GUI monitor/pairing | UDP discovery plus /24 TCP scan, then direct shared DB |
| Security | `license.py`, GUI PIN users | local license records, salted SHA-256 PINs, role checks in UI |
| HTTP legacy | `server/server.py` | simple Flask product/sale endpoints, separate and unsafe debug runtime |

`MainWindow` logical subsystems include initialization/navigation/dashboard; first-run network/device configuration; translations/theme; users/PIN; product/category/image/variant forms; POS/cart/favourites/held sales/payment; packs; customers/debts; returns/voids; suppliers/purchases; expenses; report dashboards; PDF/thermal printing and export; database backup; and close/connection lifecycle.

## Required replacement architecture

```
Flutter Desktop (AR/FR/EN, RTL, keyboard/scanner aware)
    ↓ authenticated local HTTP + WebSocket
FastAPI application
    ├─ API / auth / RBAC / device authorization
    ├─ application services and transactional commands
    ├─ reporting, export, print and backup job services
    ├─ audit, structured logs, configuration, LAN health
    ↓ SQLAlchemy unit of work
PostgreSQL
```

Use a modular monolith initially: it is locally deployable, testable, and avoids premature distributed-system complexity. In single-PC mode backend and PostgreSQL run on the store machine. In LAN mode only the server machine hosts them; clients authenticate to its backend. No Flutter process accesses PostgreSQL.

### Backend structure

```
backend/app/{main.py,api/v1,core,db,models,schemas,repositories,services,
             permissions,reporting,printing,backup,devices,workers}
backend/migrations
backend/tests/{unit,integration,contract,e2e}
```

Repositories only query/persist. Services own `SaleService.complete`, `PurchaseService.create/delete`, `ReturnService.create`, `DebtService.payment`, `InventoryService.adjust`, and void/authorization workflows. SQLAlchemy sessions are request/job scoped; Alembic is the sole schema evolution mechanism.

### Flutter structure

```
frontend/lib/{core,config,localization,routing,theme,network,models,
 repositories,state,features/{auth,dashboard,pos,products,inventory,purchases,
 suppliers,customers,debts,returns,expenses,reports,users,settings}}
```

Use Riverpod: scoped async state, testable providers, cache invalidation, and straightforward feature separation. Repository interfaces hide REST/WebSocket and local presentation caches. Use `go_router`, `intl`/ARB translations, a single Material 3 design system, semantic error/loading/empty states, and Flutter's directionality rather than manual RTL placement.

## Boundaries and non-negotiables

- API schemas—not ORM records—cross the process boundary.
- All user-visible text uses semantic ARB keys; error codes map to localized messages.
- Money uses `NUMERIC(18,3)` (store-configurable currency scale); stock uses `NUMERIC(18,3)`; never binary floats.
- A service transaction covers all financial/stock state and audit rows. Printing happens after commit via a durable job; its failure cannot roll back a sale.
- UI permissions are convenience only; every sensitive backend command enforces RBAC and records audit context.
- Offline means no Internet dependency. A disconnected LAN client is not silently allowed to create conflicting sales; its permitted queue/offline policy must be explicitly designed in Phase 16.
