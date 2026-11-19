"""Phase L1-D — backup restrictions at *both* enforcement layers.

The §4.4 matrix (``docs/LICENSING_SYSTEM_ARCHITECTURE_AUDIT_v2.md``) has
to hold for a request **and** for a direct call into ``BackupService``,
because a service that trusts its caller is not a second line of defence:

* **API layer** — the router ``license_guard`` refuses the request before
  authentication; the write routes repeat the same decision before they
  read a body or touch the database.
* **Service layer** — ``require_backup_action`` opens every public
  ``BackupService`` method, reading the server's own ``trial.state``.
  Nothing here is taken from the client: no Flutter status, no header,
  no request field.

Guarantees pinned here:

* active trial → create / list / download allowed, upload / restore
  refused (``trial_upload_forbidden`` / ``trial_restore_forbidden``);
* expired trial → list / download allowed (D3 data rescue), create /
  upload / restore / inspect refused (``trial_expired``);
* ``LICENSE_ENFORCEMENT=off`` stays a complete no-op (L0 exit criterion);
* missing state → ``license_required``, unverifiable state → 503
  ``license_status_unavailable``, enforcement ``on`` → fail closed;
* a refused restore is decided **before** the safety snapshot and before
  ``psql`` runs; a refused upload is decided **before** any byte is
  validated or written;
* Backup v1 archives keep their exact manifest/membership, carry no
  licensing state, and restore on another install whose trial state
  (install id) differs — no fingerprint comparison anywhere;
* a restore never rewrites ``trial.state`` or the licence directory.
"""

from __future__ import annotations

import json
import zipfile
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.exceptions import AppError
from app.db.base import Base
from app.db.session import get_db
from app.licensing.backup_policy import (
    BACKUP_ACTIONS,
    LICENSE_BACKUP_GRANTS,
    backup_action_allowed,
    classify_backup_action,
)
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
    TrialRestoreForbiddenError,
    TrialUploadForbiddenError,
)
from app.licensing.trial import STATE_NAME, TrialManager
from app.main import app
from app.services import backup as backup_service
from app.services.backup import BackupService

UTC = timezone.utc

DUMP_BYTES = b"-- fake pg_dump output\nCREATE TABLE x (id int);\n"

#: Every backup route of ``api/v1/backups`` and the action it maps to.
_ROUTES = (
    ("GET", "/api/v1/backups", "list"),
    ("POST", "/api/v1/backups", "create"),
    ("GET", "/api/v1/backups/3/download", "download"),
    ("GET", "/api/v1/backups/3/inspect", "inspect"),
    ("POST", "/api/v1/backups/upload", "upload"),
    ("POST", "/api/v1/backups/3/restore", "restore"),
)

#: The approved §4.4 matrix — the contract this whole file pins.
_EXPECTED_MATRIX: dict[str, dict[str, bool]] = {
    "trial": {
        "create": True,
        "list": True,
        "download": True,
        "upload": False,
        "restore": False,
        "inspect": True,
    },
    "trial_expired": {
        "create": False,
        "list": True,
        "download": True,
        "upload": False,
        "restore": False,
        "inspect": False,
    },
    "lifetime": {
        "create": True,
        "list": True,
        "download": True,
        "upload": True,
        "restore": True,
        "inspect": True,
    },
}


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
def trial_enforcement(monkeypatch: pytest.MonkeyPatch) -> str:
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    return "trial"


@pytest.fixture()
def service(session, backup_dir: Path, runner: FakeRunner) -> BackupService:
    return BackupService(session, runner=runner, directory=backup_dir)


@pytest.fixture()
def client(engine, state_dir: Path, trial_enforcement: str):
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


def _error(resp) -> dict:
    assert resp.status_code >= 400, resp.text
    return resp.json()["error"]


def _state_files(state_dir: Path) -> dict[str, bytes]:
    return {
        path.name: path.read_bytes()
        for path in sorted(state_dir.glob("*"))
        if path.is_file()
    }


# ── the matrix itself ──────────────────────────────────────────────────


def test_matrix_matches_the_approved_backup_policy():
    """The table the guard and the service both read is the approved one."""
    assert set(LICENSE_BACKUP_GRANTS) == set(_EXPECTED_MATRIX)
    for mode, actions in _EXPECTED_MATRIX.items():
        assert set(actions) == set(BACKUP_ACTIONS)
        for action in BACKUP_ACTIONS:
            assert backup_action_allowed(action, mode=mode) is actions[action], (
                mode,
                action,
            )


