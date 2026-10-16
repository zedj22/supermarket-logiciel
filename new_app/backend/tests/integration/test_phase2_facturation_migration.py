"""Integration tests for Phase 2 facturation migration 0026 — PostgreSQL only.

Runs against the dedicated supermarket_pro_test database (production is
never touched). Verifies:

- upgrade to head creates exactly the four invoice_* tables
- column types / nullability / server defaults (incl. the explicit
  invoice_documents.year: integer, NOT NULL, CHECK year > 0, no default)
- UNIQUE numbering identity EXACTLY (doc_type, year, number) + the
  numbering matrix (FAC/2026/0001 vs FAC/2027/0001 vs DEV/2026/0001)
- FK delete rules: RESTRICT (client), CASCADE (document lines),
  SET NULL (product link)
- indexes, unique constraints, named CHECK constraints
- smoke insert: 1 client, 1 document, 2 lines (one product-linked, one
  free-text product_id NULL), 1 counter — plus relationship joins
- 0027 corrective downgrade to the 0026 state and back to head
- full downgrade to the pre-Phase-2 revision removes all four tables
  cleanly and re-upgrade restores them
"""

import contextlib
import os
import subprocess
from decimal import Decimal

import pytest

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

HEAD_REV = "dbdff6c3ec7f"  # 0030_facture_sale_posting (current head)
ORIG_PHASE2_REV = "f3f734338032"  # 0026_phase2_facturation
PREVIOUS_REV = "9f2e8c7a4b1d"  # 0025_phase18_promotions (pre-Phase-2 baseline)
INVOICE_TABLES = (
    "invoice_clients",
    "invoice_documents",
    "invoice_document_lines",
    "invoice_document_counters",
)
CANARY_PRODUCT = "phase2_smoke_canary"


def _run_alembic(command: str) -> subprocess.CompletedProcess:
    """Run an alembic command against the test database."""
    env = {**os.environ, "DATABASE_URL": PG_TEST_URL}
    return subprocess.run(
        f"python -m alembic {command}",
        shell=True,
        capture_output=True,
        text=True,
        cwd=os.path.join(os.path.dirname(__file__), "..", ".."),
        env=env,
    )


def _get_test_conn():
    """Get a psycopg2 connection to the test database."""
    import psycopg2

    return psycopg2.connect(PG_TEST_URL)


