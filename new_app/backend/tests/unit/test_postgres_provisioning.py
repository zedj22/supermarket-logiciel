"""Unit tests for R3 PostgreSQL provisioning, lifecycle and RBAC hooks (§3–§6).

The database is a small in-memory fake, so these tests never open a
socket, never touch the developer's PostgreSQL and never write a file
outside ``tmp_path``.  Real-server behaviour is covered by
``tests/integration/test_postgres_lifecycle.py``.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import psycopg2
import psycopg2.errors
import pytest

from app.core import postgres_provisioning as pp
from app.core.config import BACKEND_ROOT

PASSWORD = "S3cr3t-Pa55word-for-tests-0123456789"
APP_URL = f"postgresql://app_user:{PASSWORD}@localhost:5432/supermarket_pro"
ADMIN_URL = f"postgresql://postgres:{PASSWORD}@localhost:5432/postgres"

#: Every statement the provisioning pass is allowed to execute (§4).
#: ``ALTER ROLE … PASSWORD`` is allowed: reconciling the application role's
#: password with the server is how a stale ``database.env`` is repaired.
ALLOWED_SQL = re.compile(
    r"^(SELECT|CREATE DATABASE|CREATE ROLE|ALTER ROLE)\b", re.IGNORECASE
)

DESTRUCTIVE_SQL = (
    "DROP DATABASE",
    "DROP SCHEMA",
    "DROP TABLE",
    "DROP ROLE",
    "DROP COLUMN",
    "ALTER DATABASE",
    "ALTER SCHEMA",
    "ALTER TABLE",
    "TRUNCATE",
    "DELETE FROM",
    "UPDATE ",
)


# ─────────────────────────────────────────────────────────────────────────
# Fake PostgreSQL
# ─────────────────────────────────────────────────────────────────────────


class FakePG:
    """The slice of PostgreSQL that provisioning actually talks to."""

    def __init__(
        self,
        *,
        databases=(),
        roles=(),
        revision: str | None = None,
        has_alembic_table: bool | None = None,
        connect_error: Exception | None = None,
        execute_error: Exception | None = None,
    ):
        self.databases = set(databases)
        self.roles = set(roles)
        self.revision = revision
        self.has_alembic_table = (
            revision is not None if has_alembic_table is None
            else has_alembic_table
        )
        self.connect_error = connect_error
        self.execute_error = execute_error
        self.statements: list[tuple[str, tuple | None]] = []

    @property
    def sql(self) -> list[str]:
        return [text for text, _ in self.statements]


class _FakeCursor:
    def __init__(self, pg: FakePG):
        self._pg = pg
        self._row = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params=None):
        text = sql if isinstance(sql, str) else str(sql)
        self._pg.statements.append((text, params))
        if self._pg.execute_error is not None:
            raise self._pg.execute_error
        low = " ".join(text.lower().split())
        self._row = None
        if low == "select 1":
            self._row = (1,)
        elif low.startswith("select 1 from pg_database"):
            self._row = (1,) if params and params[0] in self._pg.databases else None
        elif low.startswith("select 1 from pg_roles"):
            self._row = (1,) if params and params[0] in self._pg.roles else None
        elif low.startswith("create database"):
            match = re.search(r'CREATE DATABASE "([^"]+)"', text, re.IGNORECASE)
            assert match, f"unparseable CREATE DATABASE: {text}"
            self._pg.databases.add(match.group(1))
        elif low.startswith("create role"):
            match = re.search(r'ROLE "([^"]+)"', text, re.IGNORECASE)
            assert match, f"unparseable CREATE ROLE: {text}"
            self._pg.roles.add(match.group(1))
        elif "alembic_version" in low:
            if not self._pg.has_alembic_table:
                raise psycopg2.errors.UndefinedTable(
                    'relation "alembic_version" does not exist'
                )
            self._row = (self._pg.revision,) if self._pg.revision else None

    def fetchone(self):
        return self._row


class _FakeConnection:
    def __init__(self, pg: FakePG):
        self._pg = pg

    def cursor(self):
        return _FakeCursor(self._pg)

    def close(self):
        pass


def fake_connect(pg: FakePG):
    def connect(url, *, timeout=15):
        if pg.connect_error is not None:
            raise pg.connect_error
        return _FakeConnection(pg)

    return connect


class Harness:
    """Patches ``pp._connect`` and remembers the fake server in use."""

    def __init__(self, monkeypatch):
        self._monkeypatch = monkeypatch
        self.pg: FakePG | None = None

    def install(self, pg: FakePG) -> FakePG:
        self.pg = pg
        self._monkeypatch.setattr(pp, "_connect", fake_connect(pg))
        return pg

    @property
    def statements(self) -> list[str]:
        assert self.pg is not None, "no fake server installed yet"
        return self.pg.sql


@pytest.fixture()
def fake_pg(monkeypatch):
    """Patch every connection factory in the module with a fake server."""
    return Harness(monkeypatch)


def _runner(returncode: int = 0, stdout: str = "", stderr: str = ""):
    def run(argv, env):
        return subprocess.CompletedProcess(
            argv, returncode, stdout=stdout, stderr=stderr
        )

    return run


@pytest.fixture(autouse=True)
def no_admin_url(monkeypatch):
    monkeypatch.delenv("PG_ADMIN_URL", raising=False)


def _instance(**kwargs):
    defaults = dict(
        major=18,
        version_text="18.6",
        install_dir=Path(r"C:\Program Files\PostgreSQL\18"),
        service_name="postgresql-x64-18",
        service_state="RUNNING",
        port=5432,
        sources=("registry", "service"),
    )
    defaults.update(kwargs)
    from app.core.postgres_discovery import PostgresInstance

    return PostgresInstance(**defaults)


# ─────────────────────────────────────────────────────────────────────────
# §4 — create only when absent, never destructive
# ─────────────────────────────────────────────────────────────────────────


class TestCreateOnlyWhenAbsent:
    def test_database_exists_reflects_the_catalog(self, fake_pg):
        fake_pg.install(FakePG(databases={"other"}))
        assert pp.database_exists(ADMIN_URL, "other") is True
        assert pp.database_exists(ADMIN_URL, "supermarket_pro") is False

    def test_create_database_creates_exactly_once(self, fake_pg):
        pg = fake_pg.install(FakePG(databases=set()))
        assert pp.create_database(ADMIN_URL, "supermarket_pro", "app_user")
        assert "supermarket_pro" in pg.databases
        # second run: nothing to do
        assert pp.create_database(ADMIN_URL, "supermarket_pro", "app_user") is False
        creates = [s for s in pg.sql if s.upper().startswith("CREATE DATABASE")]
        assert len(creates) == 1

    def test_every_executed_statement_is_non_destructive(self, fake_pg):
        pg = fake_pg.install(FakePG(databases=set(), revision=None))
        pp.create_database(ADMIN_URL, "supermarket_pro", "app_user")
        pp.ensure_role(ADMIN_URL, "app_user", PASSWORD)
        pp.ensure_role_password(ADMIN_URL, "app_user", PASSWORD)
        pp.database_exists(ADMIN_URL, "supermarket_pro")

        assert pg.sql, "the fake should have recorded statements"
        for statement in pg.sql:
            assert ALLOWED_SQL.match(statement.strip()), statement
            upper = statement.upper()
            for forbidden in DESTRUCTIVE_SQL:
                assert forbidden not in upper, statement

    def test_dry_run_creates_nothing(self, fake_pg, monkeypatch):
        pg = fake_pg.install(
            FakePG(databases=set(), roles=set(), revision=None)
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())
        monkeypatch.setattr(
            "app.core.rbac_bootstrap.initialize_rbac",
            lambda *_a, **_k: pytest.fail("RBAC must not run in a dry run"),
        )

        report = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            dry_run=True,
        )

        assert report.ok
        assert report.database_created is False
        assert not any(
            s.upper().startswith("CREATE") for s in pg.sql
        ), f"dry run executed DDL: {pg.sql}"
        statuses = {step.name: step.status for step in report.steps}
        assert statuses["database"] == pp.STEP_PLANNED
        assert statuses["migrations"] == pp.STEP_PLANNED
        assert statuses["rbac"] == pp.STEP_PLANNED

    def test_existing_database_step_is_skipped(self, fake_pg, monkeypatch):
        pg = fake_pg.install(
            FakePG(
                databases={"supermarket_pro"},
                roles={"app_user"},
                revision="e5b7d2c9a41f",
            )
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        report = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )

        assert report.ok
        assert report.database_created is False
        assert not any(s.upper().startswith("CREATE") for s in pg.sql)
        statuses = {step.name: step.status for step in report.steps}
        assert statuses["database"] == pp.STEP_SKIPPED
        assert report.revision_before == report.revision_after == "e5b7d2c9a41f"

    def test_second_pass_is_idempotent(self, fake_pg, monkeypatch):
        pg = fake_pg.install(FakePG(databases=set(), revision=None))
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        first = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )
        second = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )

        assert first.database_created is True
        assert second.database_created is False
        assert second.ok
        creates = [s for s in pg.sql if s.upper().startswith("CREATE DATABASE")]
        assert len(creates) == 1


class TestStaleDatabaseEnvIsNeverTrusted:
    """A ``database.env`` left by a FAILED install proves nothing.

    The reported bug: on a reused server whose database already existed
    (the operator's own ``supermarket_pro``), the role was never created, so
    the migrations connected as ``app_user`` and failed with "password
    authentication failed".  The server's catalog — reached with the
    maintenance credential — decides, never the file.
    """

    def test_role_is_created_on_reuse_even_when_the_database_exists(
        self, fake_pg, monkeypatch
    ):
        pg = fake_pg.install(
            FakePG(databases={"supermarket_pro"}, roles=set(), revision=None)
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        report = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )

        assert report.ok
        # The role exists on the server now, created with the value from
        # database.env, and only then did anything connect as app_user.
        assert "app_user" in pg.roles
        creates = [s for s in pg.sql if s.upper().startswith("CREATE ROLE")]
        assert len(creates) == 1
        assert PASSWORD in creates[0]
        assert report.role_created is True
        assert report.database_created is False  # never re-created, never dropped
        statuses = {step.name: step.status for step in report.steps}
        assert statuses["role"] == pp.STEP_APPLIED
        assert statuses["database"] == pp.STEP_SKIPPED
        assert statuses["app_login"] == pp.STEP_APPLIED

    def test_existing_role_password_is_reconciled_with_database_env(
        self, fake_pg, monkeypatch
    ):
        pg = fake_pg.install(
            FakePG(
                databases={"supermarket_pro"},
                roles={"app_user"},
                revision="e5b7d2c9a41f",
            )
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        report = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )

        assert report.ok
        assert report.role_created is False
        alters = [s for s in pg.sql if s.upper().startswith("ALTER ROLE")]
        assert len(alters) == 1
        assert "app_user" in alters[0]
        assert PASSWORD in alters[0]
        assert not [s for s in pg.sql if s.upper().startswith("CREATE ROLE")]
        statuses = {step.name: step.status for step in report.steps}
        assert statuses["role"] == pp.STEP_APPLIED
        assert statuses["app_login"] == pp.STEP_APPLIED

    def test_reconciliation_never_touches_another_role(self, fake_pg):
        pg = fake_pg.install(
            FakePG(roles={"app_user", "someone_else"}, databases=set())
        )
        assert pp.ensure_role_password(ADMIN_URL, "app_user", PASSWORD) is True
        assert pg.roles == {"app_user", "someone_else"}
        for statement in pg.sql:
            assert ALLOWED_SQL.match(statement.strip()), statement
            if statement.upper().startswith("ALTER"):
                assert "app_user" in statement
                assert "someone_else" not in statement


# ─────────────────────────────────────────────────────────────────────────
# §3 — reuse decision, failure modes
# ─────────────────────────────────────────────────────────────────────────


class TestReuseAndFailureModes:
    def test_missing_postgresql_service_fails_closed(self, fake_pg):
        fake_pg.install(FakePG(databases={"supermarket_pro"}))

        with pytest.raises(pp.InstanceUnavailableError) as excinfo:
            pp.provision_database(
                app_url=APP_URL,
                instances=[],
                apply_migrations=False,
                initialize_rbac=False,
            )

        message = str(excinfo.value)
        assert "R3_ALLOW_POSTGRESQL_INSTALL" in message
        assert "no reusable PostgreSQL server" in message
        assert PASSWORD not in message
        assert excinfo.value.report is not None
        assert excinfo.value.report.ok is False
        # fail closed: nothing was executed against the server
        assert fake_pg.statements == []

    def test_stopped_service_is_not_reusable(self, fake_pg):
        fake_pg.install(FakePG(databases=set()))
        stopped = _instance(service_state="STOPPED")
        plan = pp.plan_provisioning(port=5432, instances=[stopped])
        assert plan.action == "install-dedicated"
        assert any("STOPPED" in reason or "not running" in reason
                   for reason in plan.reasons)

    def test_incompatible_version_is_reported_as_such(self, fake_pg):
        fake_pg.install(FakePG(databases=set()))
        ancient = _instance(major=12, version_text="12.4")
        plan = pp.plan_provisioning(port=5432, instances=[ancient])
        assert plan.action == "install-dedicated"
        assert any("minimum supported" in r for r in plan.reasons)

        with pytest.raises(pp.IncompatibleVersionError) as excinfo:
            pp.provision_database(
                app_url=APP_URL,
                instances=[ancient],
                apply_migrations=False,
                initialize_rbac=False,
            )
        assert "cannot be reused" in str(excinfo.value)

    def test_unverified_major_needs_an_explicit_opt_in(self, fake_pg):
        fake_pg.install(FakePG(databases={"supermarket_pro"}))
        future = _instance(major=19, version_text="19.1")

        plan = pp.plan_provisioning(port=5432, instances=[future])
        assert plan.action == "install-dedicated"
        assert any("newer than the verified" in r for r in plan.reasons)

        accepted = pp.plan_provisioning(
            port=5432, instances=[future], allow_unverified=True
        )
        assert accepted.action == "reuse"
        assert accepted.warnings and "allow_unverified" in accepted.warnings[0]

    def test_port_conflict_is_detected(self, fake_pg):
        fake_pg.install(FakePG(databases=set()))
        on_5433 = _instance(major=18, port=5433)
        squatter = _instance(
            major=17,
            port=5432,
            service_name="postgresql-x64-17",
            install_dir=Path(r"C:\Program Files\PostgreSQL\17"),
        )

        plan = pp.plan_provisioning(port=5432, instances=[on_5433, squatter])
        assert plan.action == "fail"
        assert any("already in use" in reason for reason in plan.reasons)
        failed = [s for s in plan.steps if s.status == pp.STEP_FAILED]
        assert failed and failed[0].name == "port"

    def test_plan_is_read_only_and_serialisable(self, fake_pg):
        fake_pg.install(FakePG(databases=set()))
        plan = pp.plan_provisioning(port=5432, instances=[_instance()])
        payload = plan.as_dict()
        assert payload["action"] == "reuse"
        assert payload["instance"]["major"] == 18
        assert PASSWORD not in str(payload)
        # planning never opens a connection
        assert fake_pg.statements == []

    def test_remote_host_skips_local_discovery(self, fake_pg, monkeypatch):
        """A remote server is the operator's business, not ours."""
        fake_pg.install(
            FakePG(databases={"supermarket_pro"}, revision="e5b7d2c9a41f")
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())
        monkeypatch.setattr(
            pp,
            "plan_provisioning",
            lambda **_k: pytest.fail("discovery must not run for a remote host"),
        )

        remote = "postgresql://app_user:pw@db.example.com:5432/supermarket_pro"
        report = pp.provision_database(
            app_url=remote,
            instances=None,
            initialize_rbac=False,
        )
        assert report.ok
        assert any(s.name == "instance" and s.status == pp.STEP_SKIPPED
                   for s in report.steps)


# ─────────────────────────────────────────────────────────────────────────
# §6 — credentials are classified, scrubbed and never logged
# ─────────────────────────────────────────────────────────────────────────


class TestCredentialHandling:
    def test_wrong_credentials_are_classified(self, fake_pg):
        fake_pg.install(
            FakePG(
                connect_error=psycopg2.OperationalError(
                    'password authentication failed for user "app_user"'
                )
            )
        )
        with pytest.raises(pp.CredentialsError) as excinfo:
            pp.check_connectivity(APP_URL)
        message = str(excinfo.value)
        assert "authentication failed" in message
        assert PASSWORD not in message
        # the connection target is reported without its password
        assert "postgresql://app_user@localhost:5432/supermarket_pro" in message

    def test_missing_server_is_classified(self, fake_pg):
        fake_pg.install(
            FakePG(
                connect_error=psycopg2.OperationalError(
                    'could not connect to server: Connection refused\n'
                    "\tIs the server running on host \"localhost\" (127.0.0.1) "
                    "and accepting TCP/IP connections on port 5432?"
                )
            )
        )
        with pytest.raises(pp.InstanceUnavailableError) as excinfo:
            pp.check_connectivity(APP_URL)
        message = str(excinfo.value)
        assert "no PostgreSQL server is accepting connections" in message
        assert "localhost:5432" in message
        assert PASSWORD not in message

    def test_unknown_failure_is_still_scrubbed(self, fake_pg):
        fake_pg.install(
            FakePG(
                connect_error=psycopg2.OperationalError(
                    f"something about {PASSWORD} went wrong"
                )
            )
        )
        with pytest.raises(pp.ProvisioningError) as excinfo:
            pp.check_connectivity(APP_URL)
        assert PASSWORD not in str(excinfo.value)

    def test_report_never_contains_the_password(self, fake_pg, monkeypatch):
        fake_pg.install(
            FakePG(
                databases={"supermarket_pro"},
                roles={"app_user"},
                revision="e5b7d2c9a41f",
            )
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        report = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )
        serialised = str(report.as_dict())
        assert PASSWORD not in serialised
        assert report.target == "postgresql://app_user@localhost:5432/supermarket_pro"

    def test_scrub_removes_every_occurrence(self):
        text = f"first {PASSWORD} second {PASSWORD}"
        assert pp.scrub(text, [PASSWORD]) == "first *** second ***"
        assert pp.scrub("untouched", []) == "untouched"

    def test_role_password_never_reaches_argv(self, fake_pg):
        """CREATE ROLE is parameter-free SQL, so the password is escaped
        into an E-string literal — never passed as an argument."""
        pg = fake_pg.install(FakePG(roles=set()))
        pp.ensure_role(ADMIN_URL, "app_user", PASSWORD)
        statement = pg.sql[-1]
        assert statement.startswith('CREATE ROLE "app_user" LOGIN PASSWORD E\'')
        assert PASSWORD.replace("\\", "\\\\").replace("'", "\\'") in statement

    def test_role_is_created_only_once(self, fake_pg):
        pg = fake_pg.install(FakePG(roles={"app_user"}))
        assert pp.ensure_role(ADMIN_URL, "app_user", PASSWORD) is False
        assert not any(s.upper().startswith("CREATE ROLE") for s in pg.sql)

    @pytest.mark.parametrize(
        "bad", ["", "has'quote", "has\nnewline", "change-me-in-production"]
    )
    def test_invalid_role_names_are_refused(self, bad):
        with pytest.raises(pp.ProvisioningError):
            pp._require_identifier(bad, "database name")

    def test_literal_escaping_handles_quotes_and_backslashes(self):
        assert pp._quote_literal("a'b") == "E'a\\'b'"
        assert pp._quote_literal("a\\b") == "E'a\\\\b'"
        assert pp._quote_ident('we"ird') == '"we""ird"'


# ─────────────────────────────────────────────────────────────────────────
# §4 — migrations are explicit, isolated and never destructive
# ─────────────────────────────────────────────────────────────────────────


class TestMigrations:
    def test_head_revision_is_a_single_revision(self):
        head = pp.head_revision()
        assert head is not None
        assert re.fullmatch(r"[0-9a-f]{12}", head), head

    def test_current_revision_is_none_without_the_table(self, fake_pg):
        fake_pg.install(FakePG(revision=None, has_alembic_table=False))
        assert pp.current_revision(APP_URL) is None

    def test_current_revision_reads_the_catalog(self, fake_pg):
        fake_pg.install(FakePG(revision="a7c1e9f3b5d2"))
        assert pp.current_revision(APP_URL) == "a7c1e9f3b5d2"

    def test_run_migrations_is_a_noop_at_head(self, fake_pg, monkeypatch):
        fake_pg.install(FakePG(revision="e5b7d2c9a41f"))
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        outcome = pp.run_migrations(APP_URL)
        assert outcome.changed is False
        assert outcome.before == outcome.after == "e5b7d2c9a41f"
        assert outcome.already_current is True

    def test_migration_failure_keeps_the_database_and_scrubs(
        self, fake_pg, monkeypatch
    ):
        pg = fake_pg.install(
            FakePG(databases={"supermarket_pro"}, revision="e5b7d2c9a41f")
        )
        monkeypatch.setattr(
            pp,
            "_default_migration_runner",
            _runner(returncode=1, stderr=f"boom while connecting to {PASSWORD}"),
        )

        with pytest.raises(pp.MigrationError) as excinfo:
            pp.run_migrations(APP_URL)

        message = str(excinfo.value)
        assert "alembic upgrade head failed" in message
        assert PASSWORD not in message
        assert "***" in message
        # the database itself was never dropped or recreated
        assert "supermarket_pro" in pg.databases
        assert not any(s.upper().startswith("DROP") for s in pg.sql)

    def test_migration_env_carries_the_target_url(self, fake_pg, monkeypatch):
        fake_pg.install(FakePG(revision=None, has_alembic_table=False))
        seen: dict[str, str] = {}

        def runner(argv, env):
            seen["url"] = env["DATABASE_URL"]
            return subprocess.CompletedProcess(argv, 0, "", "")

        monkeypatch.setattr(pp, "_default_migration_runner", runner)
        pp.run_migrations(APP_URL)
        assert seen["url"] == APP_URL
        assert PASSWORD in seen["url"]  # passed via env, never argv

    def test_migration_argv_never_carries_the_password(self, fake_pg, monkeypatch):
        fake_pg.install(FakePG(revision=None, has_alembic_table=False))
        seen: list[list[str]] = []

        def runner(argv, env):
            seen.append(list(argv))
            return subprocess.CompletedProcess(argv, 0, "", "")

        monkeypatch.setattr(pp, "_default_migration_runner", runner)
        pp.run_migrations(APP_URL)
        assert seen
        for argv in seen:
            assert PASSWORD not in " ".join(argv)

    def test_migration_subprocess_uses_the_project_alembic(self):
        source = Path(pp.__file__).read_text(encoding="utf-8")
        assert '"-m", "alembic"' in source or "'-m', 'alembic'" in source
        assert "alembic" in source


# ─────────────────────────────────────────────────────────────────────────
# §5 — RBAC step wiring
# ─────────────────────────────────────────────────────────────────────────


class TestRbacStep:
    def test_rbac_seed_runs_only_when_requested(self, fake_pg, monkeypatch):
        fake_pg.install(
            FakePG(databases={"supermarket_pro"}, revision="e5b7d2c9a41f")
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())

        called: list[bool] = []
        from app.core import rbac_bootstrap

        monkeypatch.setattr(
            rbac_bootstrap,
            "initialize_rbac",
            lambda *_a, **_k: called.append(True)
            or rbac_bootstrap.RbacReport(ok=True, seeded={"roles": 0}),
        )

        pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=True,
        )
        assert called == [True]

        called.clear()
        report = pp.provision_database(
            app_url=APP_URL,
            admin_url=ADMIN_URL,
            instances=[_instance()],
            initialize_rbac=False,
        )
        assert called == []
        assert any(s.name == "rbac" and s.status == pp.STEP_SKIPPED
                   for s in report.steps)

    def test_incomplete_rbac_fails_the_pass(self, fake_pg, monkeypatch):
        fake_pg.install(
            FakePG(databases={"supermarket_pro"}, revision="e5b7d2c9a41f")
        )
        monkeypatch.setattr(pp, "_default_migration_runner", _runner())
        from app.core import rbac_bootstrap

        monkeypatch.setattr(
            rbac_bootstrap,
            "initialize_rbac",
            lambda *_a, **_k: rbac_bootstrap.RbacReport(
                ok=False, missing_roles=("admin",)
            ),
        )

        with pytest.raises(pp.ProvisioningError) as excinfo:
            pp.provision_database(
                app_url=APP_URL,
                admin_url=ADMIN_URL,
                instances=[_instance()],
                initialize_rbac=True,
            )
        assert "admin" in str(excinfo.value)


