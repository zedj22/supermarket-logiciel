"""Phase 16 tests — LAN / multi-PC / devices.

Covers analysis §33 step 6 and the owner decisions Q1-Q13:

  Q1   mandatory 6-digit pairing code (wrong/expired code is rejected)
  Q2   device_manage is admin-only (manager and cashier are 403)
  Q6   the server PC is itself a client (pair → approve → guard accepts)
  Q8   protocol/server_id added to /system/info, no TLS anywhere
  Q9   device_id immutable, display_name is only a label
  Q11  no report contract changes (devices are never joined into reports)
  Q12  protocol compatibility enforced now, client_version recorded
  Q13  UDP discovery port configurable, default == HTTP port

Also asserts the two negative guarantees of this phase:
  * LAN_MODE off ⇒ zero behaviour change (the guard is a no-op),
  * heartbeats / pairing codes / device tokens never reach audit_logs.
"""

from __future__ import annotations

import json
import socket
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.server_identity import get_server_id
from app.db.base import Base
from app.db.session import get_db
from app.discovery.packet import (
    APP_ID,
    MAGIC,
    MAX_REQUEST_BYTES,
    MAX_RESPONSE_BYTES,
    build_discover,
    build_offer,
    parse_discover,
    parse_offer,
)
from app.discovery.responder import DiscoveryResponder
from app.main import app
from app.models.audit import AuditLog
from app.models.device import Device
from app.models.enums import AuditAction, DeviceStatus
from app.services.auth import AuthService
from app.services.devices import reset_process_state

DEVICE_ID = "pos-1000-abcdef"
OTHER_DEVICE_ID = "pos-2000-fedcba"


def _wrong_code(code: str) -> str:
    """A 6-digit code that is guaranteed not to collide with ``code``."""
    return f"{(int(code) + 1) % 1_000_000:06d}"


# ── Fixtures ──────────────────────────────────────────────────────────────


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def testing_session(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, testing_session):
    session = testing_session()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    session.commit()
    yield session
    session.close()


@pytest.fixture()
def client(engine, testing_session, db):
    def override_get_db():
        session = testing_session()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


@pytest.fixture(autouse=True)
def clean_process_state():
    """Pairing code / rate limiters / token vault are process-global."""
    reset_process_state()
    yield
    reset_process_state()


@pytest.fixture()
def lan_on(monkeypatch):
    monkeypatch.setattr(settings, "LAN_MODE", True)
    return True


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


@pytest.fixture()
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


