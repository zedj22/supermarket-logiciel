"""Phase L2-A — the three license routes on the pre-login surface.

``GET  /api/v1/license/status``        always answers (additive snapshot)
``POST /api/v1/license/activation-request``  unsigned outbound code, read-only
``POST /api/v1/license/activate``      rate-limited, size-capped, verified

Covered here: reachability without authentication, the strict 4 KiB body
cap on both the declared and the streaming path, strict JSON shape,
existing error-code mapping (`license_invalid` / `license_invalid_key` /
`license_bound_elsewhere` / `VALIDATION_ERROR` / `RATE_LIMITED`), the
10/minute activation cap, activation after trial expiry, unchanged
``/system/info`` licensing block, and the absence of hardware material,
code fragments and key material from responses **and** logs.
"""

from __future__ import annotations

import base64
import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

from app.api.v1 import license as license_api
from app.core.config import settings
from app.core.rate_limit import reset_rate_limiters
from app.db.session import get_db
from app.licensing.activation_code import (
    REQUEST_PREFIX,
    canonical_json,
    encode_activation_code,
)
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.licensing.state_store import StateStore
from app.licensing.trial import STATE_NAME as TRIAL_STATE_NAME
from app.main import app

UTC = timezone.utc

BASE = "/api/v1/license"
SYSTEM_INFO = "/api/v1/system/info"

PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l2a-api",
    system_volume_serial="SERIAL-L2A-API",
    hostname="main-pc-api",
)
HW = HardwareFingerprintService(PROVIDER).fingerprint()

KEY_ID = "k1"
LICENSE_ID = "LIC-2026-0001"

STATUS_FIELDS = {
    "mode",
    "status",
    "license_type",
    "license_id",
    "activated_at",
    "trial",
}
TRIAL_INFO_FIELDS = {
    "mode",
    "status",
    "trial_active",
    "trial_expired",
    "first_launch_at",
    "expires_at",
    "observed_at",
    "remaining_seconds",
    "trial_days",
}
ERROR_FIELDS = {"code", "message_key", "message", "details", "request_id"}


@pytest.fixture(scope="module")
def private() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()


def raw_public(private: Ed25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def make_code(
    private: Ed25519PrivateKey,
    *,
    hw_hash: str = HW,
    license_id: str = LICENSE_ID,
    key_id: str = KEY_ID,
) -> str:
    body = {
        "v": 1,
        "key_id": key_id,
        "license_id": license_id,
        "kind": "lifetime",
        "issued_at": "2026-01-01T00:00:00+00:00",
        "hw_hash": hw_hash,
        "features": ["pos"],
    }
    return encode_activation_code(body, private.sign(canonical_json(body)))


@pytest.fixture()
def license_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, private) -> SimpleNamespace:
    state_dir = tmp_path / "data" / "license"
    state_dir.mkdir(parents=True, exist_ok=True)
    keys_path = tmp_path / "verification_keys.json"
    keys_path.write_text(
        json.dumps({KEY_ID: base64.b64encode(raw_public(private)).decode("ascii")}),
        encoding="utf-8",
    )
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    monkeypatch.setattr(settings, "LICENSE_VERIFICATION_KEYS_FILE", str(keys_path))
    reset_rate_limiters()
    yield SimpleNamespace(state_dir=state_dir, keys_path=keys_path)
    reset_rate_limiters()


@pytest.fixture()
def manager(license_env) -> LicenseManager:
    return LicenseManager(
        keys_path=license_env.keys_path,
        fingerprint=HardwareFingerprintService(PROVIDER),
    )


@pytest.fixture()
def client(db_engine, license_env, manager):
    """Test client with the L2-A dependency seam (no real hardware I/O)."""

    def override_get_db():
        from sqlalchemy.orm import sessionmaker

        connection = db_engine.connect()
        transaction = connection.begin()
        session = sessionmaker(bind=connection)()
        try:
            yield session
        finally:
            session.close()
            transaction.rollback()
            connection.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[license_api.get_license_manager] = lambda: manager
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


def error_of(response) -> dict:
    payload = response.json()
    assert set(payload) == {"error"}, payload
    error = payload["error"]
    assert set(error) >= {"code", "message_key", "message", "request_id"}
    return error


def decode_request_code(code: str) -> dict:
    segment = code.split(".")[1]
    return json.loads(base64.b32decode(segment + "=" * (-len(segment) % 8)))


