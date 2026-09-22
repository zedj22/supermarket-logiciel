# PHASE 0 — Exception Audit

## Summary

| Category | Count | Severity |
|----------|-------|----------|
| `except Exception:` (bare) | 55+ | HIGH |
| `except Exception: pass` (silent) | 3+ explicit | CRITICAL |
| `except Exception: return []/None` | 20+ | HIGH |
| `except Exception: print(...)` | 5+ | MEDIUM |
| Connection close in finally | 30+ | MEDIUM |
| Network-related silent catches | 35+ | LOW (expected) |

## Detailed Findings

### CRITICAL — Silent Exception Suppression in Business Logic

#### 1. `db_manager.py:62` — Config Load
```python
except Exception:
    pass
```
- **Function**: `load_db_config()`
- **Failure**: Corrupted/missing config file
- **Impact**: Falls back to defaults silently; user unaware
- **New system**: Log warning, use defaults explicitly

#### 2. `db_manager.py:76` — Config Save
```python
except Exception:
    return False
```
- **Function**: `save_db_config()`
- **Failure**: File write error (permissions, disk full)
- **Impact**: Settings not saved; user informed via return value but no error detail
- **New system**: Raise ConfigurationError with details

#### 3. `db_manager.py:136` — Connection Close
```python
except Exception:
    pass
```
- **Function**: `test_connection()`
- **Failure**: Connection already closed
- **Impact**: Minor — cleanup failure
- **New system**: Log debug, continue

#### 4. `db_manager.py:342-346` — Pool Connection Ping
```python
except Exception:
    try:
        raw.close()
    except Exception:
        pass
```
- **Function**: `_ConnectionPool.acquire()`
- **Failure**: Dead connection
- **Impact**: Connection discarded, new one opened — correct behavior but silent
- **New system**: Log debug, continue

#### 5. `db_manager.py:822-827` — Device Registration
```python
except Exception:
    try:
        conn.rollback()
    except Exception:
        pass
    return None
```
- **Function**: `register_device_request()`
- **Failure**: Database error during device registration
- **Impact**: Returns None — caller may not handle
- **New system**: Raise DatabaseError

#### 6. `db_manager.py:853` — Get Pending Requests
```python
except Exception:
    return []
```
- **Function**: `get_pending_device_requests()`
- **Failure**: Database query failure
- **Impact**: Empty list returned; pending requests invisible
- **New system**: Raise DatabaseError

#### 7. `db_manager.py:1101-1106` — Void Invoice
```python
except Exception:
    try:
        conn.rollback()
    except Exception:
        pass
    return False
```
- **Function**: `void_invoice()`
- **Failure**: Any database error during void
- **Impact**: Returns False; invoice not voided
- **New system**: Raise with context, log full error

#### 8. `db_manager.py:1189-1190` — Financial Report
```python
except Exception:
    pass
```
- **Function**: `get_financial_report()`
- **Failure**: Database query failure
- **Impact**: Returns empty report with all zeros
- **New system**: Raise DatabaseError

#### 9. `sales.py:367-368` — Rollback
```python
except Exception:
    pass
```
- **Function**: `create_invoice()` rollback
- **Failure**: Rollback itself fails
- **Impact**: Possible inconsistent state
- **New system**: Log critical error, attempt recovery

#### 10. `packs.py:161-162` — Get All Packs
```python
except Exception:
    return []
```
- **Function**: `get_all_packs()`
- **Failure**: Database error
- **Impact**: Empty packs list
- **New system**: Raise DatabaseError

### HIGH — Silent Returns in Data Access

Multiple methods in `db_manager.py` return empty lists/None on any exception:

| Line | Function | Returns |
|------|----------|---------|
| 853 | `get_pending_device_requests()` | `[]` |
| 917 | `get_all_device_names()` | `[]` |
| 951 | `get_returns()` | `[]` |
| 975 | `get_all_sales_devices()` | `[]` |
| 1007 | `get_invoices_history()` | `[]` |
| 1033 | `get_invoice_items()` | `[]` |
| 1190 | `get_financial_report()` | `{...zeros}` |
| 1236 | `get_hourly_traffic_data()` | `{...}` |
| 1273 | `get_slow_moving_products()` | `[]` |
| 1311 | `get_product_performance()` | `[]` |
| 1348 | `get_profit_by_category()` | `[]` |
| 1383 | `get_daily_timeline()` | `[]` |
| 1418 | `get_hourly_revenue()` | `[]` |
| 1455 | `get_device_breakdown()` | `[]` |
| 1484 | `get_voided_invoices()` | `[]` |
| 1505 | `get_debt_collected()` | `0.0` |
| 1585 | `get_expenses()` | `[]` |

### MEDIUM — Exception Print (Non-Fatal)

| File | Line | Function | Print Statement |
|------|------|----------|-----------------|
| debts.py | 18 | `__init__` | `print(f"⚠ ...")` |
| inventory.py | 12 | `__init__` | `print(f"⚠ ...")` |
| db_manager.py | 459 | `__init__` | `print(f"⚠ ...")` |

### LOW — Network Operations (Expected)

`network_discovery.py` has 35+ `except Exception:` blocks. These are **expected and acceptable** because:
- Network discovery inherently involves failed connections
- UDP broadcast failures are normal
- TCP scan timeouts are normal
- Virtual adapter probing may fail
- These are part of the discovery algorithm, not error conditions

**However**, they should still be logged at DEBUG level for troubleshooting.

## Recommendations for New System

1. **Zero silent exception suppression** — Every exception must be logged
2. **Typed exceptions** — Use specific exception types (DatabaseError, ValidationError, etc.)
3. **Structured logging** — Log with context, not just print statements
4. **User-friendly messages** — Technical details in logs, safe messages to users
5. **Network exceptions** — Log at DEBUG level, not suppressed
6. **Connection management** — Use context managers, not manual close
7. **Transaction safety** — Consistent try/commit/rollback pattern
