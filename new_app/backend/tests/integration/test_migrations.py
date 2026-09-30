"""Integration tests for Phase 2 Alembic migrations â€” PostgreSQL only.

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
    """Migration 0005/0006 â€” product_selling_units + purchase packaging tables."""

    SELLING_UNITS_REV = "c3d4e5f6a7b8"
    HEAD_REV = "2f6b9c4d8a31"  # 0019 expense title optional head

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
        """0005 only adds product_selling_units â€” does not drop Phase 4 tables."""
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
    """Migration 0006 (d4e5f6a7b8c9) â€” purchase packaging / stock-breaking."""

    HEAD_REV = "2f6b9c4d8a31"  # linear chain head after 0019

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
        """0006 must not rewrite product_selling_units (Piece Ã—1, Box Ã—24)."""
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
    """Migration 0008 (f1a2b3c4d5e6) â€” products.avg_cost + movement cost cols."""

    HEAD_REV = "2f6b9c4d8a31"

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
        """0008 only adds columns â€” does not drop prior tables/columns."""
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

    HEAD_REV = "2f6b9c4d8a31"
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


class TestPhase12ReturnsVoidsMigration:
    """0016_phase12_returns_voids â€” void columns + return snapshot columns."""

    HEAD_REV = "2f6b9c4d8a31"
    PREVIOUS_REV = "d3e4f5a6b7c8"

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        """Ensure database is at head before each test."""
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"

    @staticmethod
    def _columns(table: str) -> dict:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT column_name, data_type, is_nullable,
                   numeric_precision, numeric_scale, column_default
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = %s
            """,
            (table,),
        )
        columns = {row[0]: row for row in cur.fetchall()}
        cur.close()
        conn.close()
        return columns

    @staticmethod
    def _indexes(table: str) -> set:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT indexname FROM pg_indexes "
            "WHERE schemaname = 'public' AND tablename = %s",
            (table,),
        )
        names = {row[0] for row in cur.fetchall()}
        cur.close()
        conn.close()
        return names

    @staticmethod
    def _foreign_keys(table: str) -> dict:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT kcu.column_name, ccu.table_name, rc.delete_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name
            JOIN information_schema.referential_constraints rc
                ON rc.constraint_name = tc.constraint_name
            WHERE tc.table_schema = 'public'
              AND tc.table_name = %s
              AND tc.constraint_type = 'FOREIGN KEY'
            """,
            (table,),
        )
        fks = {row[0]: (row[1], row[2]) for row in cur.fetchall()}
        cur.close()
        conn.close()
        return fks

    def test_current_is_phase12_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert self.HEAD_REV in result.stdout, result.stdout
        heads = _run_alembic("heads")
        assert heads.returncode == 0
        assert self.HEAD_REV in heads.stdout

    def test_sales_void_columns_exist_and_are_nullable(self):
        """GATE 9: void metadata columns exist, all nullable (never forced)."""
        columns = self._columns("sales")
        for name in ("voided_at", "voided_by", "void_reason"):
            assert name in columns, f"sales.{name} missing"
            assert columns[name][2] == "YES", f"sales.{name} must be nullable"

    @staticmethod
    def _money_shape(names) -> dict:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT attname, atttypid::regtype::text, attnotnull,
                   COALESCE(pg_get_expr(adbin, adrelid), '')
            FROM pg_attribute att
            JOIN pg_class c ON c.oid = att.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = att.attrelid
                 AND d.adnum = att.attnum
            WHERE n.nspname = 'public'
              AND c.relname = 'sales'
              AND att.attnum > 0
              AND NOT att.attisdropped
              AND att.attname = ANY(%s)
            """,
            (list(names),),
        )
        shape = {row[0]: row[1:] for row in cur.fetchall()}
        cur.close()
        conn.close()
        return shape

    def test_phase12_does_not_touch_sales_money_columns_downgrade(self):
        """The money shape is identical on both sides of the migration."""
        money = ("subtotal", "discount", "total", "paid", "change")

        result = _run_alembic("upgrade head")
        assert result.returncode == 0, result.stderr
        at_head = self._money_shape(money)

        result = _run_alembic(f"downgrade {self.PREVIOUS_REV}")
        assert result.returncode == 0, result.stderr
        try:
            at_previous = self._money_shape(money)
        finally:
            result = _run_alembic("upgrade head")
            assert result.returncode == 0, result.stderr

        assert at_head == at_previous, (
            f"sales money columns changed across 0016: {at_head} != {at_previous}"
        )

    def test_sales_voided_by_foreign_key(self):
        fks = self._foreign_keys("sales")
        assert "voided_by" in fks, "Missing FK: sales.voided_by -> users"
        assert fks["voided_by"][0] == "users"

    def test_returns_phase12_columns(self):
        columns = self._columns("returns")
        assert columns["client_request_id"][1] == "character varying"
        assert columns["client_request_id"][2] == "YES"
        for name in ("subtotal", "discount"):
            assert name in columns, f"returns.{name} missing"
            assert columns[name][1] == "numeric"
            assert columns[name][3] == 18 and columns[name][4] == 3
            assert columns[name][2] == "NO"

    def test_returns_unique_client_request_id_index(self):
        """GATE 16: the idempotency key is unique, not merely indexed."""
        assert "ix_returns_client_request_id" in self._indexes("returns")

        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT indisunique
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relname = 'ix_returns_client_request_id'
            """
        )
        row = cur.fetchone()
        assert row is not None, "ix_returns_client_request_id not found"
        assert row[0] is True, "client_request_id index must be UNIQUE"
        cur.close()
        conn.close()

    def test_returns_return_date_index(self):
        assert "ix_returns_return_date" in self._indexes("returns")

    def test_return_lines_product_id_is_nullable(self):
        """A charged pack summary line carries pack_id, not product_id."""
        columns = self._columns("return_lines")
        assert columns["product_id"][2] == "YES", "product_id must be nullable"

    def test_return_lines_snapshot_columns(self):
        columns = self._columns("return_lines")
        expected = {
            "pack_id": "uuid",
            "variant_name": "character varying",
            "selling_unit_name": "character varying",
            "selling_unit_multiplier": "numeric",
            "quantity_base": "numeric",
            "unit_cost": "numeric",
            "line_discount": "numeric",
        }
        for name, data_type in expected.items():
            assert name in columns, f"return_lines.{name} missing"
            assert columns[name][1] == data_type, (
                f"return_lines.{name} is {columns[name][1]}, expected {data_type}"
            )

    def test_return_lines_pack_id_foreign_key_and_index(self):
        fks = self._foreign_keys("return_lines")
        assert "pack_id" in fks, "Missing FK: return_lines.pack_id -> packs"
        assert fks["pack_id"][0] == "packs"
        assert fks["pack_id"][1] == "RESTRICT"
        assert "ix_return_lines_pack_id" in self._indexes("return_lines")

    def test_downgrade_and_reupgrade_removes_phase12_columns(self):
        result = _run_alembic(f"downgrade {self.PREVIOUS_REV}")
        assert result.returncode == 0, result.stderr

        try:
            sales = self._columns("sales")
            assert "voided_at" not in sales, "voided_at survived the downgrade"
            returns = self._columns("returns")
            assert "client_request_id" not in returns
            return_lines = self._columns("return_lines")
            assert "pack_id" not in return_lines
            assert return_lines["product_id"][2] == "NO", (
                "product_id must go back to NOT NULL"
            )
        finally:
            result = _run_alembic("upgrade head")
            assert result.returncode == 0, result.stderr


class TestPhase17ReturnReasonOptionalMigration:
    """0017_return_reason_optional â€” fix round 1 (product-owner decision).

    ``returns.reason`` becomes nullable and loses its ``'other'`` server
    default, so an omitted / ``null`` / blank API reason persists as NULL.
    Nothing else changes: a *supplied* reason is still vocabulary-validated
    by ``ReturnCreateRequest`` (unit tests), and the void reason rule is
    untouched (``sales.void_reason`` stays exactly as 0016 left it; its
    mandatory non-blank rule is API-level, asserted in
    ``tests/unit/test_void.py::test_reason_is_mandatory``).
    """

    HEAD_REV = "2f6b9c4d8a31"
    PREVIOUS_REV = "e4f5a6b7c8d9"
    TEST_RETURN_NUMBER = "RET-TEST-0017-NO-REASON"

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        """Ensure head before, and a clean database after, every test."""
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
        yield
        self._delete_test_return()
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Restore upgrade failed: {result.stderr}"

    @staticmethod
    def _column(table: str, name: str):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT data_type, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = %s AND column_name = %s
            """,
            (table, name),
        )
        row = cur.fetchone()
        cur.close()
        conn.close()
        return row

    @classmethod
    def _delete_test_return(cls) -> None:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM returns WHERE return_number = %s",
            (cls.TEST_RETURN_NUMBER,),
        )
        conn.commit()
        cur.close()
        conn.close()

    def test_reason_is_nullable_without_server_default(self):
        row = self._column("returns", "reason")
        assert row is not None, "returns.reason missing"
        data_type, is_nullable, column_default = row
        assert data_type == "character varying"
        assert is_nullable == "YES", "returns.reason must be nullable (fix round 1)"
        assert column_default is None, (
            f"returns.reason must have no server default, got {column_default!r}"
        )

    def test_void_reason_column_is_untouched(self):
        """Fix round 1 must not touch void columns (void reason stays API-mandatory)."""
        row = self._column("sales", "void_reason")
        assert row is not None, "sales.void_reason missing"
        assert row[1] == "YES", "sales.void_reason stays nullable at the DB"

    def test_null_reason_row_is_persistable_and_blocks_downgrade(self):
        """A return with no reason persists, and 0017 refuses to go back."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO returns
                (return_number, reason, subtotal, discount, total)
            VALUES (%s, NULL, 0, 0, 0)
            """,
            (self.TEST_RETURN_NUMBER,),
        )
        conn.commit()
        cur.execute(
            "SELECT reason FROM returns WHERE return_number = %s",
            (self.TEST_RETURN_NUMBER,),
        )
        assert cur.fetchone()[0] is None, "reason must persist as NULL"
        cur.close()
        conn.close()

        try:
            result = _run_alembic(f"downgrade {self.PREVIOUS_REV}")
            assert result.returncode != 0, (
                "downgrade must refuse while a return has reason IS NULL"
            )
            output = (result.stdout or "") + (result.stderr or "")
            assert "reason IS NULL" in output, output
            current = _run_alembic("current")
            assert self.HEAD_REV in current.stdout, (
                "a failed downgrade must not move alembic_version"
            )
        finally:
            self._delete_test_return()

        result = _run_alembic(f"downgrade {self.PREVIOUS_REV}")
        assert result.returncode == 0, result.stderr
        try:
            columns = TestPhase12ReturnsVoidsMigration._columns("returns")
            assert columns["reason"][2] == "NO", "NOT NULL must come back"
            assert "other" in (columns["reason"][5] or ""), (
                f"'other' server default must come back, got {columns['reason'][5]!r}"
            )
        finally:
            result = _run_alembic("upgrade head")
            assert result.returncode == 0, result.stderr


