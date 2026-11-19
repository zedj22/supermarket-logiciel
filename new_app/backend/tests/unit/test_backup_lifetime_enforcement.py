"""Phase L2-B — the §4.4 backup matrix under ``LICENSE_ENFORCEMENT=on``.

Same two-layer discipline as Phase L1-D, now fed by the combined
Lifetime/Trial decision (Phase L2-B):

* **API layer** — the router ``license_guard`` refuses the request before
  authentication, before a byte of a multipart body, before any DB work;
* **Service layer** — ``require_backup_action`` opens every public
  ``BackupService`` method with the *same* decision, so a direct service
  call cannot grant what the guard would refuse (or vice versa).

The approved matrix this file pins under ``on``::

    state                                create  list  download  upload  restore  inspect
    ------------------------------------------------------------------------------------
    valid Lifetime license (+ any trial)   ✓      ✓      ✓        ✓       ✓        ✓
    active trial, no license               ✓      ✓      ✓        ✗       ✗        ✓
    expired trial, no license              ✗      ✓      ✓        ✗       ✗        ✗
    no license, no trial                   ✗      ✗      ✗        ✗       ✗        ✗   (403 license_required)
    unverifiable trial, no license         ✗      ✗      ✗        ✗       ✗        ✗   (503 license_status_unavailable)

Plus the L2-B invariants: an invalid license is not a license, it never
demotes the trial row, and a restore taken through the ``lifetime``
grant still never touches ``LICENSE_STATE_DIR`` nor carries licensing
state into an archive.
"""

from __future__ import annotations

import base64
import json
import zipfile
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.exceptions import AppError
from app.db.base import Base
from app.db.session import get_db
from app.licensing import authorization as authorization_module
from app.licensing import trial as trial_module
from app.licensing.activation_code import canonical_json, encode_activation_code
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
    TrialUploadForbiddenError,
)
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.licensing.trial import STATE_NAME, TrialManager
from app.main import app
from app.services.backup import BackupService

UTC = timezone.utc

DUMP_BYTES = b"-- fake pg_dump output\nCREATE TABLE x (id int);\n"

KEY_ID = "k1"

#: The one signing key of this file (ephemeral, generated at import).
_PRIVATE = Ed25519PrivateKey.generate()

#: This Main PC (the machine the licenses in this file bind to).
PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l2b-bk",
    system_volume_serial="SERIAL-BK",
    hostname="main-pc-bk",
)

#: Every backup route of ``api/v1/backups`` and the action it maps to.
_ROUTES = (
    ("GET", "/api/v1/backups", "list"),
    ("POST", "/api/v1/backups", "create"),
    ("GET", "/api/v1/backups/3/download", "download"),
    ("GET", "/api/v1/backups/3/inspect", "inspect"),
    ("POST", "/api/v1/backups/upload", "upload"),
    ("POST", "/api/v1/backups/3/restore", "restore"),
)

#: The six actions, for the fail-closed parametrizations.
_ACTIONS = ("create", "list", "download", "upload", "restore", "inspect")


