"""PostgreSQL provisioning and database lifecycle (R3 §3–§5).

Three separate concerns live here, deliberately kept apart from
:mod:`app.main` so that **ordinary backend startup never provisions,
never migrates and never seeds** (that is asserted by the R3 test
suite):

``provision_database``
    The idempotent lifecycle entry point used by the installer / an
    operator.  It reuses an existing server when discovery says one is
    usable, creates the target database **only when it is absent**, runs
    the migration chain **only when explicitly asked**, and initialises
    RBAC **only when explicitly asked**.  Every step is recorded in a
    :class:`ProvisioningReport` that carries no secrets.

``plan_provisioning``
    A pure read-only assessment (discovery only, no connection) that
    answers *reuse* / *install a dedicated instance* / *fail*, with the
    reason.  Used for ``--plan`` and for the actionable error message
    when nothing usable was found.

``DedicatedInstanceSpec``
    The **testable, fail-closed provisioning adapter** for the case
    where no server can be reused (§3).  It never executes anything by
    default: running the EDB installer requires ``execute=True`` *and*
    the ``R3_ALLOW_POSTGRESQL_INSTALL=1`` gate *and* a staged installer
    whose SHA-256 matches the pinned checksum.  R3 does not install
    PostgreSQL on the development machine, so this path is exercised by
    tests only in its refusing / command-building form.

Safety rules honoured throughout:

* no ``DROP DATABASE``, no ``DROP SCHEMA``, no ``TRUNCATE``, no
  ``DELETE`` — a test scans this module's source for them;
* passwords travel in ``PGPASSWORD``-style environment or in
  ``E'...'``-quoted literals built by :func:`_quote_literal`, never in
  argv, and are scrubbed out of every error message and log line;
* connection failures are classified (bad credentials vs. no server)
  so the operator gets an actionable message instead of a stack trace.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import structlog
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from app.core.config import BACKEND_ROOT, settings
from app.core.db_dump import DbParams
from app.core.postgres_discovery import (
    VERIFIED_MAX_MAJOR,
    PostgresInstance,
    check_compatibility,
    discover_instances,
    select_instance,
)

logger = structlog.get_logger(__name__)

# ── Status vocabulary for report steps ──────────────────────────────────

STEP_APPLIED = "applied"
STEP_SKIPPED = "skipped"
STEP_FAILED = "failed"
STEP_PLANNED = "planned"

#: Hosts that mean "the server lives on this machine" — only then does
#: local discovery apply (a remote server is the operator's business).
LOCAL_HOSTS: frozenset[str] = frozenset({"", "localhost", "127.0.0.1", "::1"})

#: PostgreSQL identifiers we are willing to interpolate into DDL.
_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")

#: How long one ``alembic upgrade`` subprocess may run.
_MIGRATION_TIMEOUT_SECONDS = 900

#: Environment gate for the dedicated-installer adapter (§3).  Two
#: independent conditions must be true, on purpose.
INSTALL_GATE_ENV = "R3_ALLOW_POSTGRESQL_INSTALL"

#: Where a staged installer may live.  Never Program Files (R1: the
#: install tree is read-only for the service account).
def installer_staging_dir() -> Path:
    root = Path(settings.DATA_DIR) if settings.DATA_DIR else BACKEND_ROOT
    return root / "installers"


class ProvisioningError(RuntimeError):
    """Base class for every R3 provisioning failure (fail closed)."""

    def __init__(self, message: str, *, report: ProvisioningReport | None = None):
        super().__init__(message)
        self.report = report


class InstanceUnavailableError(ProvisioningError):
    """No reusable PostgreSQL server could be selected (§2/§3)."""


class IncompatibleVersionError(ProvisioningError):
    """A server was found but the version policy refuses it (§2)."""


class CredentialsError(ProvisioningError):
    """The supplied database credentials were rejected or are unusable."""


class MigrationError(ProvisioningError):
    """``alembic upgrade`` failed; the database is left as it was."""


# ─────────────────────────────────────────────────────────────────────────
# Report model
# ─────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Step:
    """One recorded action of a provisioning pass."""

    name: str
    status: str
    detail: str = ""


@dataclass
class ProvisioningReport:
    """Everything a pass did — safe to print, safe to log (no secrets)."""

    database_name: str = ""
    target: str = ""
    steps: list[Step] = field(default_factory=list)
    instance_label: str | None = None
    instance_sources: list[str] = field(default_factory=list)
    database_created: bool = False
    role_created: bool = False
    revision_before: str | None = None
    revision_after: str | None = None
    migrations_applied: bool = False
    rbac: dict = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return all(step.status != STEP_FAILED for step in self.steps)

    @property
    def failed_step(self) -> Step | None:
        for step in self.steps:
            if step.status == STEP_FAILED:
                return step
        return None

    def add(self, name: str, status: str, detail: str = "") -> Step:
        step = Step(name=name, status=status, detail=detail)
        self.steps.append(step)
        return step

    def as_dict(self) -> dict:
        """JSON-ready view; guaranteed to contain no credential material."""
        return {
            "ok": self.ok,
            "database": self.database_name,
            "target": self.target,
            "instance": self.instance_label,
            "instance_sources": list(self.instance_sources),
            "database_created": self.database_created,
            "role_created": self.role_created,
            "revision_before": self.revision_before,
            "revision_after": self.revision_after,
            "migrations_applied": self.migrations_applied,
            "rbac": dict(self.rbac),
            "warnings": list(self.warnings),
            "steps": [
                {"name": step.name, "status": step.status, "detail": step.detail}
                for step in self.steps
            ],
        }


# ─────────────────────────────────────────────────────────────────────────
# Secret handling
# ─────────────────────────────────────────────────────────────────────────


def scrub(text: str, secrets: list[str] | tuple[str, ...]) -> str:
    """Remove every secret from ``text`` before it reaches a log or a user."""
    result = text or ""
    for secret in secrets:
        if secret:
            result = result.replace(secret, "***")
    return result


def _secrets_of(params: DbParams) -> list[str]:
    return [params.password] if params.password else []


def _quote_ident(value: str) -> str:
    """Double-quote a *validated* PostgreSQL identifier."""
    return '"' + value.replace('"', '""') + '"'


def _quote_literal(value: str) -> str:
    """Quote any string as an ``E'...'`` escape literal.

    ``E'...'`` always honours backslash escapes, so the result is correct
    with ``standard_conforming_strings`` either on or off — which matters
    because the value here is a password we did not choose.
    """
    escaped = value.replace("\\", "\\\\").replace("'", "\\'")
    return f"E'{escaped}'"


def _require_identifier(value: str, what: str) -> str:
    if not _IDENTIFIER_RE.match(value or ""):
        raise ProvisioningError(
            f"{what} must match {_IDENTIFIER_RE.pattern!r} — refusing to "
            f"build DDL from {value!r}"
        )
    return value


# ─────────────────────────────────────────────────────────────────────────
# Connection helpers
# ─────────────────────────────────────────────────────────────────────────


def build_url(
    *,
    user: str,
    password: str,
    host: str = "127.0.0.1",
    port: int = 5432,
    dbname: str = "postgres",
) -> str:
    """A PostgreSQL URL the password cannot break.

    Never interpolate a password into a URL by hand.  A real superuser
    password ending in ``@`` produced
    ``postgresql://postgres:secret@@127.0.0.1:5432/postgres``, which psycopg2
    read as an empty host ("socket @127.0.0.1/.s.PGSQL.5432") and the
    installer reported as "password rejected".  ``URL.create`` percent-encodes
    every reserved character (``@ : / % # ? &`` …) and ``DbParams.from_url``
    decodes it again with :func:`urllib.parse.unquote`.
    """
    from sqlalchemy.engine import URL

    return URL.create(
        drivername="postgresql",
        username=user,
        password=password,
        host=host,
        port=port,
        database=dbname,
    ).render_as_string(hide_password=False)


def maintenance_url(url: str, *, database: str = "postgres") -> str:
    """Same server and credentials, pointed at a maintenance database.

    ``CREATE DATABASE`` cannot run while connected to the database it is
    creating, and the target may not exist yet — so every existence check
    and every DDL statement goes through this URL.
    """
    from urllib.parse import urlparse, urlunparse

    parts = urlparse(url)
    return urlunparse(parts._replace(path=f"/{database}"))


def _connect(url: str, *, timeout: int = 15):
    """Open an autocommitted psycopg2 connection (DDL needs autocommit)."""
    import psycopg2

    conn = psycopg2.connect(url, connect_timeout=timeout)
    conn.autocommit = True
    return conn


class MalformedConnectionError(ProvisioningError):
    """The connection string itself could not be used (not an auth problem)."""


#: SQLSTATE codes that mean "the credentials were refused".
AUTH_SQLSTATES = frozenset({"28P01", "28000"})

#: Message fragments of a refused login (psql/psycopg2, any language keeps
#: the SQLSTATE but may translate the sentence).
AUTH_TOKENS = (
    "password authentication failed",
    "no password supplied",
    "authentication failed",
    "pg_hba.conf rejects",
    "role \"",
)

#: Fragments of a URL/DSN that could not be parsed at all.
MALFORMED_TOKENS = (
    "invalid dsn",
    "invalid connection string",
    "missing \"=\"",
    "invalid argument",        # socket "@host/.s.PGSQL" from a broken URL
    "invalid url",
    "could not parse",
    "empty host",
)

#: Fragments of a genuine "nothing is listening / not reachable" error.
UNREACHABLE_TOKENS = (
    "connection refused",
    "could not connect",
    "could not translate host name",
    "timeout expired",
    "connection timed out",
    "no route to host",
    "network is unreachable",
    "server closed the connection",
    "the database system is starting up",
)


def classify_connection_error(
    exc: Exception, params: DbParams
) -> ProvisioningError:
    """Classify a driver error without guessing (public entry point).

    Distinguishing these four cases is the difference between "type the
    password again" and "the installer built a broken URL":

    * credentials refused — SQLSTATE 28P01 / 28000 (locale-proof) or an
      authentication sentence → :class:`CredentialsError`;
    * unreachable server — refused/timeout/DNS → :class:`InstanceUnavailableError`;
    * unusable connection string — :class:`MalformedConnectionError`;
    * anything else — :class:`ProvisioningError` with the raw text.

    The raw driver text is always kept in the message (password scrubbed).
    """
    detail = scrub(str(exc), _secrets_of(params))
    lowered = detail.lower()
    sqlstate = getattr(exc, "pgcode", None) or getattr(exc, "sqlstate", None)
    if sqlstate in AUTH_SQLSTATES:
        return CredentialsError(
            f"the server refused the credentials for {params.safe_repr()} "
            f"(SQLSTATE {sqlstate}): {detail}"
        )
    if any(token in lowered for token in AUTH_TOKENS):
        return CredentialsError(
            f"the server refused the credentials for {params.safe_repr()} "
            f"({detail})"
        )
    if any(token in lowered for token in MALFORMED_TOKENS):
        return MalformedConnectionError(
            "the PostgreSQL connection string could not be used — this is an "
            "installer defect, not a password problem (passwords are "
            "percent-encoded before they reach a URL): "
            f"{detail}"
        )
    if any(token in lowered for token in UNREACHABLE_TOKENS):
        return InstanceUnavailableError(
            f"no PostgreSQL server is accepting connections on "
            f"{params.host}:{params.port} ({detail}); make sure the "
            "service is installed and running, then re-run provisioning"
        )
    return ProvisioningError(f"database connection failed: {detail}")


def _classify(exc: Exception, params: DbParams) -> ProvisioningError:
    """Backwards-compatible alias for :func:`classify_connection_error`."""
    return classify_connection_error(exc, params)


def check_connectivity(url: str, *, connect=None) -> DbParams:
    """Fail fast (and actionably) when the server/credentials are unusable."""
    params = DbParams.from_url(url)
    opener = connect or _connect
    try:
        conn = opener(maintenance_url(url))
    except Exception as exc:  # noqa: BLE001 - classified above
        raise _classify(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover - fake connections in tests
            pass
    return params


def database_exists(url: str, dbname: str, *, connect=None) -> bool:
    """True when ``dbname`` already exists on the server behind ``url``."""
    params = DbParams.from_url(url)
    opener = connect or _connect
    try:
        conn = opener(maintenance_url(url))
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
            return cursor.fetchone() is not None
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass


def ensure_role(
    url: str, role: str, password: str, *, connect=None
) -> bool:
    """Create the application login role when it is missing.

    Returns ``True`` only when a role was actually created, so a second
    run is a no-op.  The statement is never logged.
    """
    _require_identifier(role, "role name")
    if not password:
        raise CredentialsError("refusing to create a role without a password")
    params = DbParams.from_url(url)
    opener = connect or _connect
    try:
        conn = opener(maintenance_url(url))
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)
            )
            if cursor.fetchone() is not None:
                return False
            cursor.execute(
                f"CREATE ROLE {_quote_ident(role)} LOGIN "
                f"PASSWORD {_quote_literal(password)}"
            )
        return True
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass


def ensure_role_password(
    url: str, role: str, password: str, *, connect=None
) -> bool:
    """Make an EXISTING role's password match the value we hold.

    A ``database.env`` written by an earlier failed install is only a claim:
    the server is the authority.  When the role already exists this sets its
    password to that stored value, so a stale file can never leave the
    application role unable to log in.

    Returns ``True`` when an ``ALTER ROLE`` was executed and ``False`` when
    the role does not exist (the caller creates it instead).  Never creates,
    drops or renames a role, never touches another role or any database, and
    the statement is never logged.
    """
    _require_identifier(role, "role name")
    if not password:
        raise CredentialsError(
            "refusing to set a role password to an empty value"
        )
    params = DbParams.from_url(url)
    opener = connect or _connect
    try:
        conn = opener(maintenance_url(url))
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)
            )
            if cursor.fetchone() is None:
                return False
            cursor.execute(
                f"ALTER ROLE {_quote_ident(role)} WITH LOGIN "
                f"PASSWORD {_quote_literal(password)}"
            )
        return True
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass


def create_database(
    url: str, dbname: str, owner: str, *, connect=None
) -> bool:
    """Create ``dbname`` owned by ``owner`` — only when it is absent.

    Returns ``True`` when the database was created by this call and
    ``False`` when it already existed (idempotency, §4).  There is no
    code path here that can drop or recreate an existing database.
    """
    _require_identifier(dbname, "database name")
    _require_identifier(owner, "database owner")
    params = DbParams.from_url(url)
    opener = connect or _connect
    try:
        conn = opener(maintenance_url(url))
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
            if cursor.fetchone() is not None:
                return False
            cursor.execute(
                f"CREATE DATABASE {_quote_ident(dbname)} "
                f"OWNER {_quote_ident(owner)}"
            )
        return True
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass


# ─────────────────────────────────────────────────────────────────────────
# Migrations (explicit only — never at application startup)
# ─────────────────────────────────────────────────────────────────────────


def current_revision(url: str, *, connect=None) -> str | None:
    """Revision recorded in ``alembic_version``, or ``None`` (no table)."""
    import psycopg2

    params = DbParams.from_url(url)
    opener = connect or _connect
    try:
        conn = opener(url)
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            try:
                cursor.execute("SELECT version_num FROM alembic_version LIMIT 1")
            except psycopg2.errors.UndefinedTable:
                return None
            row = cursor.fetchone()
            return str(row[0]) if row else None
    except Exception as exc:  # noqa: BLE001
        raise _classify(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass


def head_revision() -> str | None:
    """The single Alembic head of this repository's migration chain."""
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_ROOT / "migrations"))
    script = ScriptDirectory.from_config(config)
    return script.get_current_head()


