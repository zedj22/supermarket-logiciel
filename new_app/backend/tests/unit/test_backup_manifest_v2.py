"""Phase L3 (audit §8) — backup manifest v2: signing, verification, refusal.

The sidecar manifest evolves **additively**: every Backup v1 key stays,
and v2 adds ``format_version``, ``payload_sha256``,
``created_by: {app_version, install_id}``, ``signature``, ``key_id`` and
``public_key``.  A v2 document is signed with this install's Ed25519
keypair (a StateStore envelope under ``LICENSE_STATE_DIR``) and carries
the public half inside itself, so verification never reads local
licensing state — the property that keeps archives portable across PCs.

Pinned here:

* v1 documents (absent or explicit ``format_version: 1``) verify as 1
  and keep the SHA-256 + structural path — old backups restore unchanged;
* v2 documents verify as 2 only with every required field, a payload
  hash bound to ``sha256`` (and to the caller's file hash) and a valid
  Ed25519 signature over the canonical document minus ``signature``;
* unknown or malformed ``format_version`` is refused — never
  reinterpreted, never silently downgraded;
* the service layer applies the gate *before* persisting an upload and
  *before* any destructive restore work, and a failed signature or
  non-SQL payload stops the replay with nothing written;
* verification is self-contained: after the manifest exists, deleting
  or swapping the local state directory cannot change the verdict.
"""

from __future__ import annotations

import base64
import hashlib
import json
import zipfile
from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.exceptions import ValidationError
from app.db.base import Base
from app.licensing.trial import TrialManager
from app.services import backup as backup_service
from app.services.backup import BackupService
from app.services.backup_manifest import (
    FORMAT_VERSION,
    INSTALL_KEY_ID,
    INVALID,
    SIGNATURE_INVALID,
    SIGNING_FAILED,
    UNSUPPORTED,
    V2_REQUIRED_FIELDS,
    finalize_manifest,
    verify_manifest,
)

DUMP_BYTES = b"-- fake pg_dump output\nCREATE TABLE x (id int);\n"

