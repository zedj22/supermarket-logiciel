"""Router-level device guard (Phase 16 §12).

When ``LAN_MODE=1`` every ``/api/v1`` request outside the explicit
bootstrap allowlist must present two headers:

    X-Device-ID     the immutable ``pos-…`` machine identity
    X-Device-Token  the one-time token issued by admin approval

Guard ordering: this is a *router* dependency, so FastAPI solves it before
any endpoint-level dependency. That means a request is rejected for a
missing/unknown device **before** the JWT is even looked at — the LAN
identity check and the user session are deliberately independent layers
(§9.3), and neither can substitute for the other.

Fail closed. With ``LAN_MODE=0`` (the default, and what the whole
pre-Phase-16 test suite runs with) the guard returns immediately and
behaviour is bit-for-bit unchanged.

Status contract (Step A §12): ``device_required`` → **401** (no machine
identity offered at all); ``device_not_paired`` and ``device_revoked`` →
**403** (identity offered and refused). The error envelope is produced by
``app_error_handler`` from ``code`` + ``message_key``, so the Flutter side —
which branches on ``error.code`` — is unaffected by the status.

Allowlist — the minimum needed to bootstrap a device that is by definition
not yet paired, plus the RBAC-protected device registry itself (otherwise
the very first till could never be approved):

    /api/v1/health*          liveness probes
    /api/v1/system/info      server_id / protocol handshake
    /api/v1/auth/*           login, setup, verify, logout, reauth, me
    /api/v1/devices*         pair + pairing poll + device_manage admin API

Everything else — products, sales, reports, users, backups — is guarded.

Loopback exception (Q6): a request whose peer address is this machine
itself (``127.0.0.1`` / ``::1``) skips the *device* layer only. That is
the server PC's own local POS, which has nothing to pair with. JWT
authentication and endpoint RBAC are untouched, and a remote
``192.168.x.x`` client is unaffected — it never appears as loopback.
"""

from __future__ import annotations

import secrets
from datetime import datetime, timezone

import structlog
from fastapi import Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.security import hash_token
from app.db.session import get_db
from app.models.device import Device
from app.models.enums import DeviceStatus
from app.services.devices import (
    DeviceNotPairedError,
    DeviceRequiredError,
    DeviceRevokedError,
)

logger = structlog.get_logger(__name__)

DEVICE_ID_HEADER = "X-Device-ID"
DEVICE_TOKEN_HEADER = "X-Device-Token"

# Do not turn every request into a write (§12.5).
LAST_SEEN_THROTTLE_SECONDS = 60

ALLOW_PATHS = (
    "/api/v1/health",
    "/api/v1/system/info",
    "/api/v1/auth",
    "/api/v1/devices",
)

# Q6 — "the server PC may also be a till".
#
# The local POS on the store server talks to *itself*: it boots against
# AppConstants.defaultServerBaseUrl ("http://localhost:8000") and is the
# same machine as the backend, so there is no second PC and nothing to
# pair.  It therefore never sends X-Device-ID / X-Device-Token, and without
# this exception LAN_MODE=1 would lock the server's own POS out of every
# ordinary route (the defect found in real 2-PC QA).
#
# The exemption is the peer address of the accepted TCP socket, which
# nothing on the wire can forge: a remote 192.168.x.x client can never
# appear as one of these, so remote LAN tills stay fully guarded.
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "::ffff:127.0.0.1"})


def is_loopback_client(request: Request) -> bool:
    """True only when the TCP peer is this machine itself.

    Covers IPv4 loopback, IPv6 loopback (a "localhost" resolution that
    reaches a dual-stack listener) and the IPv4-mapped IPv6 spelling of
    the same address.  Anything else — LAN IP, public IP, unknown peer —
    is a remote client and must present device credentials.

    Caveat: a reverse proxy running *on this host* would itself be a
    loopback peer.  Phase 16 deploys uvicorn directly on the LAN (no
    proxy, no tunnel), so that situation does not arise; if one is ever
    introduced it must forward the real client address and this rule must
    be revisited.
    """
    client = request.client
    if client is None:
        return False
    return client.host in LOOPBACK_HOSTS


def is_allowlisted(path: str) -> bool:
    """True for the bootstrap surface, where no device exists yet."""
    for prefix in ALLOW_PATHS:
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def _client_ip(request: Request) -> str | None:
    client = request.client
    return client.host if client is not None else None


def _load_device(db: Session, device_id: str) -> Device | None:
    return db.scalar(select(Device).where(Device.device_id == device_id))


def _touch_last_seen(db: Session, device: Device, ip: str | None) -> None:
    """Throttled liveness update. Never audited (§18)."""
    now = datetime.now(timezone.utc)
    if device.last_seen_at is not None:
        age = (now - device.last_seen_at).total_seconds()
        if age < LAST_SEEN_THROTTLE_SECONDS:
            return
    device.last_seen_at = now
    if ip:
        device.last_ip = ip
    try:
        db.commit()
    except Exception as exc:  # pragma: no cover - liveness must not 500
        db.rollback()
        logger.warning("device_last_seen_commit_failed", error=str(exc))


def device_guard(request: Request, db: Session = Depends(get_db)) -> None:
    """Fail closed unless the caller presents a paired, unrevoked device."""
    if not settings.LAN_MODE:
        return

    path = request.url.path
    if is_allowlisted(path):
        return

    # Q6 — the server PC's own local POS is not a LAN client: it is this
    # machine reaching itself on loopback (default base URL
    # "http://localhost:8000"), so no device was ever paired for it. Skip
    # the device layer for loopback peers only; remote clients fall through
    # to the exact checks below, and JWT/RBAC still run on every route.
    if is_loopback_client(request):
        return

    device_id = request.headers.get(DEVICE_ID_HEADER)
    token = request.headers.get(DEVICE_TOKEN_HEADER)

    if not device_id or not token:
        raise DeviceRequiredError(
            message="This server requires a paired device (LAN mode)",
            details={"header": DEVICE_ID_HEADER},
        )

    device = _load_device(db, device_id)
    if device is None:
        raise DeviceNotPairedError(message="Device is not paired with this store")

    if device.status == DeviceStatus.REVOKED.value:
        raise DeviceRevokedError(
            message="This device was revoked; ask an administrator to re-approve it",
            details={"device_id": device_id},
        )

    if device.status not in (
        DeviceStatus.APPROVED.value,
    ):
        raise DeviceNotPairedError(
            message="This device is not approved yet",
            details={"device_id": device_id, "status": device.status},
        )

    stored = device.token_hash or ""
    if not stored or not secrets.compare_digest(stored, hash_token(token)):
        raise DeviceNotPairedError(message="Device credential is not valid")

    _touch_last_seen(db, device, _client_ip(request))