@dataclass(frozen=True)
class MigrationOutcome:
    """Result of one explicit ``alembic upgrade`` run."""

    before: str | None
    after: str | None
    requested: str
    changed: bool
    output: str

    @property
    def already_current(self) -> bool:
        return not self.changed


def _default_migration_runner(
    argv: list[str], env: dict[str, str]
) -> subprocess.CompletedProcess:
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(BACKEND_ROOT),
        timeout=_MIGRATION_TIMEOUT_SECONDS,
        check=False,
    )


def run_migrations(
    url: str,
    revision: str = "head",
    *,
    runner=None,
    connect=None,
) -> MigrationOutcome:
    """Run ``alembic upgrade <revision>`` against ``url``.

    Isolated in a subprocess with ``DATABASE_URL`` injected into its
    environment (the only channel ``migrations/env.py`` reads), so the
    caller's own settings are untouched.  On failure the error is scrubbed
    of the password and :class:`MigrationError` is raised — the database
    itself is left exactly where Alembic stopped, which is the documented
    Alembic behaviour and never a destructive one.
    """
    params = DbParams.from_url(url)
    before = current_revision(url, connect=connect)

    execute = runner or _default_migration_runner
    argv = [sys.executable, "-m", "alembic", "upgrade", revision]
    env = {**os.environ, "DATABASE_URL": url}
    try:
        completed = execute(argv, env)
    except subprocess.TimeoutExpired as exc:
        raise MigrationError(
            f"alembic upgrade {revision} timed out after "
            f"{_MIGRATION_TIMEOUT_SECONDS}s"
        ) from exc
    except OSError as exc:  # pragma: no cover - python missing
        raise MigrationError(f"could not start alembic: {exc}") from exc

    output = scrub(
        f"{completed.stdout or ''}\n{completed.stderr or ''}".strip(),
        _secrets_of(params),
    )
    if completed.returncode != 0:
        raise MigrationError(
            f"alembic upgrade {revision} failed (exit "
            f"{completed.returncode}): {output[-2000:]}"
        )

    after = current_revision(url, connect=connect)
    if revision not in ("head",) and after is not None and after != revision:
        # `upgrade <rev>` succeeded but did not land on the requested
        # revision — a chain that ends somewhere else.  Treat as failure.
        raise MigrationError(
            f"alembic reported success but the database is at {after}, "
            f"not the requested {revision}"
        )
    return MigrationOutcome(
        before=before,
        after=after,
        requested=revision,
        changed=before != after,
        output=output,
    )