class FakeRunner:
    """Stands in for ``DumpRunner`` — records instead of shelling out."""

    def __init__(self, content: bytes = DUMP_BYTES):
        self.content = content
        self.dumped: list[str] = []
        self.restored: list[str] = []

    def dump(self, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(self.content)
        self.dumped.append(destination.name)

    def restore(self, source: Path) -> None:
        self.restored.append(source.name)

    def version(self) -> str:
        return "pg_dump (PostgreSQL) 18.6"


# ── fixtures ───────────────────────────────────────────────────────────


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
def session(engine):
    maker = sessionmaker(bind=engine, autoflush=False)
    db = maker()
    yield db
    db.close()


@pytest.fixture()
def backup_dir(tmp_path: Path) -> Path:
    return tmp_path / "backups"


@pytest.fixture()
def runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture()
def state_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point licensing at a throwaway directory (never the real one)."""
    path = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(path))
    return path


@pytest.fixture()
def keys_path(tmp_path: Path) -> Path:
    path = tmp_path / "keys" / "verification_keys.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = _PRIVATE.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    document = {KEY_ID: base64.b64encode(raw).decode("ascii")}
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def make_code(*, hw_hash: str, license_id: str = "LIC-2026-0007") -> str:
    body = {
        "v": 1,
        "key_id": KEY_ID,
        "license_id": license_id,
        "kind": "lifetime",
        "issued_at": "2026-01-01T00:00:00+00:00",
        "hw_hash": hw_hash,
        "features": ["pos"],
    }
    return encode_activation_code(body, _PRIVATE.sign(canonical_json(body)))


def _manager(state_dir: Path, keys_path: Path) -> LicenseManager:
    return LicenseManager(
        state_dir=state_dir,
        keys_path=keys_path,
        fingerprint=HardwareFingerprintService(PROVIDER),
    )


@pytest.fixture()
def on_enforcement(monkeypatch: pytest.MonkeyPatch) -> str:
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    return "on"


@pytest.fixture()
def license_manager(
    state_dir: Path, keys_path: Path, monkeypatch: pytest.MonkeyPatch
) -> LicenseManager:
    monkeypatch.setattr(
        authorization_module,
        "_license_manager",
        lambda: _manager(state_dir, keys_path),
    )
    return _manager(state_dir, keys_path)


@pytest.fixture()
def service(session, backup_dir: Path, runner: FakeRunner) -> BackupService:
    return BackupService(session, runner=runner, directory=backup_dir)


@pytest.fixture()
def client(
    engine, state_dir: Path, on_enforcement: str, license_manager: LicenseManager
):
    """TestClient whose licensing state is this test's throwaway dir."""

    def override_get_db():
        maker = sessionmaker(bind=engine, autoflush=False)
        db = maker()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


# ── helpers ────────────────────────────────────────────────────────────


def _seed_trial(state_dir: Path, *, age: timedelta = timedelta(0)) -> Path:
    """Write ``trial.state`` as if the first start happened `age` ago."""
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    first_start = datetime.now(UTC) - age
    TrialManager(state_dir=state_dir, clock=lambda: first_start).ensure_started()
    return state_dir


def _freeze_trial(
    monkeypatch: pytest.MonkeyPatch, state_dir: Path
) -> datetime:
    """Pin the trial clock *and* seed at that instant.

    ``TrialManager.status()`` may persist an advanced ``max_seen_at``
    (pre-existing §5 T4 behaviour, at most one write per second).  Any
    test that compares ``trial.state`` byte-for-byte across reads freezes
    the clock first and seeds at the same instant, so a mere read can
    never rewrite the file and the comparison is deterministic.
    """
    moment = datetime.now(UTC).replace(microsecond=0)
    monkeypatch.setattr(trial_module, "_utc_now", lambda: moment)
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    TrialManager(state_dir=state_dir, clock=lambda: moment).ensure_started()
    return moment


def _state_files(state_dir: Path) -> dict[str, bytes]:
    return {
        path.name: path.read_bytes()
        for path in sorted(state_dir.glob("*"))
        if path.is_file()
    }


def _error(resp) -> dict:
    assert resp.status_code >= 400, resp.text
    payload = resp.json()
    assert "error" in payload, payload
    return payload["error"]


def _activate(license_manager: LicenseManager) -> None:
    license_manager.activate(
        make_code(hw_hash=HardwareFingerprintService(PROVIDER).fingerprint())
    )


def _invoke(service: BackupService, action: str):
    """One service call per §4.4 action name."""
    if action == "upload":
        return service.upload(content=DUMP_BYTES, filename="dump.sql")
    if action == "restore":
        return service.restore(1, confirm=True)
    if action in ("download", "inspect"):
        return getattr(service, action)(1)
    return getattr(service, action)()


# ── service layer: the lifetime grant (all six) ────────────────────────


def test_lifetime_grants_every_backup_action_at_the_service_layer(
    service, state_dir, on_enforcement, license_manager
):
    _seed_trial(state_dir)  # even with a trial present, lifetime answers
    _activate(license_manager)

    created = service.create()
    assert created.id == 1

    staged = service.upload(content=DUMP_BYTES, filename="dump.sql")
    assert staged.sha256

    listing = service.list()
    assert {entry.id for entry in listing.items} == {created.id, staged.id}

    data, filename = service.download(created.id)
    assert data.startswith(b"PK")
    assert filename.endswith(".zip")

    assert service.inspect(created.id) is not None

    restored = service.restore(created.id, confirm=True)
    assert restored.restored is True
    assert len(service.runner.restored) == 1


def test_expired_trial_cannot_revoke_the_lifetime_grant(
    service, state_dir, on_enforcement, license_manager
):
    _activate(license_manager)
    _seed_trial(state_dir, age=timedelta(days=11))

    created = service.create()
    service.upload(content=DUMP_BYTES, filename="dump.sql")
    assert service.inspect(created.id) is not None
    assert service.restore(created.id, confirm=True).restored is True
    assert [entry.id for entry in service.list().items]


def test_corrupt_trial_cannot_revoke_the_lifetime_grant(
    service, state_dir, on_enforcement, license_manager
):
    _activate(license_manager)
    (state_dir / f"{STATE_NAME}.state").write_bytes(b"garbage, not an envelope")

    created = service.create()
    assert service.restore(created.id, confirm=True).restored is True


def test_lifetime_grants_hold_on_a_trialless_install(
    service, state_dir, on_enforcement, license_manager
):
    """A licensed install is licensed even if no trial was ever started."""
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    _activate(license_manager)

    created = service.create()
    assert service.restore(created.id, confirm=True).restored is True


# ── service layer: trial rows still answer under `on` ──────────────────


@pytest.mark.parametrize("action", ["create", "upload", "restore", "inspect"])
def test_direct_service_calls_under_on_keep_the_expired_trial_refusals(
    action, service, state_dir, on_enforcement, runner
):
    _seed_trial(state_dir, age=timedelta(days=11))

    with pytest.raises(TrialExpiredError):
        _invoke(service, action)

    assert runner.dumped == [] and runner.restored == []


def test_expired_trial_still_lists_and_downloads_under_on(
    service, state_dir, on_enforcement
):
    """D3 data rescue survives the L2-B integration untouched."""
    _seed_trial(state_dir, age=timedelta(days=11))
    service.directory.mkdir(parents=True, exist_ok=True)
    (service.directory / "backup_20261018_143005.sql").write_bytes(DUMP_BYTES)

    listing = service.list()
    assert listing.count == 1
    data, filename = service.download(listing.items[0].id)
    assert data.startswith(b"PK")
    assert filename.endswith(".zip")


@pytest.mark.parametrize(
    ("action", "code"),
    [
        ("upload", "trial_upload_forbidden"),
        ("restore", "trial_restore_forbidden"),
    ],
)
def test_direct_service_calls_under_on_keep_the_active_trial_refusals(
    action, code, service, state_dir, on_enforcement, runner, backup_dir
):
    _seed_trial(state_dir)

    with pytest.raises(AppError) as excinfo:
        _invoke(service, action)

    assert excinfo.value.code == code
    assert runner.dumped == [] and runner.restored == []
    assert not backup_dir.exists() or not any(backup_dir.iterdir())


def test_active_trial_still_grants_create_list_download_inspect_under_on(
    service, state_dir, on_enforcement
):
    _seed_trial(state_dir)

    created = service.create()
    assert [entry.id for entry in service.list().items] == [created.id]
    data, _ = service.download(created.id)
    assert data.startswith(b"PK")
    assert service.inspect(created.id) is not None


# ── service layer: fail-closed rows under `on` ─────────────────────────


@pytest.mark.parametrize("action", _ACTIONS)
def test_missing_license_and_trial_denies_every_backup_action_under_on(
    action, service, state_dir, on_enforcement
):
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)

    with pytest.raises(LicenseRequiredError) as excinfo:
        _invoke(service, action)

    assert excinfo.value.code == "license_required"
    assert excinfo.value.status_code == 403