class TestPhase13ExpensesMigration:
    """0018_phase13_expenses - lifecycle, cancellation, idempotency, query path.

    The revision is additive: it only adds columns/indexes to ``expenses``
    and never rewrites an existing value (decision record section 5).
    """

    HEAD_REV = "2f6b9c4d8a31"
    PREVIOUS_REV = "f5a6b7c8d9e0"
    TEST_TITLE = "PHASE13-MIGRATION-TEST"

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        """Ensure head before, and a clean database after, every test."""
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
        yield
        self._delete_test_rows()
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Restore upgrade failed: {result.stderr}"

    # â”€â”€ helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    @staticmethod
    def _columns(table: str) -> dict:
        return TestPhase12ReturnsVoidsMigration._columns(table)

    @staticmethod
    def _indexes(table: str) -> set:
        return TestPhase12ReturnsVoidsMigration._indexes(table)

    @staticmethod
    def _index_definition(index_name: str) -> str:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT indexdef FROM pg_indexes "
            "WHERE schemaname = 'public' AND indexname = %s",
            (index_name,),
        )
        row = cur.fetchone()
        cur.close()
        conn.close()
        return row[0] if row else ""

    @staticmethod
    def _foreign_key_rules(table: str) -> dict:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT kcu.column_name, ccu.table_name, rc.delete_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name
            JOIN information_schema.referential_constraints rc
                ON rc.constraint_name = tc.constraint_name
            WHERE tc.table_schema = 'public'
              AND tc.table_name = %s
              AND tc.constraint_type = 'FOREIGN KEY'
            """,
            (table,),
        )
        rules = {row[0]: (row[1], row[2]) for row in cur.fetchall()}
        cur.close()
        conn.close()
        return rules

    @classmethod
    def _delete_test_rows(cls) -> None:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("DELETE FROM expenses WHERE title = %s", (cls.TEST_TITLE,))
        conn.commit()
        cur.close()
        conn.close()

    @classmethod
    def _insert(cls, *, client_request_id=None) -> None:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO expenses (title, category, amount, client_request_id)
            VALUES (%s, 'rent', 10.000, %s)
            """,
            (cls.TEST_TITLE, client_request_id),
        )
        conn.commit()
        cur.close()
        conn.close()

    @classmethod
    def _rows(cls) -> list:
        """title / amount â€” always present, survives a downgrade."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT title, amount::text FROM expenses WHERE title = %s",
            (cls.TEST_TITLE,),
        )
        rows = cur.fetchall()
        cur.close()
        conn.close()
        return rows

    @classmethod
    def _keys(cls) -> list:
        """client_request_id values (only valid while the column exists)."""
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT client_request_id FROM expenses WHERE title = %s",
            (cls.TEST_TITLE,),
        )
        keys = [row[0] for row in cur.fetchall()]
        cur.close()
        conn.close()
        return keys

    # â”€â”€ tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    def test_current_is_phase13_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert self.HEAD_REV in result.stdout, result.stdout

        heads = _run_alembic("heads")
        assert heads.returncode == 0, heads.stderr
        assert self.HEAD_REV in heads.stdout, heads.stdout

    def test_lifecycle_and_payment_columns(self):
        columns = self._columns("expenses")

        status = columns.get("status")
        assert status is not None, "expenses.status missing"
        assert status[1] == "character varying", status[1]
        assert status[2] == "NO", "status must be NOT NULL"
        assert "'posted'" in (status[5] or ""), f"got {status[5]!r}"

        drawer = columns.get("paid_from_drawer")
        assert drawer is not None, "expenses.paid_from_drawer missing"
        assert drawer[1] == "boolean", drawer[1]
        assert drawer[2] == "NO", "paid_from_drawer must be NOT NULL"
        assert "true" in (drawer[5] or "").lower(), f"got {drawer[5]!r}"

    def test_cancellation_columns_and_set_null_fk(self):
        columns = self._columns("expenses")
        for name in ("cancelled_at", "cancelled_by", "cancel_reason"):
            assert name in columns, f"expenses.{name} missing"
            assert columns[name][2] == "YES", f"{name} must stay nullable"
        assert columns["cancel_reason"][1] == "character varying"
        assert columns["cancelled_at"][1] == "timestamp with time zone"

        rules = self._foreign_key_rules("expenses")
        assert rules["cancelled_by"] == ("users", "SET NULL"), rules
        assert rules["user_id"] == ("users", "SET NULL"), rules

    def test_idempotency_and_query_indexes(self):
        indexes = self._indexes("expenses")
        for name in (
            "ux_expenses_client_request_id",
            "ix_expenses_expense_date",
            "ix_expenses_user_id",
        ):
            assert name in indexes, f"{name} missing from expenses"

        definition = self._index_definition("ux_expenses_client_request_id")
        assert "UNIQUE" in definition, definition
        assert "client_request_id IS NOT NULL" in definition, definition

    def test_null_keys_never_collide_but_duplicates_do(self):
        import psycopg2

        # NULL (pre-Phase-13 rows) must never collide
        self._insert(client_request_id=None)
        self._insert(client_request_id=None)
        assert len(self._rows()) == 2

        self._insert(client_request_id="phase13-dup-key")
        conn = _get_test_conn()
        cur = conn.cursor()
        try:
            with pytest.raises(psycopg2.errors.UniqueViolation):
                cur.execute(
                    "INSERT INTO expenses "
                    "(title, category, amount, client_request_id) "
                    "VALUES (%s, 'rent', 10.000, %s)",
                    (self.TEST_TITLE, "phase13-dup-key"),
                )
                conn.commit()
        finally:
            conn.rollback()
            cur.close()
            conn.close()

    def test_downgrade_drops_only_what_0018_added(self):
        self._insert(client_request_id="phase13-downgrade-key")
        result = _run_alembic(f"downgrade {self.PREVIOUS_REV}")
        assert result.returncode == 0, result.stderr
        try:
            columns = self._columns("expenses")
            for name in (
                "status",
                "paid_from_drawer",
                "cancelled_at",
                "cancelled_by",
                "cancel_reason",
                "client_request_id",
            ):
                assert name not in columns, f"{name} must be dropped"
            for name in ("title", "category", "amount", "expense_date", "note"):
                assert name in columns, f"{name} must survive the downgrade"

            indexes = self._indexes("expenses")
            for name in (
                "ux_expenses_client_request_id",
                "ix_expenses_expense_date",
                "ix_expenses_user_id",
            ):
                assert name not in indexes, f"{name} must be dropped"

            rows = self._rows()
            assert len(rows) == 1, "the expense row itself is never deleted"
            assert rows[0][0] == self.TEST_TITLE
            assert rows[0][1] == "10.000"
        finally:
            result = _run_alembic("upgrade head")
            assert result.returncode == 0, result.stderr

        columns = self._columns("expenses")
        assert "'posted'" in (columns["status"][5] or "")
        assert "true" in (columns["paid_from_drawer"][5] or "").lower()
        assert self._keys() == [None], "the key column comes back empty"


class TestPhase13TitleOptionalMigration:
    """0019_expense_title_optional - Fix Round 2: ``expenses.title`` NULL.

    0018 is never modified; this single follow-up revision only drops the
    NOT NULL constraint that 0002 introduced, so an omitted / blank
    expense title can be stored as NULL (decision record B1).
    """

    HEAD_REV = "2f6b9c4d8a31"
    PREVIOUS_REV = "1a2b3c4d5e6f"
    NULL_ROW_MARKER = "PHASE19-TITLE-NULL-TEST"

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        """Ensure head before, and a clean database after, every test."""
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
        yield
        self._delete_test_rows()
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Restore upgrade failed: {result.stderr}"

    @staticmethod
    def _columns(table: str) -> dict:
        return TestPhase13ExpensesMigration._columns(table)

    @classmethod
    def _insert_title(cls, title) -> None:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO expenses (title, category, amount, note)
            VALUES (%s, 'rent', 5.000, %s)
            """,
            (title, cls.NULL_ROW_MARKER),
        )
        conn.commit()
        cur.close()
        conn.close()

    @classmethod
    def _delete_test_rows(cls) -> None:
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("DELETE FROM expenses WHERE note = %s", (cls.NULL_ROW_MARKER,))
        conn.commit()
        cur.close()
        conn.close()

    def test_single_head_is_0019(self):
        current = _run_alembic("current")
        assert current.returncode == 0, current.stderr
        assert self.HEAD_REV in current.stdout, current.stdout

        heads = _run_alembic("heads")
        assert heads.returncode == 0, heads.stderr
        assert self.HEAD_REV in heads.stdout, heads.stdout
        assert self.HEAD_REV not in self.PREVIOUS_REV
        # exactly one head
        assert heads.stdout.count("(head)") == 1, heads.stdout

    def test_title_is_nullable_at_head(self):
        title = self._columns("expenses")["title"]
        assert title[1] == "character varying", title[1]
        assert title[2] == "YES", "Fix Round 2: expenses.title must be nullable"

    def test_null_title_row_round_trips(self):
        self._insert_title(None)
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT title FROM expenses WHERE note = %s", (self.NULL_ROW_MARKER,)
        )
        assert cur.fetchone()[0] is None
        cur.close()
        conn.close()

    def test_upgrade_downgrade_upgrade(self):
        result = _run_alembic(f"downgrade {self.PREVIOUS_REV}")
        assert result.returncode == 0, result.stderr
        try:
            title = self._columns("expenses")["title"]
            assert title[2] == "NO", "downgrade must restore NOT NULL"

            import psycopg2

            conn = _get_test_conn()
            cur = conn.cursor()
            try:
                with pytest.raises(psycopg2.errors.NotNullViolation):
                    cur.execute(
                        "INSERT INTO expenses (title, category, amount) "
                        "VALUES (NULL, 'rent', 5.000)"
                    )
                    conn.commit()
            finally:
                conn.rollback()
                cur.close()
                conn.close()
        finally:
            result = _run_alembic("upgrade head")
            assert result.returncode == 0, result.stderr

        assert self._columns("expenses")["title"][2] == "YES"