# ─────────────────────────────────────────────────────────────────────────
# Planning (read-only: discovery, no connection)
# ─────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class DedicatedInstanceSpec:
    """Everything needed to install a *separate* PostgreSQL instance (§3).

    The artifact fields (``installer_path``, ``sha256``) are intentionally
    empty by default: R3 does not know which installer build the customer
    will stage, and guessing a filename would be exactly the kind of
    unfounded assumption §2 forbids.  With them unset the adapter refuses
    to run — fail closed, with a message saying what to supply.
    """

    major: int = VERIFIED_MAX_MAJOR
    version: str = ""
    installer_path: Path | None = None
    sha256: str = ""
    data_dir: Path | None = None
    install_dir: Path | None = None
    port: int = 5432
    service_name: str = ""
    superuser: str = "postgres"

    def resolved_data_dir(self) -> Path:
        if self.data_dir is not None:
            return self.data_dir
        root = Path(settings.DATA_DIR) if settings.DATA_DIR else BACKEND_ROOT
        return root / "pgdata" / str(self.major)

    def resolved_install_dir(self) -> Path:
        if self.install_dir is not None:
            return self.install_dir
        root = Path(settings.DATA_DIR) if settings.DATA_DIR else BACKEND_ROOT
        return root / "pgsql" / str(self.major)

    def resolved_service_name(self) -> str:
        return self.service_name or f"postgresql-supermarketpro-{self.major}"

    @property
    def label(self) -> str:
        version = self.version or f"{self.major}.x"
        return f"dedicated PostgreSQL {version} (service {self.resolved_service_name()})"


