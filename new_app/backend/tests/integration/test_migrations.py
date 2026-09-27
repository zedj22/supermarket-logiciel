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


class TestPhase6SellingUnitsMigration:
    """Migration 0005/0006 — product_selling_units + purchase packaging tables."""

    SELLING_UNITS_REV = "c3d4e5f6a7b8"
    HEAD_REV = "c9d0e1f2a3b4"  # 0014 phase10 avg_cost backfill

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

    def test_chain_reaches_phase6_revision(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert self.HEAD_REV in result.stdout, (
            f"Expected alembic current at {self.HEAD_REV}, got: {result.stdout}"
        )
        # Selling-units revision is still in the linear chain
        history = _run_alembic("history")
        assert history.returncode == 0
        assert self.SELLING_UNITS_REV in history.stdout
        # Single head remains Phase 6 packaging correction
        heads = _run_alembic("heads")
        assert heads.returncode == 0
        assert self.HEAD_REV in heads.stdout

    def test_product_selling_units_table_exists(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name = 'product_selling_units'
            """
        )
        assert cur.fetchone()[0] == 1, "product_selling_units missing after upgrade"
        cur.close()
        conn.close()

    def test_product_selling_units_columns(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name, data_type, numeric_precision, numeric_scale
            FROM information_schema.columns
            WHERE table_name = 'product_selling_units'
            ORDER BY ordinal_position
            """
        )
        cols = {row[0]: row for row in cur.fetchall()}
        for required in (
            "id",
            "product_id",
            "name",
            "unit_type",
            "multiplier",
            "barcode",
            "selling_price",
            "is_base_unit",
            "archived_at",
        ):
            assert required in cols, f"missing column {required}"
        # multiplier NUMERIC(18,3)
        mult = cols["multiplier"]
        assert mult[1].startswith("numeric"), mult[1]
        assert mult[2] == 18 and mult[3] == 3, mult
        cur.close()
        conn.close()

    def test_selling_unit_unique_indexes(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT indexname FROM pg_indexes
            WHERE tablename = 'product_selling_units'
            """
        )
        names = {r[0] for r in cur.fetchall()}
        assert "ix_product_selling_units_barcode" in names, names
        assert any("product_id" in n for n in names), names
        cur.close()
        conn.close()

    def test_existing_products_and_variants_remain_valid(self):
        """0005 must not rewrite or drop products / product_variants rows."""
        conn = _get_test_conn()
        cur = conn.cursor()

        # Baseline: tables still queryable with expected columns
        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.columns
            WHERE table_name = 'products'
              AND column_name IN ('id', 'name', 'barcode', 'price', 'quantity')
            """
        )
        assert cur.fetchone()[0] == 5

        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.columns
            WHERE table_name = 'product_variants'
              AND column_name IN ('id', 'product_id', 'name', 'price', 'cost')
            """
        )
        assert cur.fetchone()[0] == 5

        # No destructive phase-6 rewrite: products still insertable with prior shape
        cur.execute(
            """
            INSERT INTO products (name, price, cost, quantity, unit)
            VALUES ('migration_canary', 1, 0, 1, 'piece')
            RETURNING id
            """
        )
        row = cur.fetchone()
        assert row is not None
        product_id = row[0]

        cur.execute(
            """
            INSERT INTO product_variants (product_id, name, quantity)
            VALUES (%s, 'canary-variant', 1)
            RETURNING id
            """,
            (product_id,),
        )
        var_row = cur.fetchone()
        assert var_row is not None

        # Cleanup canary
        cur.execute("DELETE FROM products WHERE id = %s", (product_id,))
        conn.commit()
        cur.close()
        conn.close()

    def test_no_destructive_rewrite_of_phase5_auth(self):
        """0005 only adds product_selling_units — does not drop Phase 4 tables."""
        conn = _get_test_conn()
        cur = conn.cursor()
        for table in ("users", "roles", "permissions", "auth_sessions", "products"):
            cur.execute(
                """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = 'public' AND table_name = %s
                """,
                (table,),
            )
            assert cur.fetchone()[0] == 1, f"table {table} missing"
        cur.close()
        conn.close()


class TestPhase6PurchasePackagingMigration:
    """Migration 0006 (d4e5f6a7b8c9) — purchase packaging / stock-breaking."""

    HEAD_REV = "c9d0e1f2a3b4"  # linear chain head after 0014

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

    def test_current_is_packaging_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert self.HEAD_REV in result.stdout, result.stdout

    def test_product_purchase_units_exists(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name = 'product_purchase_units'
            """
        )
        assert cur.fetchone()[0] == 1, "product_purchase_units missing"
        cur.close()
        conn.close()

    def test_product_stock_packages_exists(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name = 'product_stock_packages'
            """
        )
        assert cur.fetchone()[0] == 1, "product_stock_packages missing"
        cur.close()
        conn.close()

    def test_purchase_unit_columns(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name, data_type, numeric_precision, numeric_scale
            FROM information_schema.columns
            WHERE table_name = 'product_purchase_units'
            """
        )
        cols = {row[0]: row for row in cur.fetchall()}
        for required in (
            "id",
            "product_id",
            "name",
            "unit_type",
            "multiplier",
            "barcode",
            "is_default",
            "archived_at",
        ):
            assert required in cols, f"missing column {required}"
        mult = cols["multiplier"]
        assert mult[1].startswith("numeric"), mult[1]
        assert mult[2] == 18 and mult[3] == 3, mult
        # No selling_price on purchase units
        assert "selling_price" not in cols, "purchase units must not have selling_price"
        cur.close()
        conn.close()

    def test_stock_package_columns(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name, data_type, numeric_precision, numeric_scale
            FROM information_schema.columns
            WHERE table_name = 'product_stock_packages'
            """
        )
        cols = {row[0]: row for row in cur.fetchall()}
        for required in ("id", "product_id", "purchase_unit_id", "full_packages"):
            assert required in cols, f"missing column {required}"
        fp = cols["full_packages"]
        assert fp[1].startswith("numeric"), fp[1]
        assert fp[2] == 18 and fp[3] == 3, fp
        cur.close()
        conn.close()

    def test_purchase_line_document_unit_columns(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'purchase_lines'
              AND column_name IN (
                'purchase_unit_id', 'purchase_unit_name',
                'unit_multiplier', 'base_qty_equivalent'
              )
            """
        )
        names = {row[0] for row in cur.fetchall()}
        assert names == {
            "purchase_unit_id",
            "purchase_unit_name",
            "unit_multiplier",
            "base_qty_equivalent",
        }, names
        cur.close()
        conn.close()

    def test_inventory_movement_packaging_columns(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'inventory_movements'
              AND column_name IN (
                'document_quantity', 'document_unit',
                'purchase_unit_id', 'packages_change'
              )
            """
        )
        names = {row[0] for row in cur.fetchall()}
        assert names == {
            "document_quantity",
            "document_unit",
            "purchase_unit_id",
            "packages_change",
        }, names
        cur.close()
        conn.close()

    def test_unique_indexes_purchase_units(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT indexname FROM pg_indexes
            WHERE tablename = 'product_purchase_units'
            """
        )
        names = {r[0] for r in cur.fetchall()}
        assert "ix_product_purchase_units_barcode" in names, names
        cur.close()
        conn.close()

    def test_selling_units_preserved_after_0006(self):
        """0006 must not rewrite product_selling_units (Piece ×1, Box ×24)."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name = 'product_selling_units'
            """
        )
        assert cur.fetchone()[0] == 1
        cur.close()
        conn.close()

    def test_products_quantity_still_base_canonical(self):
        """products.quantity remains insertable in base units after 0006."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO products (name, price, cost, quantity, unit)
            VALUES ('packaging_canary', 1, 0, 240, 'piece')
            RETURNING id
            """
        )
        row = cur.fetchone()
        assert row is not None
        product_id = row[0]
        cur.execute("DELETE FROM products WHERE id = %s", (product_id,))
        conn.commit()
        cur.close()
        conn.close()


