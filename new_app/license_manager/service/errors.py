"""Controlled error family for the License API.

Every response failure is one of these: a stable lowercase ``code``, an HTTP
status and a message written by us.  Provider messages (Firebase, Firestore,
Google Cloud) and cryptographic detail are **never** forwarded — they are
logged as a class name only (see ``api.py`` handlers).
"""

from __future__ import annotations

from typing import Any

__all__ = [
    "AdminNotAllowlistedError",
    "ApiError",
    "AppCheckRequiredError",
    "ConfirmationRequiredError",
    "CustomerNotFoundError",
    "DeviceNotFoundError",
    "LicenseConflictError",
    "LicenseNotFoundError",
    "RateLimitedError",
    "RequestFormatInvalidError",
    "RequestTooLargeError",
    "ServiceIdentityNotAllowedError",
    "ServiceIdentityRequiredError",
    "SigningKeyError",
    "SigningKeyNotPublishedError",
    "StoreUnavailableError",
    "UnauthorizedError",
    "ValidationFailedError",
]


class ApiError(Exception):
    """Base class: a stable code, an HTTP status and a safe message."""

    code: str = "internal_error"
    status_code: int = 500

    def __init__(
        self,
        message: str,
        *,
        details: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.message = message
        self.details = details or {}
        self.headers = headers or {}
        super().__init__(message)


class ValidationFailedError(ApiError):
    """The request body does not satisfy the documented shape."""

    code = "validation_error"
    status_code = 422


class RequestFormatInvalidError(ApiError):
    """An ``SMPr1`` request, fingerprint hash or license id is malformed."""

    code = "request_format_invalid"
    status_code = 422


class UnauthorizedError(ApiError):
    """No usable Firebase ID token was presented."""

    code = "unauthorized"
    status_code = 401


class AdminNotAllowlistedError(ApiError):
    """Authenticated, but not on the server-side administrator allowlist."""

    code = "admin_not_allowlisted"
    status_code = 403


class AppCheckRequiredError(ApiError):
    """A verified App Check token is required and was not supplied."""

    code = "app_check_failed"
    status_code = 401


class ServiceIdentityRequiredError(ApiError):
    """The caller did not present a valid Cloud Run service identity token.

    Distinct from ``unauthorized``: the administrator may well have a valid
    Firebase token, but the request did not come through the Dashboard's
    runtime service account.
    """

    code = "service_identity_required"
    status_code = 401


class ServiceIdentityNotAllowedError(ApiError):
    """A valid service identity, but not one this API accepts as a caller."""

    code = "service_identity_not_allowed"
    status_code = 403


class RateLimitedError(ApiError):
    """The caller exceeded a per-administrator limit."""

    code = "rate_limited"
    status_code = 429


class RequestTooLargeError(ApiError):
    """The raw request body exceeded the documented cap."""

    code = "request_too_large"
    status_code = 413


class DeviceNotFoundError(ApiError):
    """No device has ever been recorded for this hardware fingerprint."""

    code = "device_not_found"
    status_code = 404


class CustomerNotFoundError(ApiError):
    """No customer exists with this id."""

    code = "customer_not_found"
    status_code = 404


class LicenseNotFoundError(ApiError):
    """No license exists with this id."""

    code = "license_not_found"
    status_code = 404


class LicenseConflictError(ApiError):
    """The requested transition is not allowed from the license's state."""

    code = "license_conflict"
    status_code = 409


class ConfirmationRequiredError(ApiError):
    """A destructive administrative action was not explicitly confirmed."""

    code = "confirmation_required"
    status_code = 422


class SigningKeyNotPublishedError(ApiError):
    """The signing key id is not in the packaged customer verification keys.

    Fail-closed: a code signed with a key the customer application does not
    ship would only fail later, on the customer's screen, with
    ``license_invalid_key``.  This service refuses to emit it at all.
    """

    code = "signing_key_not_published"
    status_code = 503


class SigningKeyError(ApiError):
    """The signing key could not be loaded or is unusable."""

    code = "signing_unavailable"
    status_code = 503


class StoreUnavailableError(ApiError):
    """Firestore (or the configured repository) is unavailable."""

    code = "store_unavailable"
    status_code = 503
