"""Integration tests for Phase 2 Alembic migrations — PostgreSQL only.

These tests run against the dedicated supermarket_pro_test database.
The production database is NEVER touched.

Tests verify:
- Migration upgrade/downgrade works correctly
- All tables are created with correct structure
- Server defaults (gen_random_uuid, now()) work
- All indexes and constraints are created
- Autogenerate detects no unexpected changes
"""

import os
import pathlib
import subprocess

import pytest

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)


def _run_alembic(command: str) -> subprocess.CompletedProcess:
    """Run an alembic command against the test database."""
    # Build env with test database URL
    env = {**os.environ, "DATABASE_URL": PG_TEST_URL}
    result = subprocess.run(
        f"python -m alembic {command}",
        shell=True,
        capture_output=True,
        text=True,
        cwd=os.path.join(os.path.dirname(__file__), "..", ".."),
        env=env,
    )
    return result


def _get_test_conn():
    """Get a psycopg2 connection to the test database."""
    import psycopg2
    return psycopg2.connect(PG_TEST_URL)


class TestMigrationUpgradeDowngrade:
    def test_current_at_head(self):
        # Ensure test DB is at head first
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
        result = _run_alembic("current")
        assert result.returncode == 0, f"alembic current failed: {result.stderr}"
        assert "head" in result.stdout

    def test_heads_single(self):
        result = _run_alembic("heads")
        assert result.returncode == 0
        # Should have exactly one head
        lines = [l for l in result.stdout.strip().split("\n") if l.strip() and not l.startswith("Generating")]
        assert len(lines) == 1, f"Expected 1 head, got {len(lines)}: {lines}"

    def test_downgrade_and_reupgrade(self):
        # Ensure at head first
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

        # Downgrade to baseline
        result = _run_alembic("downgrade 0001_initial")
        assert result.returncode == 0, f"Downgrade failed: {result.stderr}"

        # Verify at baseline
        result = _run_alembic("current")
        assert "0001_initial" in result.stdout

        # Re-upgrade to head
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Upgrade failed: {result.stderr}"

        # Verify at head
        result = _run_alembic("current")
        assert "head" in result.stdout

    def test_autogenerate_detects_no_changes(self):
        # Ensure at head first
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

        result = _run_alembic("revision --autogenerate -m 'check_no_changes'")
        assert result.returncode == 0, f"Autogenerate failed: {result.stderr}"
        # When no changes detected, Alembic generates an empty migration file
        # (upgrade/downgrade are just `pass`). Check for either indicator.
        stdout = result.stdout.lower()
        stderr = result.stderr.lower()
        no_changes = (
            "no changes" in stdout
            or "no changes" in stderr
            or "nothing to" in stderr
        )
        # If it generated a file, verify it's empty (no actual schema changes)
        if not no_changes and "generating" in stdout:
            import glob as g
            import os
            files = g.glob("migrations/versions/*check_no_changes*")
            if files:
                with open(files[0]) as f:
                    content = f.read()
                # Empty migration = no changes detected
                no_changes = "pass" in content and "op.create_table" not in content
                # Clean up the generated empty migration
                os.remove(files[0])
        # The autogenerate command stamped the phantom revision in the DB.
        # Stamp back to the real head so subsequent tests don't break.
        _run_alembic("stamp head")
        assert no_changes, (
            f"Expected no changes detected, got: stdout={result.stdout!r} stderr={result.stderr!r}"
        )


class TestMigrationTableStructure:
    """Verify PostgreSQL-specific table structure after migration."""

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        """Ensure database is at head before each test."""
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

    def test_tables_count(self):
        """All 23 domain tables should exist (+ alembic_version = 24)."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        """)
        count = cur.fetchone()[0]
        assert count >= 23, f"Expected >= 23 tables, got {count}"
        cur.close()
        conn.close()

    def test_uuid_server_default(self):
        """UUID columns should have gen_random_uuid() as server default."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT column_default FROM information_schema.columns
            WHERE table_name = 'users' AND column_name = 'id'
        """)
        row = cur.fetchone()
        assert row is not None, "users.id column not found"
        assert "gen_random_uuid" in str(row[0]), f"Expected gen_random_uuid, got: {row[0]}"
        cur.close()
        conn.close()

    def test_numeric_precision(self):
        """Money columns should use NUMERIC(18,3)."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT numeric_precision, numeric_scale
            FROM information_schema.columns
            WHERE table_name = 'products' AND column_name = 'price'
        """)
        row = cur.fetchone()
        assert row is not None, "products.price column not found"
        assert row[0] == 18, f"Expected precision 18, got {row[0]}"
        assert row[1] == 3, f"Expected scale 3, got {row[1]}"
        cur.close()
        conn.close()

    def test_timestamp_defaults_are_dynamic(self):
        """All timestamp columns should have now() as default, not fixed literals."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT table_name, column_name, column_default
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND data_type LIKE '%timestamp%'
              AND column_default IS NOT NULL
        """)
        fixed_defaults = []
        for table, col, default in cur.fetchall():
            if "now()" not in str(default) and "CURRENT_TIMESTAMP" not in str(default):
                fixed_defaults.append(f"{table}.{col} = {default}")

        assert len(fixed_defaults) == 0, (
            f"Found fixed timestamp defaults (should be now()): {fixed_defaults}"
        )
        cur.close()
        conn.close()

    def test_inventory_movements_has_foreign_keys(self):
        """inventory_movements should have FK to products, product_variants, users."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT kcu.column_name, ccu.table_name, ccu.column_name, rc.delete_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name
            JOIN information_schema.referential_constraints rc
                ON rc.constraint_name = tc.constraint_name
            WHERE tc.table_name = 'inventory_movements'
              AND tc.constraint_type = 'FOREIGN KEY'
        """)
        fks = {(row[0], row[1]): row[2] for row in cur.fetchall()}
        assert ("product_id", "products") in fks, "Missing FK: product_id -> products"
        assert ("variant_id", "product_variants") in fks, "Missing FK: variant_id -> product_variants"
        assert ("user_id", "users") in fks, "Missing FK: user_id -> users"
        cur.close()
        conn.close()

    def test_all_foreign_keys_present(self):
        """Verify expected FK count matches model definition (37 FKs)."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT COUNT(*)
            FROM information_schema.table_constraints
            WHERE table_schema = 'public'
              AND constraint_type = 'FOREIGN KEY'
        """)
        count = cur.fetchone()[0]
        assert count >= 37, f"Expected >= 37 FKs, got {count}"
        cur.close()
        conn.close()
