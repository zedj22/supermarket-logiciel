"""Phase L0: license guard — disabled by default, fail-closed when needed.

Exit criteria of §12 L0: with the shipped default (``LICENSE_ENFORCEMENT
=off``) the guard is a complete no-op and every existing route behaves
exactly as before; with enforcement enabled but no licensing state
installed, non-allowlisted requests fail closed — never "licensed by
default".

Phase L1 note: ``trial`` is answered by the real `TrialManager`
(covered in `test_license_guard_trial.py` and `test_trial_manager.py`).
Phase L2-B note: ``on`` is now the combined Lifetime/Trial decision, so
the fail-closed assertions below run against an install with *neither* a
license nor a trial (403 ``license_required``) — an active trial or a
valid Lifetime license admits the request instead.  The Lifetime half of
the ``on`` contract lives in `test_license_guard_on.py`.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi import Request

from app.core.config import Settings, settings
from app.licensing.errors import (
    LICENSING_ERROR_CODES,
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
    TrialRestoreForbiddenError,
    TrialUploadForbiddenError,
)
from app.licensing.guard import ALLOW_PATHS, is_allowlisted, license_guard
from app.licensing.trial import TrialManager

# ── configuration (§11.2: exactly three new settings) ──────────────────


def test_shipped_default_is_enforcement_off():
    assert settings.LICENSE_ENFORCEMENT == "off"


def test_trial_days_default_is_approved_value():
    assert settings.TRIAL_DAYS == 10


def test_license_state_dir_resolves_outside_postgres():
    resolved = Path(settings.LICENSE_STATE_DIR)
    assert resolved.is_absolute()
    assert resolved.name == "license"
    assert resolved.parent.name == "data"


def test_empty_license_state_dir_resolves_to_backend_data():
    custom = Settings(
        DATABASE_URL="sqlite:///:memory:",
        APP_SECRET_KEY="not-a-placeholder",
        JWT_SECRET_KEY="not-a-placeholder",
        LICENSE_STATE_DIR="",
    )
    assert custom.LICENSE_STATE_DIR.replace("\\", "/").endswith("data/license")


def test_trial_days_must_be_at_least_one():
    from pydantic import ValidationError

    with pytest.raises(ValidationError, match="TRIAL_DAYS"):
        Settings(
            DATABASE_URL="sqlite:///:memory:",
            APP_SECRET_KEY="not-a-placeholder",
            JWT_SECRET_KEY="not-a-placeholder",
            TRIAL_DAYS=0,
        )


def test_enforcement_rejects_unknown_mode():
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        Settings(
            DATABASE_URL="sqlite:///:memory:",
            APP_SECRET_KEY="not-a-placeholder",
            JWT_SECRET_KEY="not-a-placeholder",
            LICENSE_ENFORCEMENT="maybe",
        )


# ── error registry (§11.4 code contract) ───────────────────────────────


@pytest.mark.parametrize(
    ("error_cls", "code", "status"),
    [
        (LicenseRequiredError, "license_required", 403),
        (TrialExpiredError, "trial_expired", 403),
        (TrialRestoreForbiddenError, "trial_restore_forbidden", 403),
        (TrialUploadForbiddenError, "trial_upload_forbidden", 403),
        (LicenseInvalidError, "license_invalid", 403),
        (LicenseInvalidKeyError, "license_invalid_key", 403),
        (LicenseBoundElsewhereError, "license_bound_elsewhere", 403),
        (LicenseStatusUnavailableError, "license_status_unavailable", 503),
    ],
)
def test_error_codes_are_lowercase_and_registered(error_cls, code: str, status: int):
    error = error_cls("boom")
    assert error.code == code
    assert error.status_code == status
    assert error.code in LICENSING_ERROR_CODES
    assert error.code == error.code.lower()
    assert error.code.islower()
    assert error.message_key.startswith("errors.license.")


def test_status_unavailable_is_503_fail_closed():
    assert LicenseStatusUnavailableError().status_code == 503


# ── guard behaviour (direct calls) ─────────────────────────────────────


def _request(path: str) -> Request:
    scope = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": path,
        "raw_path": path.encode("ascii"),
        "query_string": b"",
        "headers": [],
        "client": ("127.0.0.1", 4242),
        "server": ("127.0.0.1", 8000),
    }
    return Request(scope)


async def test_guard_is_noop_when_enforcement_off():
    assert settings.LICENSE_ENFORCEMENT == "off"
    assert await license_guard(_request("/api/v1/products")) is None
    assert await license_guard(_request("/api/v1/sales")) is None


async def test_allowlisted_paths_pass_even_when_enforcement_on(
    monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    for path in ("/api/v1/health", "/api/v1/system/info", "/api/v1/auth/login",
                 "/api/v1/devices/pair", "/api/v1/license/activate"):
        assert await license_guard(_request(path)) is None


async def test_non_allowlisted_paths_fail_closed_when_enforcement_on(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    # Phase L2-B: `on` refuses an install that has neither a license nor
    # a trial — fail-closed with the registered 403, never "licensed".
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    monkeypatch.setattr(
        settings, "LICENSE_STATE_DIR", str(tmp_path / "data" / "license")
    )
    with pytest.raises(LicenseRequiredError) as excinfo:
        await license_guard(_request("/api/v1/products"))
    assert excinfo.value.status_code == 403
    assert excinfo.value.code == "license_required"


async def test_guard_has_no_loopback_exempt(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    """Unlike the device guard, the server's own POS is not exempt."""
    state_dir = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    request = _request("/api/v1/sales")
    assert request.client is not None and request.client.host == "127.0.0.1"

    # Unlicensed → refused, loopback client or not (no exemption branch).
    with pytest.raises(LicenseRequiredError):
        await license_guard(request)

    # The decision reads state, never the client: an active trial admits
    # the very same loopback request.
    TrialManager(state_dir=state_dir).ensure_started()
    assert await license_guard(request) is None