# ─────────────────────────────────────────────────────────────────────────
# §3 — the fail-closed dedicated-install adapter
# ─────────────────────────────────────────────────────────────────────────


class TestDedicatedInstallAdapter:
    @pytest.fixture(autouse=True)
    def gate_closed(self, monkeypatch):
        monkeypatch.delenv(pp.INSTALL_GATE_ENV, raising=False)

    def _spec(self, tmp_path, *, sha256: str = "") -> pp.DedicatedInstanceSpec:
        installer = tmp_path / "postgresql-18.6-1-windows-x64.exe"
        installer.write_bytes(b"fake installer payload")
        return pp.DedicatedInstanceSpec(
            major=18,
            version="18.6",
            installer_path=installer,
            sha256=sha256,
            port=5433,
        )

    def test_refuses_without_execute_flag(self, tmp_path):
        spec = self._spec(tmp_path)
        result = pp.install_dedicated(spec, password=PASSWORD, execute=False)
        assert result.executed is False
        assert "execute=False" in result.reason

    def test_refuses_without_the_environment_gate(self, tmp_path):
        spec = self._spec(tmp_path)
        result = pp.install_dedicated(spec, password=PASSWORD, execute=True)
        assert result.executed is False
        assert pp.INSTALL_GATE_ENV in result.reason

    def test_refuses_without_a_pinned_checksum(self, tmp_path, monkeypatch):
        monkeypatch.setenv(pp.INSTALL_GATE_ENV, "1")
        result = pp.install_dedicated(
            self._spec(tmp_path), password=PASSWORD, execute=True
        )
        assert result.executed is False
        assert "SHA-256" in result.reason

    def test_refuses_a_checksum_mismatch(self, tmp_path, monkeypatch):
        monkeypatch.setenv(pp.INSTALL_GATE_ENV, "1")
        spec = self._spec(tmp_path, sha256="0" * 64)
        result = pp.install_dedicated(spec, password=PASSWORD, execute=True)
        assert result.executed is False
        assert "SHA-256 mismatch" in result.reason

    def test_refuses_when_no_installer_is_staged(self, tmp_path, monkeypatch):
        monkeypatch.setenv(pp.INSTALL_GATE_ENV, "1")
        spec = pp.DedicatedInstanceSpec(sha256="a" * 64)
        ok, why = pp.verify_installer(spec)
        assert ok is False
        assert "no installer path" in why

    def test_refuses_to_start_without_an_explicit_runner(
        self, tmp_path, monkeypatch
    ):
        from app.core.db_dump import sha256_of

        monkeypatch.setenv(pp.INSTALL_GATE_ENV, "1")
        spec = self._spec(tmp_path)
        spec = pp.DedicatedInstanceSpec(
            major=spec.major,
            version=spec.version,
            installer_path=spec.installer_path,
            sha256=sha256_of(spec.installer_path),
            port=spec.port,
        )
        with pytest.raises(pp.ProvisioningError) as excinfo:
            pp.install_dedicated(spec, password=PASSWORD, execute=True)
        assert "explicit runner" in str(excinfo.value)
        assert PASSWORD not in str(excinfo.value)

    def test_command_pins_version_port_and_data_dir(self, tmp_path):
        spec = self._spec(tmp_path, sha256="a" * 64)
        argv = pp.build_unattended_command(spec, PASSWORD)
        assert argv[0] == str(spec.installer_path)
        joined = " ".join(argv)
        assert "--serverport" in joined and "5433" in joined
        assert "--datadir" in joined
        assert str(spec.resolved_data_dir()) in argv
        assert str(spec.resolved_service_name()) in argv
        assert PASSWORD in argv  # real command carries it…

    def test_command_uses_only_official_edb_parameters(self, tmp_path):
        """R5 §1.2: every unattended token is on EDB's official list.

        The R3 set carried four non-official switches that an unattended
        installer would silently ignore (wrong install prefix, no
        ACL edit, stackbuilder component handling).
        """
        spec = self._spec(tmp_path, sha256="a" * 64)
        argv = pp.build_unattended_command(spec, PASSWORD)

        assert "--unattendedmodeui" in argv
        assert "unattendmode" not in argv
        assert "--disable-components" in argv
        # Only the identifier already used by the shipped installers is
        # disabled; nothing unverified goes on the command line.
        assert argv[argv.index("--disable-components") + 1] == "stackbuilder"
        # The server and the command-line tools stay enabled: psql,
        # pg_isready and pg_dump are needed by provisioning.
        disabled = argv[argv.index("--disable-components") + 1].split(",")
        assert "server" not in disabled
        assert "commandlinetools" not in disabled
        assert "pgAdmin" not in disabled
        assert "--disablestackbuilder" not in argv
        assert "--superaccount" in argv
        assert "--superuser" not in argv
        assert "--prefix" in argv
        assert "--installprefix" not in argv
        assert argv[argv.index("--enable_acledit") + 1] == "1"
        # The official default is kept: VC++ runtimes stay offline-provisionable.
        assert "--install_runtimes" not in argv
        # The kept-as-is official switches.
        assert "--mode" in argv and "--superpassword" in argv
        assert "--serverport" in argv and "--datadir" in argv
        assert "--servicename" in argv

    def test_redacted_command_never_shows_the_password(self, tmp_path):
        spec = self._spec(tmp_path, sha256="a" * 64)
        argv = pp.build_unattended_command(spec, PASSWORD)
        redacted = pp.redacted_command(argv, PASSWORD)
        assert PASSWORD not in redacted
        assert "***" in redacted
        assert pp.redacted_argv(argv, PASSWORD).count("***") == 1

    def test_data_directory_must_not_live_in_program_files(self, tmp_path):
        spec = pp.DedicatedInstanceSpec(
            installer_path=tmp_path / "setup.exe",
            data_dir=Path(r"C:\Program Files\PostgreSQL\18\data"),
        )
        with pytest.raises(pp.ProvisioningError) as excinfo:
            pp.build_unattended_command(spec, PASSWORD)
        assert "Program Files" in str(excinfo.value)

    def test_staged_installer_location_is_outside_the_install_tree(self):
        staging = pp.installer_staging_dir()
        assert "Program Files" not in str(staging)
        assert staging.name == "installers"

    def test_plan_offers_a_dedicated_install_when_nothing_is_found(self):
        plan = pp.plan_provisioning(port=5432, instances=[])
        assert plan.action == "install-dedicated"
        payload = plan.as_dict()
        assert payload["dedicated_install"] is not None
        assert payload["dedicated_install"]["installer_path"] is None
        assert any("no PostgreSQL installation" in r for r in plan.reasons)


