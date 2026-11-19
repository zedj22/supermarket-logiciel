"""Lifetime licensing API — Phase L2-A (activation request, activate, status).

Three routes, all on the pre-login bootstrap surface (the license guard
allowlist already covers ``/api/v1/license`` so an unlicensed install can
reach them, and a trial that has expired is never locked out of them):

``POST /api/v1/license/activation-request``
    Builds the unsigned ``SMPr1.…`` request code from the existing Trial
    installation id, the current server-side hardware fingerprint and a
    timestamp.  Read-only with respect to trial state: it never calls
    ``ensure_started()`` and can neither create nor restart a trial.

``POST /api/v1/license/activate``
    Accepts ``{"activation_code": "SMP1.…"}``, verifies it and persists
    the Lifetime license through `StateStore`.  Dedicated rate limiting
    (10/minute/client IP, on top of the app-wide backstop) runs before
    the body is even read, and the raw body is capped at 4 KiB while it
    streams in — a hostile body is rejected before it is parsed.

``GET /api/v1/license/status``
    Additive, safe snapshot: ``mode``/``status`` plus the Lifetime
    identifiers when (and only when) a license verifies, and the existing
    safe trial representation from ``/system/info`` as ``trial``.

None of these responses or logs carry a hardware identifier, a
fingerprint, key material, signature bytes, a state-store envelope, a
file path or a full activation code.
"""

from __future__ import annotations

import json
from typing import Any, Literal

import structlog
from fastapi import APIRouter, Depends, Request
from pydantic import Field

from app.api.v1.system import LicenseInfo
from app.core.config import settings
from app.core.exceptions import AppError, ValidationError
from app.core.rate_limit import enforce_rate_limit, license_limiter
from app.licensing.license_manager import LicenseManager, LicenseStatus
from app.licensing.state_store import StateStoreError
from app.licensing.trial import TrialManager
from app.schemas.common import StrictBaseModel

logger = structlog.get_logger(__name__)

router = APIRouter()

#: Hard cap on the raw activation-request body.  A well-formed body is
#: ~200 bytes (``{"activation_code": "SMP1.<~460 chars>"``), so 4 KiB is
#: two orders of magnitude of headroom and nothing legitimate approaches
#: it.
MAX_ACTIVATION_BODY_BYTES = 4096


# ---------------------------------------------------------------------------
# Response schemas
# ---------------------------------------------------------------------------


class ActivationRequestResponse(StrictBaseModel):
    """What the owner copies into the offline License Generator."""

    request_code: str
    fingerprint_display_code: str


class LicenseStatusResponse(StrictBaseModel):
    """Additive licensing snapshot (Phase L2-A).

    ``mode``/``status`` mirror the vocabulary already used by
    ``/system/info`` with one addition: ``lifetime``/``active`` appear
    only after a stored license has been fully re-verified (signature +
    hardware binding).  ``trial`` carries the unchanged L1-B safe
    representation, so a Lifetime install reports ``mode: "lifetime"``
    *and* still tells the truth about its trial.
    """

    mode: Literal["trial", "trial_expired", "lifetime", "unknown"]
    status: Literal["active", "expired", "unavailable"]
    license_type: Literal["lifetime"] | None = None
    license_id: str | None = None
    activated_at: str | None = None
    trial: LicenseInfo = Field(default_factory=LicenseInfo)


# ---------------------------------------------------------------------------
# Dependency
# ---------------------------------------------------------------------------


def get_license_manager() -> LicenseManager:
    """Per-request manager bound to configured state dir + packaged keys."""
    return LicenseManager.from_settings()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _trial_info() -> LicenseInfo:
    """Safe trial snapshot — identical semantics to ``/system/info``.

    Read-only (`TrialManager.status()`, never `ensure_started()`), and a
    missing or unreadable trial degrades to the controlled
    ``unknown``/``unavailable`` payload instead of an HTTP error, because
    this endpoint must always answer.
    """
    try:
        status = TrialManager.from_settings().status()
    except (StateStoreError, OSError, ValueError):
        logger.warning("license_status_trial_state_unavailable")
        return LicenseInfo(trial_days=settings.TRIAL_DAYS)
    if status is None:
        return LicenseInfo(trial_days=settings.TRIAL_DAYS)
    return LicenseInfo(
        mode=status.mode,
        status="active" if status.active else "expired",
        trial_active=status.active,
        trial_expired=status.expired,
        first_launch_at=status.first_launch_at.isoformat(),
        expires_at=status.expires_at.isoformat(),
        observed_at=status.observed_at.isoformat(),
        remaining_seconds=max(0, int(status.remaining.total_seconds())),
        trial_days=status.trial_days,
    )


