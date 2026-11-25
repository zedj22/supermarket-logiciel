"""Shared test constants and helpers (importable as a plain module).

Kept out of ``tests/`` on purpose: the customer backend also ships a ``tests``
package, and importing ``tests.conftest`` would resolve to *that* one.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

UTC = timezone.utc

#: Fixed hardware digests — the contract signs a 64-hex SHA-256 digest.
HW_A = "a" * 64
HW_B = "b" * 64

ADMIN_TOKEN = "admin-token"
STRANGER_TOKEN = "stranger-token"
APP_CHECK_TOKEN = "appcheck-ok"

ADMIN_CLAIMS = {"uid": "admin-1", "email": "admin@example.com"}
STRANGER_CLAIMS = {"uid": "user-2", "email": "stranger@example.com"}


def admin_principal():
    """The verified administrator the tokens above resolve to."""
    from service.auth import AdminPrincipal

    return AdminPrincipal(uid="admin-1", email="admin@example.com")


ADMIN_PRINCIPAL = admin_principal()


class Clock:
    """A settable clock so issuance timestamps are deterministic."""

    def __init__(self, moment: datetime | None = None) -> None:
        self.moment = moment or datetime(2026, 3, 1, 12, 0, 0, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.moment

    def advance(self, seconds: int) -> None:
        self.moment = self.moment + timedelta(seconds=seconds)


def make_request_code(hw_hash: str, install_id: str = "install-0001") -> str:
    """Build a genuine ``SMPr1`` request exactly as the desktop backend does."""
    from service import shared

    payload = shared.contract.build_request_payload(
        install_id=install_id,
        hw_hash=hw_hash,
        requested_at=datetime(2026, 2, 28, 9, 30, 0, tzinfo=UTC),
    )
    return shared.contract.build_request_code(payload)


def issue(client: Any, headers: Any, hw_hash: str = HW_A, **body: Any) -> dict:
    """Issue (or fetch) the license for ``hw_hash`` over HTTP."""
    payload = {
        "request_code": body.pop("request_code", make_request_code(hw_hash)),
        **body,
    }
    response = client.post("/v1/licenses", json=payload, headers=headers)
    assert response.status_code in (200, 201), response.text
    return response.json()