#: EDB Windows installer switches used for an unattended install.
#:
#: Every token below is on EDB's official parameter list
#: (``enterprisedb.com/docs/supported-open-source/postgresql/installing/
#: command_line_parameters/``) — corrected in R5 from R3's non-official
#: ``--unattendmode`` / ``--disablestackbuilder`` / ``--superuser`` /
#: ``--installprefix``; see ``docs/R5_INSTALLER_DESIGN.md`` §1.2.
#: They are still **never executed** on the development machine (no
#: elevation): :func:`install_dedicated` refuses to run anything until
#: the staged artifact's SHA-256 matches and an explicit runner is
#: supplied.  ``--install_runtimes`` is deliberately absent — its
#: default is kept so the VC++ runtimes stay provisionable offline.
UNATTENDED_FLAGS: tuple[str, ...] = (
    "--mode",
    "unattended",
    "--unattendedmodeui",
    "none",
    # Only the identifier the shipped installers already use is disabled.
    # EDB's documented list for this option is ``server pgAdmin
    # stackbuilder commandlinetools``, but ``pgAdmin`` was never confirmed
    # against a real ``--help`` run (the installer needs elevation), so it
    # stays out: an unverified component name can make the unattended
    # install fail.  ``server`` and ``commandlinetools`` (psql, pg_isready,
    # pg_dump) must stay enabled for provisioning.
    "--disable-components",
    "stackbuilder",
    "--enable_acledit",
    "1",
)