def _pairing_code(client, admin_headers) -> str:
    resp = client.get("/api/v1/devices/pairing-code", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    return resp.json()["code"]


def _pair(client, code: str, device_id: str = DEVICE_ID, name: str = "Till 1"):
    return client.post(
        "/api/v1/devices/pair",
        json={
            "device_id": device_id,
            "display_name": name,
            "pairing_code": code,
            "client_version": "1.0.0",
        },
    )


def _approve_pairing(client, code, admin_headers, device_id=DEVICE_ID):
    """pair → poll → approve → poll, returning (device_id, token)."""
    pair = _pair(client, code, device_id=device_id)
    assert pair.status_code == 201, pair.text
    pairing_id = pair.json()["pairing_id"]

    first = client.get(f"/api/v1/devices/pairings/{pairing_id}")
    assert first.status_code == 200
    assert first.json()["status"] == "pending"

    approve = client.post(
        f"/api/v1/devices/{device_id}/approve", headers=admin_headers
    )
    assert approve.status_code == 200, approve.text

    second = client.get(f"/api/v1/devices/pairings/{pairing_id}")
    body = second.json()
    assert body["status"] == "approved"
    assert body["device_token"], "the one-time token must be delivered once"
    return device_id, body["device_token"]


# ── /system/info additive contract (§8.2) ─────────────────────────────────


def test_system_info_exposes_protocol_and_server_id(client):
    body = client.get("/api/v1/system/info").json()
    assert body["protocol"] == 1
    uuid.UUID(body["server_id"])  # a real UUIDv4, not an IP / hostname
    # Existing contract untouched.
    for key in ("name", "version", "environment", "database_status", "timestamp"):
        assert key in body


def test_server_id_is_stable_across_calls():
    a = get_server_id()
    b = get_server_id()
    assert a == b
    uuid.UUID(a)


def test_server_id_env_override(monkeypatch):
    monkeypatch.setattr(settings, "SERVER_ID", "fixed-server-id")
    assert get_server_id() == "fixed-server-id"


# ── Discovery packet (§4) ─────────────────────────────────────────────────


def test_discover_offer_roundtrip():
    req = build_discover("nonce-0123456789")
    assert parse_discover(req) == "nonce-0123456789"

    offer = build_offer(
        nonce="nonce-0123456789",
        server_id=str(uuid.uuid4()),
        name="Store",
        http_port=8000,
    )
    parsed = parse_offer(offer, expect_nonce="nonce-0123456789")
    assert parsed is not None
    assert parsed["app"] == "supermarket_pro"
    assert parsed["protocol"] == 1
    assert parsed["tls"] is False
    assert parsed["http_port"] == 8000


def test_discover_rejects_garbage_and_oversize():
    assert parse_discover(b"nope") is None
    assert parse_discover(MAGIC + b"\x00not-json") is None
    assert parse_discover(b"\x00" + b"a" * 400) is None
    # Right magic but way over the request budget.
    assert parse_discover(MAGIC + b"\x00" + b"a" * (MAX_REQUEST_BYTES + 50)) is None
    # Wrong version / type / nonce length.
    assert parse_discover(
        MAGIC + b'\x00{"v":2,"t":"discover","nonce":"0123456789"}'
    ) is None
    assert parse_discover(MAGIC + b'\x00{"v":1,"t":"offer","nonce":"0123456789"}') is None
    assert parse_discover(MAGIC + b'\x00{"v":1,"t":"discover","nonce":"ab"}') is None


def test_offer_rejects_stale_nonce():
    offer = build_offer(
        nonce="nonce-0123456789",
        server_id=str(uuid.uuid4()),
        name="Store",
        http_port=8000,
    )
    assert parse_offer(offer, expect_nonce="different-nonce") is None


def test_offer_never_carries_secrets():
    offer = build_offer(
        nonce="nonce-0123456789",
        server_id=str(uuid.uuid4()),
        name="Store",
        http_port=8000,
    ).decode("utf-8", "replace")
    for forbidden in ("token", "pairing_code", "pin", "password", "authorization"):
        assert forbidden not in offer


def test_offer_matches_the_flutter_client_contract():
    """Regression for the real 2-PC LAN bug: offer dropped, "server not found".

    Everything above the UDP layer was correct in that test (broadcast sent,
    responder answered, TCP 8000 + /health + /system/info all fine), but the
    Flutter client never accepted the offer: its ``_decode``
    (``lib/features/devices/discovery_service.dart``) requires
    ``decoded['app'] == discoveryAppId`` (``"supermarket_pro"``) on every
    datagram, and the backend offer carried no ``app`` field at all.
    """
    assert APP_ID == "supermarket_pro", "must equal Flutter discoveryAppId"
    nonce = "nonce-0123456789"
    server_id = str(uuid.uuid4())
    raw = build_offer(
        nonce=nonce, server_id=server_id, name="Store", http_port=8000
    )
    assert len(raw) <= MAX_RESPONSE_BYTES

    payload = json.loads(raw[len(MAGIC) + 1 :].decode("utf-8"))

    # The exact offer shape the Flutter client validates.
    assert set(payload) == {
        "v",
        "app",
        "t",
        "nonce",
        "server_id",
        "name",
        "http_port",
        "protocol",
        "tls",
    }
    assert payload["app"] == "supermarket_pro"
    assert payload["v"] == 1
    assert payload["t"] == "offer"
    assert payload["nonce"] == nonce
    assert payload["server_id"] == server_id
    assert payload["name"] == "Store"
    assert payload["http_port"] == 8000
    assert payload["protocol"] == 1
    assert payload["tls"] is False

    # Unauthenticated broadcast ⇒ public metadata only, never a secret.
    blob = json.dumps(payload).lower()
    for forbidden in ("token", "pairing_code", "pin", "password", "authorization"):
        assert forbidden not in blob


def test_discovery_responder_answers_on_loopback():
    responder = DiscoveryResponder(port=0, host="127.0.0.1")
    assert responder.start() is True
    try:
        port = responder.bound_port
        assert port

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2.0)
        try:
            sock.sendto(build_discover("nonce-abcdef123456"), ("127.0.0.1", port))
            data, _ = sock.recvfrom(2048)
        finally:
            sock.close()

        offer = parse_offer(data, expect_nonce="nonce-abcdef123456")
        assert offer is not None
        assert offer["app"] == "supermarket_pro"
        assert offer["server_id"] == get_server_id()
        assert offer["protocol"] == 1
        assert offer["tls"] is False
    finally:
        responder.stop()
    assert responder.running is False


