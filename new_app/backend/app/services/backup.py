"""Backup / restore service (Phase 17, §17.2 + Objective 2).

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
* **Objective 2 — confirmation & safety net**: a restore now requires an
  explicit ``confirm: true``; before the dump is replayed the current
  database is snapshotted once more (the *safety backup*) so a mistaken
  restore is itself undoable; after the replay a cheap connectivity check
  runs and its outcome is reported (never hidden).
* **Objective 2 — portable archive**: ``download`` returns a ZIP holding
  the dump and its manifest together (one file to move between machines);
  ``upload`` accepts that ZIP — or a raw ``.sql`` — validates it the same
  way an adopted file is validated, and stages it as a first-class backup
  with a freshly computed hash and a new id.  Integrity (hash) and
  compatibility (schema revision vs the running app) are surfaced by
  ``inspect`` *before* the operator confirms anything.
* **Audit**: creating a backup that cannot be audited is rolled back (the
  files are deleted and the request fails).  A restore cannot be undone,
  so its audit row is written afterwards and a failure there is logged
  loudly instead of reported as a failed restore — reporting "restore
  failed" when the data has already been replaced would be a lie.
* **Licensing (Phase L1-D, defense-in-depth)**: every public method
  opens with ``require_backup_action(...)``, the same §4.4 matrix the
  router guard applies.  The check reads the server's own ``trial.state``
  (never a client-supplied status), runs before a dump is taken, before
  an uploaded byte is accepted and before any destructive restore work
  begins, and is a complete no-op while ``LICENSE_ENFORCEMENT=off``.
  Backup files stay portable across machines: nothing here reads a
  hardware fingerprint, and neither license state nor activation codes
  are ever written into an archive or a manifest.
* **Manifest v2 (Phase L3, audit §8)**: ``create``/``upload`` write a
  signed v2 sidecar (``format_version``/``payload_sha256``/``created_by``
  /``signature``/``key_id``/``public_key`` — all additive, every v1 key
  unchanged) through the ``backup_manifest`` module; ``restore``
  verifies the document *before* any destructive work (v1 keeps the
  SHA-256 + structural path, unknown versions are refused, never
  reinterpreted) and ``inspect`` reports the version and signature
  verdict.  The signing key lives in the licensing state directory and
  is never read for verification — a foreign install validates an
  archive from its embedded public key alone, so portability and the
  no-fingerprint rule above are preserved.  That module (not this
  service) reaches into the licensing state: ``BackupService`` still
  consults only the §4.4 policy, exactly as Phase L1-D required.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import structlog
from sqlalchemy import text

from app.core.config import BACKEND_ROOT, settings
from app.core.db_dump import DbParams, DumpRunner, sha256_of
from app.core.exceptions import (
    AppError,
    BusinessRuleError,
    NotFoundError,
    ValidationError,
)
from app.core.filenames import sanitize_filename
from app.licensing.backup_policy import require_backup_action
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.schemas.backup import (
    BackupInfo,
    BackupInspect,
    BackupListResponse,
    BackupRestoreResponse,
)
from app.services.backup_manifest import (
    FORMAT_VERSION,
    SIGNATURE_INVALID,
    finalize_manifest,
    verify_manifest,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

_MANIFEST_SUFFIX = ".json"
_SQL_SUFFIX = ".sql"
_ARCHIVE_SUFFIX = ".zip"

#: Upload cap — a plain-SQL dump of a supermarket database stays far
#: below this; anything larger is refused before it is buffered.
MAX_UPLOAD_BYTES = 200 * 1024 * 1024

#: Members a portable archive is allowed to contain (nothing else is
#: extracted — a ZIP is untrusted input).
_ARCHIVE_DUMP_MEMBER = "dump.sql"
_ARCHIVE_MANIFEST_MEMBER = "manifest.json"


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

    @staticmethod
    def _runtime_root() -> Path:
        """Writable data root: ``DATA_DIR`` (production) or the backend
        root (development) — R1 keeps backups out of Program Files."""
        raw = (getattr(settings, "DATA_DIR", "") or "").strip()
        return Path(raw) if raw else Path(BACKEND_ROOT)

    @property
    def directory(self) -> Path:
        """Absolute backup directory (never depends on the CWD).

        An explicit ``directory`` passed to the constructor wins; otherwise
        ``BACKUP_DIR`` from settings; otherwise the default under the
        writable data root — ``<DATA_DIR>/backups`` in production (R1),
        ``<backend>/backups`` in development.
        """
        root = self._runtime_root()
        if self._directory is not None:
            path = self._directory
            if not path.is_absolute():
                path = root / path
            return path
        raw = settings.BACKUP_DIR.strip()
        path = Path(raw) if raw else root / "backups"
        if not path.is_absolute():
            path = root / path
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
        # Phase L1-D: licensing is decided here too, so a direct service
        # call cannot create a backup the router guard would refuse.
        require_backup_action("create")
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
        # Phase L3 (audit §8): every backup this install creates is a
        # signed v2 manifest; the v1 keys above stay byte-compatible so
        # older builds keep reading the document.
        manifest = finalize_manifest(manifest)
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
        require_backup_action("list")
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
        confirm: bool = False,
        actor_id: uuid.UUID | None = None,
    ) -> BackupRestoreResponse:
        """Replay one backup over the live database.

        Objective 2: an explicit ``confirm`` is required; the current
        database is snapshotted once more (safety backup) *before* the
        replay so a mistaken restore is itself undoable; a cheap
        connectivity check runs afterwards and is reported, never hidden.

        Phase L1-D: the licensing check is the **first** statement — a
        refused restore must be decided before the confirmation gate, the
        safety snapshot or anything else touches the database.
        """
        require_backup_action("restore")
        if not confirm:
            raise BusinessRuleError(
                "Restoring replaces the entire database. Send "
                "confirm: true after reviewing the backup details.",
                details={"required_field": "confirm"},
                code="RESTORE_CONFIRMATION_REQUIRED",
            )

        entries = self.list().items
        info = next((entry for entry in entries if entry.id == backup_id), None)
        if info is None:
            raise NotFoundError(f"backup {backup_id} does not exist")

        path = self.directory / info.filename
        if not path.is_file():
            raise NotFoundError(f"backup file missing: {info.filename}")

        # Phase L3 (audit §8): verify the manifest BEFORE any restore
        # work — a v2 document must carry a valid signature, an unknown
        # format_version is refused (never reinterpreted), and a v1
        # document falls through to the hash + structural checks below.
        manifest_doc = self._read_manifest(
            path.with_suffix(_MANIFEST_SUFFIX)
        )
        if manifest_doc is not None:
            verify_manifest(manifest_doc)

        if info.sha256:
            actual = sha256_of(path)
            if actual != info.sha256:
                raise BusinessRuleError(
                    "This backup has been modified since it was created "
                    "and will not be restored.",
                    details={"filename": info.filename},
                )

        # Structural check (audit §8): whatever the manifest version,
        # the payload must still look like a pg_dump script before it is
        # replayed over the live database.
        with path.open("rb") as handle:
            head = handle.read(8192)
        if not self._looks_like_sql(head):
            raise ValidationError(
                "This backup does not contain a SQL dump and will not "
                "be restored.",
                details={"filename": info.filename},
                code="BACKUP_RESTORE_INVALID",
            )

        # Safety net: snapshot the database as it is RIGHT NOW, so the
        # restore itself can be undone.  A failed snapshot aborts the
        # restore — replaying without a way back is exactly the situation
        # this feature exists to prevent.
        safety: BackupInfo | None = None
        try:
            safety = self.create(actor_id=actor_id)
        except AppError as exc:
            logger.error(
                "restore_safety_backup_failed",
                id=backup_id,
                error=str(exc),
            )
            raise BusinessRuleError(
                "A safety backup of the current database could not be "
                "taken, so the restore was cancelled. Nothing was changed.",
                details={"filename": info.filename},
                code="RESTORE_SAFETY_BACKUP_FAILED",
            ) from exc

        logger.info("backup_restore_started", id=backup_id, filename=info.filename)
        self.runner.restore(path)

        # Everything the request's session had read belongs to the
        # pre-restore database — drop it before touching the data again.
        self.db.rollback()

        # Post-restore check: the database must answer a trivial query.
        # The restore itself already committed (psql --single-transaction);
        # a failed check is reported, not swallowed, and never rewrites the
        # outcome to "failed" — the data has been replaced either way.
        post_ok = self._post_restore_check()

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
                            {
                                "id": backup_id,
                                "filename": info.filename,
                                "safety_backup_id": safety.id if safety else None,
                            }
                        ),
                        after_state=json.dumps(
                            {
                                "schema_revision": revision,
                                "post_restore_ok": post_ok,
                            },
                            default=str,
                        ),
                    )
                )
        except AppError:
            logger.error(
                "restore_audit_failed",
                id=backup_id,
                filename=info.filename,
            )

        logger.info(
            "backup_restore_done",
            id=backup_id,
            revision=revision,
            post_restore_ok=post_ok,
        )
        return BackupRestoreResponse(
            restored=True,
            backup=info,
            schema_revision=revision,
            safety_backup=safety,
            post_restore_ok=post_ok,
        )

    # -- inspect -----------------------------------------------------------

    def inspect(self, backup_id: int) -> BackupInspect:
        """Integrity + compatibility summary for the confirmation dialog."""
        require_backup_action("inspect")
        entries = self.list().items
        info = next((entry for entry in entries if entry.id == backup_id), None)
        if info is None:
            # The dump may be gone while its manifest remains — reporting
            # exactly that is the point of inspect, so fall back to the
            # sidecar instead of 404ing on a half-deleted backup.
            info = self._info_from_manifest(backup_id)
        if info is None:
            raise NotFoundError(f"backup {backup_id} does not exist")

        path = self.directory / info.filename
        file_present = path.is_file()
        sha_ok: bool | None = None
        warnings: list[str] = []

        if not file_present:
            warnings.append(
                "The dump file is missing from the backup directory; "
                "this backup cannot be restored."
            )
        elif info.sha256:
            sha_ok = sha256_of(path) == info.sha256
            if not sha_ok:
                warnings.append(
                    "The dump no longer matches the hash recorded when it "
                    "was created; restoring it will be refused."
                )
        else:
            warnings.append(
                "This backup has no recorded hash (it was copied in by "
                "hand); its integrity cannot be proven."
            )

        # Phase L3: surface the manifest version and, for v2, the
        # signature verdict.  An unsupported or malformed document is
        # refused outright; a bad signature is *reported* here so the
        # operator sees why — restore is where it becomes a hard refusal.
        format_version: int | None = None
        signature_ok: bool | None = None
        manifest_doc = self._read_manifest(
            path.with_suffix(_MANIFEST_SUFFIX)
        )
        if manifest_doc is not None:
            try:
                format_version = verify_manifest(manifest_doc)
            except ValidationError as exc:
                if exc.code != SIGNATURE_INVALID:
                    raise
                format_version = FORMAT_VERSION
                signature_ok = False
                warnings.append(
                    "The manifest signature does not verify; this backup "
                    "has been modified and restoring it will be refused."
                )
            else:
                signature_ok = True if format_version == 2 else None

        current_revision = self._schema_revision()
        compatible: bool | None = None
        if info.schema_revision and current_revision:
            compatible = info.schema_revision == current_revision
            if not compatible:
                warnings.append(
                    f"Schema mismatch: the backup was taken at revision "
                    f"{info.schema_revision} but the server is running "
                    f"{current_revision}."
                )
        elif info.schema_revision is None:
            warnings.append(
                "This backup does not record the schema revision it was "
                "taken at; compatibility cannot be checked."
            )

        return BackupInspect(
            backup=info,
            file_present=file_present,
            sha256_ok=sha_ok,
            format_version=format_version,
            signature_ok=signature_ok,
            current_schema_revision=current_revision,
            schema_compatible=compatible,
            warnings=warnings,
        )

    # -- download (portable archive) ---------------------------------------

    def download(self, backup_id: int) -> tuple[bytes, str]:
        """Build a portable ZIP (dump + manifest) for one backup.

        Returns ``(zip_bytes, filename)``.  The archive is what an
        operator moves to another machine; ``upload`` accepts it back.
        """
        require_backup_action("download")
        entries = self.list().items
        info = next((entry for entry in entries if entry.id == backup_id), None)
        if info is None:
            raise NotFoundError(f"backup {backup_id} does not exist")

        path = self.directory / info.filename
        if not path.is_file():
            raise NotFoundError(f"backup file missing: {info.filename}")

        manifest_path = path.with_suffix(_MANIFEST_SUFFIX)
        manifest_bytes = (
            manifest_path.read_bytes() if manifest_path.is_file() else b"{}"
        )

        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(_ARCHIVE_DUMP_MEMBER, path.read_bytes())
            archive.writestr(_ARCHIVE_MANIFEST_MEMBER, manifest_bytes)

        archive_name = sanitize_filename(
            f"backup_{info.id}_{path.stem}{_ARCHIVE_SUFFIX}"
        )
        logger.info("backup_download", id=backup_id, filename=archive_name)
        return buffer.getvalue(), archive_name

    # -- upload (stage a portable archive or raw dump) ----------------------

    def upload(
        self,
        *,
        content: bytes,
        filename: str,
        actor_id: uuid.UUID | None = None,
    ) -> BackupInfo:
        """Stage an uploaded archive/dump as a first-class backup.

        Accepts a portable ZIP (``dump.sql`` + ``manifest.json``) or a
        raw ``.sql``.  Validation mirrors adoption: the file must be
        non-empty and plausibly SQL; the id is always re-allocated on
        this server (an uploaded file never claims an existing id); the
        hash is recomputed here, never trusted from the upload.

        Phase L1-D: the licensing check runs **before** anything else —
        a refused upload must not be read, validated or persisted.
        """
        require_backup_action("upload")
        if len(content) > MAX_UPLOAD_BYTES:
            raise ValidationError(
                "The uploaded backup exceeds the size limit.",
                details={"bytes": len(content), "limit": MAX_UPLOAD_BYTES},
                code="BACKUP_UPLOAD_TOO_LARGE",
            )
        if not content:
            raise ValidationError(
                "The uploaded file is empty.", code="BACKUP_UPLOAD_EMPTY"
            )

        if filename.lower().endswith(_ARCHIVE_SUFFIX):
            dump_bytes, carried_manifest = self._extract_archive(content)
        else:
            dump_bytes, carried_manifest = content, None

        if not self._looks_like_sql(dump_bytes):
            raise ValidationError(
                "The uploaded file does not look like a SQL dump.",
                details={"filename": filename},
                code="BACKUP_UPLOAD_INVALID",
            )

        # Phase L3: a carried v2 manifest must verify against these exact
        # bytes before anything is written to disk — a tampered, malformed
        # or unsupported document is refused, never reinterpreted and
        # never silently downgraded to v1.
        if carried_manifest is not None:
            verify_manifest(
                carried_manifest,
                expected_sha256=hashlib.sha256(dump_bytes).hexdigest(),
            )

        directory = self.directory
        directory.mkdir(parents=True, exist_ok=True)
        entries = self.list().items
        next_id = max(
            [entry.id for entry in entries] + self.list_ids(),
            default=0,
        ) + 1

        base_name = Path(sanitize_filename(filename or "uploaded.sql")).stem
        base_name = base_name.removesuffix(".backup") or "uploaded"
        sql_name = self._unique_name(directory, base_name)
        path = directory / sql_name
        path.write_bytes(dump_bytes)

        manifest = {
            "id": next_id,
            "filename": sql_name,
            "size": path.stat().st_size,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "sha256": sha256_of(path),
            "schema_revision": (carried_manifest or {}).get("schema_revision"),
            "pg_dump_version": (carried_manifest or {}).get("pg_dump_version"),
            "app_version": (carried_manifest or {}).get("app_version"),
            "database": (carried_manifest or {}).get("database"),
            "uploaded_from": sanitize_filename(filename or "upload", max_length=120),
        }
        # Phase L3: the staged copy becomes a first-class v2 backup of
        # THIS install — freshly signed here; the origin document's
        # signature travels only inside the original archive.
        manifest = finalize_manifest(manifest)
        self._write_manifest(directory / (path.stem + _MANIFEST_SUFFIX), manifest)

        try:
            with self.transaction():
                self.db.add(
                    AuditLog(
                        user_id=actor_id,
                        action=AuditAction.BACKUP_UPLOAD.value,
                        entity_type="backup",
                        details=sql_name,
                        after_state=json.dumps(manifest, default=str),
                    )
                )
        except AppError:
            path.unlink(missing_ok=True)
            (directory / (path.stem + _MANIFEST_SUFFIX)).unlink(missing_ok=True)
            logger.error("backup_upload_audit_failed", filename=sql_name)
            raise

        logger.info("backup_uploaded", id=next_id, filename=sql_name)
        return BackupInfo(**manifest)

    # -- helpers -----------------------------------------------------------

    @staticmethod
    def _extract_archive(content: bytes) -> tuple[bytes, dict | None]:
        """Pull ``dump.sql`` (+ optional manifest) out of a portable ZIP.

        Only the two well-known members are ever read; nothing is written
        to disk here.  A ZIP without a dump member is refused.
        """
        try:
            with zipfile.ZipFile(io.BytesIO(content)) as archive:
                names = set(archive.namelist())
                if _ARCHIVE_DUMP_MEMBER not in names:
                    raise ValidationError(
                        "The archive does not contain dump.sql.",
                        details={"members": sorted(names)[:20]},
                        code="BACKUP_UPLOAD_INVALID",
                    )
                dump_bytes = archive.read(_ARCHIVE_DUMP_MEMBER)
                manifest: dict | None = None
                if _ARCHIVE_MANIFEST_MEMBER in names:
                    try:
                        parsed = json.loads(
                            archive.read(_ARCHIVE_MANIFEST_MEMBER).decode("utf-8")
                        )
                        if isinstance(parsed, dict):
                            manifest = parsed
                    except (ValueError, UnicodeDecodeError):
                        manifest = None
        except zipfile.BadZipFile as exc:
            raise ValidationError(
                "The uploaded file is not a valid ZIP archive.",
                code="BACKUP_UPLOAD_INVALID",
            ) from exc
        return dump_bytes, manifest

    @staticmethod
    def _looks_like_sql(content: bytes) -> bool:
        """Cheap sanity check — enough to reject a random binary file.

        A ``pg_dump`` plain script always carries SQL keywords in its
        first few kilobytes; anything else (an EXE, a JPEG, a truncated
        upload) does not.
        """
        head = content[:8192].lower()
        markers = (
            b"create table",
            b"create index",
            b"create sequence",
            b"copy ",
            b"insert into",
            b"alter table",
            b"drop table",
            b"set ",
            b"begin;",
            b"--\n-- postgresql database dump",
        )
        return any(marker in head for marker in markers)

    def _unique_name(self, directory: Path, base: str) -> str:
        candidate = f"{base}{_SQL_SUFFIX}"
        suffix = 2
        while (directory / candidate).exists():
            candidate = f"{base}_{suffix}{_SQL_SUFFIX}"
            suffix += 1
        return candidate

    def _info_from_manifest(self, backup_id: int) -> BackupInfo | None:
        """Look up a backup by its sidecar alone (dump may be missing)."""
        directory = self.directory
        if not directory.is_dir():
            return None
        for manifest_path in directory.glob(f"*{_MANIFEST_SUFFIX}"):
            manifest = self._read_manifest(manifest_path)
            if manifest is not None and int(manifest["id"]) == backup_id:
                return self._to_info(manifest)
        return None

    def _post_restore_check(self) -> bool:
        """Trivial liveness probe after a restore (never raises)."""
        try:
            self.db.execute(text("SELECT 1"))
            return True
        except Exception:
            logger.error("post_restore_check_failed")
            try:
                self.db.rollback()
            except Exception:  # noqa: BLE001 - best effort cleanup
                pass
            return False

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
