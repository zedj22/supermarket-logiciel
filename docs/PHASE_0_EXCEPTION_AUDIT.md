# Phase 0 — Exception Audit

## Finding

The source has a high volume of broad exception handling. Static search finds well over one hundred exact `except Exception: pass` patterns in `main_window.py` alone, in addition to broad catches that return empty lists, zero reports, `False`, or print a message. This document is a risk inventory, not a claim that each catch has been runtime-executed.

| Severity | Location/function | Current behavior | Recommended behavior |
|---|---|---|---|
| Critical | `db_manager.py` config load/save | corrupt config can silently default; save only returns false | typed config error, structured log, visible recovery |
| Critical | `sales.py:create_invoice` rollback | rollback failure suppressed | log critical with transaction/document context and fail closed |
| Critical | `db_manager.py:void_invoice`, purchase transaction paths | broad catch/boolean outcome | rollback, preserve cause, user-safe error, audit failure |
| High | report/list methods in `db_manager.py` | DB failure can become empty list/zero report | propagate `DatabaseUnavailable`; show stale/error state |
| High | GUI product/POS/customer/supplier handlers | broad catches frequently hide render/write failure | catch expected validation/I/O exceptions only; log trace id |
| High | debt/favourite/inventory initializers | print and continue | explicit readiness state; no silent ledger degradation |
| Medium | connection pool/close cleanup | cleanup errors discarded | debug logging acceptable, never mask primary error |
| Medium | PDF/export/image/backup code | rendering/file errors commonly suppressed | job status + actionable notification + retained diagnostic |
| Low | `network_discovery.py` probe/broadcast | expected socket/adapter failures suppressed | debug log with rate limiting; distinguish timeout from malformed reply |

Representative explicit locations include `load_db_config`, `save_db_config`, `_ConnectionPool.acquire/release`, `register_device_request`, `get_pending_device_requests`, `void_invoice`, financial/report getters, `SalesManager.create_invoice`, and `PacksManager.get_all_packs`. The GUI has too many anonymous catches to safely list as independently understood behavior; extraction of every site into a machine-readable file should be part of Phase 1 cleanup before porting any method.

Target policy: no bare `except`; catch only known exceptions; use typed domain errors; backend logs structured context and preserves stack traces; API returns stable safe error codes; UI shows an error/loading/retry state; network discovery may downgrade expected misses to debug. No financial mutation may report success after a caught error.