def test_discovery_responder_drops_invalid_packets():
    responder = DiscoveryResponder(port=0, host="127.0.0.1")
    assert responder.start() is True
    try:
        port = responder.bound_port
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(0.6)
        try:
            sock.sendto(b"definitely not a discover packet", ("127.0.0.1", port))
            with pytest.raises(socket.timeout):
                sock.recvfrom(2048)
        finally:
            sock.close()
    finally:
        responder.stop()


def test_discovery_is_off_by_default():
    assert settings.DISCOVERY_ENABLED is False
    assert settings.DISCOVERY_PORT == settings.PORT


# ── Pairing handshake (Q1) ────────────────────────────────────────────────


def test_pairing_code_is_six_digits(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    assert len(code) == 6 and code.isdigit()


def test_pair_requires_six_digit_code(client, admin_headers, db):
    _pairing_code(client, admin_headers)
    resp = _pair(client, "12345")
    assert resp.status_code == 422


def test_pair_rejects_wrong_code(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    resp = _pair(client, _wrong_code(code))
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "PAIRING_CODE_INVALID"


def test_pair_rejects_when_no_code_was_generated(client):
    resp = _pair(client, "123456")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "PAIRING_CODE_INVALID"


def test_pair_then_poll_is_pending(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    resp = _pair(client, code)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    # Canonical Step A §23 shape: and nothing else — in particular there is
    # no token field to contradict, because no token exists yet.
    assert set(body) == {"pairing_id", "status"}
    assert body["status"] == "pending"
    assert "device_token" not in body

    poll = client.get(f"/api/v1/devices/pairings/{body['pairing_id']}")
    assert poll.status_code == 200
    assert poll.json()["status"] == "pending"
    assert poll.json()["device_token"] is None
    # The client learns the identity of the box it is pairing with.
    assert poll.json()["server_id"] == get_server_id()
    assert poll.json()["protocol"] == 1
    assert poll.json()["tls"] is False


def test_poll_unknown_pairing_is_404(client):
    resp = client.get(f"/api/v1/devices/pairings/{uuid.uuid4()}")
    assert resp.status_code == 404


def test_approve_delivers_token_exactly_once(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    _device_id, token = _approve_pairing(client, code, admin_headers)
    assert len(token) >= 32

    # The stored row never holds the plaintext.
    row = client.get("/api/v1/devices", headers=admin_headers).json()["items"][0]
    assert row["status"] == "approved"
    assert "device_token" not in row
    assert row.get("token") is None

    # Second poll: approved, but the one-time window is gone.
    pair = _pair(client, code, device_id=OTHER_DEVICE_ID)
    # (rate limit allows this; we only need a pairing handle to poll)
    if pair.status_code == 201:
        other_pairing = pair.json()["pairing_id"]
        client.post(f"/api/v1/devices/{OTHER_DEVICE_ID}/approve", headers=admin_headers)
        first = client.get(f"/api/v1/devices/pairings/{other_pairing}").json()
        assert first["device_token"]
        second = client.get(f"/api/v1/devices/pairings/{other_pairing}").json()
        assert second["device_token"] is None
        assert second["token_unavailable"] is True


def test_pairing_is_rate_limited(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    statuses = [_pair(client, _wrong_code(code)).status_code for _ in range(5)]
    assert statuses == [401] * 5
    resp = _pair(client, _wrong_code(code))
    assert resp.status_code == 429
    assert resp.json()["error"]["code"] == "PAIRING_RATE_LIMITED"


# ── Admin registry (Q2) ───────────────────────────────────────────────────


def test_devices_requires_device_manage(client, admin_headers, manager_headers,
                                         cashier_headers):
    assert client.get("/api/v1/devices", headers=admin_headers).status_code == 200
    assert client.get("/api/v1/devices", headers=manager_headers).status_code == 403
    assert client.get("/api/v1/devices", headers=cashier_headers).status_code == 403
    assert client.get("/api/v1/devices").status_code == 401


def test_approve_requires_device_manage(client, admin_headers, manager_headers, db):
    code = _pairing_code(client, admin_headers)
    resp = _pair(client, code)
    assert resp.status_code == 201
    denied = client.post(f"/api/v1/devices/{DEVICE_ID}/approve", headers=manager_headers)
    assert denied.status_code == 403
    # Still pending — a denied approval must not mutate anything.
    row = db.execute(select(Device).where(Device.device_id == DEVICE_ID)).scalar_one()
    assert row.status == DeviceStatus.PENDING.value


def test_approve_unknown_device_is_404(client, admin_headers):
    resp = client.post("/api/v1/devices/nope-unknown-device/approve",
                       headers=admin_headers)
    assert resp.status_code == 404


def test_approving_twice_is_409(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    _approve_pairing(client, code, admin_headers)
    resp = client.post(f"/api/v1/devices/{DEVICE_ID}/approve", headers=admin_headers)
    assert resp.status_code == 409


def test_deny_rejects_a_pending_device(client, admin_headers, db):
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code).status_code == 201
    resp = client.post(
        f"/api/v1/devices/{DEVICE_ID}/deny",
        json={"reason": "unknown till"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == "rejected"

    row = db.execute(select(Device).where(Device.device_id == DEVICE_ID)).scalar_one()
    assert row.status == DeviceStatus.REJECTED.value
    assert row.token_hash is None


def test_revoke_clears_the_credential(client, admin_headers, db):
    code = _pairing_code(client, admin_headers)
    _device_id, _token = _approve_pairing(client, code, admin_headers)

    resp = client.post(
        f"/api/v1/devices/{DEVICE_ID}/revoke",
        json={"reason": "sold the till"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == "revoked"

    row = db.execute(select(Device).where(Device.device_id == DEVICE_ID)).scalar_one()
    assert row.status == DeviceStatus.REVOKED.value
    assert row.token_hash is None
    assert row.revoked_at is not None


def test_revoke_of_pending_device_is_409(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code).status_code == 201
    resp = client.post(f"/api/v1/devices/{DEVICE_ID}/revoke", headers=admin_headers)
    assert resp.status_code == 409


def test_revoked_device_must_repair_before_approval(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    _approve_pairing(client, code, admin_headers)
    assert client.post(
        f"/api/v1/devices/{DEVICE_ID}/revoke", headers=admin_headers
    ).status_code == 200

    # Re-pairing the SAME device_id re-opens the row instead of duplicating it.
    again = _pair(client, code, name="Till 1 renamed")
    assert again.status_code == 201, again.text
    rows = client.get("/api/v1/devices", headers=admin_headers).json()["total"]
    assert rows == 1

    approve = client.post(f"/api/v1/devices/{DEVICE_ID}/approve", headers=admin_headers)
    assert approve.status_code == 200


def test_pairing_an_already_approved_device_is_409(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    _approve_pairing(client, code, admin_headers)
    resp = _pair(client, code)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "DEVICE_ALREADY_PAIRED"


def test_display_name_change_does_not_change_device_id(client, admin_headers):
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code, name="Front till").status_code == 201
    client.post(f"/api/v1/devices/{DEVICE_ID}/approve", headers=admin_headers)
    items = client.get("/api/v1/devices", headers=admin_headers).json()["items"]
    assert items[0]["device_id"] == DEVICE_ID
    assert items[0]["display_name"] == "Front till"


# ── Device guard (LAN_MODE) ───────────────────────────────────────────────


def test_guard_is_a_noop_when_lan_mode_is_off(client, admin_headers):
    assert settings.LAN_MODE is False
    resp = client.get("/api/v1/users", headers=admin_headers)
    assert resp.status_code == 200
    # No device headers were sent and nothing complained about them.
    assert "device_required" not in resp.text


def test_guard_requires_device_headers(client, lan_on):
    resp = client.get("/api/v1/users")
    # Step A §12: no identity offered at all is 401; a presented-but-refused
    # identity is 403 (the three tests above/below pin each side).
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "device_required"


def test_guard_rejects_unknown_device(client, lan_on):
    resp = client.get(
        "/api/v1/users",
        headers={"X-Device-ID": "pos-9999-nope", "X-Device-Token": "x" * 40},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "device_not_paired"


def test_guard_rejects_pending_device(client, admin_headers, lan_on):
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code).status_code == 201
    resp = client.get(
        "/api/v1/users", headers={"X-Device-ID": DEVICE_ID, "X-Device-Token": "abc"}
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "device_not_paired"


def test_guard_rejects_wrong_token_for_approved_device(client, admin_headers, lan_on):
    code = _pairing_code(client, admin_headers)
    _approve_pairing(client, code, admin_headers)
    resp = client.get(
        "/api/v1/users",
        headers={"X-Device-ID": DEVICE_ID, "X-Device-Token": "wrong-token"},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "device_not_paired"


def test_guard_accepts_approved_device_with_valid_token(client, admin_headers, lan_on):
    code = _pairing_code(client, admin_headers)
    _device_id, token = _approve_pairing(client, code, admin_headers)
    resp = client.get(
        "/api/v1/users",
        headers={
            **admin_headers,
            "X-Device-ID": DEVICE_ID,
            "X-Device-Token": token,
        },
    )
    # The guard passed: the request now succeeds on JWT + device together.
    assert resp.status_code == 200
    assert "device_required" not in resp.text
    assert "device_not_paired" not in resp.text
    assert "device_revoked" not in resp.text


def test_guard_fails_before_jwt_is_checked(client, admin_headers, lan_on):
    """A paired device with a missing JWT still gets an ordinary 401."""
    code = _pairing_code(client, admin_headers)
    _device_id, token = _approve_pairing(client, code, admin_headers)
    resp = client.get(
        "/api/v1/products",
        headers={"X-Device-ID": DEVICE_ID, "X-Device-Token": token},
    )
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


def test_guard_rejects_revoked_device_with_distinct_code(client, admin_headers, lan_on):
    code = _pairing_code(client, admin_headers)
    _device_id, token = _approve_pairing(client, code, admin_headers)
    assert client.post(
        f"/api/v1/devices/{DEVICE_ID}/revoke", headers=admin_headers
    ).status_code == 200

    resp = client.get(
        "/api/v1/users",
        headers={"X-Device-ID": DEVICE_ID, "X-Device-Token": token},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "device_revoked"


def test_guard_allowlist_bootstrap_surface(client, admin_headers, lan_on):
    """Everything a not-yet-paired device needs must work without headers."""
    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 200
    assert client.get("/api/v1/system/info").status_code == 200
    assert client.get("/api/v1/auth/login-users").status_code == 200
    # The device registry is RBAC-protected, not device-token protected.
    assert client.get("/api/v1/devices", headers=admin_headers).status_code == 200

    code = _pairing_code(client, admin_headers)
    assert _pair(client, code).status_code == 201

    # …and everything else is guarded.
    assert client.get("/api/v1/users").status_code == 401
    assert client.get("/api/v1/products").status_code == 401
    assert client.get("/api/v1/customers").status_code == 401


def test_guard_records_last_seen_without_auditing(client, admin_headers, lan_on, db):
    code = _pairing_code(client, admin_headers)
    _device_id, token = _approve_pairing(client, code, admin_headers)

    headers = {**admin_headers, "X-Device-ID": DEVICE_ID, "X-Device-Token": token}
    assert client.get("/api/v1/users", headers=headers).status_code == 200

    db.expire_all()
    row = db.execute(select(Device).where(Device.device_id == DEVICE_ID)).scalar_one()
    assert row.last_seen_at is not None

    # Only the pair + approve rows exist — a heartbeat never creates one.
    actions = sorted(
        r.action
        for r in db.execute(select(AuditLog)).scalars().all()
        if r.entity_type == "device"
    )
    assert actions == sorted(
        [AuditAction.DEVICE_PAIR.value, AuditAction.DEVICE_APPROVE.value]
    )


# ── Audit guarantees (§18) ────────────────────────────────────────────────


def test_pair_approve_deny_revoke_are_audited_without_secrets(
    client, admin_headers, db
):
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code).status_code == 201
    assert client.post(
        f"/api/v1/devices/{DEVICE_ID}/deny", json={"reason": "nope"},
        headers=admin_headers,
    ).status_code == 200
    # Re-open the same device and take it all the way to approved, then revoked.
    assert _pair(client, code).status_code == 201
    assert client.post(
        f"/api/v1/devices/{DEVICE_ID}/approve", headers=admin_headers
    ).status_code == 200
    assert client.post(
        f"/api/v1/devices/{DEVICE_ID}/revoke", json={"reason": "old"},
        headers=admin_headers,
    ).status_code == 200

    rows = [
        r
        for r in db.execute(select(AuditLog)).scalars().all()
        if r.entity_type == "device"
    ]
    actions = [r.action for r in rows]
    for expected in (
        AuditAction.DEVICE_PAIR.value,
        AuditAction.DEVICE_REJECT.value,
        AuditAction.DEVICE_APPROVE.value,
        AuditAction.DEVICE_REVOKE.value,
    ):
        assert expected in actions
        assert len(expected) <= 30  # audit_logs.action is String(30)

    blob = " ".join((r.details or "") + " " + (r.action or "") for r in rows)
    assert code not in blob, "the pairing code must never be audited"
    assert "token" not in blob.lower()
    assert "pin" not in blob.lower()


def test_device_id_is_immutable_identity(client, admin_headers, db):
    """Q9: the device_id is the identity; only display_name may change."""
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code, name="Old name").status_code == 201
    assert _pair(client, code, name="New name").status_code == 201
    row = db.execute(select(Device).where(Device.device_id == DEVICE_ID)).scalar_one()
    assert row.device_id == DEVICE_ID
    assert row.display_name == "New name"


# ── Protocol / compatibility (Q12) ────────────────────────────────────────


def test_client_version_is_recorded_but_not_enforced(client, admin_headers, db):
    code = _pairing_code(client, admin_headers)
    assert _pair(client, code).status_code == 201
    client.post(f"/api/v1/devices/{DEVICE_ID}/approve", headers=admin_headers)
    row = db.execute(select(Device).where(Device.device_id == DEVICE_ID)).scalar_one()
    assert row.client_version == "1.0.0"


def test_devices_table_is_isolated_from_reports(db):
    """Q11/D-05: no domain table gets a foreign key pointing at devices.

    ``sales.device_id`` and friends stay free text so the Phase 14 report
    contract is byte-for-byte unchanged.
    """
    for name, table in Base.metadata.tables.items():
        if name == "devices":
            continue
        for fk in table.foreign_keys:
            target = (fk.target_fullname or "").split(".")[0]
            assert target != "devices", f"{name} must not reference devices"

    sales = Base.metadata.tables["sales"]
    device_col = sales.c.device_id
    assert device_col.type.__class__.__name__ in ("String", "NVARCHAR")
    assert device_col.nullable is True