def build_unattended_command(
    spec: DedicatedInstanceSpec,
    password: str,
    *,
    debug_trace: Path | None = None,
) -> list[str]:
    """The argv an elevated installer process would be started with.

    Contains the administrator password — never log this list; use
    :func:`redacted_command` for anything a human or a log might see.
    """
    installer = spec.installer_path
    if installer is None:
        raise ProvisioningError(
            "no PostgreSQL installer staged; place the EDB Windows "
            "installer under "
            f"{installer_staging_dir()} and set installer_path"
        )
    data_dir = spec.resolved_data_dir()
    if "Program Files" in str(data_dir) or "Program Files (x86)" in str(data_dir):
        raise ProvisioningError(
            f"the data directory must not live inside Program Files "
            f"(read-only install tree, R1): {data_dir}"
        )
    trace: list[str] = []
    if debug_trace is not None:
        # Documented EDB option: a timestamped trace of every install step.
        # The ~20 minutes seen on a sandbox could not be attributed without
        # it; this is evidence collection, not a speed change.
        trace = ["--debugtrace", str(debug_trace)]
    return [
        str(installer),
        *UNATTENDED_FLAGS,
        *trace,
        "--superaccount",
        spec.superuser,
        "--superpassword",
        password,
        "--serverport",
        str(spec.port),
        "--datadir",
        str(data_dir),
        "--prefix",
        str(spec.resolved_install_dir()),
        "--servicename",
        spec.resolved_service_name(),
    ]


def redacted_argv(argv: list[str], password: str) -> list[str]:
    """The argv with the password replaced — safe to log or print."""
    if not password:
        return list(argv)
    return ["***" if token == password else token for token in argv]


def redacted_command(argv: list[str], password: str) -> str:
    """The command line with the password replaced — the only form to log."""
    return " ".join(redacted_argv(argv, password))


def verify_installer(spec: DedicatedInstanceSpec) -> tuple[bool, str]:
    """Exists + SHA-256 matches.  No execution, no network."""
    installer = spec.installer_path
    if installer is None:
        return False, "no installer path configured"
    if not installer.is_file():
        return False, f"staged installer not found: {installer}"
    if not spec.sha256:
        return False, (
            "no SHA-256 pinned for the staged installer; refusing to run "
            "an unverified binary"
        )
    from app.core.db_dump import sha256_of

    actual = sha256_of(installer).lower()
    if actual != spec.sha256.lower():
        return False, (
            f"SHA-256 mismatch for {installer.name}: expected "
            f"{spec.sha256.lower()}, got {actual}"
        )
    return True, "installer verified"


@dataclass(frozen=True)
class DedicatedInstallResult:
    """Outcome of the adapter — always explicit about what happened."""

    executed: bool
    reason: str
    command: tuple[str, ...] = ()


def install_dedicated(
    spec: DedicatedInstanceSpec,
    *,
    password: str,
    execute: bool = False,
    runner=None,
    debug_trace: Path | None = None,
) -> DedicatedInstallResult:
    """Fail-closed adapter for installing a dedicated instance (§3).

    Refuses unless ALL of the following hold:

    1. the caller passed ``execute=True`` (nothing runs by default);
    2. ``R3_ALLOW_POSTGRESQL_INSTALL=1`` is in the environment (a second,
       independent gate for the installer process itself);
    3. the staged installer exists and its SHA-256 matches ``spec.sha256``.

    R3 never trips gate 2 on the development machine, so this function
    can only ever be observed refusing — which is exactly what the tests
    assert.
    """
    if not execute:
        return DedicatedInstallResult(
            executed=False,
            reason=(
                "execution not requested (execute=False); the adapter only "
                "builds and verifies the plan"
            ),
        )
    if os.environ.get(INSTALL_GATE_ENV, "") != "1":
        return DedicatedInstallResult(
            executed=False,
            reason=(
                f"refusing to install: set {INSTALL_GATE_ENV}=1 to confirm "
                "that a dedicated PostgreSQL instance may be created"
            ),
        )
    ok, why = verify_installer(spec)
    if not ok:
        return DedicatedInstallResult(executed=False, reason=why)

    argv = build_unattended_command(spec, password, debug_trace=debug_trace)
    if runner is None:
        raise ProvisioningError(
            "no installer runner supplied; refusing to start an installer "
            f"without an explicit runner (command: "
            f"{redacted_command(argv, password)})"
        )
    runner(argv)
    return DedicatedInstallResult(
        executed=True,
        reason="installer completed",
        command=tuple(redacted_argv(argv, password)),
    )


def plan_dedicated_install(
    *, major: int = VERIFIED_MAX_MAJOR, port: int = 5432
) -> DedicatedInstanceSpec:
    """Spec for the instance we would install if none can be reused."""
    return DedicatedInstanceSpec(major=major, port=port)