def test_an_unknown_license_mode_grants_nothing():
    """L2 must *add* a mode; nothing unknown may read as licensed."""
    for action in BACKUP_ACTIONS:
        assert backup_action_allowed(action, mode="on") is False
        assert backup_action_allowed(action, mode="") is False
        assert backup_action_allowed(action, mode="trial_plus") is False


def test_lifetime_is_already_a_full_access_row():
    """Phase L2 only has to produce ``lifetime`` — no redesign needed."""
    assert LICENSE_BACKUP_GRANTS["lifetime"] == BACKUP_ACTIONS


@pytest.mark.parametrize(("method", "path", "action"), _ROUTES)
def test_every_backup_route_is_classified(method: str, path: str, action: str):
    assert classify_backup_action(method, path) == action


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/api/v1/products"),
        ("POST", "/api/v1/products"),
        ("DELETE", "/api/v1/backups"),
        ("PUT", "/api/v1/backups"),
        ("GET", "/api/v1/backups/3"),
        ("PATCH", "/api/v1/backups/upload"),
        ("GET", "/api/v1/backups/upload"),
        ("POST", "/api/v1/backups/3/download"),
        ("GET", "/api/v1/backups/3/restore"),
        ("GET", "/api/v1/backup"),
    ],
)
def test_non_backup_requests_are_not_classified(method: str, path: str):
    assert classify_backup_action(method, path) is None


# ── active trial — service level ───────────────────────────────────────


def test_active_trial_allows_backup_creation(service, state_dir, trial_enforcement):
    _seed_trial(state_dir)

    info = service.create()

    assert info.id == 1
    assert (service.directory / info.filename).is_file()
    assert service.runner.dumped == [info.filename]


def test_active_trial_allows_list_and_download(service, state_dir, trial_enforcement):
    _seed_trial(state_dir)
    created = service.create()

    listing = service.list()
    assert [entry.id for entry in listing.items] == [created.id]

    data, filename = service.download(created.id)
    assert data.startswith(b"PK")
    assert filename.endswith(".zip")


def test_active_trial_rejects_upload_before_any_bytes_are_persisted(
    service, state_dir, trial_enforcement, backup_dir
):
    """D6: the refusal precedes validation *and* every write."""
    _seed_trial(state_dir)
    before = _state_files(state_dir)

    with pytest.raises(TrialUploadForbiddenError) as excinfo:
        service.upload(content=DUMP_BYTES, filename="dump.sql")

    assert excinfo.value.code == "trial_upload_forbidden"
    assert excinfo.value.status_code == 403
    assert not backup_dir.exists() or not any(backup_dir.iterdir())
    assert _state_files(state_dir) == before


def test_active_trial_rejects_restore_before_any_destructive_work(
    service, state_dir, trial_enforcement, runner
):
    """§8: refused before the confirm gate, the safety dump or psql."""
    _seed_trial(state_dir)
    created = service.create()
    dumped_before = list(runner.dumped)
    restored_before = list(runner.restored)

    with pytest.raises(TrialRestoreForbiddenError) as excinfo:
        service.restore(created.id, confirm=True)

    assert excinfo.value.code == "trial_restore_forbidden"
    assert excinfo.value.status_code == 403
    assert runner.dumped == dumped_before, "no safety backup was taken"
    assert runner.restored == restored_before, "psql never ran"


# ── expired trial — service level (D3 data rescue) ─────────────────────


def test_expired_trial_still_lists_and_downloads(
    service, state_dir, trial_enforcement
):
    """D3: existing backups stay reachable so the data can be rescued."""
    _seed_trial(state_dir, age=timedelta(days=11))
    # A backup that already exists on disk (taken while the trial ran).
    service.directory.mkdir(parents=True, exist_ok=True)
    (service.directory / "backup_20261018_143005.sql").write_bytes(DUMP_BYTES)

    listing = service.list()
    assert listing.count == 1

    data, filename = service.download(listing.items[0].id)
    assert data.startswith(b"PK")
    assert filename.endswith(".zip")


def test_expired_trial_rejects_backup_creation(
    service, state_dir, trial_enforcement, backup_dir
):
    _seed_trial(state_dir, age=timedelta(days=11))

    with pytest.raises(TrialExpiredError) as excinfo:
        service.create()

    assert excinfo.value.code == "trial_expired"
    assert excinfo.value.status_code == 403
    assert not backup_dir.exists() or not any(backup_dir.iterdir())


