"""Backup schemas (Phase 17, §17.2).

Contract source: ``PHASE_0_API_BLUEPRINT.md`` §Backups —

* ``POST /api/v1/backups`` → ``{id, filename, size, created_at}``
* ``GET  /api/v1/backups`` → list
* ``POST /api/v1/backups/{id}/restore`` → full database restore

``sha256`` / ``schema_revision`` / ``pg_dump_version`` / ``app_version`` are
additive: they let the client show *what* a backup was taken from and let
the server prove a file has not been tampered with before restoring it.

Objective 2 additions (all additive, never renaming a field):

* ``RestoreRequest``   — an explicit ``confirm: true`` is required before
  the live database is touched; a bare POST is refused with
  ``RESTORE_CONFIRMATION_REQUIRED``.
* ``BackupInspect``    — integrity (file present, SHA-256 still matches)
  and compatibility (schema revision vs the running app) summary shown in
  the confirmation dialog *before* the operator confirms.
* ``Portable archive`` — download returns a ZIP holding the dump plus its
  manifest; upload accepts that ZIP (or a raw ``.sql``) and stages it as
  a first-class backup with a freshly computed hash.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import Field

from app.schemas.common import StrictBaseModel


class BackupInfo(StrictBaseModel):
    """One backup as listed by ``GET /api/v1/backups``."""

    id: int = Field(description="Stable identifier, allocated at creation")
    filename: str = Field(description="Dump filename inside the backup dir")
    size: int = Field(ge=0, description="Size of the dump in bytes")
    created_at: datetime = Field(description="UTC creation time")
    sha256: str | None = Field(
        default=None,
        description="SHA-256 of the dump, verified before a restore",
    )
    schema_revision: str | None = Field(
        default=None,
        description="alembic revision the dump was taken at",
    )
    pg_dump_version: str | None = None
    app_version: str | None = None


class BackupListResponse(StrictBaseModel):
    """``GET /api/v1/backups`` — newest first."""

    items: list[BackupInfo]
    count: int = Field(description="Number of backups on the server")


class RestoreRequest(StrictBaseModel):
    """``POST /api/v1/backups/{id}/restore`` body.

    ``confirm`` MUST be ``true``: restoring replaces every row of the live
    database, so the API refuses a request that does not carry the
    operator's explicit confirmation (the UI collects it in a dialog that
    shows the :class:`BackupInspect` summary first).
    """

    confirm: bool = False


class BackupInspect(StrictBaseModel):
    """``GET /api/v1/backups/{id}/inspect`` — pre-restore summary.

    Everything the confirmation dialog needs to state honestly what will
    happen: whether the file is still the file that was recorded, and
    whether its schema matches the running application.
    """

    backup: BackupInfo
    file_present: bool = Field(
        description="False when the manifest exists but the dump was removed"
    )
    sha256_ok: bool | None = Field(
        default=None,
        description=(
            "Recomputed SHA-256 vs the recorded one; None when the "
            "manifest carries no hash (hand-copied dump)."
        ),
    )
    format_version: int | None = Field(
        default=None,
        description=(
            "Manifest format version: 1 (legacy, unsigned) or 2 "
            "(signed); None when the sidecar is missing."
        ),
    )
    signature_ok: bool | None = Field(
        default=None,
        description=(
            "v2 Ed25519 signature verdict; None for v1 manifests, "
            "which carry no signature. False means the document was "
            "modified and a restore will be refused."
        ),
    )
    current_schema_revision: str | None = Field(
        default=None,
        description="alembic revision of the running database",
    )
    schema_compatible: bool | None = Field(
        default=None,
        description=(
            "True when both revisions are known and equal; None when "
            "either side is unknown (never guessed)."
        ),
    )
    warnings: list[str] = Field(
        default_factory=list,
        description="Human-readable risks (missing file, hash drift, ...)",
    )


class BackupRestoreResponse(StrictBaseModel):
    """``POST /api/v1/backups/{id}/restore``."""

    restored: bool = True
    backup: BackupInfo
    schema_revision: str | None = Field(
        default=None,
        description="alembic revision reported by the restored database",
    )
    safety_backup: BackupInfo | None = Field(
        default=None,
        description=(
            "Automatic pre-restore snapshot of the database as it was "
            "before this restore replaced it."
        ),
    )
    post_restore_ok: bool = Field(
        default=True,
        description="True when the database answered a connectivity check after the replay",
    )