#: The exact Backup v1 keyset (Phase 17 §17.2) that must survive v2.
_V1_KEYS = {
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


class FakeRunner:
    def __init__(self) -> None:
        self.dumped: list[str] = []
        self.restored: list[str] = []

    def dump(self, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(DUMP_BYTES)
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
def state_dir(tmp_path: Path, monkeypatch) -> Path:
    """Point licensing at a throwaway directory (never the real one)."""
    path = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(path))
    return path


@pytest.fixture()
def service(session, backup_dir: Path, runner: FakeRunner) -> BackupService:
    return BackupService(session, runner=runner, directory=backup_dir)


# ── helpers ────────────────────────────────────────────────────────────


def _v1_manifest(**overrides) -> dict:
    doc = {
        "id": 1,
        "filename": "backup_20261108_090000.sql",
        "size": len(DUMP_BYTES),
        "created_at": "2026-11-08T09:00:00+00:00",
        "sha256": "a" * 64,
        "schema_revision": None,
        "pg_dump_version": "pg_dump (PostgreSQL) 18.6",
        "app_version": "0.0.0-test",
        "database": "postgres",
    }
    doc.update(overrides)
    return doc


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _write_archive(path: Path, dump: bytes, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("dump.sql", dump)
        archive.writestr("manifest.json", json.dumps(manifest))


def _sidecar_path(service: BackupService, created) -> Path:
    return service.directory / f"{created.filename[:-4]}.json"


# ── finalize: v2 generation ────────────────────────────────────────────


def test_finalize_adds_exactly_the_six_v2_fields(state_dir):
    doc = finalize_manifest(_v1_manifest())

    assert set(doc) - _V1_KEYS == {
        "format_version",
        "payload_sha256",
        "created_by",
        "signature",
        "key_id",
        "public_key",
    }
    assert doc["format_version"] == FORMAT_VERSION == 2
    assert doc["payload_sha256"] == doc["sha256"]
    assert doc["key_id"] == INSTALL_KEY_ID == "install"
    assert set(doc["created_by"]) == {"app_version", "install_id"}
    assert doc["created_by"]["app_version"] == settings.VERSION
    assert len(base64.b64decode(doc["public_key"])) == 32
    assert len(base64.b64decode(doc["signature"])) == 64


def test_finalize_never_mutates_the_input(state_dir):
    original = _v1_manifest()
    snapshot = dict(original)
    finalize_manifest(original)
    assert original == snapshot


def test_finalize_refuses_a_manifest_without_sha256(state_dir):
    doc = _v1_manifest()
    del doc["sha256"]
    with pytest.raises(ValidationError) as excinfo:
        finalize_manifest(doc)
    assert excinfo.value.code == INVALID


def test_finalize_records_the_trial_install_id_as_provenance(state_dir):
    TrialManager(state_dir=state_dir).ensure_started()
    expected = TrialManager(state_dir=state_dir).status().install_id

    doc = finalize_manifest(_v1_manifest())

    assert doc["created_by"]["install_id"] == expected


def test_finalize_keeps_provenance_none_without_a_trial(state_dir):
    """A missing trial never blocks a backup — it is provenance only."""
    doc = finalize_manifest(_v1_manifest())
    assert doc["created_by"]["install_id"] is None


def test_the_signing_key_lives_in_a_state_envelope(state_dir):
    finalize_manifest(_v1_manifest())
    envelope = state_dir / f"{INSTALL_KEY_ID}.keypair.state"
    assert envelope.is_file(), "StateStore envelope, never a bare key file"


def test_finalize_reuses_one_keypair_per_install(state_dir):
    first = finalize_manifest(_v1_manifest())
    second = finalize_manifest(_v1_manifest())
    assert first["public_key"] == second["public_key"]


def test_signing_fails_closed_when_the_keypair_state_is_corrupt(state_dir):
    """A broken key envelope never yields an unsigned "v2" document."""
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / f"{INSTALL_KEY_ID}.keypair.state").write_text(
        "garbage", encoding="utf-8"
    )

    with pytest.raises(ValidationError) as excinfo:
        finalize_manifest(_v1_manifest())
    assert excinfo.value.code == SIGNING_FAILED
    assert excinfo.value.status_code == 422


# ── verify: version dispatch ───────────────────────────────────────────


def test_verify_accepts_a_fresh_v2_manifest(state_dir):
    assert verify_manifest(finalize_manifest(_v1_manifest())) == 2


def test_verify_treats_an_absent_format_version_as_v1():
    assert verify_manifest(_v1_manifest()) == 1


def test_verify_treats_an_explicit_version_1_as_v1():
    assert verify_manifest(_v1_manifest(format_version=1)) == 1


def test_verify_refuses_unknown_versions():
    for version in (0, 3, 99):
        with pytest.raises(ValidationError) as excinfo:
            verify_manifest(_v1_manifest(format_version=version))
        assert excinfo.value.code == UNSUPPORTED
        assert excinfo.value.status_code == 422


def test_verify_refuses_non_integer_versions():
    for value in ("2", 2.0, True, None):
        with pytest.raises(ValidationError) as excinfo:
            verify_manifest(_v1_manifest(format_version=value))
        assert excinfo.value.code == INVALID


@pytest.mark.parametrize("field", V2_REQUIRED_FIELDS)
def test_verify_refuses_a_v2_document_missing_any_required_field(
    state_dir, field
):
    doc = finalize_manifest(_v1_manifest())
    del doc[field]

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID
    assert field in excinfo.value.details.get("missing", [])


# ── verify: payload binding ────────────────────────────────────────────


def test_verify_refuses_a_payload_hash_that_disagrees(state_dir):
    doc = finalize_manifest(_v1_manifest())
    doc["payload_sha256"] = "b" * 64

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID


def test_verify_refuses_non_hex_payload_hashes(state_dir):
    doc = finalize_manifest(_v1_manifest())
    doc["payload_sha256"] = "z" * 64

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID


def test_verify_binds_the_actual_file_hash(state_dir):
    """The upload path: the bytes on the wire must match the document."""
    doc = finalize_manifest(_v1_manifest(sha256="c" * 64))

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc, expected_sha256="d" * 64)
    assert excinfo.value.code == INVALID

    assert verify_manifest(doc, expected_sha256="c" * 64) == 2


# ── verify: signature ──────────────────────────────────────────────────


def test_verify_refuses_any_tampering_with_the_document(state_dir):
    for field, value in (
        ("filename", "evil.sql"),
        ("size", 1),
        ("sha256", "e" * 64),
        ("created_by", {"app_version": "9.9", "install_id": None}),
        ("key_id", "other"),
        ("public_key", _b64(b"\x01" * 32)),
    ):
        doc = finalize_manifest(_v1_manifest())
        doc[field] = value
        if field == "sha256":
            # Keep the payload pair consistent so the *signature* is what
            # rejects the edit (a payload mismatch is a separate refusal).
            doc["payload_sha256"] = "e" * 64
        with pytest.raises(ValidationError) as excinfo:
            verify_manifest(doc)
        assert excinfo.value.code == SIGNATURE_INVALID, field


def test_verify_refuses_a_tampered_signature_field(state_dir):
    """``signature`` is excluded from the signed bytes — editing it fails."""
    doc = finalize_manifest(_v1_manifest())
    other = finalize_manifest(_v1_manifest(sha256="f" * 64))
    doc["signature"] = other["signature"]

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == SIGNATURE_INVALID


def test_verify_refuses_malformed_base64(state_dir):
    doc = finalize_manifest(_v1_manifest())
    doc["signature"] = "!!!not-base64!!!"

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID


def test_verify_refuses_wrong_length_keys(state_dir):
    doc = finalize_manifest(_v1_manifest())
    doc["signature"] = _b64(b"\x00" * 63)
    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID

    doc = finalize_manifest(_v1_manifest())
    doc["public_key"] = _b64(b"\x00" * 31)
    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID


def test_verify_refuses_a_created_by_without_install_id(state_dir):
    doc = finalize_manifest(_v1_manifest())
    doc["created_by"] = {"app_version": "1.0"}

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID


def test_verify_refuses_an_empty_key_id(state_dir):
    doc = finalize_manifest(_v1_manifest())
    doc["key_id"] = ""

    with pytest.raises(ValidationError) as excinfo:
        verify_manifest(doc)
    assert excinfo.value.code == INVALID


def test_verification_never_reads_local_state(state_dir, tmp_path, monkeypatch):
    """Cross-PC at unit level: the embedded public key is self-contained.

    Once the document exists, pointing the server at an empty state
    directory (a foreign install with no keypair) cannot change the
    verdict — no fingerprint, no local key, no comparison.
    """
    doc = finalize_manifest(_v1_manifest())

    monkeypatch.setattr(
        settings, "LICENSE_STATE_DIR", str(tmp_path / "other_pc")
    )

    assert verify_manifest(doc) == 2


# ── service: create / upload / restore / inspect ───────────────────────


def test_create_writes_a_signed_v2_sidecar(state_dir, service):
    created = service.create()

    sidecar = json.loads(_sidecar_path(service, created).read_text("utf-8"))
    assert verify_manifest(sidecar) == 2
    assert sidecar["sha256"] == created.sha256
    assert sidecar["payload_sha256"] == created.sha256


def test_upload_accepts_a_legacy_v1_archive(state_dir, service, backup_dir):
    archive = backup_dir.parent / "legacy.zip"
    _write_archive(archive, DUMP_BYTES, _v1_manifest(sha256="0" * 64))

    staged = service.upload(content=archive.read_bytes(), filename="legacy.zip")

    assert staged.filename.endswith(".sql")
    sidecar = json.loads(_sidecar_path(service, staged).read_text("utf-8"))
    assert verify_manifest(sidecar) == 2, "staged copy is re-signed here"
    assert sidecar["uploaded_from"] == "legacy.zip"


def test_upload_refuses_a_tampered_v2_archive_before_writing(
    state_dir, service, backup_dir
):
    archive = backup_dir.parent / "travel.zip"
    real_hash = hashlib.sha256(DUMP_BYTES).hexdigest()
    _write_archive(
        archive,
        DUMP_BYTES,
        finalize_manifest(_v1_manifest(sha256=real_hash)),
    )
    with zipfile.ZipFile(archive) as zipped:
        carried = json.loads(zipped.read("manifest.json"))
    carried["filename"] = "evil.sql"  # signature now fails
    _write_archive(archive, DUMP_BYTES, carried)

    with pytest.raises(ValidationError) as excinfo:
        service.upload(content=archive.read_bytes(), filename="travel.zip")
    assert excinfo.value.code == SIGNATURE_INVALID

    assert not backup_dir.exists() or not any(backup_dir.iterdir())


def test_upload_refuses_an_unsupported_carried_version(
    state_dir, service, backup_dir
):
    archive = backup_dir.parent / "future.zip"
    carried = _v1_manifest(format_version=99)
    _write_archive(archive, DUMP_BYTES, carried)

    with pytest.raises(ValidationError) as excinfo:
        service.upload(content=archive.read_bytes(), filename="future.zip")
    assert excinfo.value.code == UNSUPPORTED

    assert not backup_dir.exists() or not any(backup_dir.iterdir())


def test_restore_refuses_a_tampered_sidecar_before_destructive_work(
    state_dir, service, runner
):
    created = service.create()
    dumped_before = list(runner.dumped)  # create() took its own dump
    sidecar_path = _sidecar_path(service, created)
    sidecar = json.loads(sidecar_path.read_text("utf-8"))
    sidecar["size"] = sidecar["size"] + 1  # signed document, now invalid
    sidecar_path.write_text(json.dumps(sidecar), encoding="utf-8")

    with pytest.raises(ValidationError) as excinfo:
        service.restore(created.id, confirm=True)
    assert excinfo.value.code == SIGNATURE_INVALID

    assert runner.dumped == dumped_before, "no safety backup was taken"
    assert runner.restored == [], "psql never ran"


def test_restore_refuses_an_unknown_sidecar_version(state_dir, service, runner):
    created = service.create()
    dumped_before = list(runner.dumped)
    sidecar_path = _sidecar_path(service, created)
    sidecar = json.loads(sidecar_path.read_text("utf-8"))
    sidecar["format_version"] = 99
    sidecar_path.write_text(json.dumps(sidecar), encoding="utf-8")

    with pytest.raises(ValidationError) as excinfo:
        service.restore(created.id, confirm=True)
    assert excinfo.value.code == UNSUPPORTED

    assert runner.dumped == dumped_before
    assert runner.restored == []