def test_expired_trial_rejects_upload(
    service, state_dir, trial_enforcement, backup_dir
):
    _seed_trial(state_dir, age=timedelta(days=11))

    with pytest.raises(TrialExpiredError) as excinfo:
        service.upload(content=DUMP_BYTES, filename="dump.sql")

    assert excinfo.value.code == "trial_expired"
    assert not backup_dir.exists() or not any(backup_dir.iterdir())


def test_expired_trial_rejects_restore_before_any_destructive_work(
    service, state_dir, trial_enforcement, runner
):
    _seed_trial(state_dir, age=timedelta(days=11))
    # An existing backup, listed by the rescue path above.
    service.directory.mkdir(parents=True, exist_ok=True)
    (service.directory / "backup_20261018_143005.sql").write_bytes(DUMP_BYTES)
    existing = service.list().items[0]

    with pytest.raises(TrialExpiredError) as excinfo:
        service.restore(existing.id, confirm=True)

    assert excinfo.value.code == "trial_expired"
    assert runner.dumped == [], "no safety backup was taken"
    assert runner.restored == [], "psql never ran"


def test_expired_trial_rejects_inspect(service, state_dir, trial_enforcement):
    _seed_trial(state_dir, age=timedelta(days=11))
    service.directory.mkdir(parents=True, exist_ok=True)
    (service.directory / "backup_20261018_143005.sql").write_bytes(DUMP_BYTES)
    existing = service.list().items[0]

    with pytest.raises(TrialExpiredError):
        service.inspect(existing.id)


# ── direct service calls can never bypass the guard ────────────────────


@pytest.mark.parametrize(
    "call",
    [
        lambda svc: svc.create(),
        lambda svc: svc.upload(content=DUMP_BYTES, filename="dump.sql"),
        lambda svc: svc.restore(1, confirm=True),
        lambda svc: svc.inspect(1),
    ],
    ids=["create", "upload", "restore", "inspect"],
)
def test_direct_service_calls_cannot_bypass_an_expired_trial(
    call, service, state_dir, trial_enforcement, runner
):
    _seed_trial(state_dir, age=timedelta(days=11))

    with pytest.raises(AppError) as excinfo:
        call(service)

    assert excinfo.value.code == "trial_expired"
    assert runner.dumped == [] and runner.restored == []


@pytest.mark.parametrize(
    "call",
    [
        lambda svc: svc.upload(content=DUMP_BYTES, filename="dump.sql"),
        lambda svc: svc.restore(1, confirm=True),
    ],
    ids=["upload", "restore"],
)
def test_direct_service_calls_cannot_bypass_an_active_trial(
    call, service, state_dir, trial_enforcement, runner, backup_dir
):
    _seed_trial(state_dir)

    with pytest.raises(AppError) as excinfo:
        call(service)

    assert excinfo.value.code in (
        "trial_upload_forbidden",
        "trial_restore_forbidden",
    )
    assert runner.dumped == [] and runner.restored == []
    assert not backup_dir.exists() or not any(backup_dir.iterdir())


# ── enforcement modes ──────────────────────────────────────────────────


def test_enforcement_off_is_a_complete_noop(service, state_dir, monkeypatch):
    """L0 exit criterion: with licensing off nothing is decided at all."""
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "off")
    _seed_trial(state_dir, age=timedelta(days=11))  # expired on disk

    created = service.create()
    service.upload(content=DUMP_BYTES, filename="dump.sql")
    assert service.restore(created.id, confirm=True).restored is True
    assert service.list().count >= 1


def test_missing_trial_state_is_license_required(
    service, state_dir, trial_enforcement
):
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)

    with pytest.raises(LicenseRequiredError) as excinfo:
        service.create()

    assert excinfo.value.code == "license_required"
    assert excinfo.value.status_code == 403


def test_unverifiable_trial_state_fails_closed(
    service, state_dir, trial_enforcement
):
    _seed_trial(state_dir)
    (state_dir / f"{STATE_NAME}.state").write_bytes(b"garbage, not an envelope")

    with pytest.raises(LicenseStatusUnavailableError) as excinfo:
        service.create()

    assert excinfo.value.code == "license_status_unavailable"
    assert excinfo.value.status_code == 503


def test_enforcement_on_admits_an_active_trial(
    service, state_dir, monkeypatch
):
    """Phase L2-B: `on` admits *either* a license *or* an active trial.

    The Trial half of the combined decision — the Lifetime half is
    pinned in ``test_backup_lifetime_enforcement.py``.
    """
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    _seed_trial(state_dir)

    created = service.create()
    assert created.id == 1
    assert service.runner.dumped == [created.filename]


