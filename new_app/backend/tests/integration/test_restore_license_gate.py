"""Phase L3 (audit §8 / §12) — restore gates proven on real PostgreSQL.

Skipped when PostgreSQL client tools or the test database are missing, so
the suite still runs on a machine without them — the *behaviour* of every
gate is covered by the unit suites with an injected fake runner.  What
only a real run can prove lives here:

* **the cross-PC scenario of §8**: PC1 takes a backup during its own
  trial, its trial expires (download-only, D3), and PC2 — trialless,
  holding a Lifetime licence, running ``LICENSE_ENFORCEMENT=on`` —
  uploads that archive and restores it for real; PC2's licence survives
  untouched and PC1's trial/licence is never imported;
* a legacy **v1 sidecar** (no ``format_version``, unsigned) still
  restores with the real ``pg_dump``/``psql`` pair;
* a **trial restore is refused before psql runs** — the live probe row
  proves nothing was replayed;
* an **unsupported manifest version** and a **broken v2 signature** are
  refused before any destructive work, again proven against the live
  database;
* an **unparseable sidecar** falls through to the pre-existing Phase 17
  adoption path, which rewrites only the ``.json`` index — never the
  dump.

Never touches ``supermarket_pro`` — only ``supermarket_pro_test``.
"""

from __future__ import annotations

import base64
import io
import json
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.core.config import settings
from app.core.db_dump import DbParams, DumpRunner, find_pg_tool
from app.core.exceptions import ValidationError
from app.licensing import authorization as authorization_module
from app.licensing.activation_code import canonical_json, encode_activation_code
from app.licensing.errors import TrialExpiredError, TrialRestoreForbiddenError
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.licensing.trial import STATE_NAME, TrialManager
from app.services.backup import BackupService
from app.services.backup_manifest import SIGNATURE_INVALID, UNSUPPORTED
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

PROBE_TABLE = "l3_restore_gate_probe"

HAVE_TOOLS = bool(find_pg_tool("pg_dump")) and bool(find_pg_tool("psql"))

pytestmark = [
    pytest.mark.skipif(
        not PG_IS_AVAILABLE,
        reason="PostgreSQL test database (supermarket_pro_test) not available",
    ),
    pytest.mark.skipif(
        not HAVE_TOOLS,
        reason="pg_dump / psql client tools not found",
    ),
]

UTC = timezone.utc

KEY_ID = "k1"

#: The one signing key of this file (ephemeral, generated at import).
_PRIVATE = Ed25519PrivateKey.generate()

#: The Main PC the licences in this file bind to.
PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l3-gate",
    system_volume_serial="SERIAL-L3",
    hostname="main-pc-l3",
)


# ── fixtures ───────────────────────────────────────────────────────────


@pytest.fixture()
def params() -> DbParams:
    return DbParams.from_url(PG_TEST_URL)


@pytest.fixture()
def runner(params: DbParams) -> DumpRunner:
    return DumpRunner(params, timeout=120)


@pytest.fixture()
def pg_session():
    engine = create_engine(PG_TEST_URL)
    maker = sessionmaker(bind=engine, autoflush=False)
    session = maker()
    try:
        yield session
    finally:
        session.close()
        engine.dispose()


@pytest.fixture()
def backup_dir(tmp_path: Path) -> Path:
    return tmp_path / "backups"


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
    path.write_text(json.dumps({KEY_ID: _b64(raw)}), encoding="utf-8")
    return path


@pytest.fixture()
def service(
    pg_session, runner, backup_dir, state_dir
) -> BackupService:
    return BackupService(pg_session, runner=runner, directory=backup_dir)


@pytest.fixture()
def probe():
    """A table that exists in the dump, so we can prove what was restored."""
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    conn.autocommit = False
    with conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {PROBE_TABLE}")
        cur.execute(f"CREATE TABLE {PROBE_TABLE} (v text)")
        cur.execute(f"INSERT INTO {PROBE_TABLE} VALUES ('original')")
    conn.commit()
    try:
        yield
    finally:
        with conn.cursor() as cur:
            cur.execute(f"DROP TABLE IF EXISTS {PROBE_TABLE}")
        conn.commit()
        conn.close()