@dataclass(frozen=True)
class ProvisioningPlan:
    """Read-only answer to "what would provisioning do here?"."""

    #: ``reuse`` — an instance was selected;
    #: ``install-dedicated`` — nothing usable, a dedicated install is
    #: required (and is NOT performed by this phase);
    #: ``fail`` — even a dedicated install cannot be proposed.
    action: str
    reasons: list[str]
    instance: PostgresInstance | None = None
    spec: DedicatedInstanceSpec | None = None
    steps: list[Step] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def can_reuse(self) -> bool:
        return self.action == "reuse"

    def as_dict(self) -> dict:
        instance = None
        if self.instance is not None:
            instance = {
                "label": self.instance.label,
                "major": self.instance.major,
                "version": self.instance.version_text,
                "service": self.instance.service_name,
                "state": self.instance.service_state,
                "port": self.instance.port,
                "sources": list(self.instance.sources),
            }
        spec = None
        if self.spec is not None:
            spec = {
                "label": self.spec.label,
                "installer_path": (
                    str(self.spec.installer_path)
                    if self.spec.installer_path
                    else None
                ),
                "data_dir": str(self.spec.resolved_data_dir()),
                "port": self.spec.port,
                "service": self.spec.resolved_service_name(),
            }
        return {
            "action": self.action,
            "reasons": list(self.reasons),
            "instance": instance,
            "dedicated_install": spec,
            "warnings": list(self.warnings),
            "steps": [
                {"name": s.name, "status": s.status, "detail": s.detail}
                for s in self.steps
            ],
        }


def plan_provisioning(
    *,
    allow_unverified: bool = False,
    port: int | None = None,
    instances: list[PostgresInstance] | None = None,
) -> ProvisioningPlan:
    """Discover, judge and decide — without connecting to anything (§3)."""
    found = discover_instances() if instances is None else instances
    reasons: list[str] = []
    warnings: list[str] = []
    steps: list[Step] = []

    if not found:
        reasons.append(
            "no PostgreSQL installation was detected (registry, install "
            "directories and Windows services were all consulted)"
        )
        steps.append(
            Step("discover", STEP_FAILED, "no PostgreSQL installation detected")
        )
        spec = plan_dedicated_install(port=port or 5432)
        return ProvisioningPlan(
            action="install-dedicated",
            reasons=reasons,
            spec=spec,
            steps=steps,
        )

    steps.append(
        Step(
            "discover",
            STEP_APPLIED,
            "; ".join(item.label for item in found),
        )
    )

    selected = select_instance(
        found, require_running=True, allow_unverified=allow_unverified
    )
    if selected is None:
        for item in found:
            compat = check_compatibility(item)
            if not compat.accepted:
                reasons.append(f"{item.label}: {compat.reason}")
            elif not compat.verified and not allow_unverified:
                reasons.append(f"{item.label}: {compat.reason}")
            elif not item.is_running:
                name = item.service_name or "(unknown)"
                if item.service_state:
                    reasons.append(
                        f"{item.label}: the Windows service {name} is "
                        f"{item.service_state} — start it, or let "
                        "provisioning install a dedicated instance"
                    )
                else:
                    # Never claim "not running" when the state is simply
                    # unknown: that report sent a technician chasing a
                    # healthy service.
                    reasons.append(
                        f"{item.label}: the Windows service {name} exists "
                        "but its state could not be read — check `sc query "
                        f"{name}`, or let provisioning install a dedicated "
                        "instance"
                    )
            else:  # pragma: no cover - select_instance would have taken it
                reasons.append(f"{item.label}: not selected")
        steps.append(
            Step("select", STEP_FAILED, "no reusable instance")
        )
        spec = plan_dedicated_install(
            major=max(
                (i.major for i in found if i.major is not None),
                default=VERIFIED_MAX_MAJOR,
            ),
            port=port or 5432,
        )
        return ProvisioningPlan(
            action="install-dedicated",
            reasons=reasons,
            spec=spec,
            steps=steps,
            warnings=warnings,
        )

    compat = check_compatibility(selected)
    steps.append(Step("select", STEP_APPLIED, selected.label))
    if not compat.verified:
        warnings.append(compat.reason)

    if port and selected.port and port != selected.port:
        warnings.append(
            f"the configured port {port} does not match the detected "
            f"instance port {selected.port} ({selected.label})"
        )

    if port:
        conflicts = [
            item
            for item in found
            if item is not selected
            and item.is_running
            and item.port == port
        ]
        if conflicts:
            steps.append(
                Step(
                    "port",
                    STEP_FAILED,
                    "port "
                    f"{port} is already served by "
                    + ", ".join(item.label for item in conflicts),
                )
            )
            reasons.append(
                f"port {port} is already in use by "
                + ", ".join(item.label for item in conflicts)
            )
            return ProvisioningPlan(
                action="fail",
                reasons=reasons,
                instance=selected,
                steps=steps,
                warnings=warnings,
            )
        steps.append(Step("port", STEP_APPLIED, f"port {port} is free"))
    else:
        steps.append(
            Step(
                "port",
                STEP_SKIPPED,
                f"using the detected port {selected.port or 'unknown'}",
            )
        )

    return ProvisioningPlan(
        action="reuse",
        reasons=[f"reusing {selected.label}"],
        instance=selected,
        steps=steps,
        warnings=warnings,
    )


# ─────────────────────────────────────────────────────────────────────────
# The lifecycle entry point (§4 / §5)
# ─────────────────────────────────────────────────────────────────────────


def _is_local(host: str) -> bool:
    return host.lower().strip("[]") in LOCAL_HOSTS


def _resolve_admin_url() -> str | None:
    """Maintenance credentials from ``PG_ADMIN_URL``, else none at all.

    Never ``settings.DATABASE_URL`` by accident: the application's own
    URL may well be a least-privilege role that cannot create databases,
    and silently trying (and failing) with it produces a confusing error
    instead of the actionable one we want.
    """
    candidate = (os.environ.get("PG_ADMIN_URL") or "").strip()
    return candidate or None