def expire_trial(state_dir: Path) -> None:
    """Rewrite the trial's own timestamps 40 days into the past."""
    store = StateStore(state_dir)
    payload = store.read(TRIAL_STATE_NAME)
    assert isinstance(payload, dict)
    stamp = (datetime.now(UTC) - timedelta(days=40)).replace(microsecond=0).isoformat()
    store.write(
        TRIAL_STATE_NAME,
        {
            "install_id": payload["install_id"],
            "first_launch_at": stamp,
            "last_seen_at": stamp,
            "max_seen_at": stamp,
        },
    )


# ── reachability / shape ────────────────────────────────────────────────────


def test_status_is_reachable_pre_login_and_reports_no_license(client):
    response = client.get(f"{BASE}/status")

    assert response.status_code == 200
    body = response.json()
    assert set(body) == STATUS_FIELDS
    assert body["mode"] in {"trial", "trial_expired", "unknown"}
    assert body["status"] in {"active", "expired", "unavailable"}
    assert body["license_type"] is None
    assert body["license_id"] is None
    assert body["activated_at"] is None
    assert set(body["trial"]) == TRIAL_INFO_FIELDS
    assert body["trial"]["mode"] == "trial"
    assert body["trial"]["trial_active"] is True
    assert body["trial"]["trial_days"] == settings.TRIAL_DAYS


def test_activation_request_returns_exactly_the_two_safe_fields(client, license_env):
    response = client.post(f"{BASE}/activation-request")

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"request_code", "fingerprint_display_code"}

    payload = decode_request_code(body["request_code"])
    assert payload["hw_hash"] == HW
    assert payload["install_id"]
    assert body["request_code"].startswith(f"{REQUEST_PREFIX}.")
    assert len(body["fingerprint_display_code"].split("-")) == 13

    text = response.text
    for secret in (PROVIDER.machine_guid, PROVIDER.hostname, PROVIDER.system_volume_serial):
        assert secret not in text


def test_activation_request_never_creates_a_trial(client, license_env):
    (license_env.state_dir / "trial.state").unlink()

    response = client.post(f"{BASE}/activation-request")

    assert response.status_code == 403
    assert error_of(response)["code"] == "license_required"
    assert not (license_env.state_dir / "trial.state").exists()

    # The snapshot endpoint keeps answering even with no trial at all.
    status = client.get(f"{BASE}/status")
    assert status.status_code == 200
    assert status.json()["mode"] == "unknown"


def test_unknown_license_route_still_404s_not_403s(client):
    assert client.get(f"{BASE}/nope").status_code == 404


# ── activation round trip ───────────────────────────────────────────────────


def test_activate_round_trip_reports_lifetime_and_keeps_the_trial(
    client, license_env, private
):
    code = make_code(private)

    response = client.post(f"{BASE}/activate", json={"activation_code": code})

    assert response.status_code == 200
    body = response.json()
    assert set(body) == STATUS_FIELDS
    assert body["mode"] == "lifetime"
    assert body["status"] == "active"
    assert body["license_type"] == "lifetime"
    assert body["license_id"] == LICENSE_ID
    assert body["activated_at"]
    assert set(body["trial"]) == TRIAL_INFO_FIELDS
    assert body["trial"]["mode"] == "trial"

    status = client.get(f"{BASE}/status")
    assert status.status_code == 200
    assert status.json()["mode"] == "lifetime"
    assert status.json()["license_id"] == LICENSE_ID

    # /system/info keeps the unchanged L1-B trial-only licensing block.
    info = client.get(SYSTEM_INFO)
    assert info.status_code == 200
    assert set(info.json()["license"]) == TRIAL_INFO_FIELDS
    assert info.json()["license"]["mode"] == "trial"

    # Nothing sensitive in any response.
    for text in (response.text, status.text, info.text):
        for secret in (HW, PROVIDER.machine_guid, PROVIDER.hostname, code):
            assert secret not in text


def test_foreign_hardware_code_is_bound_elsewhere(client, private):
    response = client.post(
        f"{BASE}/activate", json={"activation_code": make_code(private, hw_hash="f" * 64)}
    )

    assert response.status_code == 403
    assert error_of(response)["code"] == "license_bound_elsewhere"
    assert client.get(f"{BASE}/status").json()["mode"] == "trial"


def test_unknown_key_id_maps_to_license_invalid_key(client, private):
    response = client.post(
        f"{BASE}/activate", json={"activation_code": make_code(private, key_id="k9")}
    )

    assert response.status_code == 403
    assert error_of(response)["code"] == "license_invalid_key"


def test_malformed_or_oversized_code_is_license_invalid(client):
    for code in (
        "SMP1.ABC.DEF",
        "SMPr1.ABC.DEF",
        f"SMP1.{'A' * 600}",
    ):
        response = client.post(f"{BASE}/activate", json={"activation_code": code})
        assert response.status_code == 403, code
        error = error_of(response)
        assert error["code"] == "license_invalid"
        assert code not in response.text


