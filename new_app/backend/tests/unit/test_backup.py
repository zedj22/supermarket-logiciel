"""Phase 17 §17.2 — backup / restore. + Objective 2 extensions.

Covers:
- the catalogue is the filesystem: an empty (or absent) directory lists nothing
- ``pg_dump`` output + sidecar manifest are written together, ids increment
- ``GET /backups`` is authenticated but not admin-only
- create/restore require ``backup_restore`` (admin): 401 / 403 for others
- an orphan ``.sql`` (no manifest) is adopted instead of silently ignored
- restore verifies the recorded SHA-256 and refuses a tampered dump
- restore replays exactly the requested file; unknown id → 404
- a failed dump never leaves a half-written file behind
- create is all-or-nothing with its audit row: no audit ⇒ no backup files
- audit rows for both ``backup`` and ``restore`` actions
- ``DbParams`` never exposes the password and URL-decodes it correctly

Objective 2:
- restore requires an explicit ``confirm: true`` (bare POST → 422
  ``RESTORE_CONFIRMATION_REQUIRED``, nothing touched)
- a safety backup is taken before the replay and reported in the response;
  a failed safety backup cancels the restore (``RESTORE_SAFETY_BACKUP_FAILED``)
- ``GET /{id}/inspect``: integrity (hash) + schema-compatibility summary
- ``GET /{id}/download``: portable ZIP (``dump.sql`` + ``manifest.json``)
- ``POST /upload``: stages a raw ``.sql`` or a portable ZIP as a first-class
  backup (id re-allocated, hash recomputed, ``backup_upload`` audit row);
  refuses empty / non-SQL / bad-ZIP / oversized content
- unit-level portable roundtrip: create → download → upload → restore

No test shells out: ``DumpRunner`` is injected, so the suite passes on a
machine without PostgreSQL tooling.  The real tools are covered by
``tests/integration/test_backup_dump.py``.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.db_dump import DbParams, sha256_of
from app.core.exceptions import ServiceUnavailableError
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.services.auth import AuthService
from app.services.backup import BackupService

DUMP_BYTES = b"-- fake pg_dump output\nCREATE TABLE x (id int);\n"


class FakeRunner:
    """Stands in for ``DumpRunner`` — records instead of shelling out."""

    def __init__(
        self,
        content: bytes = DUMP_BYTES,
        fail: bool = False,
        fail_restore: bool = False,
    ):
        self.content = content
        self.fail = fail
        self.fail_restore = fail_restore
        self.dumped: list[str] = []
        self.restored: list[str] = []

    def dump(self, destination: Path) -> None:
        if self.fail:
            raise ServiceUnavailableError("pg_dump failed: connection refused")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(self.content)
        self.dumped.append(destination.name)

    def restore(self, source: Path) -> None:
        if self.fail:
            raise ServiceUnavailableError("psql failed: syntax error")
        if self.fail_restore:
            raise ServiceUnavailableError("psql failed: syntax error")
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
def TestingSession(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, TestingSession):
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    yield session
    session.close()


@pytest.fixture()
def backup_dir(tmp_path: Path) -> Path:
    return tmp_path / "backups"


@pytest.fixture()
def runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture()
def client(engine, TestingSession, db, backup_dir, runner, monkeypatch):
    monkeypatch.setattr(settings, "BACKUP_DIR", str(backup_dir))
    monkeypatch.setattr(
        BackupService, "runner", property(lambda self: runner)
    )

    def override_get_db():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": pin}
    )
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


def _audit_rows(db) -> list[AuditLog]:
    return list(
        db.scalars(
            select(AuditLog)
            .where(AuditLog.entity_type == "backup")
            .order_by(AuditLog.action_at)
        )
    )


# ── list ───────────────────────────────────────────────────────────────


def test_list_requires_authentication(client):
    resp = client.get("/api/v1/backups")
    assert resp.status_code == 401


def test_list_is_open_to_any_authenticated_user(
    client, admin_headers, cashier_headers
):
    """A cashier may *see* that backups exist; only admins may act."""
    assert client.get("/api/v1/backups", headers=cashier_headers).status_code == 200


def test_list_returns_empty_for_a_missing_directory(
    client, admin_headers, backup_dir
):
    assert not backup_dir.exists()
    resp = client.get("/api/v1/backups", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json() == {"items": [], "count": 0}


# ── create ─────────────────────────────────────────────────────────────


def test_create_requires_authentication(client):
    resp = client.post("/api/v1/backups")
    assert resp.status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_create_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    resp = client.post("/api/v1/backups", headers=headers)
    assert resp.status_code == 403


def test_create_writes_sql_and_manifest(client, admin_headers, backup_dir):
    resp = client.post("/api/v1/backups", headers=admin_headers)
    assert resp.status_code == 201, resp.text
    body = resp.json()

    # Blueprint contract: {id, filename, size, created_at}
    for key in ("id", "filename", "size", "created_at"):
        assert key in body, key
    assert body["filename"].endswith(".sql")
    assert body["size"] == len(DUMP_BYTES)
    assert body["sha256"] == sha256_of(backup_dir / body["filename"])

    assert (backup_dir / body["filename"]).read_bytes() == DUMP_BYTES
    manifest = json.loads(
        (backup_dir / (Path(body["filename"]).stem + ".json")).read_text(
            encoding="utf-8"
        )
    )
    assert manifest["id"] == body["id"]
    assert manifest["filename"] == body["filename"]


def test_create_assigns_incrementing_ids(client, admin_headers):
    first = client.post("/api/v1/backups", headers=admin_headers).json()
    second = client.post("/api/v1/backups", headers=admin_headers).json()
    assert (first["id"], second["id"]) == (1, 2)
    assert first["filename"] != second["filename"] or first["id"] != second["id"]


def test_list_returns_newest_first(client, admin_headers):
    client.post("/api/v1/backups", headers=admin_headers)
    client.post("/api/v1/backups", headers=admin_headers)
    items = client.get("/api/v1/backups", headers=admin_headers).json()["items"]
    assert [item["id"] for item in items] == [2, 1]


def test_create_writes_backup_audit_row(client, admin_headers, db):
    resp = client.post("/api/v1/backups", headers=admin_headers)
    filename = resp.json()["filename"]

    rows = [row for row in _audit_rows(db) if row.action == "backup"]
    assert len(rows) == 1
    assert rows[0].details == filename
    assert json.loads(rows[0].after_state)["sha256"]


def test_create_is_audited_per_backup(client, admin_headers, db):
    client.post("/api/v1/backups", headers=admin_headers)
    client.post("/api/v1/backups", headers=admin_headers)
    rows = [row for row in _audit_rows(db) if row.action == "backup"]
    assert len(rows) == 2


def test_failed_dump_leaves_nothing_behind(
    client, admin_headers, backup_dir, runner
):
    runner.fail = True
    resp = client.post("/api/v1/backups", headers=admin_headers)
    assert resp.status_code == 503
    assert not backup_dir.exists() or list(backup_dir.iterdir()) == []

    listed = client.get("/api/v1/backups", headers=admin_headers).json()
    assert listed == {"items": [], "count": 0}


# ── adoption ───────────────────────────────────────────────────────────


def test_orphan_sql_is_adopted_on_list(client, admin_headers, backup_dir):
    backup_dir.mkdir(parents=True)
    (backup_dir / "copied_by_hand.sql").write_text("-- dump\n", encoding="utf-8")

    items = client.get("/api/v1/backups", headers=admin_headers).json()["items"]
    assert [item["filename"] for item in items] == ["copied_by_hand.sql"]
    assert items[0]["sha256"]

    # the manifest it wrote makes it a first-class backup next time round
    assert (backup_dir / "copied_by_hand.json").is_file()
    repeat = client.get("/api/v1/backups", headers=admin_headers).json()["items"]
    assert repeat[0]["id"] == items[0]["id"]


def test_orphan_manifest_id_is_not_reused(client, admin_headers, backup_dir):
    backup_dir.mkdir(parents=True)
    (backup_dir / "a.sql").write_text("-- dump\n", encoding="utf-8")
    (backup_dir / "a.json").write_text(
        json.dumps(
            {
                "id": 41,
                "filename": "a.sql",
                "size": 9,
                "created_at": "2026-01-01T00:00:00+00:00",
            }
        ),
        encoding="utf-8",
    )
    (backup_dir / "b.sql").write_text("-- dump\n", encoding="utf-8")

    items = client.get("/api/v1/backups", headers=admin_headers).json()["items"]
    ids = sorted(item["id"] for item in items)
    assert ids == [41, 42]


def test_corrupt_manifest_is_ignored_not_fatal(
    client, admin_headers, backup_dir
):
    backup_dir.mkdir(parents=True)
    (backup_dir / "x.sql").write_text("-- dump\n", encoding="utf-8")
    (backup_dir / "x.json").write_text("{not json", encoding="utf-8")

    resp = client.get("/api/v1/backups", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json()["count"] == 1


# ── restore ────────────────────────────────────────────────────────────


def _create(client, headers) -> dict:
    resp = client.post("/api/v1/backups", headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_restore_requires_authentication(client):
    resp = client.post("/api/v1/backups/1/restore", json={"confirm": True})
    assert resp.status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_restore_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    resp = client.post("/api/v1/backups/1/restore", json={"confirm": True}, headers=headers)
    assert resp.status_code == 403


def test_restore_without_confirmation_is_refused(
    client, admin_headers, runner
):
    """A bare POST (no confirm body) must not touch the database."""
    backup = _create(client, admin_headers)
    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore", headers=admin_headers
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "RESTORE_CONFIRMATION_REQUIRED"
    assert runner.restored == []


def test_restore_with_explicit_false_is_refused(
    client, admin_headers, runner
):
    backup = _create(client, admin_headers)
    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": False},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert runner.restored == []


def test_restore_replays_the_requested_file(
    client, admin_headers, runner, db
):
    backup = _create(client, admin_headers)

    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["restored"] is True
    assert body["backup"]["id"] == backup["id"]
    assert body["post_restore_ok"] is True
    # A safety snapshot of the pre-restore database was taken first.
    assert body["safety_backup"] is not None
    assert body["safety_backup"]["id"] != backup["id"]
    assert runner.restored == [backup["filename"]]


def test_restore_takes_a_safety_backup_before_replaying(
    client, admin_headers, runner, backup_dir
):
    backup = _create(client, admin_headers)
    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    # The safety backup is a real dump on disk, restorable in turn.
    safety = resp.json()["safety_backup"]
    assert (backup_dir / safety["filename"]).is_file()
    assert safety["filename"] != backup["filename"]


def test_restore_is_cancelled_when_the_safety_backup_fails(
    client, admin_headers, runner
):
    """No way back ⇒ no restore. Nothing is replayed."""
    backup = _create(client, admin_headers)
    runner.fail = True  # the safety snapshot's dump will fail

    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "RESTORE_SAFETY_BACKUP_FAILED"
    assert runner.restored == []


def test_restore_writes_restore_audit_row(client, admin_headers, db):
    backup = _create(client, admin_headers)
    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200

    rows = [row for row in _audit_rows(db) if row.action == "restore"]
    assert len(rows) == 1
    assert rows[0].details == backup["filename"]
    assert json.loads(rows[0].before_state)["id"] == backup["id"]
    assert json.loads(rows[0].before_state)["safety_backup_id"] is not None


def test_restore_unknown_id_is_404(client, admin_headers, runner):
    _create(client, admin_headers)
    resp = client.post(
        "/api/v1/backups/999/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert runner.restored == []


def test_restore_of_a_tampered_file_is_refused(
    client, admin_headers, backup_dir, runner, db
):
    backup = _create(client, admin_headers)
    path = backup_dir / backup["filename"]
    path.write_bytes(DUMP_BYTES + b"-- tampered\n")

    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert runner.restored == []

    rows = [row for row in _audit_rows(db) if row.action == "restore"]
    assert rows == []


def test_restore_of_a_deleted_file_is_404(client, admin_headers, backup_dir, runner):
    backup = _create(client, admin_headers)
    (backup_dir / backup["filename"]).unlink()

    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert runner.restored == []


def test_failed_restore_is_reported_as_failed(client, admin_headers, runner):
    backup = _create(client, admin_headers)
    runner.fail_restore = True  # safety dump succeeds; the replay fails

    resp = client.post(
        f"/api/v1/backups/{backup['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 503
    assert runner.restored == []


def test_restore_still_reports_success_after_the_dump_was_replaced(
    client, admin_headers, runner
):
    """A second backup must not be restorable under the first one's id."""
    first = _create(client, admin_headers)
    second = _create(client, admin_headers)

    resp = client.post(
        f"/api/v1/backups/{first['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["backup"]["filename"] == first["filename"]
    assert runner.restored == [first["filename"]]
    assert second["filename"] != first["filename"]


# ── inspect (Objective 2) ──────────────────────────────────────────────


def test_inspect_requires_authentication(client):
    assert client.get("/api/v1/backups/1/inspect").status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_inspect_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    assert (
        client.get("/api/v1/backups/1/inspect", headers=headers).status_code
        == 403
    )


def test_inspect_reports_integrity_for_a_fresh_backup(
    client, admin_headers, backup_dir
):
    backup = _create(client, admin_headers)
    resp = client.get(
        f"/api/v1/backups/{backup['id']}/inspect", headers=admin_headers
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["backup"]["id"] == backup["id"]
    assert body["file_present"] is True
    assert body["sha256_ok"] is True
    # SQLite has no alembic_version, so the only warning is the
    # schema-revision one — integrity itself is clean.
    assert all("revision" in w for w in body["warnings"])


def test_inspect_flags_a_tampered_dump(client, admin_headers, backup_dir):
    backup = _create(client, admin_headers)
    (backup_dir / backup["filename"]).write_bytes(DUMP_BYTES + b"-- evil\n")

    body = client.get(
        f"/api/v1/backups/{backup['id']}/inspect", headers=admin_headers
    ).json()
    assert body["sha256_ok"] is False
    assert any("no longer matches" in w for w in body["warnings"])


def test_inspect_flags_a_missing_dump(client, admin_headers, backup_dir):
    backup = _create(client, admin_headers)
    (backup_dir / backup["filename"]).unlink()

    body = client.get(
        f"/api/v1/backups/{backup['id']}/inspect", headers=admin_headers
    ).json()
    assert body["file_present"] is False
    assert any("missing" in w for w in body["warnings"])


def test_inspect_reports_schema_compatibility(client, admin_headers, db):
    """A same-session backup matches the running revision when known."""
    backup = _create(client, admin_headers)
    body = client.get(
        f"/api/v1/backups/{backup['id']}/inspect", headers=admin_headers
    ).json()
    # SQLite has no alembic_version table ⇒ both sides None, never guessed.
    assert body["current_schema_revision"] is None
    assert body["schema_compatible"] is None
    assert any("revision" in w for w in body["warnings"])


def test_inspect_unknown_id_is_404(client, admin_headers):
    assert (
        client.get("/api/v1/backups/999/inspect", headers=admin_headers).status_code
        == 404
    )


# ── download (portable archive, Objective 2) ───────────────────────────


def test_download_requires_authentication(client):
    assert client.get("/api/v1/backups/1/download").status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_download_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    assert (
        client.get("/api/v1/backups/1/download", headers=headers).status_code
        == 403
    )


def test_download_returns_a_zip_with_dump_and_manifest(client, admin_headers):
    backup = _create(client, admin_headers)
    resp = client.get(
        f"/api/v1/backups/{backup['id']}/download", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/zip"
    disposition = resp.headers["content-disposition"]
    assert disposition.startswith("attachment; filename=")
    assert ".zip" in disposition
    assert str(backup["id"]) in disposition

    import io
    import zipfile as zf

    with zf.ZipFile(io.BytesIO(resp.content)) as archive:
        assert set(archive.namelist()) == {"dump.sql", "manifest.json"}
        assert archive.read("dump.sql") == DUMP_BYTES
        manifest = json.loads(archive.read("manifest.json"))
    assert manifest["id"] == backup["id"]
    assert manifest["sha256"] == backup["sha256"]


def test_download_unknown_id_is_404(client, admin_headers):
    assert (
        client.get("/api/v1/backups/999/download", headers=admin_headers).status_code
        == 404
    )


def test_download_of_a_deleted_file_is_404(client, admin_headers, backup_dir):
    backup = _create(client, admin_headers)
    (backup_dir / backup["filename"]).unlink()
    assert (
        client.get(
            f"/api/v1/backups/{backup['id']}/download", headers=admin_headers
        ).status_code
        == 404
    )


# ── upload (Objective 2) ───────────────────────────────────────────────


def _sql_content() -> bytes:
    return DUMP_BYTES


def test_upload_requires_authentication(client):
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.sql", _sql_content(), "application/sql")},
    )
    assert resp.status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_upload_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.sql", _sql_content(), "application/sql")},
        headers=headers,
    )
    assert resp.status_code == 403


def test_upload_raw_sql_is_staged_as_a_backup(
    client, admin_headers, backup_dir
):
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("hand_copied.sql", _sql_content(), "application/sql")},
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["filename"].endswith(".sql")
    assert (backup_dir / body["filename"]).read_bytes() == _sql_content()
    assert body["sha256"] == sha256_of(backup_dir / body["filename"])
    assert body["schema_revision"] is None  # raw upload, no manifest

    listed = client.get("/api/v1/backups", headers=admin_headers).json()
    assert body["id"] in [item["id"] for item in listed["items"]]


