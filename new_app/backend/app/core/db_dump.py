"""PostgreSQL dump / restore helpers (Phase 17, §17.2).

Why `pg_dump` and not a hand-rolled `COPY`-every-table export: ``pg_dump``
is the only supported way to take a *consistent* logical backup of a
PostgreSQL database (it takes per-transaction snapshots, emits the schema,
sequences, constraints and ``alembic_version`` together, and its output is
the documented restore format).  Reimplementing that would silently produce
backups that cannot be restored.

Only the standard library is used — ``subprocess`` + ``shutil.which`` — so
no new dependency is introduced.

Binary discovery order (this machine has PostgreSQL 18 installed but
``pg_dump`` is **not** on ``PATH``):

1. an explicit path from ``PG_DUMP_PATH`` / ``PSQL_PATH``;
2. ``PATH`` (``shutil.which``);
3. ``C:\\Program Files\\PostgreSQL\\<ver>\\bin`` (highest version first),
   and the ``Program Files (x86)`` equivalent.

The password travels in the ``PGPASSWORD`` environment variable, never in
argv, and is never logged.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse

import structlog

from app.core.config import settings
from app.core.exceptions import ServiceUnavailableError

logger = structlog.get_logger(__name__)

#: Well-known Windows install roots, probed newest-version-first.
_PG_TOOL_ROOTS = (
    Path(r"C:\Program Files\PostgreSQL"),
    Path(r"C:\Program Files (x86)\PostgreSQL"),
)


def find_pg_tool(name: str, override: str = "") -> Path | None:
    """Locate a PostgreSQL client binary, or ``None`` when absent.

    ``name`` is the tool without extension (``pg_dump`` / ``psql``).
    ``override`` is the configured absolute path (``PG_DUMP_PATH`` etc.).
    """
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_file():
            return candidate
        logger.warning("pg_tool_override_missing", tool=name, path=override)
    on_path = shutil.which(name)
    if on_path:
        return Path(on_path)
    for root in _PG_TOOL_ROOTS:
        if not root.is_dir():
            continue
        try:
            candidates = sorted(root.glob(f"*/bin/{name}.exe"), reverse=True)
        except OSError:  # pragma: no cover - unreadable install dir
            continue
        for candidate in candidates:
            if candidate.is_file():
                return candidate
    return None


def require_pg_tool(name: str, override: str = "") -> Path:
    """Same as :func:`find_pg_tool` but raises a 503 when it is missing."""
    tool = find_pg_tool(name, override)
    if tool is None:
        raise ServiceUnavailableError(
            f"{name} was not found on this server. Install PostgreSQL "
            f"client tools, or set {name.upper()}_PATH in .env.",
            details={"tool": name},
        )
    return tool


@dataclass(frozen=True)
class DbParams:
    """Connection parameters parsed out of ``DATABASE_URL``."""

    host: str
    port: int
    dbname: str
    user: str
    password: str

    @classmethod
    def from_url(cls, url: str) -> DbParams:
        parsed = urlparse(url)
        if not parsed.scheme.startswith("postgres"):
            raise ValueError(f"unsupported database scheme: {parsed.scheme!r}")
        path = (parsed.path or "").lstrip("/")
        return cls(
            host=parsed.hostname or "localhost",
            port=parsed.port or 5432,
            dbname=path.split("/")[0],
            user=unquote(parsed.username or "postgres"),
            password=unquote(parsed.password or ""),
        )

    def tool_env(self) -> dict[str, str]:
        """Environment for a client subprocess.

        Connection details travel as ``PG*`` variables and the password as
        ``PGPASSWORD`` — never in argv, where ``ps`` would expose it.  The
        explicit ``PGDATABASE``/``PGHOST``/... entries matter because they
        stop the tools from silently falling back to the OS username or to
        whatever ``DATABASE_URL`` the operator happens to have exported.
        """
        env = dict(os.environ)
        env["PGHOST"] = self.host
        env["PGPORT"] = str(self.port)
        env["PGDATABASE"] = self.dbname
        env["PGUSER"] = self.user
        env["PGPASSWORD"] = self.password
        return env

    def safe_repr(self) -> str:
        """Connection info without the password — the only form to log."""
        return f"postgresql://{self.user}@{self.host}:{self.port}/{self.dbname}"


def sha256_of(path: Path) -> str:
    """Streaming SHA-256 so a multi-GB dump never lands in memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class DumpRunner:
    """Runs ``pg_dump`` / ``psql`` for one database.

    Injectable so the service can be unit-tested without shelling out; a
    real run is exercised by ``tests/integration/test_backup_dump.py``.
    """

    def __init__(
        self,
        params: DbParams | None = None,
        timeout: int | None = None,
    ):
        self._params = params
        self._timeout = timeout or settings.BACKUP_TIMEOUT_SECONDS

    @property
    def params(self) -> DbParams:
        if self._params is None:
            self._params = DbParams.from_url(settings.DATABASE_URL)
        return self._params

    # -- dump --------------------------------------------------------------

    def dump(self, destination: Path) -> None:
        """Write a plain-SQL dump to ``destination``.

        The dump goes to a temporary file first and is renamed only on
        success, so a failed/interrupted run can never be mistaken for a
        restorable backup.

        ``--clean --if-exists`` makes the output self-restoring: `psql`
        can replay it over a live schema in a single transaction.
        """
        pg_dump = require_pg_tool("pg_dump", settings.PG_DUMP_PATH)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temp = destination.with_suffix(destination.suffix + ".partial")
        if temp.exists():
            temp.unlink()

        command = [
            str(pg_dump),
            "--format=plain",
            "--clean",
            "--if-exists",
            "--no-owner",
            "--no-privileges",
            "--file",
            str(temp),
        ]
        try:
            self._run(command)
        except Exception:
            if temp.exists():
                temp.unlink()
            raise

        os.replace(temp, destination)

    # -- restore -----------------------------------------------------------

    def restore(self, source: Path) -> None:
        """Replay ``source`` over the configured database.

        ``--single-transaction`` gives the blueprint's "full database
        restore" its atomicity: any statement error aborts the whole
        restore and leaves the database exactly as it was.
        """
        psql = require_pg_tool("psql", settings.PSQL_PATH)
        if not source.is_file():
            raise FileNotFoundError(str(source))
        command = [
            str(psql),
            "--single-transaction",
            "--no-psqlrc",
            "--set=ON_ERROR_STOP=1",
            "--file",
            str(source),
        ]
        self._run(command)

    def version(self) -> str:
        """``pg_dump --version`` output, recorded in the manifest."""
        pg_dump = require_pg_tool("pg_dump", settings.PG_DUMP_PATH)
        return self._run([str(pg_dump), "--version"]).strip()

    # -- internals ---------------------------------------------------------

    def _run(self, command: list[str]) -> str:
        params = self.params
        logger.info(
            "pg_tool_exec",
            tool=Path(command[0]).name,
            target=params.safe_repr(),
            timeout=self._timeout,
        )
        try:
            completed = subprocess.run(
                command,
                env=params.tool_env(),
                capture_output=True,
                text=True,
                timeout=self._timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise ServiceUnavailableError(
                f"{Path(command[0]).name} timed out after "
                f"{self._timeout}s",
                details={"tool": Path(command[0]).name},
            ) from exc
        except OSError as exc:  # pragma: no cover - binary vanished
            raise ServiceUnavailableError(
                f"{Path(command[0]).name} could not be started: {exc}",
                details={"tool": Path(command[0]).name},
            ) from exc

        if completed.returncode != 0:
            # stderr is safe to surface: pg_dump/psql never echo the
            # password, and PGPASSWORD is not part of argv.
            raise ServiceUnavailableError(
                f"{Path(command[0]).name} failed: "
                f"{completed.stderr.strip() or completed.stdout.strip()}",
                details={
                    "tool": Path(command[0]).name,
                    "returncode": completed.returncode,
                },
            )
        return completed.stdout
