"""Backup / restore service (Phase 17, §17.2).

Design (decisions recorded in ``docs/PHASE_17_IMPLEMENTATION.md``):

* **Storage** is the server's own ``backups/`` directory, holding a plain
  ``.sql`` from ``pg_dump`` plus a ``.json`` sidecar manifest.  There is
  deliberately **no ``backups`` table**: the filesystem is already the
  catalogue, and a table would drift from it the moment somebody removes a
  file by hand (§17.2 constraint — no new migration beyond the settings
  one).
* **Identity** is a stable integer allocated when a backup is created
  (``max(previous ids) + 1``) and recorded in the manifest, so restoring
  by id cannot silently point at a different file as new backups arrive.
* **Restore safety**: the SHA-256 recorded at creation is verified before
  anything is replayed, ``psql --single-transaction`` makes the restore
  all-or-nothing, and the request's own session is rolled back afterwards
  so it cannot keep reading a pre-restore snapshot.
* **Audit**: creating a backup that cannot be audited is rolled back (the
  files are deleted and the request fails).  A restore cannot be undone,
  so its audit row is written afterwards and a failure there is logged
  loudly instead of reported as a failed restore — reporting "restore
  failed" when the data has already been replaced would be a lie.
"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

import structlog
from sqlalchemy import text

from app.core.config import BACKEND_ROOT, settings
from app.core.db_dump import DbParams, DumpRunner, sha256_of
from app.core.exceptions import AppError, BusinessRuleError, NotFoundError
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.schemas.backup import (
    BackupInfo,
    BackupListResponse,
    BackupRestoreResponse,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

_MANIFEST_SUFFIX = ".json"
_SQL_SUFFIX = ".sql"


class BackupService(BaseService):
    """Filesystem-backed backup catalogue."""

    def __init__(
        self,
        db,
        *,
        runner: DumpRunner | None = None,
        directory: Path | None = None,
    ):
        super().__init__(db)
        self._runner = runner
        self._directory = directory

    # -- locations ---------------------------------------------------------

    @property
    def directory(self) -> Path:
        """Absolute backup directory (never depends on the CWD)."""
        raw = settings.BACKUP_DIR.strip()
        path = Path(raw) if raw else BACKEND_ROOT / "backups"
        if not path.is_absolute():
            path = BACKEND_ROOT / path
        return path

    @property
    def runner(self) -> DumpRunner:
        if self._runner is None:
            self._runner = DumpRunner(
                DbParams.from_url(settings.DATABASE_URL)
            )
        return self._runner

    # -- create ------------------------------------------------------------

    def create(self, *, actor_id: uuid.UUID | None = None) -> BackupInfo:
        """Take a new backup and append its ``backup`` audit row."""
        directory = self.directory
        directory.mkdir(parents=True, exist_ok=True)

        entries = self.list().items
        next_id = max(
            [entry.id for entry in entries] + self.list_ids(),
            default=0,
        ) + 1
        filename = self._next_filename(directory, datetime.now(timezone.utc))
        path = directory / filename

        # The dump itself may raise — nothing is persisted in that case.
        self.runner.dump(path)

        manifest = {
            "id": next_id,
            "filename": filename,
            "size": path.stat().st_size,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "sha256": sha256_of(path),
            "schema_revision": self._schema_revision(),
            "pg_dump_version": self._tool_version(),
            "app_version": settings.VERSION,
            "database": self._database_name(),
        }
        self._write_manifest(directory / (path.stem + _MANIFEST_SUFFIX), manifest)

        try:
            with self.transaction():
                self.db.add(
                    AuditLog(
                        user_id=actor_id,
                        action=AuditAction.BACKUP.value,
                        entity_type="backup",
                        details=filename,
                        after_state=json.dumps(manifest, default=str),
                    )
                )
        except AppError:
            # Not auditable ⇒ not a backup: remove the artefacts and let
            # the caller see a real failure instead of an untracked file.
            path.unlink(missing_ok=True)
            (directory / (path.stem + _MANIFEST_SUFFIX)).unlink(missing_ok=True)
            logger.error("backup_audit_failed", filename=filename)
            raise

        logger.info(
            "backup_created",
            id=next_id,
            filename=filename,
            size=manifest["size"],
        )
        return BackupInfo(**manifest)

    # -- list --------------------------------------------------------------

    def list(self) -> BackupListResponse:
        """Every backup on disk, newest first.

        Side effect (deliberate, documented): a ``.sql`` that has no
        sidecar — a dump left behind by an interrupted create, or one
        copied in by hand — is *adopted*: a manifest is written for it so
        it becomes visible and restorable instead of silently ignored.
        Adoption only ever creates the ``.json`` index, never touches a
        dump.
        """
        directory = self.directory
        if not directory.is_dir():
            return BackupListResponse(items=[], count=0)

        entries: list[BackupInfo] = []
        used_ids: set[int] = set(self.list_ids())

        for sql_path in sorted(directory.glob(f"*{_SQL_SUFFIX}")):
            manifest_path = sql_path.with_suffix(_MANIFEST_SUFFIX)
            manifest = self._read_manifest(manifest_path)
            if manifest is None:
                manifest = self._adopt(sql_path, used_ids)
                self._write_manifest(manifest_path, manifest)
                logger.warning("backup_manifest_adopted", filename=sql_path.name)
            used_ids.add(int(manifest["id"]))
            entries.append(self._to_info(manifest))

        entries.sort(key=lambda entry: entry.id, reverse=True)
        return BackupListResponse(items=entries, count=len(entries))

    # -- restore -----------------------------------------------------------

    def restore(
        self,
        backup_id: int,
        *,
        actor_id: uuid.UUID | None = None,
    ) -> BackupRestoreResponse:
        """Replay one backup over the live database."""
        entries = self.list().items
        info = next((entry for entry in entries if entry.id == backup_id), None)
        if info is None:
            raise NotFoundError(f"backup {backup_id} does not exist")

        path = self.directory / info.filename
        if not path.is_file():
            raise NotFoundError(f"backup file missing: {info.filename}")

        if info.sha256:
            actual = sha256_of(path)
            if actual != info.sha256:
                raise BusinessRuleError(
                    "This backup has been modified since it was created "
                    "and will not be restored.",
                    details={"filename": info.filename},
                )

        logger.info("backup_restore_started", id=backup_id, filename=info.filename)
        self.runner.restore(path)

        # Everything the request's session had read belongs to the
        # pre-restore database — drop it before touching the data again.
        self.db.rollback()
        revision = self._schema_revision()

        # Best effort: the restore already happened and cannot be undone,
        # so a failed audit row must not be reported as a failed restore.
        try:
            with self.transaction():
                self.db.add(
                    AuditLog(
                        user_id=actor_id,
                        action=AuditAction.RESTORE.value,
                        entity_type="backup",
                        details=info.filename,
                        before_state=json.dumps(
                            {"id": backup_id, "filename": info.filename}
                        ),
                        after_state=json.dumps(
                            {"schema_revision": revision}, default=str
                        ),
                    )
                )
        except AppError:
            logger.error(
                "restore_audit_failed",
                id=backup_id,
                filename=info.filename,
            )

        logger.info("backup_restore_done", id=backup_id, revision=revision)
        return BackupRestoreResponse(
            restored=True,
            backup=info,
            schema_revision=revision,
        )

    # -- helpers -----------------------------------------------------------

    def _next_filename(self, directory: Path, moment: datetime) -> str:
        base = f"backup_{moment.strftime('%Y%m%d_%H%M%S')}"
        candidate = f"{base}{_SQL_SUFFIX}"
        suffix = 2
        while (directory / candidate).exists():
            candidate = f"{base}_{suffix}{_SQL_SUFFIX}"
            suffix += 1
        return candidate

    def _adopt(self, sql_path: Path, used_ids: set[int]) -> dict:
        """Build (but do not persist) a manifest for an orphan ``.sql``."""
        stat = sql_path.stat()
        next_id = max(used_ids, default=0) + 1
        used_ids.add(next_id)
        return {
            "id": next_id,
            "filename": sql_path.name,
            "size": stat.st_size,
            "created_at": datetime.fromtimestamp(
                stat.st_mtime, tz=timezone.utc
            ).isoformat(),
            "sha256": sha256_of(sql_path),
            "schema_revision": None,
            "pg_dump_version": None,
            "app_version": None,
            "database": None,
        }

    def list_ids(self) -> list[int]:
        """Ids already claimed by manifests on disk (used when adopting)."""
        directory = self.directory
        if not directory.is_dir():
            return []
        ids: list[int] = []
        for manifest_path in directory.glob(f"*{_MANIFEST_SUFFIX}"):
            manifest = self._read_manifest(manifest_path)
            if manifest is not None and "id" in manifest:
                ids.append(int(manifest["id"]))
        return ids

    @staticmethod
    def _read_manifest(path: Path) -> dict | None:
        """Parse a sidecar manifest, or ``None`` if it is unusable.

        Anything missing the fields needed to restore safely falls through
        to adoption rather than breaking the whole listing.
        """
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(data, dict):
            return None
        if not all(key in data for key in ("id", "filename", "created_at")):
            return None
        try:
            int(data["id"])
        except (TypeError, ValueError):
            return None
        return data

    @staticmethod
    def _write_manifest(path: Path, manifest: dict) -> None:
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(
            json.dumps(manifest, indent=2, default=str),
            encoding="utf-8",
        )
        os.replace(temp, path)

    @staticmethod
    def _to_info(manifest: dict) -> BackupInfo:
        return BackupInfo(
            id=int(manifest["id"]),
            filename=str(manifest["filename"]),
            size=int(manifest.get("size") or 0),
            created_at=datetime.fromisoformat(str(manifest["created_at"])),
            sha256=manifest.get("sha256"),
            schema_revision=manifest.get("schema_revision"),
            pg_dump_version=manifest.get("pg_dump_version"),
            app_version=manifest.get("app_version"),
        )

    def _schema_revision(self) -> str | None:
        """Current alembic revision, or ``None`` on a bare database."""
        try:
            row = self.db.execute(
                text("SELECT version_num FROM alembic_version")
            ).first()
        except Exception:
            # No alembic_version yet (bare database) — nothing to report.
            self.db.rollback()
            return None
        return str(row[0]) if row else None

    def _tool_version(self) -> str | None:
        try:
            return self.runner.version() or None
        except AppError:
            return None

    def _database_name(self) -> str | None:
        """Which database the dump covers — recorded for the operator."""
        try:
            return DbParams.from_url(settings.DATABASE_URL).dbname
        except ValueError:
            # Non-Postgres URL (unit tests run on SQLite); not a failure.
            return None