@pytest.mark.parametrize("action", _ACTIONS)
def test_unverifiable_trial_denies_every_backup_action_under_on(
    action, service, state_dir, on_enforcement
):
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / f"{STATE_NAME}.state").write_bytes(b"garbage, not an envelope")

    with pytest.raises(LicenseStatusUnavailableError) as excinfo:
        _invoke(service, action)

    assert excinfo.value.code == "license_status_unavailable"
    assert excinfo.value.status_code == 503


def test_corrupt_trial_without_license_cannot_use_the_lifetime_grant(
    service, state_dir, on_enforcement, license_manager
):
    """An invalid license is not a license: the corrupt trial still denies."""
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    # license.state exists… corrupted, so it cannot verify.
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "license.state").write_bytes(b"garbage, not a license")

    with pytest.raises(LicenseRequiredError) as excinfo:
        service.create()

    assert excinfo.value.code == "license_required"


# ── service layer: refusals precede all side effects (D6) ──────────────


def test_refused_restore_precedes_safety_dump_and_psql_under_on(
    service, state_dir, on_enforcement, runner
):
    _seed_trial(state_dir, age=timedelta(days=11))
    service.directory.mkdir(parents=True, exist_ok=True)
    (service.directory / "backup_20261018_143005.sql").write_bytes(DUMP_BYTES)
    existing = service.list().items[0]

    with pytest.raises(TrialExpiredError):
        service.restore(existing.id, confirm=True)

    assert runner.dumped == [], "no safety backup was taken"
    assert runner.restored == [], "psql never ran"


