"""Integration tests for migration 0028 — Phase 6 facturation settings.

PostgreSQL only (real ``supermarket_pro_test`` database, Alembic CLI, raw
psycopg2 — same harness as ``test_migrations.py``).  The production
database is NEVER touched.

Scenarios:

- the linear chain has exactly one head and it is 0028
- the seven company/fiscal columns exist with their exact shape and with
  NO server default (DDL == ``Base.metadata.create_all``)
- nothing else on ``app_settings`` changed
- an ``app_settings`` row written BEFORE the migration is backfilled to
  '' instead of failing the NOT NULL add, and its old values survive
- downgrade drops exactly the seven columns, keeps the original ones and
  the row, re-upgrade restores the head
- ``alembic check`` reports no drift between the model and the migrated
  schema
"""

from __future__ import annotations

import os
import subprocess

import psycopg2
import pytest

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

HEAD_REV = "9f4c1a7d2e63"  # 0030_facture_sale_posting
PREV_REV = "b2e603d5c016"  # 0027_phase2_facturation_year_numbering
# The 0028 revision is a FIXED historical fact — it revises 0027 forever,
# regardless of which revision is currently the head (0029+).
REV_0028 = "2dbe2160afb5"  # 0028_phase6_facturation_settings

# column -> (data_type, character_maximum_length, is_nullable)
NEW_COLUMNS: dict[str, tuple[str, int | None, str]] = {
    "store_wilaya": ("character varying", 100, "NO"),
    "store_email": ("character varying", 100, "NO"),
    "store_nif": ("character varying", 30, "NO"),
    "store_nis": ("character varying", 30, "NO"),
    "store_rc": ("character varying", 30, "NO"),
    "store_ai": ("character varying", 30, "NO"),
    "store_rib": ("character varying", 30, "NO"),
}

# The pre-Phase-6 shape: these must survive every operation unchanged.
ORIGINAL_COLUMNS: dict[str, tuple[str, int | None, str]] = {
    "id": ("integer", None, "NO"),
    "store_name": ("character varying", 120, "NO"),
    "store_phone": ("character varying", 40, "NO"),
    "store_address": ("character varying", 255, "NO"),
    "invoice_footer": ("character varying", 255, "NO"),
    "default_paper": ("character varying", 10, "NO"),
    "ask_before_print": ("boolean", None, "NO"),
    "auto_print_invoice": ("boolean", None, "NO"),
    "allow_debt": ("boolean", None, "NO"),
    "low_stock_threshold": ("integer", None, "NO"),
    "created_at": ("timestamp with time zone", None, "NO"),
    "updated_at": ("timestamp with time zone", None, "NO"),
}


def _run_alembic(command: str) -> subprocess.CompletedProcess:
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
    return psycopg2.connect(PG_TEST_URL)


def _app_settings_columns() -> dict[str, dict]:
    conn = _get_test_conn()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT column_name, data_type, character_maximum_length,
               is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = 'app_settings'
        ORDER BY ordinal_position
        """
    )
    rows = {
        name: {
            "data_type": data_type,
            "length": length,
            "nullable": nullable,
            "default": default,
        }
        for name, data_type, length, nullable, default in cur.fetchall()
    }
    cur.close()
    conn.close()
    return rows


def _shape(columns: dict[str, dict], name: str) -> tuple:
    column = columns[name]
    return (
        column["data_type"],
        column["length"],
        column["nullable"],
    )


def _select_settings_rows() -> list[dict]:
    conn = _get_test_conn()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, store_name, store_phone, store_address, invoice_footer,
               default_paper, ask_before_print, auto_print_invoice,
               allow_debt, low_stock_threshold
        FROM app_settings
        ORDER BY id
        """
    )
    names = [d[0] for d in cur.description]
    rows = [dict(zip(names, record)) for record in cur.fetchall()]
    cur.close()
    conn.close()
    return rows


def _delete_settings_rows() -> None:
    conn = _get_test_conn()
    cur = conn.cursor()
    cur.execute("DELETE FROM app_settings")
    conn.commit()
    cur.close()
    conn.close()


def _insert_settings_row(values: dict) -> None:
    """Insert a singleton row honouring whatever schema is currently live.

    At 0027 only the Phase 17 columns exist; at head the seven Phase 6
    columns are required (NOT NULL, no server default), so they are added
    here as '' — exactly what the migration backfills.
    """
    present = _app_settings_columns()
    payload = {
        name: value
        for name, value in values.items()
        if name in present
    }
    for name in NEW_COLUMNS:
        if name in present:
            payload[name] = ""
    # deterministic singleton id (the table was emptied just above)
    payload["id"] = values.get("id", 1)
    columns = list(payload) + ["created_at", "updated_at"]
    placeholders = ", ".join(f"%({name})s" for name in payload)
    conn = _get_test_conn()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO app_settings ({columns}) VALUES ({values}, now(), now())".format(
            columns=", ".join(columns),
            values=placeholders or "NULL",
        ),
        payload,
    )
    conn.commit()
    cur.close()
    conn.close()


CANARY = {
    "store_name": "Canary Superette",
    "store_phone": "021 55 66 77",
    "store_address": "12 Rue de la Liberté, Alger",
    "invoice_footer": "Merci de votre visite",
    "default_paper": "A4",
    "ask_before_print": True,
    "auto_print_invoice": True,
    "allow_debt": False,
    "low_stock_threshold": 9,
}


