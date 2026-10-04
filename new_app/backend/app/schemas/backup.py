"""Backup schemas (Phase 17, §17.2).

Contract source: ``PHASE_0_API_BLUEPRINT.md`` §Backups —

* ``POST /api/v1/backups`` → ``{id, filename, size, created_at}``
* ``GET  /api/v1/backups`` → list
* ``POST /api/v1/backups/{id}/restore`` → full database restore

``sha256`` / ``schema_revision`` / ``pg_dump_version`` / ``app_version`` are
additive: they let the client show *what* a backup was taken from and let
the server prove a file has not been tampered with before restoring it.
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


class BackupRestoreResponse(StrictBaseModel):
    """``POST /api/v1/backups/{id}/restore``."""

    restored: bool = True
    backup: BackupInfo
    schema_revision: str | None = Field(
        default=None,
        description="alembic revision reported by the restored database",
    )