# ── body cap (declared + streaming) ─────────────────────────────────────────


def test_declared_oversized_body_is_rejected_before_parsing(client):
    raw = b'{"activation_code":"' + b"A" * 5000 + b'"}'
    response = client.post(
        f"{BASE}/activate", content=raw, headers={"content-type": "application/json"}
    )

    assert response.status_code == 422
    error = error_of(response)
    assert error["code"] == "VALIDATION_ERROR"
    assert error["details"]["max_bytes"] == 4096


def test_streamed_oversized_body_is_abandoned_mid_flight(client):
    def chunks():
        yield b'{"activation_code":"'
        for _ in range(4):
            yield b"A" * 1200
        yield b'"}'

    response = client.post(
        f"{BASE}/activate", content=chunks(), headers={"content-type": "application/json"}
    )

    assert response.status_code == 422
    error = error_of(response)
    assert error["code"] == "VALIDATION_ERROR"
    assert error["details"]["max_bytes"] == 4096


# ── strict JSON shape ───────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "raw",
    [
        b"not json",
        b"[]",
        b"{}",
        b'{"activation_code": null}',
        b'{"activation_code": ""}',
        b'{"activation_code": 123}',
        b'{"activation_code": "SMP1.ABC.DEF", "extra": 1}',
        b'{"activation_code":"a","activation_code":"b"}',
        b"nan",
    ],
)
def test_malformed_activation_bodies_are_validation_errors(client, raw):
    response = client.post(
        f"{BASE}/activate", content=raw, headers={"content-type": "application/json"}
    )

    assert response.status_code == 422
    assert error_of(response)["code"] == "VALIDATION_ERROR"


# ── rate limiting ───────────────────────────────────────────────────────────


def test_activation_attempts_are_capped_at_ten_per_minute(client):
    reset_rate_limiters()

    for _ in range(10):
        response = client.post(
            f"{BASE}/activate", json={"activation_code": "SMP1.ABC.DEF"}
        )
        assert response.status_code == 403
        assert error_of(response)["code"] == "license_invalid"

    limited = client.post(f"{BASE}/activate", json={"activation_code": "SMP1.ABC.DEF"})

    assert limited.status_code == 429
    error = error_of(limited)
    assert error["code"] == "RATE_LIMITED"
    assert error["details"]["scope"] == "license_activation"
    assert error["details"]["retry_seconds"] >= 0


def test_status_reads_are_not_rate_limited_by_the_activation_cap(client):
    reset_rate_limiters()
    for _ in range(15):
        assert client.get(f"{BASE}/status").status_code == 200
    assert client.post(
        f"{BASE}/activate", json={"activation_code": "SMP1.ABC.DEF"}
    ).status_code == 403


# ── expired trial ───────────────────────────────────────────────────────────


def test_activation_works_when_the_trial_has_expired(
    client, license_env, private, monkeypatch
):
    expire_trial(license_env.state_dir)
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")

    status = client.get(f"{BASE}/status")
    assert status.status_code == 200
    assert status.json()["mode"] == "trial_expired"
    assert status.json()["trial"]["trial_expired"] is True

    response = client.post(f"{BASE}/activate", json={"activation_code": make_code(private)})

    assert response.status_code == 200
    body = response.json()
    assert body["mode"] == "lifetime"
    assert body["trial"]["mode"] == "trial_expired"

    reread = client.get(f"{BASE}/status")
    assert reread.json()["mode"] == "lifetime"
    assert reread.json()["trial"]["trial_expired"] is True
    assert client.get(SYSTEM_INFO).status_code == 200


# ── logs ────────────────────────────────────────────────────────────────────


def test_logs_never_carry_the_code_fragments_or_hardware(
    client, license_env, private, caplog
):
    good = make_code(private)
    bad = "SMP1.ABC.DEF"

    with caplog.at_level(logging.INFO):
        assert client.post(f"{BASE}/activation-request").status_code == 200
        assert client.post(
            f"{BASE}/activate", json={"activation_code": good}
        ).status_code == 200
        assert client.post(
            f"{BASE}/activate", json={"activation_code": bad}
        ).status_code == 403

    # Positive control: the capture really saw this route's own events
    # (the WARNING-level rejection proves log capture works at all).
    assert "license_activation_requested" in caplog.text
    assert "license_activated" in caplog.text
    assert "app_error" in caplog.text

    for secret in (
        good,
        bad,
        HW,
        PROVIDER.machine_guid,
        PROVIDER.hostname,
        PROVIDER.system_volume_serial,
        str(license_env.state_dir),
        str(license_env.keys_path),
    ):
        assert secret not in caplog.text