def test_upload_does_not_claim_an_existing_id(client, admin_headers):
    existing = _create(client, admin_headers)  # takes id 1
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.sql", _sql_content(), "application/sql")},
        headers=admin_headers,
    )
    assert resp.status_code == 201
    assert resp.json()["id"] == existing["id"] + 1


def test_upload_writes_a_backup_upload_audit_row(client, admin_headers, db):
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.sql", _sql_content(), "application/sql")},
        headers=admin_headers,
    )
    assert resp.status_code == 201
    rows = [row for row in _audit_rows(db) if row.action == "backup_upload"]
    assert len(rows) == 1
    assert rows[0].details == resp.json()["filename"]


def test_upload_rejects_an_empty_file(client, admin_headers):
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.sql", b"", "application/sql")},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "BACKUP_UPLOAD_EMPTY"


def test_upload_rejects_a_non_sql_binary(client, admin_headers):
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.sql", b"\x89PNG\r\n\x1a\n" + b"\x00" * 64, "application/sql")},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "BACKUP_UPLOAD_INVALID"


def test_upload_rejects_a_bad_zip(client, admin_headers):
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.zip", b"PK\x03\x04not-a-real-zip", "application/zip")},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "BACKUP_UPLOAD_INVALID"


def test_upload_rejects_a_zip_without_a_dump_member(client, admin_headers):
    import io
    import zipfile as zf

    buffer = io.BytesIO()
    with zf.ZipFile(buffer, "w") as archive:
        archive.writestr("notes.txt", "hello")
    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("x.zip", buffer.getvalue(), "application/zip")},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "BACKUP_UPLOAD_INVALID"