def _license_fields(manager: LicenseManager) -> tuple[str, str | None, str | None]:
    """``(license_type, license_id, activated_at)`` — null unless verified.

    Anything that cannot be verified (missing record, tampered payload,
    unreadable key file, unknown key, wrong hardware, unreadable
    fingerprint) answers the same way: no license is reported.  The
    reason is logged as an error *code* or an exception *name* only —
    never a value, a path or a code fragment.
    """
    try:
        status: LicenseStatus | None = manager.status()
    except (StateStoreError, OSError) as exc:
        logger.warning("license_state_unavailable", reason=type(exc).__name__)
        return None, None, None
    except AppError as exc:
        logger.warning("license_state_not_valid", reason=exc.code)
        return None, None, None
    if status is None:
        return None, None, None
    return status.license_type, status.license_id, status.activated_at.isoformat()


def build_status_response(manager: LicenseManager) -> LicenseStatusResponse:
    """Full safe snapshot: Lifetime wins over trial, both are reported."""
    trial = _trial_info()
    license_type, license_id, activated_at = _license_fields(manager)
    if license_type is not None:
        return LicenseStatusResponse(
            mode="lifetime",
            status="active",
            license_type=license_type,
            license_id=license_id,
            activated_at=activated_at,
            trial=trial,
        )
    return LicenseStatusResponse(
        mode=trial.mode,
        status=trial.status,
        license_type=None,
        license_id=None,
        activated_at=None,
        trial=trial,
    )


# ---------------------------------------------------------------------------
# Request body (size-capped before parsing)
# ---------------------------------------------------------------------------


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"duplicate field {key!r}")
        seen.add(key)
    return dict(pairs)


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite number {value}")


def _too_large() -> ValidationError:
    return ValidationError(
        "The request body is too large",
        details={"field": "activation_code", "max_bytes": MAX_ACTIVATION_BODY_BYTES},
    )


async def read_activation_code(request: Request) -> str:
    """Read ``{"activation_code": …}`` with a hard 4 KiB streaming cap.

    The body is read from the wire in chunks and abandoned the moment it
    exceeds the cap, so the limit is enforced *before* JSON parsing (and
    before the licensing code ever sees a byte).  Malformed bodies answer
    the same 422 ``VALIDATION_ERROR`` envelope FastAPI already emits.
    """
    declared = request.headers.get("content-length")
    if declared is not None:
        try:
            size = int(declared)
        except ValueError as exc:
            raise ValidationError("Invalid Content-Length header") from exc
        if size > MAX_ACTIVATION_BODY_BYTES:
            raise _too_large()

    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > MAX_ACTIVATION_BODY_BYTES:
            raise _too_large()
        chunks.append(chunk)

    raw = b"".join(chunks)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError("The request body is not valid UTF-8") from exc
    try:
        document: Any = json.loads(
            text, object_pairs_hook=_reject_duplicates, parse_constant=_reject_constant
        )
    except ValueError as exc:
        raise ValidationError("The request body is not valid JSON") from exc
    if not isinstance(document, dict):
        raise ValidationError("The request body must be a JSON object")
    if set(document) != {"activation_code"}:
        raise ValidationError(
            "The request body must contain only 'activation_code'",
            details={"field": "activation_code"},
        )
    code = document["activation_code"]
    if not isinstance(code, str) or not code.strip():
        raise ValidationError(
            "'activation_code' must be a non-empty string",
            details={"field": "activation_code"},
        )
    return code


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post(
    "/activation-request",
    response_model=ActivationRequestResponse,
    tags=["license"],
)
async def activation_request(
    manager: LicenseManager = Depends(get_license_manager),
) -> ActivationRequestResponse:
    """Create the unsigned request code the owner sends to the Generator.

    No body, no authentication (pre-login), and no side effect on trial
    state.  Fails closed with the existing licensing errors when the
    installation id or the fingerprint cannot be established.
    """
    request = manager.build_activation_request()
    # Deliberately identifier-free: no install id, no digest, no code.
    logger.info("license_activation_requested")
    return ActivationRequestResponse(
        request_code=request.request_code,
        fingerprint_display_code=request.fingerprint_display_code,
    )


@router.post("/activate", response_model=LicenseStatusResponse, tags=["license"])
async def activate(
    request: Request,
    manager: LicenseManager = Depends(get_license_manager),
) -> LicenseStatusResponse:
    """Activate a signed Lifetime license issued for this Main PC.

    Order of defence: dedicated rate limit → raw body size cap → strict
    JSON shape → code format/schema/signature/hardware verification →
    atomic persistence.  A failure at any step writes nothing, so an
    invalid attempt can never destroy an already-valid license.
    """
    enforce_rate_limit(request, license_limiter, scope="license_activation")
    code = await read_activation_code(request)
    status = manager.activate(code)
    logger.info("license_activated", license_id=status.license_id)
    return build_status_response(manager)


@router.get("/status", response_model=LicenseStatusResponse, tags=["license"])
async def license_status(
    manager: LicenseManager = Depends(get_license_manager),
) -> LicenseStatusResponse:
    """Current licensing snapshot — additive and safe to poll.

    Never starts or restarts the trial, never reveals hardware
    information, and reports ``unknown``/``unavailable`` rather than
    guessing whenever state cannot be verified.
    """
    return build_status_response(manager)
