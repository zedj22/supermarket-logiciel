"""Centralized exception classes and handlers for FastAPI.

Converts AppError subclasses into structured JSON error responses.
Logs unexpected exceptions with full context. Never exposes raw
exception messages or stack traces to clients.
"""

import traceback
from typing import Any

import structlog
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import IntegrityError, NoResultFound
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = structlog.get_logger(__name__)


# ---------------------------------------------------------------------------
# Domain exception classes
# ---------------------------------------------------------------------------


class AppError(Exception):
    """Base application error.

    Subclasses set a stable `code` and default `status_code`. The `message_key`
    is a localization key that Flutter will translate; the optional `details`
    dict carries structured context.
    """

    code: str = "INTERNAL_ERROR"
    status_code: int = 500
    message_key: str = "errors.internal"

    def __init__(
        self,
        message: str | None = None,
        details: dict[str, Any] | None = None,
        *,
        code: str | None = None,
        status_code: int | None = None,
        message_key: str | None = None,
    ):
        self.message = message or self.__class__.__name__
        self.details = details or {}
        if code is not None:
            self.code = code
        if status_code is not None:
            self.status_code = status_code
        if message_key is not None:
            self.message_key = message_key
        super().__init__(self.message)


class ValidationError(AppError):
    """Input validation failed."""

    code = "VALIDATION_ERROR"
    status_code = 422
    message_key = "errors.validation"


class AuthenticationError(AppError):
    """Authentication failed (bad PIN, expired token, etc.)."""

    code = "AUTHENTICATION_ERROR"
    status_code = 401
    message_key = "errors.authentication"


class UnauthorizedError(AppError):
    """No credentials provided."""

    code = "UNAUTHORIZED"
    status_code = 401
    message_key = "errors.unauthorized"


class AuthorizationError(AppError):
    """Authenticated but not permitted for this action."""

    code = "AUTHORIZATION_ERROR"
    status_code = 403
    message_key = "errors.authorization"


class ForbiddenError(AppError):
    """Access to the requested resource is forbidden."""

    code = "FORBIDDEN"
    status_code = 403
    message_key = "errors.forbidden"


class NotFoundError(AppError):
    """Requested resource does not exist."""

    code = "NOT_FOUND"
    status_code = 404
    message_key = "errors.notFound"


class ConflictError(AppError):
    """Resource conflict (duplicate, state clash)."""

    code = "CONFLICT"
    status_code = 409
    message_key = "errors.conflict"


class DatabaseConstraintError(AppError):
    """A database integrity constraint rejected the write.

    NOT NULL / foreign key / check failures are server-side data
    integrity problems, not business conflicts: clients must never
    render them with conflict/stock copy ("stock conflict — review
    quantities"), and they must not be confused with the unique-key
    idempotency races that services catch as ``ConflictError``.
    """

    code = "DATABASE_CONSTRAINT"
    status_code = 409
    message_key = "errors.database"


class BusinessRuleError(AppError):
    """Business rule violation."""

    code = "BUSINESS_RULE_ERROR"
    status_code = 422
    message_key = "errors.businessRule"


class DatabaseError(AppError):
    """Database operation failed."""

    code = "DATABASE_ERROR"
    status_code = 500
    message_key = "errors.database"


class ServiceUnavailableError(AppError):
    """Required service is temporarily unavailable."""

    code = "SERVICE_UNAVAILABLE"
    status_code = 503
    message_key = "errors.serviceUnavailable"


# ---------------------------------------------------------------------------
# Database error translation
# ---------------------------------------------------------------------------


def _integrity_kind(exc: IntegrityError) -> str:
    """Classify an IntegrityError by SQLSTATE, with text fallback.

    psycopg2 exposes the SQLSTATE as ``orig.pgcode``; SQLite (unit
    tests) has no SQLSTATE, so the driver message is matched instead.
    """
    sqlstate = getattr(getattr(exc, "orig", None), "pgcode", None)
    text = str(exc).lower()
    if sqlstate == "23505" or "unique" in text or "duplicate key" in text:
        return "unique"
    if sqlstate == "23502" or "not-null" in text or "not null constraint" in text:
        return "not_null"
    if sqlstate == "23503" or "foreign key" in text:
        return "foreign_key"
    if sqlstate == "23514" or "check constraint" in text:
        return "check"
    if sqlstate == "23P01" or "exclusion" in text:
        return "exclusion"
    return "other"


