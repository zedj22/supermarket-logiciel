"""Tests for Phase 3 exception hierarchy and error contract.

Verifies:
- All exception classes have correct codes, status codes, message keys
- Error responses have stable shape (code, message_key, request_id)
- Database error translation works correctly
- No raw exception strings leak to clients
"""

from app.core.exceptions import (
    AppError,
    AuthenticationError,
    AuthorizationError,
    BusinessRuleError,
    ConflictError,
    DatabaseConstraintError,
    DatabaseError,
    ForbiddenError,
    NotFoundError,
    ServiceUnavailableError,
    UnauthorizedError,
    ValidationError,
    translate_db_error,
)
from sqlalchemy.exc import IntegrityError, NoResultFound


# ── Exception class tests ─────────────────────────────────────────────


def test_app_error_defaults():
    err = AppError()
    assert err.code == "INTERNAL_ERROR"
    assert err.status_code == 500
    assert err.message_key == "errors.internal"
    assert err.message == "AppError"
    assert err.details == {}


def test_app_error_custom_message():
    err = AppError(message="Something broke", details={"foo": "bar"})
    assert err.message == "Something broke"
    assert err.details == {"foo": "bar"}


def test_validation_error():
    err = ValidationError()
    assert err.code == "VALIDATION_ERROR"
    assert err.status_code == 422
    assert err.message_key == "errors.validation"


def test_authentication_error():
    err = AuthenticationError()
    assert err.code == "AUTHENTICATION_ERROR"
    assert err.status_code == 401


def test_unauthorized_error():
    err = UnauthorizedError()
    assert err.code == "UNAUTHORIZED"
    assert err.status_code == 401


def test_authorization_error():
    err = AuthorizationError()
    assert err.code == "AUTHORIZATION_ERROR"
    assert err.status_code == 403


def test_forbidden_error():
    err = ForbiddenError()
    assert err.code == "FORBIDDEN"
    assert err.status_code == 403


def test_not_found_error():
    err = NotFoundError()
    assert err.code == "NOT_FOUND"
    assert err.status_code == 404


def test_conflict_error():
    err = ConflictError()
    assert err.code == "CONFLICT"
    assert err.status_code == 409


def test_business_rule_error():
    err = BusinessRuleError(message="Cannot void completed sale")
    assert err.code == "BUSINESS_RULE_ERROR"
    assert err.status_code == 422
    assert err.message == "Cannot void completed sale"


def test_database_error():
    err = DatabaseError()
    assert err.code == "DATABASE_ERROR"
    assert err.status_code == 500


def test_service_unavailable_error():
    err = ServiceUnavailableError()
    assert err.code == "SERVICE_UNAVAILABLE"
    assert err.status_code == 503


# ── Error contract tests ──────────────────────────────────────────────


def test_error_response_has_required_fields(client):
    """404 responses must have code, message_key, and request_id."""
    response = client.get("/api/v1/nonexistent")
    assert response.status_code == 404
    body = response.json()
    assert "error" in body
    error = body["error"]
    assert "code" in error
    assert "message_key" in error
    assert "request_id" in error


def test_error_response_has_request_id_header(client):
    """Response should include X-Request-ID header."""
    response = client.get("/api/v1/nonexistent")
    assert "x-request-id" in response.headers


def test_error_response_does_not_expose_stack_trace(client):
    """Error responses must never contain raw Python exception strings."""
    response = client.get("/api/v1/nonexistent")
    body = response.json()
    error_str = str(body)
    assert "traceback" not in error_str.lower()
    assert "Traceback (most recent call last)" not in error_str


def test_422_validation_error_shape(client):
    """405/422 errors from FastAPI must have structured error body.

    Note: True 422 requires a Pydantic body model on the endpoint.
    We test 405 (Method Not Allowed) which goes through our handler
    and proves the structured error contract works for HTTP errors.
    """
    response = client.post("/api/v1/health/live")
    assert response.status_code == 405
    body = response.json()
    assert "error" in body
    error = body["error"]
    assert error["code"] == "METHOD_NOT_ALLOWED"
    assert "request_id" in error


def test_error_handler_preserves_custom_request_id(client):
    """If client sends X-Request-ID, it should appear in the error response."""
    response = client.get(
        "/api/v1/nonexistent",
        headers={"X-Request-ID": "test-correlation-123"},
    )
    assert response.json()["error"]["request_id"] == "test-correlation-123"


# ── Database error translation ────────────────────────────────────────


