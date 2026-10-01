"""Phase 14 Step D — reports / dashboard performance benchmark.

Seeds an ISOLATED PostgreSQL database with ~200 k sales (+ lines, returns,
expenses, ledgers), then measures the eleven Phase 14 read surfaces and runs
``EXPLAIN (ANALYZE, BUFFERS)`` on every statement they execute.

The production database (``supermarket_pro``) is never touched: the script
derives a separate URL (``supermarket_bench_phase14``) from ``.env``.

Usage::

    python scripts/benchmark_reports_phase14.py            # full run
    python scripts/benchmark_reports_phase14.py --skip-seed  # reuse data
    python scripts/benchmark_reports_phase14.py --iterations 50

Budgets (§15 of the decision record, measured at the documented range caps):

    financial           <= 300 ms p95
    products/categories <= 500 ms p95
    daily/hourly/peak   <= 300 ms p95
    dashboard           <= 400 ms p95
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import statistics
import subprocess
import sys
import time
import uuid
import warnings
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

warnings.filterwarnings("ignore")

BACKEND_DIR = Path(__file__).resolve().parents[1]
BENCH_DB_NAME = "supermarket_bench_phase14"

N_SALES = 200_000
N_RETURNS = 8_000
N_RETURN_LINES = 12_000
N_EXPENSES = 5_000
N_DEBT_ENTRIES = 40_000
N_SUPPLIER_ENTRIES = 6_000
N_PRODUCTS = 200
N_NEVER_SOLD = 30
N_CATEGORIES = 8
N_CUSTOMERS = 150
N_SUPPLIERS = 10
WINDOW_DAYS = 400

BUDGETS_MS = {
    "financial": 300,
    "products": 500,
    "categories": 500,
    "daily": 300,
    "hourly": 300,
    "peak-hours": 300,
    "dashboard": 400,
}


# --------------------------------------------------------------------------
# environment
# --------------------------------------------------------------------------


def _base_url() -> str:
    env_file = BACKEND_DIR / ".env"
    for line in env_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("DATABASE_URL="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("DATABASE_URL not found in .env")


def _bench_url(base: str) -> str:
    head, _, _dbname = base.rpartition("/")
    return f"{head}/{BENCH_DB_NAME}"


def _psycopg(url: str):
    import psycopg2

    return psycopg2.connect(url)


def _reset_database(url: str) -> None:
    conn = _psycopg(url.rpartition("/")[0] + "/postgres")
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        "WHERE datname = %s AND pid <> pg_backend_pid()",
        (BENCH_DB_NAME,),
    )
    cur.execute(f'DROP DATABASE IF EXISTS "{BENCH_DB_NAME}"')
    cur.execute(f'CREATE DATABASE "{BENCH_DB_NAME}"')
    cur.close()
    conn.close()


def _migrate(url: str) -> None:
    env = {**os.environ, "DATABASE_URL": url}
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=str(BACKEND_DIR),
        env=env,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise SystemExit(f"alembic upgrade failed:\n{result.stdout}\n{result.stderr}")


# --------------------------------------------------------------------------
# seed
# --------------------------------------------------------------------------


def _window() -> tuple[datetime, datetime]:
    end = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    start = end - timedelta(days=WINDOW_DAYS)
    return start, end


def seed(url: str) -> None:
    """Bulk-insert the benchmark dataset with psycopg2 ``execute_values``."""
    from psycopg2.extras import execute_values, register_uuid

    register_uuid()
    conn = _psycopg(url)
    cur = conn.cursor()
    start, end = _window()
    span_seconds = int((end - start).total_seconds())
    rnd = _Lcg(seed=20260930)

    def when() -> datetime:
        return start + timedelta(seconds=rnd.int(0, span_seconds))

    print(f"  categories ({N_CATEGORIES}) ...", flush=True)
    category_ids = [uuid.uuid4() for _ in range(N_CATEGORIES)]
    execute_values(
        cur,
        "INSERT INTO categories (id, name, sort_order) VALUES %s",
        [(cid, f"Category {i}", i) for i, cid in enumerate(category_ids)],
    )

    print(f"  products ({N_PRODUCTS}) ...", flush=True)
    products = []
    for i in range(N_PRODUCTS):
        price = round(10 + rnd.int(0, 490), 3)
        cost = round(price * 0.6, 3)
        products.append(
            {
                "id": uuid.uuid4(),
                "name": f"Product {i:04d}",
                "barcode": f"B{i:06d}",
                "category_id": category_ids[i % N_CATEGORIES] if i % 10 else None,
                "price": price,
                "cost": cost,
                "avg_cost": cost,
                "quantity": float(rnd.int(20, 500)),
            }
        )
    execute_values(
        cur,
        "INSERT INTO products (id, name, barcode, category_id, unit, price, cost,"
        " quantity, avg_cost, low_stock_threshold) VALUES %s",
        [
            (
                p["id"],
                p["name"],
                p["barcode"],
                p["category_id"],
                "piece",
                p["price"],
                p["cost"],
                p["quantity"],
                p["avg_cost"],
                5,
            )
            for p in products
        ],
    )

    print(f"  customers ({N_CUSTOMERS}) / suppliers ({N_SUPPLIERS}) ...", flush=True)
    customer_ids = [uuid.uuid4() for _ in range(N_CUSTOMERS)]
    execute_values(
        cur,
        "INSERT INTO customers (id, name, phone, balance, debt_ceiling) VALUES %s",
        [(cid, f"Customer {i}", None, 0, 1000) for i, cid in enumerate(customer_ids)],
    )
    supplier_ids = [uuid.uuid4() for _ in range(N_SUPPLIERS)]
    execute_values(
        cur,
        "INSERT INTO suppliers (id, name, phone, balance) VALUES %s",
        [(sid, f"Supplier {i}", None, 0) for i, sid in enumerate(supplier_ids)],
    )

    cur.execute("SELECT id FROM users LIMIT 1")
    row = cur.fetchone()
    user_id = row[0] if row else None

    sellable = products[N_NEVER_SOLD:]
    methods = ["cash"] * 60 + ["card"] * 20 + ["partial"] * 10 + ["credit"] * 10

    print(f"  sales ({N_SALES}) + sale lines ...", flush=True)
    sale_ids: list[uuid.UUID] = []
    line_rows: list[tuple] = []
    batch_sales: list[tuple] = []
    line_insert = (
        "INSERT INTO sale_lines (sale_id, product_id, product_name, product_unit,"
        " unit_price, unit_cost, quantity, line_discount, line_total,"
        " selling_unit_multiplier) VALUES %s"
    )

    def flush_lines() -> None:
        if line_rows:
            execute_values(cur, line_insert, line_rows, page_size=10_000)
            line_rows.clear()

    sales_insert = (
        "INSERT INTO sales (id, invoice_number, customer_id, user_id, status,"
        " subtotal, discount, total, paid, change, payment_method, device_id,"
        " sale_date, voided_at, void_reason) VALUES %s"
    )

    for i in range(N_SALES):
        sale_id = uuid.uuid4()
        sale_ids.append(sale_id)
        n_lines = 1 + rnd.int(0, 2)
        lines = []
        for _ in range(n_lines):
            product = sellable[rnd.int(0, len(sellable) - 1)]
            qty = float(1 + rnd.int(0, 2))
            discount = (
                round(product["price"] * qty * 0.05, 3) if rnd.int(0, 9) == 0 else 0.0
            )
            line_total = round(product["price"] * qty - discount, 3)
            lines.append((product, qty, discount, line_total))
            line_rows.append(
                (
                    sale_id,
                    product["id"],
                    product["name"],
                    "piece",
                    product["price"],
                    product["avg_cost"],
                    qty,
                    discount,
                    line_total,
                    6.0 if rnd.int(0, 19) == 0 else None,
                )
            )

        subtotal = round(sum(ln[3] for ln in lines), 3)
        invoice_discount = round(subtotal * 0.05, 3) if rnd.int(0, 19) == 0 else 0.0
        total = round(subtotal - invoice_discount, 3)
        method = methods[rnd.int(0, 99)]
        change = 0.0
        if method == "cash":
            change = round(total * 0.05, 3) if rnd.int(0, 4) == 0 else 0.0
            paid = round(total + change, 3)
        elif method == "card":
            paid = total
        elif method == "partial":
            paid = round(total * 0.4, 3)
        else:
            paid = 0.0
        voided = rnd.int(0, 19) == 0
        moment = when()
        batch_sales.append(
            (
                sale_id,
                f"INV-{i:07d}",
                customer_ids[rnd.int(0, N_CUSTOMERS - 1)] if rnd.int(0, 9) == 0 else None,
                user_id,
                "void" if voided else "completed",
                subtotal,
                invoice_discount,
                total,
                paid,
                change,
                method,
                "POS-1" if rnd.int(0, 9) < 7 else "POS-2",
                moment,
                moment if voided else None,
                "voided in benchmark" if voided else None,
            )
        )
        if len(batch_sales) >= 20_000:
            execute_values(cur, sales_insert, batch_sales, page_size=10_000)
            batch_sales.clear()
            flush_lines()
    if batch_sales:
        execute_values(cur, sales_insert, batch_sales, page_size=10_000)
        batch_sales.clear()

    print("  flushing remaining sale lines ...", flush=True)
    flush_lines()

    print(f"  returns ({N_RETURNS}) + return lines ...", flush=True)
    return_rows = []
    return_line_rows = []
    for i in range(N_RETURNS):
        return_id = uuid.uuid4()
        sale_id = sale_ids[rnd.int(0, len(sale_ids) - 1)]
        product = sellable[rnd.int(0, len(sellable) - 1)]
        qty = float(1 + rnd.int(0, 2))
        total = round(product["price"] * qty, 3)
        moment = when()
        return_rows.append(
            (
                return_id,
                f"RET-{i:06d}",
                sale_id,
                None,
                "defective",
                total,
                moment,
                "POS-1",
                total,
                0.0,
            )
        )
        return_line_rows.append(
            (
                return_id,
                product["id"],
                product["name"],
                "piece",
                product["price"],
                qty,
                total,
                product["avg_cost"],
                qty,
                0.0,
            )
        )
    execute_values(
        cur,
        "INSERT INTO returns (id, return_number, sale_id, customer_id, reason, total,"
        " return_date, device_id, subtotal, discount) VALUES %s",
        return_rows,
    )
    execute_values(
        cur,
        "INSERT INTO return_lines (return_id, product_id, product_name, product_unit,"
        " unit_price, quantity, line_total, unit_cost, quantity_base,"
        " line_discount) VALUES %s",
        return_line_rows,
        page_size=10_000,
    )

    print(f"  expenses ({N_EXPENSES}) ...", flush=True)
    execute_values(
        cur,
        "INSERT INTO expenses (id, title, category, amount, expense_date, status,"
        " paid_from_drawer, user_id) VALUES %s",
        [
            (
                uuid.uuid4(),
                f"Benchmark expense {i}",
                "supplies",
                round(10 + rnd.int(0, 490), 3),
                when(),
                "posted",
                rnd.int(0, 9) < 6,
                user_id,
            )
            for i in range(N_EXPENSES)
        ],
        page_size=10_000,
    )

    print(f"  debt ledger ({N_DEBT_ENTRIES}) ...", flush=True)
    debt_types = ["sale"] * 50 + ["payment"] * 45 + ["adjustment"] * 5
    execute_values(
        cur,
        "INSERT INTO debt_ledger_entries (id, customer_id, entry_type, amount,"
        " entry_date, note) VALUES %s",
        [
            (
                uuid.uuid4(),
                customer_ids[rnd.int(0, N_CUSTOMERS - 1)],
                debt_types[rnd.int(0, 99)],
                round(5 + rnd.int(0, 500), 3),
                when(),
                "benchmark",
            )
            for _ in range(N_DEBT_ENTRIES)
        ],
        page_size=10_000,
    )

    print(f"  supplier ledger ({N_SUPPLIER_ENTRIES}) ...", flush=True)
    supplier_types = ["purchase"] * 60 + ["payment"] * 40
    execute_values(
        cur,
        "INSERT INTO supplier_ledger_entries (id, supplier_id, entry_type, amount,"
        " entry_date, note) VALUES %s",
        [
            (
                uuid.uuid4(),
                supplier_ids[rnd.int(0, N_SUPPLIERS - 1)],
                supplier_types[rnd.int(0, 99)],
                round(50 + rnd.int(0, 5000), 3),
                when(),
                "benchmark",
            )
            for _ in range(N_SUPPLIER_ENTRIES)
        ],
        page_size=10_000,
    )

    conn.commit()
    cur.execute("ANALYZE")
    conn.commit()
    cur.close()
    conn.close()
    print("  seed complete + ANALYZE", flush=True)


class _Lcg:
    """Tiny deterministic PRNG so a re-seed produces the same dataset."""

    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFFFFFF

    def int(self, low: int, high: int) -> int:
        self.state = (1103515245 * self.state + 12345) & 0x7FFFFFFF
        return low + self.state % (high - low + 1)


# --------------------------------------------------------------------------
# authentication
# --------------------------------------------------------------------------


def _admin_headers(client) -> dict:
    from app.core.seed import seed_roles_and_permissions
    from app.db.engine import get_session_factory
    from app.services.auth import AuthService

    session = get_session_factory()()
    try:
        seed_roles_and_permissions(session)
        session.commit()
        service = AuthService(session)
        try:
            service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
            session.commit()
        except Exception:
            session.rollback()
        items = client.get("/api/v1/auth/login-users").json()["items"]
        user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    finally:
        session.close()

    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"})
    if resp.status_code != 200:
        raise SystemExit(f"login failed: {resp.status_code} {resp.text}")
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


def _counts(url: str) -> dict[str, int]:
    conn = _psycopg(url)
    cur = conn.cursor()
    counts = {}
    for table in (
        "sales",
        "sale_lines",
        "returns",
        "return_lines",
        "expenses",
        "debt_ledger_entries",
        "supplier_ledger_entries",
        "products",
    ):
        cur.execute(f"SELECT count(*) FROM {table}")
        counts[table] = cur.fetchone()[0]
    cur.close()
    conn.close()
    return counts


# --------------------------------------------------------------------------
# measurement
# --------------------------------------------------------------------------


def _windows(today: date) -> dict[str, dict]:
    """Endpoint → query params, measured at the documented range caps."""
    cap_from = (today - timedelta(days=WINDOW_DAYS - 1)).isoformat()
    day = today.isoformat()
    hour_from = (today - timedelta(days=30)).isoformat()
    return {
        "financial": {"date_from": cap_from, "date_to": day},
        "sales": {"date_from": cap_from, "date_to": day, "status": "all"},
        "products": {"date_from": cap_from, "date_to": day},
        "categories": {"date_from": cap_from, "date_to": day},
        "daily": {"date_from": cap_from, "date_to": day},
        "hourly": {"date_from": hour_from, "date_to": day},
        "peak-hours": {"lookback_days": 90},
        "slow-moving": {"days": 365, "threshold": 0},
        "voided": {"date_from": cap_from, "date_to": day},
        "suppliers": {"date_from": cap_from, "date_to": day},
        "dashboard": {},
    }


def _percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    idx = max(0, math.ceil(pct * len(ordered)) - 1)
    return ordered[idx]


def measure(client, headers: dict, iterations: int) -> list[dict]:

    today = datetime.now(timezone.utc).date()
    results = []
    for name, params in _windows(today).items():
        path = "/api/v1/dashboard" if name == "dashboard" else f"/api/v1/reports/{name}"
        for _ in range(2):  # warm-up
            resp = client.get(path, params=params, headers=headers)
            if resp.status_code != 200:
                raise SystemExit(f"{name}: HTTP {resp.status_code} {resp.text[:300]}")
        samples = []
        payload_size = 0
        for _ in range(iterations):
            began = time.perf_counter()
            resp = client.get(path, params=params, headers=headers)
            samples.append((time.perf_counter() - began) * 1000)
            payload_size = len(resp.content)
            if resp.status_code != 200:
                raise SystemExit(f"{name}: HTTP {resp.status_code} {resp.text[:300]}")
        results.append(
            {
                "endpoint": name,
                "params": params,
                "p50_ms": round(statistics.median(samples), 1),
                "p95_ms": round(_percentile(samples, 0.95), 1),
                "max_ms": round(max(samples), 1),
                "payload_bytes": payload_size,
                "budget_ms": BUDGETS_MS.get(name),
            }
        )
    return results


def explain(client, headers: dict) -> dict[str, list[dict]]:
    """EXPLAIN (ANALYZE, BUFFERS) every statement each surface executes."""
    from sqlalchemy import event

    from app.db.engine import get_engine

    engine = get_engine()
    engine.echo = False
    captured: list[tuple[str, tuple]] = []

    def _before(conn, cursor, statement, parameters, context, executemany):
        if parameters is None:
            captured.append((statement, ()))
        elif isinstance(parameters, dict):
            captured.append((statement, parameters))
        elif isinstance(parameters, tuple):
            captured.append((statement, parameters))

    today = datetime.now(timezone.utc).date()
    out: dict[str, list[dict]] = {}
    conn = _psycopg(engine.url.render_as_string(hide_password=False))
    cur = conn.cursor()
    for name, params in _windows(today).items():
        path = "/api/v1/dashboard" if name == "dashboard" else f"/api/v1/reports/{name}"
        captured.clear()
        event.listen(engine, "before_cursor_execute", _before)
        client.get(path, params=params, headers=headers)
        event.remove(engine, "before_cursor_execute", _before)

        rows = []
        for statement, parameters in captured:
            if statement.lstrip().upper().startswith(("SELECT", "WITH")):
                try:
                    cur.execute(
                        "EXPLAIN (ANALYZE, BUFFERS) " + statement, parameters
                    )
                    plan = [r[0] for r in cur.fetchall()]
                except Exception as exc:  # pragma: no cover - plan-only failure
                    rows.append({"sql": statement[:160], "error": str(exc)[:200]})
                    continue
                execution_ms = next(
                    (
                        float(line.split(":", 1)[1].strip().split()[0])
                        for line in plan
                        if line.startswith("Execution Time")
                    ),
                    0.0,
                )
                first = plan[0] if plan else ""
                rows.append(
                    {
                        "sql": statement[:160],
                        "execution_ms": round(execution_ms, 2),
                        "plan_top": first[:200],
                    }
                )
        rows.sort(key=lambda r: r.get("execution_ms", 0), reverse=True)
        out[name] = rows
    cur.close()
    conn.close()
    return out


# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------


def print_report(
    results: list[dict],
    plans: dict[str, list[dict]],
    path: Path,
    counts: dict[str, int],
) -> None:
    failures = []
    print("\n=== endpoint latency (p95 at documented range caps) ===")
    header = f"{'endpoint':16} {'p50':>8} {'p95':>8} {'max':>8} {'payload':>9} {'budget':>7}  verdict"
    print(header)
    for row in results:
        budget = row["budget_ms"]
        if budget is None:
            verdict = "n/a (no budget)"
        elif row["p95_ms"] <= budget:
            verdict = "PASS"
        else:
            verdict = "FAIL"
            failures.append((row["endpoint"], row["p95_ms"], budget))
        budget_text = f"{budget} ms" if budget else "-"
        print(
            f"{row['endpoint']:16} {row['p50_ms']:>7.1f} {row['p95_ms']:>7.1f}"
            f" {row['max_ms']:>7.1f} {row['payload_bytes']:>8}B {budget_text:>7}  {verdict}"
        )

    print("\n=== EXPLAIN (ANALYZE, BUFFERS) — slowest statements per endpoint ===")
    for name, rows in plans.items():
        print(f"\n{name}:")
        for row in rows[:3]:
            if "error" in row:
                print(f"   plan error: {row['error']}")
                continue
            print(f"   {row['execution_ms']:>8.2f} ms  {row['plan_top']}")
            print(f"                 {row['sql']}")

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "dataset": counts,
        "endpoints": results,
        "plans": plans,
        "budget_failures": [
            {"endpoint": e, "p95_ms": p, "budget_ms": b} for e, p, b in failures
        ],
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"\nresults written to {path}")
    if failures:
        print(f"BUDGET FAILURES: {failures}")
    else:
        print("all budgets met")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> int:
    global N_SALES

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-seed", action="store_true", help="reuse seeded data")
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument(
        "--sales",
        type=int,
        default=N_SALES,
        help="number of sales to seed (default 200000)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=BACKEND_DIR / "docs" / "phase14_benchmark_results.json",
    )
    args = parser.parse_args()
    N_SALES = args.sales

    base = _base_url()
    bench = _bench_url(base)
    os.environ["DATABASE_URL"] = bench
    os.environ.setdefault("APP_ENV", "development")

    if not args.skip_seed:
        print(f"resetting database {BENCH_DB_NAME} ...")
        _reset_database(base)
        print("applying migrations ...")
        _migrate(bench)
        print("seeding ...")
        seed(bench)

    from fastapi.testclient import TestClient

    from app.db.engine import get_engine
    from app.main import app

    get_engine().echo = False
    logging.disable(logging.INFO)
    with TestClient(app, raise_server_exceptions=False) as client:
        headers = _admin_headers(client)
        print(f"measuring {args.iterations} samples per endpoint ...")
        results = measure(client, headers, args.iterations)
        print("collecting EXPLAIN ANALYZE plans ...")
        plans = explain(client, headers)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    counts = _counts(bench)
    print_report(results, plans, args.out, counts)
    return 1 if results and any(
        r["budget_ms"] and r["p95_ms"] > r["budget_ms"] for r in results
    ) else 0


if __name__ == "__main__":
    raise SystemExit(main())