def provision_database(
    *,
    app_url: str | None = None,
    admin_url: str | None = None,
    dbname: str | None = None,
    owner: str | None = None,
    app_password: str | None = None,
    apply_migrations: bool = True,
    initialize_rbac: bool = True,
    allow_unverified: bool = False,
    dry_run: bool = False,
    instances: list[PostgresInstance] | None = None,
) -> ProvisioningReport:
    """Idempotent database lifecycle: reuse → create-if-absent → migrate → seed.

    Every parameter defaults to the operator's configuration; nothing is
    invented.  Raises a :class:`ProvisioningError` subclass on failure,
    with the partial :class:`ProvisioningReport` attached as ``.report``.
    """
    url = app_url or settings.DATABASE_URL
    params = DbParams.from_url(url)
    target_db = dbname or params.dbname
    role = owner or params.user
    # The role password is whatever the caller holds (database.env) or, when
    # it was not passed separately, the one embedded in the app URL.
    role_password = app_password or params.password
    _require_identifier(target_db, "database name")
    _require_identifier(role, "application role")

    report = ProvisioningReport(
        database_name=target_db,
        target=params.safe_repr(),
    )

    # ── 1. reuse decision (local servers only, read-only) ────────────
    plan: ProvisioningPlan | None = None
    if _is_local(params.host):
        plan = plan_provisioning(
            allow_unverified=allow_unverified,
            port=params.port,
            instances=instances,
        )
        report.warnings.extend(plan.warnings)
        for step in plan.steps:
            report.steps.append(step)
        if plan.instance is not None:
            report.instance_label = plan.instance.label
            report.instance_sources = list(plan.instance.sources)
        if plan.action != "reuse":
            detail = "; ".join(plan.reasons) or "no reusable instance"
            report.add("instance", STEP_FAILED, detail)
            spec = plan.spec or plan_dedicated_install(port=params.port)
            remediation = (
                ". Options: start the existing service, or stage a "
                f"dedicated install (adapter ready: {spec.label}; "
                "installer + SHA-256 required, execution gated by "
                f"{INSTALL_GATE_ENV}=1)"
            )
            # A version refusal is a different problem with a different
            # fix (upgrade/downgrade the server, or explicitly accept the
            # unverified major) than a missing/stopped service.
            if plan.reasons and all(
                "older than the minimum" in reason
                or "newer than the verified" in reason
                for reason in plan.reasons
            ):
                raise IncompatibleVersionError(
                    "the detected PostgreSQL server cannot be reused: "
                    + detail
                    + remediation,
                    report=report,
                )
            raise InstanceUnavailableError(
                "no reusable PostgreSQL server was found: "
                + detail
                + remediation,
                report=report,
            )
        report.add("instance", STEP_APPLIED, plan.instance.label)
    else:
        report.add(
            "instance",
            STEP_SKIPPED,
            f"{params.host} is not a local host — discovery does not apply",
        )

    # ── 2. reachability / credentials ────────────────────────────────
    probe_url = admin_url or _resolve_admin_url()
    check_target = probe_url or url
    try:
        check_connectivity(check_target)
    except ProvisioningError as exc:
        report.add("connect", STEP_FAILED, str(exc))
        exc.report = report
        raise
    report.add("connect", STEP_APPLIED, DbParams.from_url(check_target).safe_repr())

    # ── 3. role FIRST, always through the maintenance connection ────
    # A reused server is the normal case on a shop PC, and its catalog is
    # the only authority: `database.env` proves nothing (a failed install
    # leaves one behind whose password the server never accepted).  So the
    # role is reconciled with the SERVER before anything connects as it:
    #   missing -> CREATE ROLE <app_user> LOGIN PASSWORD <database.env>
    #   present -> ALTER ROLE <app_user> WITH LOGIN PASSWORD <database.env>
    # This is why a reused server with an already-existing database still
    # ends up with a working application role.
    exists = database_exists(check_target, target_db)
    if dry_run:
        if role_password:
            report.add(
                "role",
                STEP_PLANNED,
                f"role {role} (create when absent, else reconcile password)",
            )
        report.add(
            "database",
            STEP_PLANNED,
            f"{target_db} would be created"
            + (f" owned by {role}" if role else ""),
        )
    else:
        if probe_url is None and not exists:
            message = (
                f"database {target_db} does not exist and no admin "
                "credentials were supplied; set PG_ADMIN_URL to a "
                "maintenance connection (a role that may CREATE DATABASE) "
                "and re-run provisioning"
            )
            report.add("database", STEP_FAILED, message)
            raise CredentialsError(message, report=report)
        if probe_url is not None and role_password:
            report.role_created = ensure_role(probe_url, role, role_password)
            reconciled = False
            if not report.role_created:
                reconciled = ensure_role_password(
                    probe_url, role, role_password
                )
            detail = f"application role {role}"
            if report.role_created:
                detail += " created"
            elif reconciled:
                detail += " password reconciled with database.env"
            else:
                detail += " already present"
            report.add(
                "role",
                STEP_APPLIED if (report.role_created or reconciled)
                else STEP_SKIPPED,
                detail,
            )
        if exists:
            report.add("database", STEP_SKIPPED, f"{target_db} already exists")
        else:
            report.database_created = create_database(
                probe_url, target_db, role
            )
            report.add(
                "database",
                STEP_APPLIED,
                f"created {target_db} owned by {role}",
            )

    # ── 3b. the application credential must work BEFORE migrating ────
    # Migrations and the RBAC seed run as the application role; failing here
    # with a precise message is worth more than an alembic traceback.
    if not dry_run:
        try:
            check_connectivity(url)
        except ProvisioningError as exc:
            report.add("app_login", STEP_FAILED, str(exc))
            message = (
                f"the application role {role} still cannot log in to "
                f"{target_db} after the password was reconciled with the "
                "server. Delete <DATA_DIR>\\config\\database.env and "
                "re-run the provisioning pass so a new password is "
                f"generated and applied. Underlying error: {exc}"
            )
            raise CredentialsError(message, report=report) from exc
        report.add(
            "app_login", STEP_APPLIED, DbParams.from_url(url).safe_repr()
        )

    # ── 4. migrations — explicit only (§4) ───────────────────────────
    if not apply_migrations:
        report.add("migrations", STEP_SKIPPED, "not requested")
    elif dry_run:
        try:
            current = current_revision(url) or "none"
        except ProvisioningError:
            current = "unknown (database unreachable)"
        report.add(
            "migrations",
            STEP_PLANNED,
            f"alembic upgrade head (currently {current})",
        )
    else:
        try:
            outcome = run_migrations(url)
        except MigrationError as exc:
            report.add("migrations", STEP_FAILED, str(exc))
            exc.report = report
            raise
        report.revision_before = outcome.before
        report.revision_after = outcome.after
        report.migrations_applied = outcome.changed
        report.add(
            "migrations",
            STEP_APPLIED if outcome.changed else STEP_SKIPPED,
            f"{outcome.before or 'none'} → {outcome.after or 'none'}",
        )

    # ── 5. RBAC seed — explicit only (§5) ────────────────────────────
    if not initialize_rbac:
        report.add("rbac", STEP_SKIPPED, "not requested")
    elif dry_run:
        report.add("rbac", STEP_PLANNED, "roles, permissions and grants")
    else:
        from app.core.rbac_bootstrap import initialize_rbac as _seed_rbac

        # The session is bound to the URL this pass provisioned, not to
        # the process-global engine: provisioning must seed exactly the
        # database it just created.
        engine = create_engine(url, echo=False, future=True)
        try:
            with Session(bind=engine) as db:
                rbac_report = _seed_rbac(db)
        finally:
            engine.dispose()
        report.rbac = rbac_report.as_dict()
        report.add(
            "rbac",
            STEP_APPLIED if rbac_report.ok else STEP_FAILED,
            rbac_report.summary,
        )
        if not rbac_report.ok:
            raise ProvisioningError(
                f"RBAC initialisation incomplete: {rbac_report.summary}",
                report=report,
            )

    logger.info(
        "provisioning_complete",
        database=report.database_name,
        target=report.target,
        created=report.database_created,
        migrations=report.migrations_applied,
        steps=[f"{s.name}:{s.status}" for s in report.steps],
    )
    return report