def test_translate_integrity_error():
    """A UNIQUE integrity violation stays a ConflictError.

    The services' idempotency-race handlers catch ConflictError to
    replay the winning request, so unique violations keep code CONFLICT.
    """
    result = translate_db_error(IntegrityError("stmt", {}, Exception("unique")))
    assert result.code == "CONFLICT"
    assert result.status_code == 409


# ── Regression: purchase save NOT NULL violation (supplier_id) ────────
#
# Production failure this pins down: the live database was still at
# migration 0035 (purchases.supplier_id NOT NULL) while a purchase was
# saved without a supplier (sport, qty 10 @ 1500). Postgres raised
# SQLSTATE 23502 on purchases_supplier_id_not_null; the generic
# IntegrityError -> ConflictError mapping then handed clients code
# CONFLICT, which Flutter renders as the stock-conflict copy
# ("Stock conflict — review quantities") on a screen about a purchase.
# That mislabel must never come back: a DB integrity failure is
# DATABASE_CONSTRAINT, never CONFLICT/stock.

_PG_NOT_NULL_MESSAGE = (
    'null value in column "supplier_id" of relation "purchases" '
    "violates not-null constraint"
)


def test_translate_not_null_violation_is_database_constraint():
    result = translate_db_error(
        IntegrityError("INSERT INTO purchases ...", {"supplier_id": None}, Exception(_PG_NOT_NULL_MESSAGE))
    )
    assert isinstance(result, DatabaseConstraintError)
    assert not isinstance(result, ConflictError)
    assert result.code == "DATABASE_CONSTRAINT"
    assert result.code != "CONFLICT"
    assert result.status_code == 409
    assert result.message == "A database constraint was violated"
    assert result.details["type"] == "integrity_violation"
    assert result.details["kind"] == "not_null"


def test_translate_foreign_key_violation_is_database_constraint():
    result = translate_db_error(
        IntegrityError(
            "INSERT INTO purchase_lines ...",
            {},
            Exception(
                'insert or update on table "purchase_lines" violates '
                'foreign key constraint "purchase_lines_product_id_fkey"'
            ),
        )
    )
    assert isinstance(result, DatabaseConstraintError)
    assert result.code == "DATABASE_CONSTRAINT"
    assert result.details["kind"] == "foreign_key"


def test_translate_check_violation_is_database_constraint():
    result = translate_db_error(
        IntegrityError(
            "INSERT INTO purchase_lines ...",
            {},
            Exception('new row for relation "purchase_lines" violates check constraint'),
        )
    )
    assert isinstance(result, DatabaseConstraintError)
    assert result.code == "DATABASE_CONSTRAINT"
    assert result.details["kind"] == "check"


def test_translate_sqlite_not_null_violation_reproduces_the_failure():
    """End-to-end reproduction of the failing constraint (no live DB).

    Creates a purchases table the way migration 0035 left it (supplier
    NOT NULL), performs the exact insert the purchase editor sends, and
    asserts the translated AppError is DATABASE_CONSTRAINT — the wire
    contract that stops clients from showing stock copy.
    """
    from sqlalchemy import create_engine, text

    engine = create_engine("sqlite:///:memory:")
    with engine.begin() as conn:
        # Mirror the pre-0036 column: supplier NOT NULL.
        conn.execute(
            text(
                "CREATE TABLE purchases ("
                "id VARCHAR(32) PRIMARY KEY, "
                "invoice_number VARCHAR(50) NOT NULL, "
                "supplier_id VARCHAR(32) NOT NULL)"
            )
        )
        raised = None
        try:
            conn.execute(
                text(
                    "INSERT INTO purchases (id, invoice_number, supplier_id) "
                    "VALUES ('p1', 'PUR-20261023-0001', NULL)"
                )
            )
        except Exception as exc:  # sqlalchemy wraps the driver error
            raised = exc
        assert raised is not None, "pre-0036 schema must reject a NULL supplier"
        assert isinstance(raised, IntegrityError)
        assert "not null constraint" in str(raised).lower()

    result = translate_db_error(raised)
    assert result.code == "DATABASE_CONSTRAINT"
    assert result.code != "CONFLICT"
    assert result.message == "A database constraint was violated"
    engine.dispose()


def test_translate_no_result_found():
    """NoResultFound should translate to NotFoundError."""
    result = translate_db_error(NoResultFound())
    assert result.code == "NOT_FOUND"
    assert result.status_code == 404


def test_translate_generic_exception():
    """Unknown exceptions should translate to DatabaseError."""
    result = translate_db_error(RuntimeError("something broke"))
    assert result.code == "DATABASE_ERROR"
    assert result.status_code == 500