def test_enforcement_on_refuses_an_install_with_no_license_and_no_trial(
    service, state_dir, monkeypatch
):
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)

    with pytest.raises(LicenseRequiredError) as excinfo:
        service.create()

    assert excinfo.value.code == "license_required"
    assert excinfo.value.status_code == 403


def test_licensing_errors_never_leak_state_paths(
    service, state_dir, trial_enforcement
):
    _seed_trial(state_dir, age=timedelta(days=11))

    with pytest.raises(AppError) as excinfo:
        service.create()

    text = f"{excinfo.value.message} {excinfo.value.details}"
    assert str(state_dir) not in text
    assert "hmac" not in text.lower()


# ── API level ──────────────────────────────────────────────────────────


def test_api_active_trial_matrix(client, state_dir):
    _seed_trial(state_dir)

    # Allowed by the guard → the request reaches authentication (401).
    assert client.get("/api/v1/backups").status_code == 401
    assert client.post("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/1/download").status_code == 401
    assert client.get("/api/v1/backups/1/inspect").status_code == 401

    # Refused by the guard with the contract codes.
    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    )
    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_upload_forbidden"
    assert _error(upload)["message_key"] == "errors.license.trialUploadForbidden"

    restore = client.post("/api/v1/backups/1/restore", json={"confirm": True})
    assert restore.status_code == 403
    assert _error(restore)["code"] == "trial_restore_forbidden"
    assert _error(restore)["message_key"] == "errors.license.trialRestoreForbidden"


def test_api_expired_trial_matrix(client, state_dir):
    _seed_trial(state_dir, age=timedelta(days=11))

    # D3: listing and downloading existing backups stay reachable.
    assert client.get("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/1/download").status_code == 401

    # Everything that writes is refused with `trial_expired`.
    create = client.post("/api/v1/backups")
    assert create.status_code == 403
    assert _error(create)["code"] == "trial_expired"

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", DUMP_BYTES, "application/sql")},
    )
    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_expired"

    restore = client.post("/api/v1/backups/1/restore", json={"confirm": True})
    assert restore.status_code == 403
    assert _error(restore)["code"] == "trial_expired"

    inspect = client.get("/api/v1/backups/1/inspect")
    assert inspect.status_code == 403
    assert _error(inspect)["code"] == "trial_expired"


def test_api_refusal_happens_before_the_body_is_consumed(client, state_dir):
    """The guard answers from the URL alone — no upload is parsed."""
    _seed_trial(state_dir)

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", b"\x00" * 4096, "application/zip")},
    )

    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_upload_forbidden"
    assert str(state_dir) not in upload.text


# ── Backup v1 compatibility + cross-PC independence ────────────────────

#: The exact manifest keys Backup v1 wrote (Phase 17 §17.2 / Objective 2).
_V1_MANIFEST_KEYS = {
    "id",
    "filename",
    "size",
    "created_at",
    "sha256",
    "schema_revision",
    "pg_dump_version",
    "app_version",
    "database",
}


def test_backup_v1_manifest_and_archive_are_unchanged(
    service, state_dir, trial_enforcement
):
    """Phase L3 (§8): v2 is strictly additive over Backup v1.

    Every v1 key survives byte-for-byte, only the six v2 fields appear,
    and the archive membership (``dump.sql`` + ``manifest.json``) is
    untouched — old builds keep reading the document.
    """
    _seed_trial(state_dir)
    created = service.create()

    manifest_path = service.directory / f"{created.filename[:-4]}.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert _V1_MANIFEST_KEYS <= set(manifest)
    assert set(manifest) - _V1_MANIFEST_KEYS == {
        "format_version",
        "payload_sha256",
        "created_by",
        "signature",
        "key_id",
        "public_key",
    }
    assert manifest["format_version"] == 2
    assert manifest["payload_sha256"] == manifest["sha256"]

    data, _ = service.download(created.id)
    with zipfile.ZipFile(BytesIO(data)) as archive:
        assert set(archive.namelist()) == {"dump.sql", "manifest.json"}
        carried = json.loads(archive.read("manifest.json"))
    assert carried == manifest, "the ZIP carries the sidecar verbatim"