def test_refused_upload_persists_nothing_under_on(
    service, state_dir, on_enforcement, backup_dir, monkeypatch
):
    _freeze_trial(monkeypatch, state_dir)
    before = _state_files(state_dir)

    with pytest.raises(TrialUploadForbiddenError) as excinfo:
        service.upload(content=DUMP_BYTES, filename="dump.sql")

    assert excinfo.value.status_code == 403
    assert not backup_dir.exists() or not any(backup_dir.iterdir())
    assert _state_files(state_dir) == before


# ── service layer: the restore/state invariants under `on` + lifetime ──


def test_lifetime_restore_never_touches_the_license_state_directory(
    service, state_dir, on_enforcement, license_manager, monkeypatch
):
    _freeze_trial(monkeypatch, state_dir)
    _activate(license_manager)

    created = service.create()
    # create() may materialise the §8 signing key in the state directory;
    # the invariant under test is that *restore* never rewrites it.
    before_files = _state_files(state_dir)
    before_status = TrialManager(state_dir=state_dir).status()

    restored = service.restore(created.id, confirm=True)

    assert restored.restored is True
    assert _state_files(state_dir) == before_files, "licensing state was rewritten"
    after = TrialManager(state_dir=state_dir).status()
    assert after.install_id == before_status.install_id
    assert after.first_launch_at == before_status.first_launch_at
    assert after.expires_at == before_status.expires_at


def test_lifetime_archives_carry_no_license_state(
    service, state_dir, on_enforcement, license_manager
):
    _seed_trial(state_dir)
    _activate(license_manager)
    install_id = TrialManager(state_dir=state_dir).status().install_id

    created = service.create()
    data, _ = service.download(created.id)
    with zipfile.ZipFile(BytesIO(data)) as archive:
        assert set(archive.namelist()) == {"dump.sql", "manifest.json"}
        blob = b"".join(archive.read(name) for name in archive.namelist())
        carried = json.loads(archive.read("manifest.json"))

    # §8 created_by is the sanctioned provenance: the install id appears
    # exactly once, as manifest metadata — never as license state.
    assert carried["created_by"]["install_id"] == install_id
    assert blob.count(install_id.encode()) == 1
    for marker in (
        b"trial.state",
        b"license.state",
        b"LICENSE_STATE_DIR",
        b"activation",
        b"SMP1.",
    ):
        assert marker.lower() not in blob.lower()


# ── API layer: the matrix through the mounted guard ────────────────────


def test_api_lifetime_matrix_under_on(state_dir, client, license_manager):
    _seed_trial(state_dir, age=timedelta(days=11))  # expired — lifetime wins
    _activate(license_manager)

    # Every route passes the guard: 401 is authentication, not licensing.
    assert client.get("/api/v1/backups").status_code == 401
    assert client.post("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/3/download").status_code == 401
    assert client.get("/api/v1/backups/3/inspect").status_code == 401
    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    )
    assert upload.status_code == 401
    restore = client.post("/api/v1/backups/3/restore", json={"confirm": True})
    assert restore.status_code == 401


def test_api_active_trial_matrix_under_on(state_dir, client):
    _seed_trial(state_dir)

    assert client.get("/api/v1/backups").status_code == 401
    assert client.post("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/3/download").status_code == 401
    assert client.get("/api/v1/backups/3/inspect").status_code == 401

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    )
    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_upload_forbidden"
    assert _error(upload)["message_key"] == "errors.license.trialUploadForbidden"

    restore = client.post("/api/v1/backups/3/restore", json={"confirm": True})
    assert restore.status_code == 403
    assert _error(restore)["code"] == "trial_restore_forbidden"
    assert _error(restore)["message_key"] == "errors.license.trialRestoreForbidden"


