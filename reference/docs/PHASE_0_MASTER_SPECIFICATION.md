# PHASE 0 — Master Specification

## Final Report

| Metric | Value |
|--------|-------|
| Total Python files | 22 |
| Total Python lines | 22,896 |
| Classes | ~25 |
| Functions/Methods | ~450+ |
| Database tables | 14 (+ 1 created by debts.py: `debt_transactions`) |
| GUI screens/pages | 16+ |
| Translation keys | ~500+ (in `_TRANSLATIONS` dict) |
| Silent exception handlers | 55+ `except Exception:` blocks across project |
| Security issues | 6+ |
| Performance issues | 10+ |
| Legacy components | 2 (`sales_v21.py`, `sale_window.py`) |
| Architecture problems | Critical monolith in `main_window.py` (17,326 lines) |

## Source of Truth

The existing Python application at `python_app/` is the primary behavioral reference. All features documented here were verified through static code analysis of the actual source files.

## Target Product

A complete retail/supermarket POS and management system rebuilt as:
- **Frontend**: Flutter Desktop (Windows primary)
- **Backend**: Python FastAPI
- **Database**: PostgreSQL with SQLAlchemy/Alembic
- **Architecture**: Local-first, multi-PC LAN capable

## Key Findings Summary

### Architecture
- `main_window.py` is a 17,326-line monolith containing ALL UI, business logic, SQL, POS, reports, settings, localization, network, device handling, printing, exports, and user management
- Database layer (`db_manager.py`, 2,222 lines) contains SQLite-to-MySQL compatibility layer
- Module files are thin wrappers that delegate most logic to the monolith

### Business Rules Verified
- POS: Cart → search → variants → packs → weights → customer → discount → payment → invoice → print
- Sales: Optimistic locking on stock (`WHERE quantity >= ?`), pack decomposition, variant deduction
- Purchases: Full transaction (header + items + stock + inventory movements + supplier balance)
- Returns: Both independent and from-invoice, stock restoration
- Debts: Separate ledger (`debt_transactions`) + customer balance
- Inventory: Movement tracking with reasons, manual adjustment
- Users: PIN-based auth with SHA-256 hashing, admin/cashier roles
- Multi-PC: UDP broadcast + TCP scan discovery, pairing approval system

### Critical Issues Found
1. **Monolithic architecture** — single file contains 75%+ of all logic
2. **SQL compatibility layer** — unnecessary complexity for SQLite→MySQL translation
3. **Silent exception suppression** — 55+ bare `except Exception:` blocks
4. **Hardcoded strings** — Arabic/French/English mixed throughout
5. **No separation of concerns** — UI, business logic, data access all intermixed
6. **Connection management** — manual close everywhere, leak-prone patterns
7. **Security** — plaintext DB password in config, MD5 device ID hashing
8. **License check disabled** — commented out in main.py

---

See individual documentation files for detailed analysis.