def test_allowlist_matches_prefixes_with_boundary():
    for path in ALLOW_PATHS:
        assert is_allowlisted(path) is True
        assert is_allowlisted(path + "/child") is True
    # Similar-looking paths must NOT slip through the boundary.
    assert is_allowlisted("/api/v1/healthcheck") is False
    assert is_allowlisted("/api/v1/authx") is False
    assert is_allowlisted("/api/v1/products") is False
    assert is_allowlisted("/api/v1/sales") is False
    assert is_allowlisted("/api/v1/backups") is False
    assert is_allowlisted("/health") is False


# ── HTTP-level behaviour through the real app ──────────────────────────


def test_health_works_with_enforcement_off(client):
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert "license" not in response.text.lower()


def test_ordinary_route_keeps_its_old_behaviour_with_enforcement_off(client):
    """Phase L0 exit criterion: no request is altered when disabled."""
    response = client.get("/api/v1/products")
    assert response.status_code == 401  # unchanged auth behaviour
    body = response.text.lower()
    assert "license" not in body
    assert "trial" not in body


def test_guard_is_mounted_and_enforces_combined_policy_when_enabled(
    client, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    """Phase L2-B over HTTP: `on` answers from the real licensing state."""
    state_dir = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")

    # Neither a license nor a trial → fail closed with the contract code.
    unlicensed = client.get("/api/v1/products")
    assert unlicensed.status_code == 403
    payload = unlicensed.json()["error"]
    assert payload["code"] == "license_required"
    assert payload["message_key"] == "errors.license.required"

    # An active trial (the other half of the `on` policy) admits the
    # request: 401 is authentication, not licensing.
    TrialManager(state_dir=state_dir).ensure_started()
    assert client.get("/api/v1/products").status_code == 401

    # The bootstrap surface stays reachable so an install can be repaired.
    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/auth/login-users").status_code == 200