# ── helpers ────────────────────────────────────────────────────────────


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def make_code(*, hw_hash: str, license_id: str = "LIC-2026-0301") -> str:
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


def _activate(license_manager: LicenseManager) -> None:
    license_manager.activate(
        make_code(hw_hash=HardwareFingerprintService(PROVIDER).fingerprint())
    )


def _seed_trial(state_dir: Path, *, age: timedelta = timedelta(0)) -> Path:
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    first_start = datetime.now(UTC) - age
    TrialManager(state_dir=state_dir, clock=lambda: first_start).ensure_started()
    return state_dir


def _read_probe() -> list[str]:
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT v FROM {PROBE_TABLE} ORDER BY v")
            return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()


def _write_probe(values: list[str]) -> None:
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    conn.autocommit = False
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM {PROBE_TABLE}")
        for value in values:
            cur.execute(
                f"INSERT INTO {PROBE_TABLE} (v) VALUES (%s)", (value,)
            )
    conn.commit()
    conn.close()


def _sidecar_path(service: BackupService, filename: str) -> Path:
    return service.directory / f"{filename[:-4]}.json"


def _load_sidecar(service: BackupService, filename: str) -> dict:
    return json.loads(_sidecar_path(service, filename).read_text("utf-8"))


def _save_sidecar(service: BackupService, filename: str, doc: dict) -> None:
    _sidecar_path(service, filename).write_text(
        json.dumps(doc), encoding="utf-8"
    )


# ── §8 cross-PC: trial backup → expired PC1 → lifetime PC2 restores ────


def test_cross_pc_trial_backup_restores_on_a_lifetime_pc(
    probe, pg_session, runner, state_dir, keys_path, tmp_path, monkeypatch
):
    # --- PC1: backup taken during its own active trial -------------------
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    _seed_trial(state_dir, age=timedelta(days=2))
    pc1_install_id = TrialManager(state_dir=state_dir).status().install_id
    pc1_service = BackupService(
        pg_session, runner=runner, directory=tmp_path / "pc1" / "backups"
    )

    original = pc1_service.create()
    archive_bytes, archive_name = pc1_service.download(original.id)
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as zipped:
        carried = json.loads(zipped.read("manifest.json"))
    assert carried["created_by"]["install_id"] == pc1_install_id
    assert carried["format_version"] == 2

    _write_probe(["pc1-doomed"])

    # PC1's trial expires after the archive was taken: D3 keeps the
    # download open for rescue, but a restore is refused — and with the
    # real runner installed, "refused" must mean psql never ran.
    _seed_trial(state_dir, age=timedelta(days=11))
    with pytest.raises(TrialExpiredError):
        pc1_service.restore(original.id, confirm=True)
    pc1_service.download(original.id)  # the rescue copy stays reachable
    assert _read_probe() == ["pc1-doomed"], "nothing was replayed"

    # --- PC2: trialless Main PC, Lifetime licence, enforcement `on` ------
    pc2_state = tmp_path / "pc2" / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(pc2_state))
    monkeypatch.setattr(
        authorization_module,
        "_license_manager",
        lambda: _manager(pc2_state, keys_path),
    )
    pc2_manager = _manager(pc2_state, keys_path)
    _activate(pc2_manager)
    license_before = (pc2_state / "license.state").read_bytes()
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")

    pc2_service = BackupService(
        pg_session, runner=runner, directory=tmp_path / "pc2" / "backups"
    )

    # The archive travels: upload stages it (signature verified against
    # these exact bytes), restore replays it for real.
    staged = pc2_service.upload(content=archive_bytes, filename=archive_name)
    result = pc2_service.restore(staged.id, confirm=True)
    assert result.restored is True
    assert result.post_restore_ok is True
    assert _read_probe() == ["original"]

    # PC2's licence survived byte-for-byte; PC1's trial/licence was never
    # imported: PC2 stays trialless and holds no PC1 identity anywhere in
    # its licensing state.
    assert (pc2_state / "license.state").read_bytes() == license_before
    assert pc2_manager.status() is not None
    assert not (pc2_state / f"{STATE_NAME}.state").exists()
    for state_file in pc2_state.glob("*"):
        assert pc1_install_id.encode() not in state_file.read_bytes()

    # The staged copy on PC2 is PC2's own signed v2 manifest, with no
    # trial provenance (PC2 is trialless) — but the same dump bytes that
    # left PC1 (ids are per-directory, so they may well coincide).
    staged_sidecar = _load_sidecar(pc2_service, staged.filename)
    assert staged_sidecar["format_version"] == 2
    assert staged_sidecar["created_by"]["install_id"] is None
    assert staged_sidecar["sha256"] == carried["sha256"]