def test_upload_accepts_a_portable_archive(client, admin_headers, backup_dir):
    """The archive ``download`` produced can be ``upload``ed back."""
    original = _create(client, admin_headers)
    archive_bytes = client.get(
        f"/api/v1/backups/{original['id']}/download", headers=admin_headers
    ).content

    resp = client.post(
        "/api/v1/backups/upload",
        files={"file": ("restored.zip", archive_bytes, "application/zip")},
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    staged = resp.json()
    # The id is re-allocated on this server, never claimed from the archive.
    assert staged["id"] != original["id"]
    assert staged["schema_revision"] is None  # FakeRunner has no alembic
    assert (backup_dir / staged["filename"]).read_bytes() == DUMP_BYTES


def test_upload_of_an_oversized_file_is_refused(client, admin_headers):
    from app.services.backup import MAX_UPLOAD_BYTES

    payload = b"CREATE TABLE x (id int);\n" + b"-- pad\n" * 16
    # Simulate the cap without allocating 200 MB: patch the module constant.
    import app.services.backup as backup_module

    original = backup_module.MAX_UPLOAD_BYTES
    backup_module.MAX_UPLOAD_BYTES = len(payload) - 1
    try:
        resp = client.post(
            "/api/v1/backups/upload",
            files={"file": ("x.sql", payload, "application/sql")},
            headers=admin_headers,
        )
    finally:
        backup_module.MAX_UPLOAD_BYTES = original
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "BACKUP_UPLOAD_TOO_LARGE"
    assert MAX_UPLOAD_BYTES > len(payload)  # sanity: default is far larger


# ── portable roundtrip (Objective 2, unit level) ───────────────────────


def test_download_upload_restore_roundtrip(
    client, admin_headers, runner, backup_dir
):
    """create → download → upload → restore the staged copy."""
    original = _create(client, admin_headers)
    archive_bytes = client.get(
        f"/api/v1/backups/{original['id']}/download", headers=admin_headers
    ).content

    staged = client.post(
        "/api/v1/backups/upload",
        files={"file": ("portable.zip", archive_bytes, "application/zip")},
        headers=admin_headers,
    ).json()

    resp = client.post(
        f"/api/v1/backups/{staged['id']}/restore",
        json={"confirm": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert runner.restored == [staged["filename"]]


# ── service-level: audit must accompany a backup ───────────────────────


def test_create_removes_files_when_the_audit_write_fails(
    db, backup_dir, runner, monkeypatch
):
    """No audit row ⇒ no backup: an unauditable backup is not a backup."""
    from app.core.exceptions import DatabaseError

    monkeypatch.setattr(settings, "BACKUP_DIR", str(backup_dir))
    monkeypatch.setattr(
        BackupService, "runner", property(lambda self: runner)
    )

    def exploding_transaction(self):
        raise DatabaseError("audit write failed")

    monkeypatch.setattr(BackupService, "transaction", exploding_transaction)

    with pytest.raises(DatabaseError):
        BackupService(db).create()

    assert list(backup_dir.iterdir()) == []


def test_directory_defaults_when_config_is_empty(monkeypatch):
    monkeypatch.setattr(settings, "BACKUP_DIR", "  ")
    service = BackupService(None)
    assert service.directory.is_absolute()
    assert service.directory.name == "backups"


def test_relative_directory_is_resolved_against_the_backend(monkeypatch):
    monkeypatch.setattr(settings, "BACKUP_DIR", "backups")
    directory = BackupService(None).directory
    assert directory.is_absolute()
    assert directory.name == "backups"
    assert directory.parent.name == "backend"


# ── DbParams / hashing ─────────────────────────────────────────────────


def test_db_params_decodes_the_url_encoded_password():
    params = DbParams.from_url(
        "postgresql://postgres:Islem2002%40@localhost:5432/supermarket_pro"
    )
    assert params.password == "Islem2002@"
    assert params.user == "postgres"
    assert params.host == "localhost"
    assert params.port == 5432
    assert params.dbname == "supermarket_pro"


def test_db_params_safe_repr_hides_the_password():
    params = DbParams.from_url(
        "postgresql://postgres:secret@localhost:5432/supermarket_pro"
    )
    assert "secret" not in params.safe_repr()
    assert "supermarket_pro" in params.safe_repr()


def test_db_params_tool_env_sets_pg_variables_and_keeps_password_out_of_argv():
    params = DbParams.from_url(
        "postgresql://postgres:secret@dbhost:5433/shop"
    )
    env = params.tool_env()
    assert env["PGHOST"] == "dbhost"
    assert env["PGPORT"] == "5433"
    assert env["PGDATABASE"] == "shop"
    assert env["PGUSER"] == "postgres"
    assert env["PGPASSWORD"] == "secret"


def test_db_params_rejects_non_postgres_scheme():
    with pytest.raises(ValueError):
        DbParams.from_url("sqlite:///:memory:")


def test_sha256_of_is_content_based(tmp_path):
    target = tmp_path / "a.sql"
    target.write_bytes(b"hello")
    assert sha256_of(target) == (
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )
