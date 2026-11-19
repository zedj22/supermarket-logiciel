"""R4 §6 — end-to-end license activation with a TEST key.

The full customer path, proven over HTTP against the real application:

1. the Main PC asks for an activation request;
2. the owner issues a Lifetime license for that request (signed with a
   **test** key generated into ``tmp_path`` - never a production key);
3. ``POST /api/v1/license/activate`` verifies and persists it;
4. ``GET  /api/v1/license/status`` reports ``lifetime``;
5. a brand-new ``LicenseManager`` and ``TestClient`` - the same state a
   restart would find on disk - still report ``lifetime``;
6. the same code issued for *different* hardware is refused with
   ``license_bound_elsewhere``;
7. a license signed by a key the package does not ship is refused with
   ``license_invalid_key``.

No PostgreSQL is involved: the license routes carry no database
dependency, so this runs everywhere the unit suite runs.
"""

from __future__ import annotations

import base64
import json
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import NamedTuple

import pytest
from fastapi.testclient import TestClient

from app.api.v1 import license as license_api
from app.core.config import settings
from app.core.rate_limit import reset_rate_limiters
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.main import app
from tools.license_generator import cli, generator, keystore

BASE = "/api/v1/license"
KEY_ID = "r4test"
UNSHIPPED_KEY_ID = "r4unshipped"

MAIN = StaticHardwareInfoProvider(
    machine_guid="guid-r4-main",
    system_volume_serial="SERIAL-R4-MAIN",
    hostname="main-pc-r4",
)
OTHER = StaticHardwareInfoProvider(
    machine_guid="guid-r4-other",
    system_volume_serial="SERIAL-R4-OTHER",
    hostname="second-pc-r4",
)


class ActivationEnv(NamedTuple):
    key_dir: Path
    unshipped_key_dir: Path
    keys_path: Path
    state_dir: Path


def error_of(response) -> dict:
    payload = response.json()
    assert set(payload) == {"error"}, payload
    error = payload["error"]
    assert set(error) >= {"code", "message_key", "message", "request_id"}
    return error


def keygen(key_dir: Path, key_id: str) -> None:
    assert cli.main(["keygen", "--key-dir", str(key_dir), "--key-id", key_id]) == 0


@pytest.fixture()
def env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ActivationEnv:
    """A throwaway state dir plus a TEST key, published as the only key."""
    key_dir = tmp_path / "keystore"
    unshipped_key_dir = tmp_path / "keystore_unshipped"
    state_dir = tmp_path / "license"
    state_dir.mkdir(parents=True, exist_ok=True)
    keys_path = tmp_path / "verification_keys.json"

    keygen(key_dir, KEY_ID)
    keygen(unshipped_key_dir, UNSHIPPED_KEY_ID)

    public = keystore.load_keystore(key_dir)[KEY_ID].public
    keys_path.write_text(
        json.dumps({KEY_ID: base64.b64encode(public).decode("ascii")}),
        encoding="utf-8",
    )

    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    monkeypatch.setattr(settings, "LICENSE_VERIFICATION_KEYS_FILE", str(keys_path))
    reset_rate_limiters()
    yield ActivationEnv(key_dir, unshipped_key_dir, keys_path, state_dir)
    reset_rate_limiters()


@contextmanager
def main_pc(env: ActivationEnv) -> Iterator[TestClient]:
    """A client whose manager verifies against the Main PC hardware."""
    manager = LicenseManager(
        keys_path=env.keys_path,
        fingerprint=HardwareFingerprintService(MAIN),
    )
    app.dependency_overrides[license_api.get_license_manager] = lambda: manager
    reset_rate_limiters()
    try:
        with TestClient(app) as client:
            yield client
    finally:
        app.dependency_overrides.clear()
        reset_rate_limiters()


@contextmanager
def other_pc(env: ActivationEnv) -> Iterator[TestClient]:
    """A client bound to *different* hardware, same packaged keys."""
    manager = LicenseManager(
        keys_path=env.keys_path,
        fingerprint=HardwareFingerprintService(OTHER),
    )
    app.dependency_overrides[license_api.get_license_manager] = lambda: manager
    reset_rate_limiters()
    try:
        with TestClient(app) as client:
            yield client
    finally:
        app.dependency_overrides.clear()
        reset_rate_limiters()


def request_code(client: TestClient) -> str:
    response = client.post(f"{BASE}/activation-request")
    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"request_code", "fingerprint_display_code"}
    return body["request_code"]


# ── the happy path ──────────────────────────────────────────────────────────


def test_a_lifetime_license_is_issued_activated_and_reported(
    env: ActivationEnv,
) -> None:
    with main_pc(env) as client:
        code = request_code(client)

    issued = generator.issue_license(code, key_id=KEY_ID, key_dir=env.key_dir)
    assert issued.key_id == KEY_ID
    assert issued.code.startswith("SMP1.")
    # The owner-side ledger lives in the owner's keystore, never in the package.
    assert (env.key_dir / "issuance_log.jsonl").is_file()

    with main_pc(env) as client:
        activated = client.post(
            f"{BASE}/activate", json={"activation_code": issued.code}
        )

        assert activated.status_code == 200, activated.text
        body = activated.json()
        assert body["mode"] == "lifetime"
        assert body["license_type"] == "lifetime"
        assert body["license_id"] == issued.license_id
        assert body["trial"]["mode"] == "trial"

        status = client.get(f"{BASE}/status")
        assert status.status_code == 200
        assert status.json()["mode"] == "lifetime"
        assert status.json()["license_id"] == issued.license_id


def test_activation_survives_a_restart_of_the_backend(env: ActivationEnv) -> None:
    with main_pc(env) as client:
        code = request_code(client)
        issued = generator.issue_license(code, key_id=KEY_ID, key_dir=env.key_dir)
        assert (
            client.post(
                f"{BASE}/activate", json={"activation_code": issued.code}
            ).status_code
            == 200
        )

    # A brand-new manager + client reads only what is on disk - exactly what
    # a process restart would find.
    with main_pc(env) as client:
        body = client.get(f"{BASE}/status").json()

    assert body["mode"] == "lifetime"
    assert body["license_id"] == issued.license_id
    assert body["activated_at"] is not None


def test_re_activating_the_same_code_is_a_idempotent_no_op(
    env: ActivationEnv,
) -> None:
    with main_pc(env) as client:
        code = request_code(client)
        issued = generator.issue_license(code, key_id=KEY_ID, key_dir=env.key_dir)
        first = client.post(
            f"{BASE}/activate", json={"activation_code": issued.code}
        )
        assert first.status_code == 200
        activated_at = first.json()["activated_at"]

        again = client.post(
            f"{BASE}/activate", json={"activation_code": issued.code}
        )

        assert again.status_code == 200
        assert again.json()["license_id"] == issued.license_id
        assert again.json()["activated_at"] == activated_at


# ── the refusals ────────────────────────────────────────────────────────────


def test_a_code_issued_for_another_machine_is_refused(env: ActivationEnv) -> None:
    with other_pc(env) as client:
        foreign = request_code(client)
    foreign_license = generator.issue_license(
        foreign, key_id=KEY_ID, key_dir=env.key_dir
    )

    with main_pc(env) as client:
        response = client.post(
            f"{BASE}/activate", json={"activation_code": foreign_license.code}
        )

        assert response.status_code == 403
        assert error_of(response)["code"] == "license_bound_elsewhere"
        # Nothing was written: the installation is still trial-only.
        assert client.get(f"{BASE}/status").json()["mode"] in {"trial", "trial_expired"}


def test_a_key_the_package_does_not_ship_is_refused(env: ActivationEnv) -> None:
    with main_pc(env) as client:
        code = request_code(client)

    # Signed by a key that exists in the owner's keystore but was never
    # published into the customer's verification_keys.json.
    unshipped = generator.issue_license(
        code, key_id=UNSHIPPED_KEY_ID, key_dir=env.unshipped_key_dir
    )
    assert unshipped.key_id == UNSHIPPED_KEY_ID

    with main_pc(env) as client:
        response = client.post(
            f"{BASE}/activate", json={"activation_code": unshipped.code}
        )

        assert response.status_code == 403
        assert error_of(response)["code"] == "license_invalid_key"
        assert client.get(f"{BASE}/status").json()["mode"] in {"trial", "trial_expired"}


def test_a_malformed_code_never_installs_anything(env: ActivationEnv) -> None:
    with main_pc(env) as client:
        for code in ("SMP1.ABC.DEF", "SMPr1.ABC.DEF", "not-a-code"):
            response = client.post(
                f"{BASE}/activate", json={"activation_code": code}
            )
            assert response.status_code == 403, code
            assert error_of(response)["code"] == "license_invalid"

        assert client.get(f"{BASE}/status").json()["license_id"] is None
        manager = LicenseManager(
            keys_path=env.keys_path,
            fingerprint=HardwareFingerprintService(MAIN),
        )
        assert manager.status() is None


# ── the request itself ──────────────────────────────────────────────────────


def test_the_activation_request_carries_no_hardware_identifiers(
    env: ActivationEnv,
) -> None:
    with main_pc(env) as client:
        response = client.post(f"{BASE}/activation-request")

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"request_code", "fingerprint_display_code"}
    assert body["request_code"].startswith("SMPr1.")
    text = response.text
    for identifier in (
        MAIN.machine_guid,
        MAIN.system_volume_serial,
        MAIN.hostname,
    ):
        assert identifier not in text


def test_the_shipped_key_file_is_untouched_by_activation(
    env: ActivationEnv,
) -> None:
    before = env.keys_path.read_text(encoding="utf-8")

    with main_pc(env) as client:
        code = request_code(client)
        issued = generator.issue_license(code, key_id=KEY_ID, key_dir=env.key_dir)
        client.post(f"{BASE}/activate", json={"activation_code": issued.code})

    assert env.keys_path.read_text(encoding="utf-8") == before
    # Only public material is in the package key file.
    assert '"private"' not in before