# ── legacy v1 compatibility with the real runner ───────────────────────


def test_legacy_v1_sidecar_still_restores_on_real_pg(
    probe, service, state_dir
):
    created = service.create()
    sidecar = _load_sidecar(service, created.filename)
    for field in (
        "format_version",
        "payload_sha256",
        "created_by",
        "signature",
        "key_id",
        "public_key",
    ):
        sidecar.pop(field)
    _save_sidecar(service, created.filename, sidecar)

    _write_probe(["legacy-doomed"])
    result = service.restore(created.id, confirm=True)

    assert result.restored is True
    assert _read_probe() == ["original"]


# ── the trial refusal, proven against the live database ────────────────


def test_trial_restore_is_refused_before_real_psql_runs(
    probe, service, state_dir, monkeypatch
):
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    _seed_trial(state_dir)

    created = service.create()
    _write_probe(["doomed"])

    with pytest.raises(TrialRestoreForbiddenError):
        service.restore(created.id, confirm=True)

    assert _read_probe() == ["doomed"], "psql never ran"
    # D3: the rescue download stays open even while restore is refused.
    data, name = service.download(created.id)
    assert data.startswith(b"PK") and name.endswith(".zip")


# ── invalid manifests refused before any destructive work ──────────────


def test_unsupported_manifest_version_is_refused_before_replay(
    probe, service, state_dir
):
    created = service.create()
    sidecar = _load_sidecar(service, created.filename)
    sidecar["format_version"] = 99
    _save_sidecar(service, created.filename, sidecar)

    _write_probe(["doomed"])
    with pytest.raises(ValidationError) as excinfo:
        service.restore(created.id, confirm=True)
    assert excinfo.value.code == UNSUPPORTED
    assert _read_probe() == ["doomed"]


def test_broken_sidecar_signature_is_refused_before_replay(
    probe, service, state_dir
):
    created = service.create()
    sidecar = _load_sidecar(service, created.filename)
    sidecar["database"] = "tampered"
    _save_sidecar(service, created.filename, sidecar)

    _write_probe(["doomed"])
    with pytest.raises(ValidationError) as excinfo:
        service.restore(created.id, confirm=True)
    assert excinfo.value.code == SIGNATURE_INVALID
    assert _read_probe() == ["doomed"]


def test_unparseable_sidecar_is_adopted_and_the_dump_is_never_touched(
    probe, service, state_dir
):
    """Phase 17 adoption (pre-existing) survives L3 unchanged.

    A sidecar that cannot be parsed falls through to adoption: the index
    is rewritten, the dump bytes are not — and everything the restore
    then relies on (sha256, structural check) is recomputed from that
    untouched dump.
    """
    created = service.create()
    dump_path = service.directory / created.filename
    dump_before = dump_path.read_bytes()
    _sidecar_path(service, created.filename).write_text(
        "{ this is not json", encoding="utf-8"
    )

    listing = service.list()

    assert dump_path.read_bytes() == dump_before, "the dump was rewritten"
    assert [entry.filename for entry in listing.items] == [created.filename]
    adopted = _load_sidecar(service, created.filename)
    assert "format_version" not in adopted, "adoption writes an honest v1"