class TestPhase7InventoryPMPMigration:
    """Migration 0008 (f1a2b3c4d5e6) — products.avg_cost + movement cost cols."""

    HEAD_REV = "c9d0e1f2a3b4"

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

    def test_current_is_phase7_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert self.HEAD_REV in result.stdout, result.stdout
        heads = _run_alembic("heads")
        assert heads.returncode == 0
        assert self.HEAD_REV in heads.stdout

    def test_products_avg_cost_column(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name, data_type, numeric_precision, numeric_scale,
                   is_nullable, column_default
            FROM information_schema.columns
            WHERE table_name = 'products' AND column_name = 'avg_cost'
            """
        )
        row = cur.fetchone()
        assert row is not None, "products.avg_cost missing after 0008"
        assert row[1].startswith("numeric"), row[1]
        assert row[2] == 18 and row[3] == 3, row
        assert row[4] == "NO", f"avg_cost should be NOT NULL, got {row[4]}"
        cur.close()
        conn.close()

    def test_inventory_movement_cost_columns(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name, data_type, numeric_precision, numeric_scale,
                   is_nullable
            FROM information_schema.columns
            WHERE table_name = 'inventory_movements'
              AND column_name IN ('unit_cost', 'avg_cost_after')
            """
        )
        cols = {row[0]: row for row in cur.fetchall()}
        assert "unit_cost" in cols, "unit_cost missing"
        assert "avg_cost_after" in cols, "avg_cost_after missing"
        for name, row in cols.items():
            assert row[1].startswith("numeric"), (name, row[1])
            assert row[2] == 18 and row[3] == 3, (name, row)
            assert row[4] == "YES", f"{name} should be nullable"
        cur.close()
        conn.close()

    def test_movement_date_index_exists(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT indexname FROM pg_indexes
            WHERE tablename = 'inventory_movements'
              AND indexname = 'ix_inventory_movements_movement_date'
            """
        )
        assert cur.fetchone() is not None, "movement_date index missing"
        cur.close()
        conn.close()

    def test_products_cost_not_renamed(self):
        """products.cost must still exist (nominal/last-purchase)."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_name = 'products' AND column_name = 'cost'
            """
        )
        assert cur.fetchone()[0] == 1
        cur.close()
        conn.close()

    def test_existing_rows_default_avg_cost_zero(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO products (name, price, cost, quantity, unit)
            VALUES ('pmp_canary', 1, 0, 1, 'piece')
            RETURNING id, avg_cost
            """
        )
        row = cur.fetchone()
        assert row is not None
        assert float(row[1]) == 0.0
        cur.execute("DELETE FROM products WHERE id = %s", (row[0],))
        conn.commit()
        cur.close()
        conn.close()

    def test_no_destructive_rewrite(self):
        """0008 only adds columns — does not drop prior tables/columns."""
        conn = _get_test_conn()
        cur = conn.cursor()
        for table in (
            "products",
            "product_variants",
            "inventory_movements",
            "product_selling_units",
            "product_purchase_units",
            "product_stock_packages",
            "users",
        ):
            cur.execute(
                """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = 'public' AND table_name = %s
                """,
                (table,),
            )
            assert cur.fetchone()[0] == 1, f"table {table} missing"
        cur.close()
        conn.close()


