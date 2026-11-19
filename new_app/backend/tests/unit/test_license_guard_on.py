"""Phase L2-B — the ``LICENSE_ENFORCEMENT=on`` decision (§8) over HTTP.

`app.licensing.authorization.decide_licensing` is the single place the
combined Lifetime / Free-Trial policy lives; this file pins it decision
by decision and then proves the mounted app answers exactly that way
(§4 / §7 / §9):

* enforcement ``off`` reads **no** licensing state at all (L0 no-op);
* a valid Lifetime license authorizes *first* — even with an expired or
  corrupt trial — and the trial is not read at all;
* an active trial authorizes in second place, license or no license;
* without either: expired → 403 ``trial_expired``, missing → 403
  ``license_required``, unverifiable → 503 ``license_status_unavailable``;
* a license that fails re-verification (corrupt record, wrong hardware,
  unusable keys) is *not* a license, is never fatal on its own and can
  never demote an active trial;
* enforcement ``trial`` stays frozen Phase L1 — a Lifetime license is
  never consulted there;
* every decision rebuilds the manager from state (no cached status), a
  backend restart changes nothing, and neither ``/license/status`` nor
  ``/system/info`` changed shape under ``on``; client-supplied claims
  (headers) are ignored.

Licensing state in this file is always a throwaway ``tmp_path``; the
Lifetime codes are signed in-test with an ephemeral Ed25519 key bound to
a `StaticHardwareInfoProvider`, and ``authorization._license_manager`` —
the module's one seam — is pointed at that world.
"""

from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.license import get_license_manager
from app.core.config import settings
from app.db.base import Base
from app.db.session import get_db
from app.licensing import authorization as authorization_module
from app.licensing.activation_code import canonical_json, encode_activation_code
from app.licensing.authorization import decide_licensing
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
)
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LICENSE_STATE_NAME, LicenseManager
from app.licensing.trial import STATE_NAME, TrialManager
from app.main import app

UTC = timezone.utc

KEY_ID = "k1"

#: The one signing key of this file (ephemeral, generated at import).
_PRIVATE = Ed25519PrivateKey.generate()

#: This Main PC (the machine the licenses in this file bind to).
PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l2b-main",
    system_volume_serial="SERIAL-L2B",
    hostname="main-pc",
)

#: A different machine — a license issued for it must never verify here.
OTHER_PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-other-pc",
    system_volume_serial="SERIAL-OTHER",
    hostname="other-pc",
)


# ── fixtures ───────────────────────────────────────────────────────────


def _raw_public() -> bytes:
    return _PRIVATE.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def write_keys(path: Path, keys: dict[str, bytes]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        key_id: base64.b64encode(material).decode("ascii")
        for key_id, material in keys.items()
    }
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def make_code(
    *,
    hw_hash: str,
    license_id: str = "LIC-2026-0001",
    key_id: str = KEY_ID,
    private: Ed25519PrivateKey = _PRIVATE,
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


def hw(provider: StaticHardwareInfoProvider = PROVIDER) -> str:
    return HardwareFingerprintService(provider).fingerprint()


def _manager(
    state_dir: Path,
    keys_path: Path,
    provider: StaticHardwareInfoProvider = PROVIDER,
) -> LicenseManager:
    return LicenseManager(
        state_dir=state_dir,
        keys_path=keys_path,
        fingerprint=HardwareFingerprintService(provider),
    )


@pytest.fixture()
def state_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Throwaway licensing state, installed before the app starts."""
    path = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(path))
    return path


@pytest.fixture()
def keys_path(tmp_path: Path) -> Path:
    return write_keys(
        tmp_path / "keys" / "verification_keys.json",
        {KEY_ID: _raw_public()},
    )


@pytest.fixture()
def on_enforcement(monkeypatch: pytest.MonkeyPatch) -> str:
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    return "on"


@pytest.fixture()
def license_manager(
    state_dir: Path, keys_path: Path, monkeypatch: pytest.MonkeyPatch
) -> LicenseManager:
    """Activate-through manager plus the production seam.

    The seam is a *factory* (exactly like `LicenseManager.from_settings`):
    every decision builds a fresh manager, so nothing can be shared
    between passes.
    """
    monkeypatch.setattr(
        authorization_module,
        "_license_manager",
        lambda: _manager(state_dir, keys_path),
    )
    return _manager(state_dir, keys_path)


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


def _override_db(engine):
    def override_get_db():
        maker = sessionmaker(bind=engine, autoflush=False)
        db = maker()
        try:
            yield db
        finally:
            db.close()

    return override_get_db


@pytest.fixture()
def client(
    engine, state_dir: Path, on_enforcement: str, license_manager: LicenseManager
):
    """The real mounted app — licensing state is this test's throwaway dir.

    Declared after the licensing fixtures on purpose: the lifespan then
    seeds its first-start trial into ``state_dir`` (§5 T1), exactly like
    a real install.
    """
    app.dependency_overrides[get_db] = _override_db(engine)
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


@pytest.fixture()
def licensed_api(client, license_manager: LicenseManager):
    """/license endpoints answering from *this test's* manager (static hw)."""
    app.dependency_overrides[get_license_manager] = lambda: license_manager
    yield client
    app.dependency_overrides.pop(get_license_manager, None)


# ── helpers ────────────────────────────────────────────────────────────


def _seed_trial(state_dir: Path, *, age: timedelta = timedelta(0)) -> None:
    """Write ``trial.state`` as if the first start happened `age` ago."""
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    first_start = datetime.now(UTC) - age
    TrialManager(state_dir=state_dir, clock=lambda: first_start).ensure_started()


def _trial_file(state_dir: Path) -> Path:
    return state_dir / f"{STATE_NAME}.state"


def _license_file(state_dir: Path) -> Path:
    return state_dir / f"{LICENSE_STATE_NAME}.state"


def _error(resp) -> dict:
    assert resp.status_code >= 400, resp.text
    payload = resp.json()
    assert "error" in payload, payload
    return payload["error"]


# ── §8 decision matrix — enforcement off / lifetime / trial ────────────


def test_off_reads_no_licensing_state_at_all(
    state_dir: Path, keys_path: Path, monkeypatch: pytest.MonkeyPatch
):
    """L0 exit criterion, still true under the combined decision."""
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "off")

    def _boom(*args, **kwargs):
        raise AssertionError("enforcement off must not read licensing state")

    monkeypatch.setattr(authorization_module, "_license_manager", _boom)
    monkeypatch.setattr(TrialManager, "from_settings", _boom)

    decision = decide_licensing()

    assert decision.outcome == "disabled"
    assert decision.authorized is True
    assert decision.license_mode is None
    assert decision.denial_error() is None
    assert decision.trial is None and decision.lifetime is None