def _table_exists(cur, table: str) -> bool:
    cur.execute(
        "SELECT COUNT(*) FROM information_schema.tables "
        "WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return cur.fetchone()[0] == 1


def _columns(cur, table: str) -> dict:
    """column_name -> information_schema column metadata."""
    cur.execute(
        """
        SELECT column_name, data_type, is_nullable, column_default,
               numeric_precision, numeric_scale, character_maximum_length
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = %s
        """,
        (table,),
    )
    return {
        row[0]: {
            "type": row[1],
            "nullable": row[2],
            "default": row[3],
            "precision": row[4],
            "scale": row[5],
            "length": row[6],
        }
        for row in cur.fetchall()
    }


def _cleanup_invoice_rows(conn) -> None:
    """Best-effort removal of smoke rows (any phase-2 test run leftovers)."""
    with contextlib.suppress(Exception):
        cur = conn.cursor()
        for table in (
            "invoice_document_lines",
            "invoice_documents",
            "invoice_clients",
            "invoice_document_counters",
        ):
            cur.execute(f"DELETE FROM {table}")
        cur.execute("DELETE FROM products WHERE name = %s", (CANARY_PRODUCT,))
        conn.commit()
        cur.close()


class TestPhase2FacturationMigration:
    """Migration 0026 — the four facturation tables (Phase 2 database)."""

    @pytest.fixture(autouse=True)
    def _setup_db(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
        yield
        with contextlib.suppress(Exception):
            conn = _get_test_conn()
            try:
                _cleanup_invoice_rows(conn)
            finally:
                conn.close()

    def test_current_at_phase2_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert HEAD_REV in result.stdout, result.stdout
        heads = _run_alembic("heads")
        assert heads.returncode == 0, heads.stderr
        lines = [
            line
            for line in heads.stdout.strip().split("\n")
            if line.strip() and not line.startswith("Generating")
        ]
        assert len(lines) == 1, f"Expected a single linear head: {lines}"
        assert HEAD_REV in heads.stdout

    def test_four_invoice_tables_created(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        for table in INVOICE_TABLES:
            assert _table_exists(cur, table), f"table {table} missing"
        # Isolation: no second product catalog, no per-doctype tables.
        assert not _table_exists(cur, "invoice_products")
        assert not _table_exists(cur, "invoice_document_fac")
        # Phase 1-18 tables untouched by this migration.
        for table in ("sales", "sale_lines", "customers", "products"):
            assert _table_exists(cur, table), f"pre-existing table {table} missing"
        cur.close()
        conn.close()

    def test_column_types_nullability_and_defaults(self):
        conn = _get_test_conn()
        cur = conn.cursor()

        clients = _columns(cur, "invoice_clients")
        assert clients["name"]["type"] == "character varying"
        assert clients["name"]["length"] == 200
        assert clients["name"]["nullable"] == "NO"
        for optional in ("address", "wilaya", "phone", "nif", "rc", "ai", "nis"):
            assert clients[optional]["nullable"] == "YES", optional
        assert clients["archived_at"]["nullable"] == "YES"  # MasterModel
        assert "customer_id" not in clients  # isolated from customers

        documents = _columns(cur, "invoice_documents")
        assert documents["document_date"]["type"] == "date"
        assert documents["document_date"]["nullable"] == "NO"
        assert documents["document_date"]["default"] is None  # never server-today
        assert documents["number"]["nullable"] == "NO"
        assert documents["number"]["default"] is None  # Phase 5 allocates
        assert documents["number"]["length"] == 50
        # Review fix: the numbering year is an explicit column — integer,
        # NOT NULL, CHECK year > 0, NO server default (never inferred from
        # document_date).
        assert documents["year"]["type"] == "integer"
        assert documents["year"]["nullable"] == "NO"
        assert documents["year"]["default"] is None
        assert documents["client_id"]["type"] == "uuid"
        assert documents["client_id"]["nullable"] == "NO"
        assert documents["notes"]["type"] == "text"
        assert documents["notes"]["nullable"] == "YES"
        assert "archived_at" not in documents  # DocumentModel: version, no archive
        # Server defaults mirror factura_simple (FAC / cash / all options true).
        assert "FAC" in (documents["doc_type"]["default"] or "")
        assert "cash" in (documents["payment_method"]["default"] or "")
        for flag in (
            "show_discount",
            "show_tva",
            "show_timbre",
            "show_payment_method",
            "show_amount_words",
        ):
            assert documents[flag]["type"] == "boolean", flag
            assert documents[flag]["nullable"] == "NO", flag
            assert "true" in (documents[flag]["default"] or ""), flag
        assert "1" in (documents["version"]["default"] or "")

        lines = _columns(cur, "invoice_document_lines")
        assert lines["document_id"]["type"] == "uuid"
        assert lines["document_id"]["nullable"] == "NO"
        assert lines["product_id"]["type"] == "uuid"
        assert lines["product_id"]["nullable"] == "YES"  # free-text lines
        assert lines["description"]["type"] == "text"
        assert lines["description"]["nullable"] == "NO"
        for money in ("quantity", "unit_price_ht", "tva_rate", "discount_pct"):
            assert lines[money]["type"] == "numeric", money
            assert lines[money]["precision"] == 18, money
            assert lines[money]["scale"] == 3, money
            assert lines[money]["nullable"] == "NO", money
        assert lines["position"]["type"] == "integer"
        assert lines["position"]["nullable"] == "NO"
        assert lines["position"]["default"] is not None

        counters = _columns(cur, "invoice_document_counters")
        assert counters["doc_type"]["nullable"] == "NO"
        assert counters["year"]["type"] == "integer"
        assert counters["year"]["nullable"] == "NO"
        assert counters["year"]["default"] is None
        assert counters["last_number"]["type"] == "integer"
        assert counters["last_number"]["nullable"] == "NO"
        assert "0" in (counters["last_number"]["default"] or "")

        cur.close()
        conn.close()

    def test_foreign_key_delete_rules(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute("""
            SELECT tc.table_name, kcu.column_name, ccu.table_name, rc.delete_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name
            JOIN information_schema.referential_constraints rc
                ON rc.constraint_name = tc.constraint_name
            WHERE tc.table_schema = 'public'
              AND tc.constraint_type = 'FOREIGN KEY'
              AND tc.table_name LIKE 'invoice%'
        """)
        fks = {(row[0], row[1]): (row[2], row[3]) for row in cur.fetchall()}
        # 0030 added invoice_documents.sale_id -> sales (SET NULL), so 7.
        assert len(fks) == 7, f"Expected exactly 7 facturation FKs, got {fks}"
        assert fks[("invoice_documents", "client_id")] == (
            "invoice_clients",
            "RESTRICT",
        ), "invoice_documents.client_id must be FK RESTRICT -> invoice_clients"
        # 0030: the posted-FAC link never destroys the fiscal document.
        assert fks[("invoice_documents", "sale_id")] == (
            "sales",
            "SET NULL",
        ), "invoice_documents.sale_id must be FK SET NULL -> sales"
        assert fks[("invoice_document_lines", "document_id")] == (
            "invoice_documents",
            "CASCADE",
        ), "invoice_document_lines.document_id must be FK CASCADE -> invoice_documents"
        assert fks[("invoice_document_lines", "product_id")] == (
            "products",
            "SET NULL",
        ), "invoice_document_lines.product_id must be FK SET NULL -> products"
        # Stage 3A (0029): option identity links — all SET NULL like
        # product_id, a deleted option never destroys a historical line.
        assert fks[("invoice_document_lines", "variant_id")] == (
            "product_variants",
            "SET NULL",
        ), "invoice_document_lines.variant_id must be FK SET NULL -> product_variants"
        assert fks[("invoice_document_lines", "selling_unit_id")] == (
            "product_selling_units",
            "SET NULL",
        ), (
            "invoice_document_lines.selling_unit_id must be FK SET NULL "
            "-> product_selling_units"
        )
        assert fks[("invoice_document_lines", "pack_id")] == (
            "packs",
            "SET NULL",
        ), "invoice_document_lines.pack_id must be FK SET NULL -> packs"
        cur.close()
        conn.close()

    def test_indexes_exact(self):
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT tablename, indexname FROM pg_indexes "
            "WHERE tablename LIKE 'invoice%' ORDER BY tablename, indexname"
        )
        actual: dict[str, set] = {}
        for tablename, indexname in cur.fetchall():
            actual.setdefault(tablename, set()).add(indexname)
        expected = {
            "invoice_clients": {
                "invoice_clients_pkey",
                "ix_invoice_clients_id",
                "ix_invoice_clients_name",
                "ix_invoice_clients_nif",
                "ix_invoice_clients_phone",
                "ix_invoice_clients_rc",
            },
            "invoice_documents": {
                "invoice_documents_pkey",
                "ix_invoice_documents_id",
                "ix_invoice_documents_client_id",
                "ix_invoice_documents_document_date",
                "ix_invoice_documents_doc_type",
                "ix_invoice_documents_doc_type_document_date",
                "uq_invoice_documents_doc_type_year_number",
                # 0030: unique index on the optional sale link.
                "ix_invoice_documents_sale_id",
            },
            "invoice_document_lines": {
                "invoice_document_lines_pkey",
                "ix_invoice_document_lines_id",
                "ix_invoice_document_lines_document_id",
                "ix_invoice_document_lines_product_id",
                # Stage 3A (0029) option identity indexes.
                "ix_invoice_document_lines_variant_id",
                "ix_invoice_document_lines_selling_unit_id",
                "ix_invoice_document_lines_pack_id",
            },
            "invoice_document_counters": {
                "invoice_document_counters_pkey",
                "ix_invoice_document_counters_id",
                "uq_invoice_document_counters_doc_type_year",
            },
        }
        assert actual == expected, f"Index mismatch: {actual}"
        cur.close()
        conn.close()

    def test_unique_and_check_constraints(self):
        conn = _get_test_conn()
        cur = conn.cursor()

        cur.execute(
            """
            SELECT conname FROM pg_constraint
            WHERE contype = 'u'
              AND conrelid::regclass::text LIKE 'invoice%'
            ORDER BY conname
            """
        )
        uniques = [row[0] for row in cur.fetchall()]
        assert uniques == [
            "uq_invoice_document_counters_doc_type_year",
            "uq_invoice_documents_doc_type_year_number",
        ], uniques

        # Requirement: the numbering unique is EXACTLY (doc_type, year,
        # number) — ordinal column order included, old (doc_type, number)
        # constraint gone.
        cur.execute(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
               AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'UNIQUE'
              AND tc.table_name = 'invoice_documents'
              AND tc.constraint_name = 'uq_invoice_documents_doc_type_year_number'
            ORDER BY kcu.ordinal_position
            """
        )
        unique_cols = [row[0] for row in cur.fetchall()]
        assert unique_cols == ["doc_type", "year", "number"], unique_cols

        cur.execute(
            """
            SELECT conname FROM pg_constraint
            WHERE contype = 'c'
              AND conname LIKE 'ck_invoice%'
            ORDER BY conname
            """
        )
        checks = {row[0] for row in cur.fetchall()}
        assert checks == {
            "ck_invoice_documents_doc_type",
            "ck_invoice_documents_payment_method",
            "ck_invoice_documents_year",
            "ck_invoice_document_lines_quantity",
            "ck_invoice_document_lines_unit_price_ht",
            "ck_invoice_document_lines_discount_pct",
            "ck_invoice_document_counters_doc_type",
            "ck_invoice_document_counters_year",
            "ck_invoice_document_counters_last_number",
        }, checks
        cur.close()
        conn.close()

    def test_smoke_insert_relationships_and_db_behaviour(self):
        import psycopg2

        conn = _get_test_conn()
        try:
            _cleanup_invoice_rows(conn)
            cur = conn.cursor()

            # Free-text link target: an existing Supermarket Pro product.
            cur.execute(
                "INSERT INTO products (name, price, cost, quantity) "
                "VALUES (%s, 100, 0, 1) RETURNING id",
                (CANARY_PRODUCT,),
            )
            product_id = cur.fetchone()[0]

            cur.execute(
                "INSERT INTO invoice_clients (id, name, nif, phone) "
                "VALUES (gen_random_uuid(), 'Phase2 Smoke Client', "
                "'000123456789012', '0555000111') RETURNING id"
            )
            client_id = cur.fetchone()[0]

            # Everything possible is omitted to exercise SERVER DEFAULTS;
            # year has NO default — it is the required numbering year.
            cur.execute(
                """
                INSERT INTO invoice_documents
                    (id, number, year, document_date, client_id, notes)
                VALUES
                    (gen_random_uuid(), '0001', 2026, DATE '2026-10-08',
                     %s, 'phase2 smoke')
                RETURNING id, doc_type, payment_method, version, show_timbre,
                          show_discount, show_tva, show_payment_method,
                          show_amount_words, created_at
                """,
                (client_id,),
            )
            (
                doc_id,
                doc_type,
                payment_method,
                version,
                show_timbre,
                show_discount,
                show_tva,
                show_payment_method,
                show_amount_words,
                created_at,
            ) = cur.fetchone()
            assert doc_type == "FAC"
            assert payment_method == "cash"
            assert version == 1
            assert show_timbre is True
            assert show_discount is True
            assert show_tva is True
            assert show_payment_method is True
            assert show_amount_words is True
            assert created_at is not None

            # Line 1: product-linked, position omitted -> server default 0.
            cur.execute(
                """
                INSERT INTO invoice_document_lines
                    (id, document_id, product_id, description, quantity,
                     unit_price_ht, tva_rate, discount_pct)
                VALUES
                    (gen_random_uuid(), %s, %s, 'Produit lie', 2,
                     19.99, 19, 0)
                RETURNING id, position, product_id, unit_price_ht
                """,
                (doc_id, product_id),
            )
            line1_id, line1_position, line1_product, line1_price = cur.fetchone()
            assert line1_position == 0
            assert line1_product == product_id
            assert line1_price == Decimal("19.99")

            # Line 2: free text (product_id NULL), explicit position.
            cur.execute(
                """
                INSERT INTO invoice_document_lines
                    (id, document_id, product_id, description, quantity,
                     unit_price_ht, tva_rate, discount_pct, position)
                VALUES
                    (gen_random_uuid(), %s, NULL, 'Texte libre', 1,
                     5.5, 9, 10.5, 1)
                RETURNING id, product_id
                """,
                (doc_id,),
            )
            line2_id, line2_product = cur.fetchone()
            assert line2_product is None

            # Counter row: last_number omitted -> server default 0.
            cur.execute(
                "INSERT INTO invoice_document_counters (id, doc_type, year) "
                "VALUES (gen_random_uuid(), 'FAC', 2026) RETURNING id"
            )
            counter_id = cur.fetchone()[0]
            conn.commit()

            # Relationship verification (document -> client, -> lines).
            cur.execute(
                "SELECT d.number, c.name FROM invoice_documents d "
                "JOIN invoice_clients c ON c.id = d.client_id WHERE d.id = %s",
                (doc_id,),
            )
            assert cur.fetchone() == ("0001", "Phase2 Smoke Client")
            cur.execute(
                "SELECT COUNT(*) FROM invoice_document_lines WHERE document_id = %s",
                (doc_id,),
            )
            assert cur.fetchone()[0] == 2
            cur.execute(
                "SELECT last_number FROM invoice_document_counters WHERE id = %s",
                (counter_id,),
            )
            assert cur.fetchone()[0] == 0

            # Numbering matrix on PostgreSQL — UNIQUE(doc_type, year, number).
            # FAC / 2026 / 0001 is already committed above.
            cur.execute(
                "INSERT INTO invoice_documents "
                "(id, doc_type, year, number, document_date, client_id) "
                "VALUES (gen_random_uuid(), 'FAC', 2027, '0001', "
                "DATE '2027-01-05', %s)",
                (client_id,),
            )  # FAC / 2027 / 0001 -> allowed (same serial, other year)
            cur.execute(
                "INSERT INTO invoice_documents "
                "(id, doc_type, year, number, document_date, client_id) "
                "VALUES (gen_random_uuid(), 'DEV', 2026, '0001', "
                "DATE '2026-02-10', %s)",
                (client_id,),
            )  # DEV / 2026 / 0001 -> allowed (same serial, other doc_type)
            with pytest.raises(psycopg2.IntegrityError):
                cur.execute(
                    "INSERT INTO invoice_documents "
                    "(id, doc_type, year, number, document_date, client_id) "
                    "VALUES (gen_random_uuid(), 'FAC', 2026, '0001', "
                    "DATE '2026-03-01', %s)",
                    (client_id,),
                )  # FAC / 2026 / 0001 twice -> rejected
            conn.rollback()  # drop the two proof rows + clear aborted tx
            with pytest.raises(psycopg2.IntegrityError):
                cur.execute(
                    "INSERT INTO invoice_documents "
                    "(id, doc_type, year, number, document_date, client_id) "
                    "VALUES (gen_random_uuid(), 'FAC', 0, '0002', "
                    "DATE '2026-04-01', %s)",
                    (client_id,),
                )  # year <= 0 -> rejected by ck_invoice_documents_year
            conn.rollback()

            # (a) FK RESTRICT: a referenced client cannot be deleted.
            with pytest.raises(psycopg2.IntegrityError):
                cur.execute("DELETE FROM invoice_clients WHERE id = %s", (client_id,))
            conn.rollback()

            # (b) FK SET NULL: deleting the product keeps every line alive.
            cur.execute("DELETE FROM products WHERE id = %s", (product_id,))
            conn.commit()
            cur.execute(
                "SELECT product_id, description FROM invoice_document_lines WHERE id = %s",
                (line1_id,),
            )
            assert cur.fetchone() == (None, "Produit lie")

            # (c) FK CASCADE: deleting the document removes its lines, while
            #     the client row (RESTRICTed side) survives.
            cur.execute("DELETE FROM invoice_documents WHERE id = %s", (doc_id,))
            conn.commit()
            cur.execute(
                "SELECT COUNT(*) FROM invoice_document_lines WHERE document_id = %s",
                (doc_id,),
            )
            assert cur.fetchone()[0] == 0
            cur.execute("SELECT COUNT(*) FROM invoice_clients WHERE id = %s", (client_id,))
            assert cur.fetchone()[0] == 1

            # Free-text line (line2) died with the cascade above too.
            cur.execute(
                "SELECT COUNT(*) FROM invoice_document_lines WHERE id = %s",
                (line2_id,),
            )
            assert cur.fetchone()[0] == 0
            cur.close()
        finally:
            _cleanup_invoice_rows(conn)
            conn.close()

    def test_downgrade_removes_phase2_tables_then_reupgrade_restores(self):
        result = _run_alembic(f"downgrade {PREVIOUS_REV}")
        assert result.returncode == 0, f"Downgrade failed: {result.stderr}"

        conn = _get_test_conn()
        cur = conn.cursor()
        for table in INVOICE_TABLES:
            assert not _table_exists(cur, table), f"{table} survived downgrade"
        # Pre-existing tables untouched by the downgrade.
        assert _table_exists(cur, "sales")
        assert _table_exists(cur, "products")
        cur.close()
        conn.close()

        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert PREVIOUS_REV in result.stdout, result.stdout

        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Re-upgrade failed: {result.stderr}"
        result = _run_alembic("current")
        assert HEAD_REV in result.stdout, result.stdout

        conn = _get_test_conn()
        cur = conn.cursor()
        for table in INVOICE_TABLES:
            assert _table_exists(cur, table), f"{table} missing after re-upgrade"
        cur.close()
        conn.close()

    def test_corrective_migration_downgrade_roundtrip(self):
        """0027 downgrades to exactly the 0026 state, and back to head."""
        # Fixture left the DB at head: year column + (doc_type, year, number).
        result = _run_alembic(f"downgrade {ORIG_PHASE2_REV}")
        assert result.returncode == 0, f"Corrective downgrade failed: {result.stderr}"

        conn = _get_test_conn()
        cur = conn.cursor()
        documents = _columns(cur, "invoice_documents")
        assert "year" not in documents, "year survived the 0027 downgrade"
        assert "number" in documents  # 0026 columns untouched
        cur.execute(
            """
            SELECT conname FROM pg_constraint
            WHERE contype = 'u'
              AND conrelid::regclass::text = 'invoice_documents'
            """
        )
        assert [row[0] for row in cur.fetchall()] == ["uq_invoice_documents_doc_type_number"], (
            "0026 unique constraint not restored"
        )
        cur.close()
        conn.close()

        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert ORIG_PHASE2_REV in result.stdout, result.stdout

        # Back to head.
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Re-upgrade failed: {result.stderr}"
        result = _run_alembic("current")
        assert HEAD_REV in result.stdout, result.stdout

        conn = _get_test_conn()
        cur = conn.cursor()
        documents = _columns(cur, "invoice_documents")
        assert "year" in documents, "year missing after re-upgrade"
        assert documents["year"]["nullable"] == "NO"
        assert documents["year"]["default"] is None
        cur.execute(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
               AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'UNIQUE'
              AND tc.constraint_name = 'uq_invoice_documents_doc_type_year_number'
            ORDER BY kcu.ordinal_position
            """
        )
        assert [row[0] for row in cur.fetchall()] == [
            "doc_type",
            "year",
            "number",
        ]
        cur.close()
        conn.close()
