# Phase 3 Implementation — Backend Foundation

## 1. Objective

Build the backend application architecture that sits between the Flutter client and SQLAlchemy models. Phase 3 establishes API versioning, router structure, dependency injection, Pydantic schemas, repository layer, service layer foundation, transaction management, API error handling, request correlation IDs, pagination, filtering, and common response/error structures.

## 2. Existing Architecture Before Phase 3

| Layer | Status |
|---|---|
| FastAPI app factory | Established (Phase 1) |
| SQLAlchemy models | 23 tables (Phase 2) |
| Alembic migrations | 3 migrations, single head (Phase 2) |
| Health endpoints | `/health`, `/health/live`, `/health/ready` (Phase 1) |
| Exception hierarchy | AppError, ValidationError, AuthenticationError, AuthorizationError, NotFoundError, ConflictError, DatabaseError, ServiceUnavailableError (Phase 1) |
| Structured logging | structlog (Phase 1) |
| CORS | Configured (Phase 1) |
| Placeholder packages | schemas/, services/, repositories/, permissions/ (empty) |

## 3. Architecture After Phase 3

```
HTTP Request
    ↓
RequestIDMiddleware (correlation ID)
    ↓
FastAPI Router (/api/v1/...)
    ↓
Dependency Injection (session, pagination, ordering)
    ↓
Pydantic Request Schema
    ↓
Service (transaction boundary, business orchestration)
    ↓
Repository (persistence, queries, filtering)
    ↓
SQLAlchemy Session
    ↓
PostgreSQL

Response flow:
PostgreSQL → SQLAlchemy Model → Repository → Service → Pydantic Response → Router → HTTP
```

## 4. Files Created/Modified

### New Files
```
app/api/dependencies.py          — DI: session, request_id, pagination, ordering, current_user placeholder
app/api/v1/system.py             — Example foundation endpoint (system info)
app/core/middleware.py           — RequestIDMiddleware (X-Request-ID correlation)
app/schemas/common.py            — Base schemas, pagination, ordering, error, success responses
app/repositories/base.py         — Generic BaseRepository (CRUD, pagination, ordering, filtering)
app/services/base.py             — BaseService with transaction management
tests/unit/test_exceptions_v3.py — 19 exception/error contract tests
tests/unit/test_request_id.py    — 8 request ID tests
tests/unit/test_schemas.py       — 13 schema validation tests
tests/unit/test_system.py        — 6 system endpoint tests
tests/unit/test_repository.py    — 10 repository foundation tests
tests/unit/test_service.py       — 6 service/transaction tests
```

### Modified Files
```
app/core/exceptions.py           — Added UnauthorizedError, ForbiddenError, BusinessRuleError,
                                   StarletteHTTPException handler, translate_db_error(),
                                   request_id in all error responses
app/main.py                      — Added RequestIDMiddleware, OpenAPI tags, improved description
app/api/v1/router.py             — Included system router
app/schemas/__init__.py          — Barrel export of common schemas
app/repositories/__init__.py     — Barrel export of BaseRepository
app/services/__init__.py         — Barrel export of BaseService
tests/unit/test_exceptions.py    — Updated for structured error responses
tests/unit/test_request_id.py    — Updated for structured error responses
tests/unit/test_models.py        — Resilient table count (≥23, ignores test models)
tests/unit/test_repository.py    — Renamed test classes to avoid pytest collection warnings
tests/unit/test_service.py       — Fixed for DatabaseError translation
```

## 5. API Structure

```
/api/v1/
    /health              — Full health check (app + DB)
    /health/live         — Liveness probe
    /health/ready        — Readiness probe
    /system/info         — System information (Phase 3 foundation demo)
```

Future feature routers will be added under `/api/v1/` via `api_router.include_router()`.

## 6. Dependency Injection

| Dependency | Type | Purpose |
|---|---|---|
| `get_db` | Generator[Session] | Request-scoped database session |
| `get_request_id` | str | X-Request-ID correlation (preserves client ID or generates UUID4) |
| `get_pagination` | PaginationParams | page, page_size (1 ≤ page ≤ ∞, 1 ≤ page_size ≤ 100) |
| `get_ordering` | OrderingParams | sort_by, sort_dir (asc/desc) |
| `get_current_user_id` | str \| None | Placeholder for Phase 4 authentication |

Annotated shortcuts: `RequestID`, `Pagination`, `Ordering`, `CurrentUser`.

## 7. Repository Layer

`BaseRepository[ModelT]` provides:

| Method | Purpose |
|---|---|
| `get_by_id(id)` | Retrieve by PK, returns None if missing |
| `get_by_id_or_none(id)` | Retrieve by PK, raises NotFoundError if missing |
| `list(pagination, ordering, filters)` | Paginated list with total count |
| `create(instance)` | Persist and flush |
| `delete(instance)` | Hard delete and flush (prefer archive in production) |
| `refresh(instance)` | Refresh from DB |
| `count(filters)` | Count with optional filters |