# ─────────────────────────────────────────────────────────────────────────
# §4/§5 — ordinary application startup never provisions
# ─────────────────────────────────────────────────────────────────────────


class TestStartupIsolation:
    BANNED_TOKENS = (
        "postgres_provisioning",
        "rbac_bootstrap",
        "provision_database",
        "run_migrations",
        "alembic",
        "initialize_rbac",
    )

    def test_main_module_never_references_provisioning(self):
        source = (BACKEND_ROOT / "app" / "main.py").read_text(encoding="utf-8")
        for token in self.BANNED_TOKENS:
            assert token not in source, f"app/main.py references {token}"

    def test_fresh_interpreter_importing_the_app_loads_no_provisioning(self):
        """Stronger than a source scan: import the app in a clean process."""
        code = (
            "import sys\n"
            "import app.main\n"
            "banned = sorted(\n"
            "    m for m in (\n"
            "        'app.core.postgres_provisioning',\n"
            "        'app.core.rbac_bootstrap',\n"
            "        'app.core.postgres_discovery',\n"
            "        'alembic',\n"
            "        'alembic.command',\n"
            "    ) if m in sys.modules\n"
            ")\n"
            "print('BANNED=' + ','.join(banned))\n"
        )
        completed = subprocess.run(
            [sys.executable, "-c", code],
            cwd=str(BACKEND_ROOT),
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        assert completed.returncode == 0, completed.stderr
        assert "BANNED=" in completed.stdout
        banned = completed.stdout.split("BANNED=", 1)[1].strip()
        assert banned == "", f"startup imported {banned}"

    def test_startup_does_not_call_provisioning_or_rbac(self, monkeypatch):
        def boom(*_args, **_kwargs):
            raise AssertionError("provisioning must not run at startup")

        monkeypatch.setattr(pp, "provision_database", boom)
        from app.core import rbac_bootstrap

        monkeypatch.setattr(rbac_bootstrap, "initialize_rbac", boom)

        from fastapi.testclient import TestClient

        from app.main import app

        with TestClient(app) as client:
            response = client.get("/api/v1/health/live")
        assert response.status_code == 200


# ─────────────────────────────────────────────────────────────────────────
# §6 — the application role password lives in database.env (R2 machinery)
# ─────────────────────────────────────────────────────────────────────────


class TestDatabaseSecrets:
    def test_generated_once_and_never_rewritten(self, tmp_path):
        from app.core.secrets import ensure_database_password

        first = ensure_database_password(tmp_path)
        assert first.created is True
        assert first.source == "generated"
        assert len(first.password) >= 32
        before = first.path.read_bytes()

        second = ensure_database_password(tmp_path)
        assert second.created is False
        assert second.source == "file"
        assert second.password == first.password
        assert first.path.read_bytes() == before

    def test_secrets_env_is_never_modified(self, tmp_path):
        from app.core.secrets import (
            database_env_file,
            ensure_database_password,
            ensure_production_secrets,
        )

        secrets_result = ensure_production_secrets(tmp_path)
        secrets_bytes = secrets_result.path.read_bytes()

        ensure_database_password(tmp_path, external="installer-supplied-pw")

        assert secrets_result.path.read_bytes() == secrets_bytes
        assert database_env_file(tmp_path) != secrets_result.path
        assert database_env_file(tmp_path).exists()

    def test_external_password_is_persisted_once(self, tmp_path):
        from app.core.secrets import ensure_database_password

        first = ensure_database_password(
            tmp_path, external="installer-supplied-pw"
        )
        assert first.source == "external"
        assert first.created is True

        second = ensure_database_password(
            tmp_path, external="a-different-password"
        )
        assert second.created is False
        assert second.password == "installer-supplied-pw"

    def test_placeholder_external_password_is_refused(self, tmp_path):
        from app.core.secrets import SecretsError, ensure_database_password

        with pytest.raises(SecretsError):
            ensure_database_password(
                tmp_path, external="change-me-in-production"
            )

    def test_load_is_read_only(self, tmp_path):
        from app.core.secrets import load_database_password

        assert load_database_password(tmp_path) is None
        assert not (tmp_path / "config" / "database.env").exists()

    def test_missing_data_dir_fails_closed(self, monkeypatch):
        from app.core.secrets import SecretsError, ensure_database_password

        monkeypatch.delenv("DATA_DIR", raising=False)
        with pytest.raises(SecretsError) as excinfo:
            ensure_database_password()
        assert "DATA_DIR" in str(excinfo.value)

    def test_password_file_format(self, tmp_path):
        from app.core.secrets import ensure_database_password

        result = ensure_database_password(tmp_path)
        text = result.path.read_text(encoding="utf-8")
        assert text.startswith("# Supermarket Pro")
        assert "DATABASE_PASSWORD=" in text
        assert result.password in text.split("=", 1)[1]

    @pytest.mark.skipif(
        os.name != "posix", reason="POSIX file modes only"
    )
    def test_file_mode_is_restrictive(self, tmp_path):
        from app.core.secrets import ensure_database_password

        result = ensure_database_password(tmp_path)
        mode = os.stat(result.path).st_mode & 0o777
        assert mode == 0o600, oct(mode)


def test_dedicated_service_name_running_is_reused():
    """Regression: a Running dedicated instance must plan as `reuse`."""
    instance = _instance(service_name="postgresql-supermarketpro-18")
    plan = pp.plan_provisioning(port=5432, instances=[instance])
    assert plan.action == "reuse"


def test_unknown_service_state_never_claims_not_running():
    instance = _instance(
        service_name="postgresql-supermarketpro-18", service_state=None
    )
    plan = pp.plan_provisioning(port=5432, instances=[instance])
    assert plan.action == "install-dedicated"
    joined = " ".join(plan.reasons)
    assert "state could not be read" in joined
    assert "is not running" not in joined
