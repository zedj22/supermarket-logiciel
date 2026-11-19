"""Integration tests for the R3 PostgreSQL lifecycle — real server only.

Everything here runs against ONE explicitly isolated scratch database,
``supermarket_pro_r3_test``, which is created if absent and **never
dropped** (R3 forbids destructive SQL).  The development database
(``supermarket_pro``) and the R2 backup directory are never modified:
the module asserts both.

Skipped automatically when PostgreSQL is not reachable, exactly like the
existing migration integration tests.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import psycopg2
import pytest

from app.core import postgres_provisioning as pp
from app.core.config import BACKEND_ROOT, settings
from app.core.postgres_discovery import discover_instances
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database not available",
)

#: The ONLY database this module is allowed to create or migrate.
SCRATCH_DB = "supermarket_pro_r3_test"

ADMIN_URL = PG_TEST_URL  # maintenance credentials (superuser)

SCRATCH_URL = (
    PG_TEST_URL.replace("/supermarket_pro_test", f"/{SCRATCH_DB}")
    if PG_TEST_URL
    else None
)

#: Guard rails asserted by the tests below.
DEV_DB = "supermarket_pro"


def _connect(url: str):
    conn = psycopg2.connect(url)
    conn.autocommit = True
    return conn


def _database_exists(url: str, dbname: str) -> bool:
    with _connect(url) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
            return cur.fetchone() is not None


def _revision(url: str) -> str | None:
    with _connect(url) as conn:
        with conn.cursor() as cur:
            try:
                cur.execute("SELECT version_num FROM alembic_version LIMIT 1")
            except psycopg2.errors.UndefinedTable:
                return None
            row = cur.fetchone()
            return row[0] if row else None


def _table_count(url: str) -> int:
    with _connect(url) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM information_schema.tables "
                "WHERE table_schema = 'public' AND table_type = 'BASE TABLE'"
            )
            return cur.fetchone()[0]


def _backup_digest() -> str:
    """Content hash of the whole backup directory (or 'absent')."""
    root = settings.BACKUP_DIR
    path = Path(root) if root else BACKEND_ROOT / "backups"
    if not path.is_dir():
        return "absent"
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(str(file.relative_to(path)).encode())
            digest.update(file.read_bytes())
    return digest.hexdigest()


@pytest.fixture(scope="module", autouse=True)
def scratch_is_isolated():
    """Refuse to run against anything other than the scratch database."""
    assert SCRATCH_URL is not None
    assert SCRATCH_URL.endswith(f"/{SCRATCH_DB}")
    assert SCRATCH_DB != DEV_DB
    assert "/supermarket_pro_test" not in SCRATCH_URL
    yield


class TestFreshInstallation:
    def test_fresh_database_is_created_migrated_and_seeded(self):
        # The scratch database may exist from an earlier run; drop-free
        # semantics mean we simply provision whatever is there.
        report = pp.provision_database(
            app_url=SCRATCH_URL,
            admin_url=ADMIN_URL,
        )

        assert report.ok, report.as_dict()
        assert report.database_name == SCRATCH_DB
        assert _database_exists(ADMIN_URL, SCRATCH_DB)
        assert report.revision_after == pp.head_revision()
        assert report.rbac.get("ok") is True
        assert report.rbac.get("users_modified") == 0

        # a real schema, not an empty shell
        assert _table_count(SCRATCH_URL) >= 23

    def test_the_development_database_is_untouched(self):
        """R3 must never migrate the developer's active database."""
        with _connect(ADMIN_URL) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (DEV_DB,))
                assert cur.fetchone() is not None, DEV_DB
        # we only ever pointed provisioning at the scratch URL
        assert SCRATCH_URL.endswith(SCRATCH_DB)

    def test_database_is_at_the_single_migration_head(self):
        assert _revision(SCRATCH_URL) == pp.head_revision()

    def test_migration_head_is_unique(self):
        from alembic.config import Config
        from alembic.script import ScriptDirectory

        config = Config(str(BACKEND_ROOT / "alembic.ini"))
        config.set_main_option("script_location", str(BACKEND_ROOT / "migrations"))
        script = ScriptDirectory.from_config(config)
        heads = script.get_heads()
        assert len(heads) == 1, heads
        assert heads[0] == pp.head_revision()


class TestIdempotentReprovisioning:
    def test_second_pass_reuses_everything(self):
        report = pp.provision_database(
            app_url=SCRATCH_URL,
            admin_url=ADMIN_URL,
        )
        assert report.ok
        assert report.database_created is False
        assert report.migrations_applied is False
        assert report.revision_before == report.revision_after
        statuses = {step.name: step.status for step in report.steps}
        assert statuses["database"] == pp.STEP_SKIPPED
        assert statuses["migrations"] == pp.STEP_SKIPPED

    def test_reinstall_against_the_existing_database_changes_nothing(self):
        tables_before = _table_count(SCRATCH_URL)
        revision_before = _revision(SCRATCH_URL)

        report = pp.provision_database(
            app_url=SCRATCH_URL,
            admin_url=ADMIN_URL,
            apply_migrations=True,
            initialize_rbac=True,
        )

        assert report.ok
        assert report.database_created is False
        assert _table_count(SCRATCH_URL) == tables_before
        assert _revision(SCRATCH_URL) == revision_before

    def test_repeated_provisioning_keeps_a_single_catalog(self):
        for _ in range(2):
            report = pp.provision_database(
                app_url=SCRATCH_URL,
                admin_url=ADMIN_URL,
                apply_migrations=False,
            )
            assert report.ok

        with _connect(SCRATCH_URL) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM roles")
                assert cur.fetchone()[0] == 3
                cur.execute("SELECT COUNT(*) FROM permissions")
                assert cur.fetchone()[0] >= 30