def translate_db_error(exc: Exception) -> AppError:
    """Translate a SQLAlchemy/database exception into an AppError.

    Never exposes raw database details to clients. Logs the original
    exception for debugging.

    IntegrityError classification matters for the client contract:
    a generic integrity failure (NOT NULL / FK / CHECK ...) becomes
    ``DATABASE_CONSTRAINT`` so clients show an accurate database error,
    while a *unique* violation stays ``CONFLICT`` because the services'
    idempotency-race handlers catch ``ConflictError`` to replay the
    winning request.
    """
    logger.warning("database_exception", exc_type=type(exc).__name__, exc_message=str(exc))

    if isinstance(exc, IntegrityError):
        kind = _integrity_kind(exc)
        message = "A database constraint was violated"
        details = {"type": "integrity_violation", "kind": kind}
        if kind == "unique":
            return ConflictError(message=message, details=details)
        return DatabaseConstraintError(message=message, details=details)
    if isinstance(exc, NoResultFound):
        return NotFoundError(message="The requested record was not found")

    return DatabaseError(message="An unexpected database error occurred")


# ---------------------------------------------------------------------------
# Exception handlers
# ---------------------------------------------------------------------------


def register_exception_handlers(app: FastAPI) -> None:
    """Register all exception handlers on the FastAPI app."""

    @app.exception_handler(RequestValidationError)
    async def request_validation_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        """Convert FastAPI/Pydantic body errors into the standard error envelope.

        Default FastAPI returns ``{"detail": [{loc, msg, type}, ...]}`` which
        Flutter cannot surface usefully. We emit a human-readable ``message``
        (joined field errors) plus structured ``details`` keyed by field.
        """
        request_id = getattr(request.state, "request_id", None)
        messages: list[str] = []
        details: dict[str, Any] = {}
        for err in exc.errors():
            loc_parts = [str(p) for p in err.get("loc", ()) if p != "body"]
            field = ".".join(loc_parts) or "body"
            msg = str(err.get("msg", "Invalid value"))
            # Pydantic wraps model_validator ValueError as "Value error, ..."
            if msg.startswith("Value error, "):
                msg = msg[len("Value error, ") :]
            messages.append(f"{field}: {msg}" if loc_parts else msg)
            details[field] = msg

        message = "; ".join(messages) if messages else "Validation failed"
        logger.warning(
            "request_validation_error",
            message=message,
            details=details,
            path=request.url.path,
            method=request.method,
            request_id=request_id,
        )
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "VALIDATION_ERROR",
                    "message_key": "errors.validation",
                    "message": message,
                    "details": details,
                    "request_id": request_id,
                }
            },
        )

    @app.exception_handler(StarletteHTTPException)
    async def http_exception_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        """Handle Starlette/FastAPI HTTP exceptions with structured response.

        This catches 404, 405, and other HTTP exceptions from FastAPI's
        routing layer that don't go through our AppError handler.
        """
        request_id = getattr(request.state, "request_id", None)
        status_code = exc.status_code

        # Map status codes to error codes
        code_map = {
            404: "NOT_FOUND",
            405: "METHOD_NOT_ALLOWED",
        }
        code = code_map.get(status_code, "HTTP_ERROR")

        logger.warning(
            "http_exception",
            status_code=status_code,
            detail=str(exc.detail),
            path=request.url.path,
            method=request.method,
            request_id=request_id,
        )
        return JSONResponse(
            status_code=status_code,
            content={
                "error": {
                    "code": code,
                    "message_key": f"errors.http.{status_code}",
                    "message": str(exc.detail),
                    "details": {},
                    "request_id": request_id,
                }
            },
        )

    @app.exception_handler(AppError)
    async def app_error_handler(request: Request, exc: AppError) -> JSONResponse:
        """Handle known application errors with structured response."""
        request_id = getattr(request.state, "request_id", None)
        logger.warning(
            "app_error",
            code=exc.code,
            message=exc.message,
            details=exc.details,
            path=request.url.path,
            method=request.method,
            request_id=request_id,
        )
        return JSONResponse(
            status_code=exc.status_code,
            content={
                "error": {
                    "code": exc.code,
                    "message_key": exc.message_key,
                    "message": exc.message,
                    "details": exc.details,
                    "request_id": request_id,
                }
            },
        )

    @app.exception_handler(Exception)
    async def unhandled_error_handler(request: Request, exc: Exception) -> JSONResponse:
        """Handle unexpected errors. Logs full traceback, returns safe response."""
        request_id = getattr(request.state, "request_id", None)
        tb = traceback.format_exception(type(exc), exc, exc.__traceback__)

        logger.error(
            "unhandled_exception",
            exc_type=type(exc).__name__,
            exc_message=str(exc),
            path=request.url.path,
            method=request.method,
            request_id=request_id,
            traceback="\n".join(tb),
        )

        return JSONResponse(
            status_code=500,
            content={
                "error": {
                    "code": "INTERNAL_ERROR",
                    "message_key": "errors.internal",
                    "message": "An unexpected error occurred",
                    "details": {},
                    "request_id": request_id,
                }
            },
        )