# ─────────────────────────────────────────────────────────────────────────
# CLI — the installer / operator entry point
# ─────────────────────────────────────────────────────────────────────────


def build_parser():
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m app.core.postgres_provisioning",
        description=(
            "Idempotent PostgreSQL provisioning: reuse an existing server, "
            "create the database only when absent, migrate and seed only "
            "on explicit request.  Never drops or rewrites anything."
        ),
    )
    parser.add_argument(
        "--plan",
        action="store_true",
        help="read-only assessment (discovery only, no connection)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="connect and inspect, but create/migrate/seed nothing",
    )
    parser.add_argument(
        "--no-migrations",
        action="store_true",
        help="do not run alembic upgrade",
    )
    parser.add_argument(
        "--no-rbac",
        action="store_true",
        help="do not seed roles/permissions",
    )
    parser.add_argument(
        "--allow-unverified",
        action="store_true",
        help="accept a PostgreSQL major newer than the verified maximum",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="print the report as JSON",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entry point.  Exit 0 on success, 1 on any provisioning failure."""
    import json

    args = build_parser().parse_args(argv)

    try:
        if args.plan:
            plan = plan_provisioning(allow_unverified=args.allow_unverified)
            payload = plan.as_dict()
            failed = plan.action == "fail"
        else:
            report = provision_database(
                apply_migrations=not args.no_migrations,
                initialize_rbac=not args.no_rbac,
                allow_unverified=args.allow_unverified,
                dry_run=args.dry_run,
            )
            payload = report.as_dict()
            failed = not report.ok
    except ProvisioningError as exc:
        payload = {"ok": False, "error": str(exc)}
        if exc.report is not None:
            payload["report"] = exc.report.as_dict()
        failed = True

    if args.as_json:
        print(json.dumps(payload, indent=2, default=str))
    else:
        _print_human(payload)
    return 1 if failed else 0


def _print_human(payload: dict) -> None:
    if "error" in payload:
        print(f"FAILED: {payload['error']}")
    elif payload.get("action"):
        print(f"Plan: {payload['action']}")
        for reason in payload.get("reasons", []):
            print(f"  - {reason}")
    else:
        print(f"{'OK' if payload.get('ok') else 'FAILED'}: "
              f"database {payload.get('database')} on {payload.get('target')}")
    report = payload.get("report", payload)
    for step in report.get("steps", []):
        print(f"  [{step['status']:<8}] {step['name']}: {step['detail']}")
    for warning in report.get("warnings", []):
        print(f"  warning: {warning}")


if __name__ == "__main__":
    raise SystemExit(main())