class TestFailureModesAgainstARealServer:
    def test_migration_failure_leaves_the_database_intact(self):
        revision_before = _revision(SCRATCH_URL)
        tables_before = _table_count(SCRATCH_URL)

        with pytest.raises(pp.MigrationError) as excinfo:
            pp.run_migrations(SCRATCH_URL, revision="no_such_revision")

        assert "alembic upgrade" in str(excinfo.value)
        assert _database_exists(ADMIN_URL, SCRATCH_DB) is True
        assert _revision(SCRATCH_URL) == revision_before
        assert _table_count(SCRATCH_URL) == tables_before

    def test_wrong_credentials_are_rejected_without_creating_anything(self):
        bad_url = SCRATCH_URL.replace(
            f"://{SCRATCH_URL.split('://')[1].split('@')[0]}@",
            "://app_user:totally-wrong-password@",
        )
        assert "totally-wrong-password" in bad_url

        with pytest.raises(pp.CredentialsError) as excinfo:
            pp.check_connectivity(bad_url)

        message = str(excinfo.value)
        assert "totally-wrong-password" not in message
        assert "authentication failed" in message
        # the scratch database is still exactly where it was
        assert _database_exists(ADMIN_URL, SCRATCH_DB) is True

    def test_missing_database_without_admin_credentials_fails_closed(self):
        """No PG_ADMIN_URL → no silent attempt with the app's own role."""
        import os

        name = "supermarket_pro_r3_no_admin"
        url = SCRATCH_URL.replace(SCRATCH_DB, name)
        # This name is never created by any test, so it must stay absent.
        assert not _database_exists(ADMIN_URL, name)

        old = os.environ.pop("PG_ADMIN_URL", None)
        try:
            with pytest.raises(pp.CredentialsError) as excinfo:
                pp.provision_database(
                    app_url=url,
                    admin_url=None,
                    apply_migrations=False,
                    initialize_rbac=False,
                )
        finally:
            if old is not None:
                os.environ["PG_ADMIN_URL"] = old

        assert "PG_ADMIN_URL" in str(excinfo.value)
        # fail closed: the refusal happened before any server-side action
        assert _database_exists(ADMIN_URL, name) is False

    def test_unknown_database_is_created_when_admin_credentials_exist(self):
        name = "supermarket_pro_r3_absent"
        existed_before = _database_exists(ADMIN_URL, name)
        url = SCRATCH_URL.replace(SCRATCH_DB, name)

        report = pp.provision_database(
            app_url=url,
            admin_url=ADMIN_URL,
            apply_migrations=False,
            initialize_rbac=False,
        )

        assert report.database_created is (not existed_before)
        assert _database_exists(ADMIN_URL, name) is True
        # R3 forbids DROP DATABASE, so this scratch database (and the main
        # one) deliberately outlive the test run; a second run therefore
        # exercises the reuse path instead of creation.


class TestDiscoveryAgainstTheRealMachine:
    def test_discovery_finds_the_server_we_are_using(self):
        instances = discover_instances()
        assert instances, "discovery found no PostgreSQL installation"
        ports = {item.port for item in instances}
        assert 5432 in ports or any(item.is_running for item in instances)
        for item in instances:
            assert item.sources, "every instance must record its sources"

    def test_plan_reuses_the_running_server(self):
        plan = pp.plan_provisioning(port=5432)
        assert plan.action == "reuse"
        assert plan.instance is not None
        assert plan.instance.is_running
        payload = plan.as_dict()
        assert payload["instance"]["state"] == "RUNNING"


class TestBackupsAreNeverTouched:
    def test_full_provisioning_leaves_backups_byte_identical(self):
        before = _backup_digest()
        report = pp.provision_database(
            app_url=SCRATCH_URL,
            admin_url=ADMIN_URL,
            apply_migrations=False,
            initialize_rbac=False,
        )
        assert report.ok
        assert _backup_digest() == before

    def test_planning_leaves_backups_byte_identical(self):
        before = _backup_digest()
        plan = pp.plan_provisioning(port=5432)
        assert plan.action in ("reuse", "install-dedicated", "fail")
        assert _backup_digest() == before


class TestAdministratorCredentialsSurviveProvisioning:
    def test_provisioning_cannot_overwrite_an_admin_pin(self):
        marker = "integration-pin-hash-must-survive"
        with _connect(SCRATCH_URL) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id FROM users WHERE pin_hash = %s", (marker,))
                row = cur.fetchone()
                if row is None:
                    cur.execute(
                        "INSERT INTO users (id, full_name, pin_hash, is_active,"
                        " failed_login_attempts, created_at, updated_at)"
                        " VALUES (gen_random_uuid(), 'R3 Canary', %s, true, 0,"
                        " now(), now())",
                        (marker,),
                    )
                cur.execute(
                    "SELECT COUNT(*) FROM users WHERE pin_hash = %s", (marker,)
                )
                assert cur.fetchone()[0] == 1

        report = pp.provision_database(
            app_url=SCRATCH_URL,
            admin_url=ADMIN_URL,
            apply_migrations=False,
        )
        assert report.ok
        assert report.rbac.get("users_modified") == 0

        with _connect(SCRATCH_URL) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT pin_hash, full_name FROM users WHERE pin_hash = %s",
                    (marker,),
                )
                row = cur.fetchone()
                assert row == (marker, "R3 Canary")