def test_lifetime_authorizes_before_the_trial_is_even_read(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
    monkeypatch: pytest.MonkeyPatch,
):
    license_manager.activate(make_code(hw_hash=hw()))

    def _boom(*args, **kwargs):
        raise AssertionError("the trial must not be read once a license is valid")

    monkeypatch.setattr(TrialManager, "from_settings", _boom)

    decision = decide_licensing()

    assert decision.outcome == "lifetime"
    assert decision.authorized is True
    assert decision.license_mode == "lifetime"
    assert decision.lifetime is not None
    assert decision.lifetime.license_id == "LIC-2026-0001"
    assert decision.trial is None
    assert decision.denial_error() is None
    assert not _trial_file(state_dir).exists()


def test_lifetime_wins_over_an_expired_trial(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
):
    license_manager.activate(make_code(hw_hash=hw()))
    _seed_trial(state_dir, age=timedelta(days=11))

    decision = decide_licensing()

    assert decision.outcome == "lifetime"
    assert decision.license_mode == "lifetime"


def test_lifetime_wins_over_a_corrupt_trial(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
):
    license_manager.activate(make_code(hw_hash=hw()))
    _trial_file(state_dir).write_bytes(b"garbage, not an envelope")

    decision = decide_licensing()

    assert decision.outcome == "lifetime"
    assert decision.trial is None, "a corrupt trial must not even be read"
    assert _trial_file(state_dir).read_bytes() == b"garbage, not an envelope"


def test_active_trial_authorizes_without_any_license(
    state_dir: Path, on_enforcement: str
):
    _seed_trial(state_dir)

    decision = decide_licensing()

    assert decision.outcome == "trial_active"
    assert decision.authorized is True
    assert decision.license_mode == "trial"
    assert decision.lifetime is None
    assert decision.denial_error() is None


def test_expired_trial_without_license_is_denied_with_trial_expired(
    state_dir: Path, on_enforcement: str
):
    _seed_trial(state_dir, age=timedelta(days=11))

    decision = decide_licensing()

    assert decision.outcome == "trial_expired"
    assert decision.authorized is False
    assert decision.license_mode == "trial_expired"
    error = decision.denial_error()
    assert isinstance(error, TrialExpiredError)
    assert error.status_code == 403
    expected = TrialManager(state_dir=state_dir).status().expires_at.isoformat()
    assert expected in error.message


def test_missing_license_and_trial_is_license_required(
    state_dir: Path, on_enforcement: str
):
    decision = decide_licensing()

    assert decision.outcome == "trial_missing"
    assert decision.authorized is False
    assert decision.license_mode is None
    error = decision.denial_error()
    assert isinstance(error, LicenseRequiredError)
    assert error.status_code == 403
    assert error.code == "license_required"