class TestPhase6SettingsMigration:
    @pytest.fixture(autouse=True)
    def _setup_db(self):
        """Every test starts at head; leftovers are always cleaned."""
        saved_rows = _select_settings_rows()
        _delete_settings_rows()
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
        yield
        _delete_settings_rows()
        for row in saved_rows:
            _insert_settings_row(row)
        _run_alembic("upgrade head")

    # -- chain ------------------------------------------------------------

    def test_current_at_single_head(self):
        result = _run_alembic("current")
        assert result.returncode == 0, result.stderr
        assert HEAD_REV in result.stdout, result.stdout
        heads = _run_alembic("heads")
        assert heads.returncode == 0
        lines = [
            line
            for line in heads.stdout.strip().split("\n")
            if line.strip() and not line.startswith("Generating")
        ]
        assert len(lines) == 1, heads.stdout
        assert HEAD_REV in heads.stdout

    def test_0028_revises_0027(self):
        history = _run_alembic("history")
        assert history.returncode == 0, history.stderr
        assert f"{PREV_REV} -> {REV_0028}" in history.stdout, history.stdout
        assert "0028_phase6_facturation_settings" in history.stdout

    # -- schema -----------------------------------------------------------

    def test_seven_columns_exist_with_the_exact_shape(self):
        columns = _app_settings_columns()
        for name, expected in NEW_COLUMNS.items():
            assert name in columns, f"missing column {name}"
            assert _shape(columns, name) == expected, name
            # model-side default only, exactly like every 0022 column
            assert columns[name]["default"] is None, name
        assert set(columns) == set(NEW_COLUMNS) | set(ORIGINAL_COLUMNS)

    def test_original_columns_are_untouched(self):
        columns = _app_settings_columns()
        for name, expected in ORIGINAL_COLUMNS.items():
            assert _shape(columns, name) == expected, name
        for name in (
            "store_name",
            "store_phone",
            "store_address",
            "invoice_footer",
            "default_paper",
            "ask_before_print",
            "auto_print_invoice",
            "allow_debt",
            "low_stock_threshold",
        ):
            assert columns[name]["default"] is None, name
        assert "now()" in (columns["created_at"]["default"] or "")
        assert "now()" in (columns["updated_at"]["default"] or "")
        # the singleton CHECK of 0022 is still there
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT conname FROM pg_constraint "
            "WHERE conrelid = 'app_settings'::regclass AND contype = 'c'"
        )
        names = {row[0] for row in cur.fetchall()}
        cur.close()
        conn.close()
        assert "ck_app_settings_singleton" in names
        assert "ck_app_settings_default_paper" in names
        assert "ck_app_settings_low_stock_threshold" in names

    # -- data -------------------------------------------------------------

    def test_preexisting_row_is_backfilled_and_keeps_its_values(self):
        _run_alembic(f"downgrade {PREV_REV}")
        assert _run_alembic("current").stdout.find(HEAD_REV) == -1
        columns = _app_settings_columns()
        for name in NEW_COLUMNS:
            assert name not in columns, name

        _delete_settings_rows()
        _insert_settings_row(CANARY)

        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Upgrade failed: {result.stderr}"

        columns = _app_settings_columns()
        for name in NEW_COLUMNS:
            assert columns[name]["default"] is None, name
            assert columns[name]["nullable"] == "NO", name

        rows = _select_settings_rows()
        assert len(rows) == 1
        assert rows[0]["store_name"] == "Canary Superette"
        assert rows[0]["allow_debt"] is False
        assert rows[0]["low_stock_threshold"] == 9

        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "SELECT store_wilaya, store_email, store_nif, store_nis, "
            "store_rc, store_ai, store_rib, store_wilaya IS NULL "
            "FROM app_settings WHERE id = 1"
        )
        values = cur.fetchone()
        cur.close()
        conn.close()
        assert values[:7] == ("", "", "", "", "", "", "")
        assert values[7] is False  # backfilled, never NULL

    def test_downgrade_drops_only_the_seven_columns(self):
        _insert_settings_row(CANARY)
        conn = _get_test_conn()
        cur = conn.cursor()
        cur.execute(
            "UPDATE app_settings SET store_nif = %s, store_wilaya = %s",
            ("0002213400067", "Alger"),
        )
        conn.commit()
        cur.close()
        conn.close()

        result = _run_alembic(f"downgrade {PREV_REV}")
        assert result.returncode == 0, f"Downgrade failed: {result.stderr}"

        columns = _app_settings_columns()
        for name in NEW_COLUMNS:
            assert name not in columns, f"{name} survived the downgrade"
        for name in ORIGINAL_COLUMNS:
            assert name in columns, f"{name} was dropped by mistake"

        # the row and its Phase 17 values are untouched
        rows = _select_settings_rows()
        assert len(rows) == 1
        assert rows[0]["store_name"] == "Canary Superette"
        assert rows[0]["store_address"] == "12 Rue de la Liberté, Alger"

        result = _run_alembic("upgrade head")
        assert result.returncode == 0, f"Re-upgrade failed: {result.stderr}"
        columns = _app_settings_columns()
        for name in NEW_COLUMNS:
            assert name in columns, name
            assert columns[name]["default"] is None, name
        rows = _select_settings_rows()
        assert rows[0]["store_name"] == "Canary Superette"
        # documented data loss: the fiscal value lived in a dropped column
        assert rows[0]["allow_debt"] is False
        assert rows[0]["low_stock_threshold"] == 9

    # -- model / migration parity ----------------------------------------

    def test_alembic_check_reports_no_drift(self):
        result = _run_alembic("check")
        assert result.returncode == 0, (
            f"alembic check failed: {result.stdout} {result.stderr}"
        )
        assert "No new upgrade operations detected" in result.stdout

    def test_upgrade_head_is_idempotent(self):
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, result.stderr
        result = _run_alembic("upgrade head")
        assert result.returncode == 0, result.stderr
        assert HEAD_REV in _run_alembic("current").stdout