# ---------------------------------------------------------------------------
# Phase 10 bugfix: products.avg_cost backfill (0014)
# ---------------------------------------------------------------------------


class TestPhase10AvgCostBackfillMigration:
    """Migration 0014 (c9d0e1f2a3b4) - seeds a PMP that was never priced.

    0008 added products.avg_cost with DEFAULT 0 and no backfill, so every
    product row created before Phase 7 reported a PMP of 0 while
    products.cost held a real value. The pack profitability preview
    (SUM(base_quantity * avg_cost)) then computed cost 0 and a margin of
    exactly 100%.
    """

    HEAD_REV = "c9d0e1f2a3b4"
    PREV_REV = "b7c8d9e0f1a2"

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

    def _rewind(self):
        """Rewind one revision so 0014 runs again over our canary rows."""
        result = _run_alembic(f"downgrade {self.PREV_REV}")
        assert result.returncode == 0, f"Downgrade failed: {result.stderr}"

    def _upgrade(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Upgrade failed: {result.stderr}"

    def _insert_product(self, cost, avg_cost, name):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO products (name, price, cost, quantity, unit, avg_cost)
            VALUES (%s, %s, %s, %s, 'piece', %s)
            RETURNING id
            """,
            (name, cost, cost, 5, avg_cost),
        )
        product_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()
        return product_id

    def _insert_movement(self, product_id, movement_type, unit_cost, change):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO inventory_movements (
                id, product_id, movement_type, quantity_change,
                quantity_before, quantity_after, unit_cost, movement_date
            )
            VALUES (gen_random_uuid(), %s, %s, %s, %s, %s, %s, now())
            """,
            (product_id, movement_type, change, 0, change, unit_cost),
        )
        conn.commit()
        cur.close()
        conn.close()

    def _avg_cost(self, product_id):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("SELECT avg_cost FROM products WHERE id = %s", (product_id,))
        value = float(cur.fetchone()[0])
        cur.close()
        conn.close()
        return value

    def _cleanup(self, product_id):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM inventory_movements WHERE product_id = %s",
            (product_id,),
        )
        cur.execute("DELETE FROM products WHERE id = %s", (product_id,))
        conn.commit()
        cur.close()
        conn.close()

    def test_current_is_backfill_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert self.HEAD_REV in result.stdout, result.stdout
        heads = _run_alembic("heads")
        assert heads.returncode == 0
        assert self.HEAD_REV in heads.stdout

    def test_legacy_zero_avg_cost_seeded_from_nominal_cost(self):
        """A pre-Phase-7 row with a real cost must stop reporting PMP 0."""
        self._rewind()
        product_id = self._insert_product(
            cost="240.000", avg_cost="0", name="legacy_backfill_canary"
        )
        # sales never price the PMP - they must not block the seed
        self._insert_movement(
            product_id, movement_type="sale", unit_cost=None, change=-1
        )
        assert self._avg_cost(product_id) == 0.0

        self._upgrade()
        assert self._avg_cost(product_id) == 240.0

        # idempotent: running the head again changes nothing
        self._upgrade()
        assert self._avg_cost(product_id) == 240.0

        self._cleanup(product_id)

    def test_receipt_priced_pmp_is_never_rewritten(self):
        """A PMP already owned by an explicit receipt stays untouched."""
        self._rewind()
        product_id = self._insert_product(
            cost="240.000", avg_cost="0", name="priced_backfill_canary"
        )
        # a priced receipt owns the average (even at 0)
        self._insert_movement(
            product_id,
            movement_type="adjustment",
            unit_cost="0.000",
            change=10,
        )

        self._upgrade()
        assert self._avg_cost(product_id) == 0.0

        self._cleanup(product_id)

    def test_priced_rows_and_zero_cost_rows_are_left_alone(self):
        """cost = 0 stays 0 - there is nothing to seed from."""
        self._rewind()
        product_id = self._insert_product(
            cost="0", avg_cost="0", name="free_backfill_canary"
        )

        self._upgrade()
        assert self._avg_cost(product_id) == 0.0

        self._cleanup(product_id)