def test_unverifiable_trial_without_license_is_503(
    state_dir: Path, on_enforcement: str
):
    state_dir.mkdir(parents=True, exist_ok=True)
    _trial_file(state_dir).write_bytes(b"garbage, not an envelope")

    decision = decide_licensing()

    assert decision.outcome == "trial_unavailable"
    assert decision.authorized is False
    error = decision.denial_error()
    assert isinstance(error, LicenseStatusUnavailableError)
    assert error.status_code == 503
    assert error.code == "license_status_unavailable"


# ── an invalid license is never a license (and never fatal) ────────────


def test_corrupt_license_record_never_demotes_an_active_trial(
    state_dir: Path, on_enforcement: str
):
    state_dir.mkdir(parents=True, exist_ok=True)
    _license_file(state_dir).write_bytes(b"garbage, not a license")
    _seed_trial(state_dir)

    decision = decide_licensing()

    assert decision.outcome == "trial_active"
    assert decision.lifetime is None
    assert decision.denial_error() is None


def test_hardware_mismatch_never_demotes_an_active_trial(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
    monkeypatch: pytest.MonkeyPatch,
):
    """A license issued for other hardware is *not* a license (§10.3)."""
    license_manager.activate(make_code(hw_hash=hw()))
    # The machine's hardware changed after activation.
    monkeypatch.setattr(
        authorization_module,
        "_license_manager",
        lambda: _manager(state_dir, keys_path, provider=OTHER_PROVIDER),
    )
    _seed_trial(state_dir)

    decision = decide_licensing()

    assert decision.outcome == "trial_active"
    assert decision.lifetime is None


def test_unusable_key_file_never_fails_the_decision_alone(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
):
    license_manager.activate(make_code(hw_hash=hw()))
    keys_path.unlink()
    _seed_trial(state_dir, age=timedelta(days=11))

    decision = decide_licensing()

    # Missing keys ⇒ "no license" (never 503 by itself); the trial's own
    # state still produces the denial code.
    assert decision.outcome == "trial_expired"
    assert decision.lifetime is None


def test_corrupt_license_without_any_trial_is_license_required(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
):
    license_manager.activate(make_code(hw_hash=hw()))
    _trial_file(state_dir).unlink(missing_ok=True)
    _license_file(state_dir).write_bytes(b"corrupted after activation")

    decision = decide_licensing()

    # The license side degrades to "no license"; with no trial either,
    # the answer is the registered 403 — never "licensed", never a guess.
    assert decision.outcome == "trial_missing"
    assert decision.denial_error().code == "license_required"


def test_corrupt_license_and_corrupt_trial_fail_closed_as_503(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
):
    license_manager.activate(make_code(hw_hash=hw()))
    _license_file(state_dir).write_bytes(b"corrupted after activation")
    _trial_file(state_dir).write_bytes(b"garbage, not an envelope")

    decision = decide_licensing()

    assert decision.outcome == "trial_unavailable"
    assert decision.denial_error().status_code == 503


# ── frozen Phase L1 semantics under enforcement=trial ──────────────────


def test_trial_mode_never_consults_the_lifetime_license(
    state_dir: Path,
    keys_path: Path,
    license_manager: LicenseManager,
    monkeypatch: pytest.MonkeyPatch,
):
    license_manager.activate(make_code(hw_hash=hw()))
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    _seed_trial(state_dir, age=timedelta(days=11))

    decision = decide_licensing()

    assert decision.outcome == "trial_expired"
    assert decision.lifetime is None, "Phase L1 must ignore the license"


def test_trial_mode_over_http_stays_frozen_despite_a_valid_license(
    state_dir: Path,
    client,
    license_manager: LicenseManager,
    monkeypatch: pytest.MonkeyPatch,
):
    license_manager.activate(make_code(hw_hash=hw()))
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    _seed_trial(state_dir, age=timedelta(days=11))

    resp = client.get("/api/v1/products")

    assert resp.status_code == 403
    assert _error(resp)["code"] == "trial_expired"


# ── every pass is rebuilt from state (no cache, restart-safe) ──────────


def test_every_decision_builds_a_fresh_manager(
    state_dir: Path,
    keys_path: Path,
    on_enforcement: str,
    license_manager: LicenseManager,
    monkeypatch: pytest.MonkeyPatch,
):
    license_manager.activate(make_code(hw_hash=hw()))

    calls: list[int] = []

    def factory() -> LicenseManager:
        calls.append(1)
        return _manager(state_dir, keys_path)

    monkeypatch.setattr(authorization_module, "_license_manager", factory)

    first = decide_licensing()
    second = decide_licensing()

    assert first.outcome == "lifetime"
    assert second.outcome == "lifetime"
    assert len(calls) == 2, "each decision must re-read state from disk"