def test_api_expired_trial_matrix_under_on(state_dir, client):
    _seed_trial(state_dir, age=timedelta(days=11))

    # D3: listing and downloading existing backups stay reachable.
    assert client.get("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/3/download").status_code == 401

    create = client.post("/api/v1/backups")
    assert create.status_code == 403
    assert _error(create)["code"] == "trial_expired"

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    )
    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_expired"

    restore = client.post("/api/v1/backups/3/restore", json={"confirm": True})
    assert restore.status_code == 403
    assert _error(restore)["code"] == "trial_expired"

    inspect = client.get("/api/v1/backups/3/inspect")
    assert inspect.status_code == 403
    assert _error(inspect)["code"] == "trial_expired"


def test_api_missing_license_and_trial_fails_closed_under_on(state_dir, client):
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)

    for method, path, action in _ROUTES:
        if method == "POST" and action == "upload":
            resp = client.post(
                path,
                files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
            )
        elif method == "POST" and action == "restore":
            resp = client.post(path, json={"confirm": True})
        else:
            resp = getattr(client, method.lower())(path)
        assert resp.status_code == 403, (method, path, resp.text)
        assert _error(resp)["code"] == "license_required", path


def test_api_unverifiable_trial_fails_closed_as_503_under_on(state_dir, client):
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / f"{STATE_NAME}.state").write_bytes(b"garbage, not an envelope")

    create = client.post("/api/v1/backups")
    assert create.status_code == 503
    assert _error(create)["code"] == "license_status_unavailable"
    assert _error(create)["message_key"] == "errors.license.statusUnavailable"


def test_api_refuses_the_upload_before_endpoint_validation_under_on(
    state_dir, client, backup_dir
):
    """Well-formed multipart the endpoint could not accept: still 403.

    The guard runs before the endpoint's own parameters are solved, so a
    body that would fail endpoint validation (wrong part name) answers
    with the licensing refusal — not 422 — and nothing is persisted.
    """
    _seed_trial(state_dir)

    resp = client.post(
        "/api/v1/backups/upload",
        files={"wrong_field": ("dump.sql", DUMP_BYTES, "application/sql")},
    )

    assert resp.status_code == 403
    assert _error(resp)["code"] == "trial_upload_forbidden"
    assert not backup_dir.exists() or not any(backup_dir.iterdir())


def test_a_malformed_multipart_body_fails_fastapi_parsing_before_any_guard(
    state_dir, client, backup_dir
):
    """Empirically pinned body-read order (FastAPI 0.141.x).

    ``get_request_handler`` reads/parses the request body **before**
    solving dependencies — including the router-level license guard —
    so an unparseable multipart body answers FastAPI's own 400
    ("There was an error parsing the body") and no licensing code runs.
    Either way the upload is refused and **nothing is persisted**: the
    endpoint (which would call ``require_backup_action``) never executes,
    and a parse failure writes nothing.  Pre-body rejection would need a
    guard in front of routing (middleware), which is deliberately *not*
    part of the preserved L1 guard architecture.
    """
    _seed_trial(state_dir)

    resp = client.post(
        "/api/v1/backups/upload",
        content=b"<<<this is not multipart at all>>>",
        headers={"content-type": "multipart/form-data; boundary=zzz"},
    )

    assert resp.status_code == 400
    assert "error parsing the body" in resp.text
    assert not backup_dir.exists() or not any(backup_dir.iterdir())
    # And the licensing refusal is what a *readable* body gets:
    assert client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    ).status_code == 403


def test_api_lifetime_grants_survive_an_expired_trial(
    state_dir, client, license_manager
):
    _activate(license_manager)
    _seed_trial(state_dir, age=timedelta(days=11))

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    )
    assert upload.status_code == 401

    restore = client.post("/api/v1/backups/3/restore", json={"confirm": True})
    assert restore.status_code == 401

    inspect = client.get("/api/v1/backups/3/inspect")
    assert inspect.status_code == 401
