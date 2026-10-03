"""Device / pairing schemas (Phase 16).

Two layers are deliberately kept apart in the wire contract:

* the **pairing handshake** (``POST /devices/pair`` +
  ``GET /devices/pairings/{pairing_id}``) which is unauthenticated and
  protected by the 6-digit pairing code (owner Q1) and a rate limit, and
* the **device registry** (``GET /devices``, approve / deny / revoke)
  which is authenticated and protected by ``device_manage`` (owner Q2).

The one-time ``device_token`` appears in exactly one response: the first
approval poll.  It is never stored plaintext server-side, never logged,
never returned again.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import Field, field_validator

from app.schemas.common import StrictBaseModel

PROTOCOL_VERSION = 1

# Status values mirrored from app.models.enums.DeviceStatus — kept as plain
# strings in the contract so a client on an older protocol still parses them.
STATUS_PENDING = "pending"
STATUS_APPROVED = "approved"
STATUS_REJECTED = "rejected"
STATUS_REVOKED = "revoked"


class DevicePairRequest(StrictBaseModel):
    """POST /api/v1/devices/pair — unauthenticated, rate limited.

    ``pairing_code`` is the mandatory 6-digit code the admin generated on
    the store server (owner Q1).  It is compared in constant time and is
    NEVER echoed back or written to the audit log.
    """

    device_id: str = Field(..., min_length=8, max_length=100)
    display_name: str = Field(..., min_length=1, max_length=150)
    pairing_code: str = Field(..., min_length=6, max_length=6)
    client_version: str | None = Field(default=None, max_length=50)

    @field_validator("device_id")
    @classmethod
    def _device_id_shape(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped or len(stripped) > 100:
            raise ValueError("device_id must be 1..100 characters")
        # The Flutter client generates ``pos-<millis>-<rand>``; we only
        # require a conservative character set so nothing surprising ever
        # reaches a report header or an audit row.
        allowed = set("abcdefghijklmnopqrstuvwxyz"
                      "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        if not set(stripped) <= allowed:
            raise ValueError("device_id contains unsupported characters")
        return stripped

    @field_validator("display_name")
    @classmethod
    def _display_name_shape(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("display_name must not be blank")
        return stripped

    @field_validator("pairing_code")
    @classmethod
    def _six_digits(cls, v: str) -> str:
        stripped = v.strip()
        if len(stripped) != 6 or not stripped.isdigit():
            raise ValueError("pairing_code must be exactly 6 digits")
        return stripped


class DevicePairResponse(StrictBaseModel):
    """POST /api/v1/devices/pair — 201, canonical Step A §23 shape.

    Exactly two fields: the handle needed to poll and the handshake state.
    There is deliberately **no token field here at all** — the device token
    does not exist until an admin approves the request, and it is then
    delivered exactly once by ``GET /devices/pairings/{pairing_id}``.
    """

    pairing_id: uuid.UUID
    status: str


class DevicePairingStatusResponse(StrictBaseModel):
    """GET /api/v1/devices/pairings/{pairing_id} — the client poll.

    ``device_token`` is present ONLY on the first poll after approval and
    only for a short server-side window; afterwards it is null and the
    field is still present so clients can branch on a stable shape.
    ``token_unavailable`` tells the client the one-time window closed
    (e.g. the server restarted) and it must re-pair.
    """

    pairing_id: uuid.UUID
    device_id: str
    display_name: str
    status: str
    approved_at: datetime | None = None
    rejected_at: datetime | None = None
    device_token: str | None = None
    token_unavailable: bool = False
    # Identity of the server the device is pairing with (§8.2).
    server_id: str
    server_name: str
    http_port: int
    protocol: int = PROTOCOL_VERSION
    tls: bool = False


class DeviceResponse(StrictBaseModel):
    """One row of the admin devices registry."""

    id: uuid.UUID
    device_id: str
    display_name: str
    status: str
    client_version: str | None = None
    approved_at: datetime | None = None
    approved_by: uuid.UUID | None = None
    approved_by_name: str | None = None
    rejected_at: datetime | None = None
    revoked_at: datetime | None = None
    last_seen_at: datetime | None = None
    last_ip: str | None = None
    # An IP is metadata, never an identity — surfaced so the admin can spot
    # "that is not the till I expect", nothing more.
    requested_ip: str | None = None
    created_at: datetime | None = None


class DeviceListResponse(StrictBaseModel):
    """GET /api/v1/devices."""

    items: list[DeviceResponse]
    total: int


class DeviceReasonRequest(StrictBaseModel):
    """POST /devices/{device_id}/deny|revoke — reason is optional context.

    Stored nowhere except the audit row (``entity_type=device``), so it is
    capped small and never contains a token.
    """

    reason: str | None = Field(default=None, max_length=200)

    @field_validator("reason")
    @classmethod
    def _blank_reason_is_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


class PairingCodeResponse(StrictBaseModel):
    """GET /api/v1/devices/pairing-code — admin only (device_manage).

    The code itself is never audited. It is short lived and lives in
    process memory only (Phase 16 has no settings table).
    """

    code: str
    generated_at: datetime
    expires_at: datetime
    expires_in_seconds: int
    protocol: int = PROTOCOL_VERSION
    server_id: str
    http_port: int