def test_no_license_state_ever_enters_an_archive(
    service, state_dir, trial_enforcement
):
    _seed_trial(state_dir)
    created = service.create()
    install_id = TrialManager(state_dir=state_dir).status().install_id

    data, _ = service.download(created.id)
    with zipfile.ZipFile(BytesIO(data)) as archive:
        blob = b"".join(archive.read(name) for name in archive.namelist())
        carried = json.loads(archive.read("manifest.json"))

    # §8 created_by is the ONE sanctioned provenance field: the install
    # id rides exactly once, as manifest metadata — never as license
    # state, a state filename or an activation artefact.
    assert carried["created_by"]["install_id"] == install_id
    assert blob.count(install_id.encode()) == 1
    for marker in (b"trial.state", b"LICENSE_STATE_DIR", b"activation"):
        assert marker.lower() not in blob.lower()


def test_backup_is_independent_of_the_install_that_created_it(
    session, state_dir, trial_enforcement, tmp_path, monkeypatch
):
    """Cross-PC: PC1's trial backup restores on PC2 with its own state.

    No fingerprint, install id or licence is compared — the archive is
    portable by construction (§7.5 / approved restore policy).
    """
    # --- PC1: backup taken during its own active trial -------------------
    _seed_trial(state_dir, age=timedelta(days=2))
    pc1_id = TrialManager(state_dir=state_dir).status().install_id
    pc1_dir = tmp_path / "pc1" / "backups"
    pc1 = BackupService(session, runner=FakeRunner(), directory=pc1_dir)
    created = pc1.create()
    archive_bytes, _ = pc1.download(created.id)

    # --- the archive travels (download → copy → restore elsewhere) -------
    pc2_state = tmp_path / "pc2" / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(pc2_state))
    _seed_trial(pc2_state, age=timedelta(days=1))
    pc2_id = TrialManager(state_dir=pc2_state).status().install_id
    assert pc2_id != pc1_id, "the two installs must have their own state"

    pc2_dir = tmp_path / "pc2" / "backups"
    pc2_runner = FakeRunner()
    pc2 = BackupService(session, runner=pc2_runner, directory=pc2_dir)

    # Enforcement is off here: this is the post-Lifetime state L2 will
    # produce (upload + restore are granted by the `lifetime` row), and
    # nothing in the service may refuse the transfer on identity grounds.
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "off")

    # PC2 accepts the portable archive through the supported path.
    staged = pc2.upload(content=archive_bytes, filename="portability.zip")
    assert staged.sha256 == created.sha256, "same dump, re-hashed on PC2"

    listing = pc2.list()
    assert [entry.filename for entry in listing.items] == [staged.filename]

    data, _ = pc2.download(listing.items[0].id)
    assert data.startswith(b"PK")

    restored = pc2.restore(listing.items[0].id, confirm=True)
    assert restored.restored is True
    assert pc2_runner.restored == [staged.filename]

    # PC2's own licensing state is untouched by any of it.
    assert TrialManager(state_dir=pc2_state).status().install_id == pc2_id


def test_restore_never_touches_the_license_state_directory(
    service, state_dir, trial_enforcement, monkeypatch
):
    """A restored database must not overwrite or reset licensing state."""
    _seed_trial(state_dir)
    before_status = TrialManager(state_dir=state_dir).status()

    # The licence directory is a plain directory, never the catalogue.
    assert state_dir != service.directory
    assert state_dir.name == "license"

    created = service.create()
    # create() may materialise the §8 signing key in the state directory;
    # the invariant under test is that *restore* never rewrites it.
    before_files = _state_files(state_dir)

    # During the trial the restore itself is refused (proved above) …
    with pytest.raises(TrialRestoreForbiddenError):
        service.restore(created.id, confirm=True)
    assert _state_files(state_dir) == before_files

    # … and once licensing grants it (Phase L2 `lifetime`, modelled here
    # by enforcement off) the restore still leaves licensing state alone.
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "off")
    restored = service.restore(created.id, confirm=True)

    assert restored.restored is True
    assert _state_files(state_dir) == before_files, "trial.state was rewritten"

    after = TrialManager(state_dir=state_dir).status()
    assert after.install_id == before_status.install_id
    assert after.first_launch_at == before_status.first_launch_at
    assert after.expires_at == before_status.expires_at
    assert after.mode == before_status.mode


def test_the_backup_service_source_binds_no_hardware_identity():
    """No fingerprint / install id is read while backing up or restoring."""
    source = Path(backup_service.__file__).read_text(encoding="utf-8")
    for token in (
        "LICENSE_STATE_DIR",
        "StateStore",
        "TrialManager",
        "STATE_NAME",
        "install_id",
        "HardwareFingerprintService",
    ):
        assert token not in source, token