def test_lifetime_authorizes_again_after_a_backend_restart(
    engine, state_dir: Path, on_enforcement: str, license_manager: LicenseManager
):
    license_manager.activate(make_code(hw_hash=hw()))
    app.dependency_overrides[get_db] = _override_db(engine)
    try:
        with TestClient(app) as first_session:
            assert first_session.get("/api/v1/products").status_code == 401

        # A new lifespan = a backend restart: same state files, no cache.
        with TestClient(app) as second_session:
            assert second_session.get("/api/v1/products").status_code == 401
    finally:
        app.dependency_overrides.clear()


# ── HTTP contract: business routes under `on` ──────────────────────────


def test_business_routes_admit_a_valid_lifetime_license(
    state_dir: Path, client, license_manager: LicenseManager
):
    license_manager.activate(make_code(hw_hash=hw()))

    # 401 is authentication — the guard already admitted the request.
    assert client.get("/api/v1/products").status_code == 401
    assert client.get("/api/v1/backups").status_code == 401
    assert client.post("/api/v1/backups").status_code == 401
    # The §4.4 lifetime row even grants restore — and the expired trial
    # sitting on the same install cannot take it away.
    _seed_trial(state_dir, age=timedelta(days=11))
    restore = client.post("/api/v1/backups/3/restore", json={"confirm": True})
    assert restore.status_code == 401


def test_expired_trial_without_license_refuses_business_routes(
    state_dir: Path, client
):
    _seed_trial(state_dir, age=timedelta(days=11))

    resp = client.get("/api/v1/products")

    assert resp.status_code == 403
    assert resp.headers["content-type"].startswith("application/json")
    body = _error(resp)
    assert body["code"] == "trial_expired"
    assert body["message_key"] == "errors.license.trialExpired"


def test_unverifiable_trial_without_license_is_503_over_http(
    state_dir: Path, client
):
    state_dir.mkdir(parents=True, exist_ok=True)
    _trial_file(state_dir).write_bytes(b"garbage, not an envelope")

    resp = client.get("/api/v1/products")

    assert resp.status_code == 503
    body = _error(resp)
    assert body["code"] == "license_status_unavailable"
    assert body["message_key"] == "errors.license.statusUnavailable"


def test_client_supplied_license_claims_are_ignored(state_dir: Path, client):
    """Neither headers nor any client state may grant authorization (§4)."""
    _trial_file(state_dir).unlink(missing_ok=True)

    resp = client.get(
        "/api/v1/products",
        headers={
            "X-License-Status": "active",
            "X-Initial-License-Mode": "lifetime",
            "License-Mode": "lifetime",
        },
    )

    assert resp.status_code == 403
    assert _error(resp)["code"] == "license_required"


# ── HTTP contract: /license/status and /system/info under `on` ────────


def test_license_status_under_on_prefers_lifetime_then_trial(
    licensed_api, license_manager: LicenseManager
):
    before = licensed_api.get("/api/v1/license/status")
    assert before.status_code == 200
    assert before.json()["mode"] == "trial"
    assert before.json()["status"] == "active"

    license_manager.activate(make_code(hw_hash=hw()))

    after = licensed_api.get("/api/v1/license/status")
    assert after.status_code == 200
    body = after.json()
    assert body["mode"] == "lifetime"
    assert body["status"] == "active"
    assert body["license_type"] == "lifetime"
    assert body["license_id"] == "LIC-2026-0001"
    assert body["activated_at"]
    # The trial half of the snapshot still tells the truth (§7).
    assert body["trial"]["mode"] == "trial"
    assert body["trial"]["trial_active"] is True


def test_system_info_contract_is_unchanged_under_on(
    state_dir: Path, client, license_manager: LicenseManager
):
    license_manager.activate(make_code(hw_hash=hw()))

    resp = client.get("/api/v1/system/info")

    assert resp.status_code == 200
    license_block = resp.json()["license"]
    # /system/info stays the trial-only LicenseInfo it has always been —
    # no lifetime field was added to it in L2-B.
    assert license_block["mode"] == "trial"
    assert license_block["trial_active"] is True
    assert "lifetime" not in license_block
    assert "license_id" not in license_block


def test_repair_surface_stays_reachable_without_any_state(
    state_dir: Path, client
):
    _trial_file(state_dir).unlink(missing_ok=True)

    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/system/info").status_code == 200
    assert client.get("/api/v1/license/status").status_code == 200
    assert client.get("/api/v1/auth/login-users").status_code == 200