Filters use SQLAlchemy expressions (never raw SQL from user input).

## 8. Service Layer

`BaseService` provides:

| Method | Purpose |
|---|---|
| `transaction()` | Context manager — commits on exit, rolls back on exception |
| `run_in_transaction(fn)` | Execute a callable within a transaction boundary |

Transaction policy:
- Services own the transaction boundary
- AppError exceptions re-raised (not translated)
- Database exceptions translated via `translate_db_error()`
- Multiple repository operations in one transaction

## 9. Schema Layer

| Schema | Purpose |
|---|---|
| `StrictBaseModel` | Base with ORM mode, strip whitespace |
| `PaginationParams` | page, page_size with validation |
| `PaginatedResponse[T]` | items, total, page, page_size, pages |
| `OrderingParams` | field, direction (asc/desc) |
| `ErrorDetail` | code, message_key, message, details, request_id |
| `ErrorResponse` | error envelope |
| `SuccessResponse` | message, details |
| `IDResponse` | UUID id |
| `TimestampMixin` | created_at, updated_at |

## 10. Error Handling

### Exception Hierarchy (11 classes)
| Class | Code | Status | Purpose |
|---|---|---|---|
| `AppError` | INTERNAL_ERROR | 500 | Base class |
| `ValidationError` | VALIDATION_ERROR | 422 | Input validation |
| `AuthenticationError` | AUTHENTICATION_ERROR | 401 | Bad PIN/token |
| `UnauthorizedError` | UNAUTHORIZED | 401 | No credentials |
| `AuthorizationError` | AUTHORIZATION_ERROR | 403 | Not permitted |
| `ForbiddenError` | FORBIDDEN | 403 | Access forbidden |
| `NotFoundError` | NOT_FOUND | 404 | Resource missing |
| `ConflictError` | CONFLICT | 409 | Duplicate/constraint |
| `BusinessRuleError` | BUSINESS_RULE_ERROR | 422 | Business rule violation |
| `DatabaseError` | DATABASE_ERROR | 500 | DB failure |
| `ServiceUnavailableError` | SERVICE_UNAVAILABLE | 503 | Service down |

### Error Response Shape
```json
{
  "error": {
    "code": "NOT_FOUND",
    "message_key": "errors.notFound",
    "message": "Product not found",
    "details": {"id": "abc-123"},
    "request_id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

### Database Error Translation
`translate_db_error()` converts SQLAlchemy exceptions:
- `IntegrityError` → `ConflictError`
- `NoResultFound` → `NotFoundError`
- Other → `DatabaseError`

Never exposes raw PostgreSQL errors to clients.

## 11. Request ID / Correlation

- Header: `X-Request-ID`
- Middleware generates UUID4 if client doesn't provide one
- Stored in `request.state.request_id`
- Available in: error responses, log context, response headers
- Structured logging includes request_id via structlog contextvars

## 12. Pagination

- Default page_size: 40
- Maximum page_size: 100
- Minimum page: 1
- Response includes: items, total, page, page_size, pages (calculated)
- Enforced via Pydantic validation on query parameters

## 13. Filtering / Sorting

- Sorting via `sort_by` and `sort_dir` query parameters
- Sort direction restricted to `asc` or `desc` (regex validated)
- Sort fields validated against model columns (allowlist pattern)
- Filters use SQLAlchemy expressions (never raw SQL)
- Pattern documented for future feature modules

## 14. Transaction Handling

```python
# Context manager pattern
with service.transaction():
    repo1.create(entity1)
    repo2.update(entity2)
    # auto-commits on clean exit
    # auto-rolls-back on any exception