def test_restore_still_accepts_a_pure_v1_sidecar(state_dir, service, runner):
    """Legacy backups (no format_version, unsigned) restore unchanged."""
    created = service.create()
    sidecar_path = _sidecar_path(service, created)
    sidecar = json.loads(sidecar_path.read_text("utf-8"))
    for field in (
        "format_version",
        "payload_sha256",
        "created_by",
        "signature",
        "key_id",
        "public_key",
    ):
        sidecar.pop(field)
    sidecar_path.write_text(json.dumps(sidecar), encoding="utf-8")

    restored = service.restore(created.id, confirm=True)

    assert restored.restored is True
    assert runner.restored == [created.filename]


def test_restore_refuses_a_non_sql_payload_with_a_valid_hash(
    state_dir, service, runner, backup_dir
):
    """SHA-256 and signature both pass; the structural check still stops it."""
    junk = b"\x00\x01 not a dump \x02\x03"

    sidecar = _v1_manifest(
        filename="junk.sql",
        sha256=hashlib.sha256(junk).hexdigest(),
        size=len(junk),
    )
    backup_dir.mkdir(parents=True, exist_ok=True)
    (backup_dir / "junk.sql").write_bytes(junk)
    (backup_dir / "junk.json").write_text(json.dumps(sidecar), encoding="utf-8")
    existing = service.list().items[0]

    with pytest.raises(ValidationError) as excinfo:
        service.restore(existing.id, confirm=True)
    assert excinfo.value.code == "BACKUP_RESTORE_INVALID"

    assert runner.dumped == [] and runner.restored == []


def test_inspect_reports_the_version_and_signature_verdict(
    state_dir, service
):
    created = service.create()

    report = service.inspect(created.id)

    assert report.format_version == 2
    assert report.signature_ok is True
    assert report.sha256_ok is True
    # A valid v2 document adds no warning of its own.
    assert all("revision" in w for w in report.warnings)


def test_inspect_reports_a_broken_signature_instead_of_raising(
    state_dir, service
):
    """Inspect surfaces the verdict; *restore* is where it becomes fatal."""
    created = service.create()
    sidecar_path = _sidecar_path(service, created)
    sidecar = json.loads(sidecar_path.read_text("utf-8"))
    sidecar["database"] = "tampered"
    sidecar_path.write_text(json.dumps(sidecar), encoding="utf-8")

    report = service.inspect(created.id)

    assert report.signature_ok is False
    assert report.format_version == 2
    assert any("signature does not verify" in w for w in report.warnings)

    with pytest.raises(ValidationError) as excinfo:
        service.restore(created.id, confirm=True)
    assert excinfo.value.code == SIGNATURE_INVALID


def test_inspect_reports_v1_manifests_without_a_signature(state_dir, service):
    created = service.create()
    sidecar_path = _sidecar_path(service, created)
    sidecar = json.loads(sidecar_path.read_text("utf-8"))
    for field in (
        "format_version",
        "payload_sha256",
        "created_by",
        "signature",
        "key_id",
        "public_key",
    ):
        sidecar.pop(field)
    sidecar_path.write_text(json.dumps(sidecar), encoding="utf-8")

    report = service.inspect(created.id)

    assert report.format_version == 1
    assert report.signature_ok is None


def test_inspect_refuses_an_unknown_version(state_dir, service):
    created = service.create()
    sidecar_path = _sidecar_path(service, created)
    sidecar = json.loads(sidecar_path.read_text("utf-8"))
    sidecar["format_version"] = 42
    sidecar_path.write_text(json.dumps(sidecar), encoding="utf-8")

    with pytest.raises(ValidationError) as excinfo:
        service.inspect(created.id)
    assert excinfo.value.code == UNSUPPORTED


def test_the_manifest_module_is_where_the_state_is_reached():
    """BackupService still consults only the §4.4 policy (L1-D/L1-E).

    The signing key lives in ``LICENSE_STATE_DIR``; that read belongs to
    the manifest module, never to ``backup.py`` — the source scans in
    ``test_l1e_trial_lifecycle_integration`` and
    ``test_trial_manager`` keep guarding it.
    """
    source = Path(backup_service.__file__).read_text(encoding="utf-8")
    for token in (
        "LICENSE_STATE_DIR",
        "StateStore",
        "TrialManager",
        "install_id",
        "backup_manifest",
    ):
        # `backup_manifest` may be imported, but no state machinery.
        if token == "backup_manifest":
            assert "from app.services.backup_manifest import" in source
            continue
        assert token not in source, token
