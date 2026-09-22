# Phase 0 — Legacy Audit

| Component | Classification | Evidence / treatment |
|---|---|---|
| `modules/sales_v21.py` | LEGACY / possibly callable manually | parallel older sale implementation; `MainWindow` POS uses `modules/sales.py`, not this module. Preserve read-only for comparison. |
| `gui/sale_window.py` | LEGACY | alternate 321-line sale popup; main workflow is `MainWindow.show_pos` / `complete_sale`. |
| `gui/add_product_window.py` | POSSIBLY ACTIVE | standalone product popup exists; main window has `_open_product_form`; inspect runtime menu binding during parity test. |
| `server/server.py` | POSSIBLY ACTIVE legacy API | standalone Flask endpoints for product/sale, not invoked by `main.py`; may be used externally. |
| SQLite compatibility code | ACTIVE technical debt | database manager actively translates SQL while target is MySQL/MariaDB. Replace with native PostgreSQL SQLAlchemy. |

Never delete these components in Phase 0. Before migration, create a runtime smoke matrix for every menu/action and observe import/call use; static non-reference is not absolute proof of external invocation.