# Callable pattern
result = service.run_in_transaction(lambda db: do_work(db))
```

## 15. Health / Readiness

Preserved from Phase 1:
- `GET /api/v1/health` — Full check (app + DB)
- `GET /api/v1/health/live` — Liveness (process running)
- `GET /api/v1/health/ready` — Readiness (DB connected)
- All include `X-Request-ID`
- No secrets exposed

## 16. OpenAPI

- Title: "Supermarket Pro API"
- Tags: health, system
- Description includes API version info
- Docs available at `/docs` (non-production only)
- ReDoc available at `/redoc` (non-production only)

## 17. Security

- CORS: configuration-based via `CORS_ORIGINS` setting
- Default origins: localhost only (not `*`)
- No hardcoded secrets in source code
- No debug mode in production defaults
- Error responses never expose stack traces or DB details
- `translate_db_error()` sanitizes all database errors
- Passwords/PINs never logged

## 18. Tests

### Test Summary

| File | Tests | Coverage |
|---|---|---|
| test_config.py | 8 | Settings, Alembic configparser |
| test_database.py | 3 | BaseModel, TimestampMixin, get_db |
| test_enums.py | 14 | All enum values, serialization |
| test_exceptions.py | 2 | 404, 405 structured errors |
| test_exceptions_v3.py | 19 | All exception classes, error contract, DB translation |
| test_health.py | 5 | Health, liveness, readiness, security |
| test_models.py | 56 | Tables, PKs, columns, FKs, constraints, CRUD, relationships |
| test_repository.py | 10 | CRUD, pagination, ordering, filters, count |
| test_request_id.py | 8 | Correlation ID, preservation, error inclusion |
| test_schemas.py | 13 | Pagination, ordering, error, success schemas |
| test_service.py | 6 | Transaction commit, rollback, AppError, multiple ops |
| test_system.py | 6 | System info endpoint, structure, DB status |
| test_migrations.py | 10 | PostgreSQL upgrade/downgrade, structure |
| **Total** | **166** | **166 passed, 0 failed** |

### PostgreSQL Integration Tests
- 10 migration tests run against `supermarket_pro_test`
- Production `supermarket_pro` never touched
- Tests verify: upgrade/downgrade, autogenerate, structure, FKs, timestamps

## 19. PostgreSQL Integration Results

```
tests/integration/test_migrations.py — 10/10 PASSED
- test_current_at_head ✅
- test_heads_single ✅
- test_downgrade_and_reupgrade ✅
- test_autogenerate_detects_no_changes ✅
- test_tables_count ✅
- test_uuid_server_default ✅
- test_numeric_precision ✅
- test_timestamp_defaults_are_dynamic ✅
- test_inventory_movements_has_foreign_keys ✅
- test_all_foreign_keys_present ✅
```

## 20. Verification Commands

```cmd
:: Run all tests
cd C:\Users\MSI\Desktop\supermarket_logiciel\new_app\backend
python -m pytest tests/ -v

:: Compile check
python -m compileall app/ -q

:: Alembic status
python -m alembic current
python -m alembic heads

:: Start the server
python -m uvicorn app.main:app --reload

:: Manual endpoint tests (Windows CMD):
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/health/live
curl http://127.0.0.1:8000/health/ready
curl http://127.0.0.1:8000/api/v1/system/info
curl http://127.0.0.1:8000/docs
curl -X POST http://127.0.0.1:8000/api/v1/health/live
curl http://127.0.0.1:8000/api/v1/nonexistent
curl -H "X-Request-ID: my-test-123" http://127.0.0.1:8000/api/v1/health/live
```

## 21. Results

| Check | Result |
|---|---|
| Tests | 166 passed, 0 failed |
| compileall | 0 errors |
| Alembic head | `a1b2c3d4e5f6` (single head) |
| Migration chain | `0001` → `0002` → `0003` (unchanged) |
| New migrations | None (no schema changes in Phase 3) |
| CORS | Configuration-based, not `*` |
| Secrets | None hardcoded |
| Error contract | Stable (code, message_key, message, request_id) |
| Request IDs | All endpoints return X-Request-ID |

## 22. Known Limitations

1. **No real authentication** — `get_current_user_id` is a placeholder returning None
2. **No complete CRUD modules** — Only foundation endpoint (system/info) exists
3. **Repository filtering** — Basic SQLAlchemy expression filtering only; no complex query builder
4. **No API version negotiation** — Single v1; version header/URL switching not yet implemented
5. **Pagination calculation** — Pages calculated as `ceil(total / page_size)` on client; server sends raw count
6. **No rate limiting** — Not required for local-first desktop app
7. **No request body validation tests** — True 422 validation requires Pydantic body models (will come with business endpoints)

## 23. Deferred Decisions

The following remain **UNRESOLVED** and require product owner approval:
1. Payment split behavior
2. Tax calculation
3. Currency rounding
4. Cash drawer effect
5. Negative stock policy
6. Pack + variant combination rules
7. Debt ceiling enforcement
8. Offline LAN transaction policy

## 24. Phase Completion Checklist

- [x] FastAPI API architecture established
- [x] `/api/v1` foundation exists
- [x] Repository layer exists
- [x] Service layer exists
- [x] Pydantic schema conventions exist
- [x] Dependency injection exists
- [x] Transaction boundaries defined
- [x] Structured API errors work (all status codes covered)
- [x] Request IDs work (middleware + error responses)
- [x] Pagination foundation works
- [x] Filtering/sorting foundation is safe (no raw SQL)
- [x] Health endpoints still work
- [x] OpenAPI is organized (tags, description)
- [x] Security checks pass (no secrets, CORS config, no stack traces)
- [x] Tests pass (166/166)
- [x] PostgreSQL integration tests pass (10/10)
- [x] No existing Phase 2 migration modified
- [x] Consolidated report updated
