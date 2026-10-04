"""Phase 17 §17.8 — performance audit (Phase 0 target SLOs).

Seeds an ISOLATED PostgreSQL database (``supermarket_bench_phase17``) with a
product-scale fixture (``--products 1000 | 10000 | 100000``, default 10000)
plus report history, then measures the Phase 0 target SLOs through the real
HTTP surface (FastAPI ``TestClient``).  The production database
(``supermarket_pro``) is never touched: the URL is derived from ``.env`` the
same way ``scripts/benchmark_reports_phase14.py`` does.

Budgets (``docs/PHASE_0_PERFORMANCE_AUDIT.md``, "Target SLOs"):

    pos_lookup    GET  /products/search              p95 <   100 ms
    pos_barcode   GET  /products/barcode-lookup      p95 <   100 ms
    product_page  GET  /products?page=1&page_size=50 p95 <   200 ms
    sale_command  POST /sales                        p95 <   500 ms (excl. printing)
    dashboard     GET  /dashboard                    p95 <  2000 ms
    daily_report  GET  /reports/daily                p95 <  2000 ms
    receipt_start POST /print                        p95 <  3000 ms (job begins)
    export        POST /exports                      p95 <  5000 ms
    concurrent    pos_lookup + sale_command from --tills (default 4) tills
                  with --think-ms between requests (the POS search box is
                  debounced, so a real till never fires back-to-back); these
                  reuse the budgets above (Phase 0: "concurrent tills").
    saturation    the same tills with think_ms=0, i.e. back-to-back until the
                  single-process server saturates.  Recorded for the report,
                  no budget: it measures headroom, not the SLO.

Usage::

    python scripts/benchmark_phase17.py --products 1000
    python scripts/benchmark_phase17.py --products 100000 --iterations 30
    python scripts/benchmark_phase17.py --skip-seed --products 10000

Exit code is 1 when any measured p95 exceeds its budget.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import statistics
import sys
import time
import uuid
import warnings
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

warnings.filterwarnings("ignore")

BACKEND_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

import benchmark_reports_phase14 as p14  # noqa: E402  (shared harness)

BENCH_DB_NAME = "supermarket_bench_phase17"
N_CATEGORIES = 8
N_CUSTOMERS = 100

# Phase 0 target SLOs, milliseconds (p95).
BUDGETS_MS = {
    "pos_lookup": 100,
    "pos_barcode": 100,
    "product_page": 200,
    "sale_command": 500,
    "dashboard": 2000,
    "daily_report": 2000,
    "receipt_start": 3000,
    "export": 5000,
}
OK_STATUS = {"sale_command": {201, 200}}


# --------------------------------------------------------------------------
# seed
# --------------------------------------------------------------------------


def seed(url: str, n_products: int, n_sales: int) -> None:
    """Bulk-insert the Phase 17 fixture with psycopg2 ``execute_values``."""
    from psycopg2.extras import execute_values, register_uuid

    register_uuid()
    conn = p14._psycopg(url)
    cur = conn.cursor()
    start, end = p14._window()
    span_seconds = int((end - start).total_seconds())
    rnd = p14._Lcg(seed=20261004)

    def when() -> datetime:
        return start + timedelta(seconds=rnd.int(0, span_seconds))

    print(f"  categories ({N_CATEGORIES}) ...", flush=True)
    category_ids = [uuid.uuid4() for _ in range(N_CATEGORIES)]
    execute_values(
        cur,
        "INSERT INTO categories (id, name, sort_order) VALUES %s",
        [(cid, f"Category {i}", i) for i, cid in enumerate(category_ids)],
    )

    print(f"  products ({n_products}) ...", flush=True)
    products = []
    for i in range(n_products):
        price = round(10 + rnd.int(0, 490), 3)
        cost = round(price * 0.6, 3)
        products.append(
            {
                "id": uuid.uuid4(),
                "name": f"Product {i:06d}",
                "barcode": f"B{i:08d}",
                "category_id": category_ids[i % N_CATEGORIES] if i % 10 else None,
                "price": price,
                "cost": cost,
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
                p["cost"],
                5,
            )
            for p in products
        ],
        page_size=5_000,
    )

    print(f"  customers ({N_CUSTOMERS}) ...", flush=True)
    customer_ids = [uuid.uuid4() for _ in range(N_CUSTOMERS)]
    execute_values(
        cur,
        "INSERT INTO customers (id, name, phone, balance, debt_ceiling) VALUES %s",
        [(cid, f"Customer {i}", None, 0, 1000) for i, cid in enumerate(customer_ids)],
        page_size=5_000,
    )

    methods = ["cash"] * 60 + ["card"] * 20 + ["partial"] * 10 + ["credit"] * 10
    print(f"  sales ({n_sales}) + sale lines ...", flush=True)
    sale_rows: list[tuple] = []
    line_rows: list[tuple] = []
    line_insert = (
        "INSERT INTO sale_lines (sale_id, product_id, product_name, product_unit,"
        " unit_price, unit_cost, quantity, line_discount, line_total,"
        " selling_unit_multiplier) VALUES %s"
    )
    sales_insert = (
        "INSERT INTO sales (id, invoice_number, customer_id, user_id, status,"
        " subtotal, discount, total, paid, change, payment_method, device_id,"
        " sale_date, voided_at, void_reason) VALUES %s"
    )

    for i in range(n_sales):
        sale_id = uuid.uuid4()
        n_lines = 1 + rnd.int(0, 2)
        subtotal = 0.0
        for _ in range(n_lines):
            product = products[rnd.int(0, n_products - 1)]
            qty = float(1 + rnd.int(0, 2))
            discount = (
                round(product["price"] * qty * 0.05, 3) if rnd.int(0, 9) == 0 else 0.0
            )
            line_total = round(product["price"] * qty - discount, 3)
            subtotal = round(subtotal + line_total, 3)
            line_rows.append(
                (
                    sale_id,
                    product["id"],
                    product["name"],
                    "piece",
                    product["price"],
                    product["cost"],
                    qty,
                    discount,
                    line_total,
                    None,
                )
            )
        invoice_discount = round(subtotal * 0.05, 3) if rnd.int(0, 19) == 0 else 0.0
        total = round(subtotal - invoice_discount, 3)
        method = methods[rnd.int(0, 99)]
        if method == "cash":
            paid = round(total * 1.05, 3)
            change = round(paid - total, 3)
        elif method == "card":
            paid, change = total, 0.0
        elif method == "partial":
            paid, change = round(total * 0.4, 3), 0.0
        else:
            paid, change = 0.0, 0.0
        sale_rows.append(
            (
                sale_id,
                f"INV-{i:07d}",
                customer_ids[rnd.int(0, N_CUSTOMERS - 1)] if rnd.int(0, 9) == 0 else None,
                None,
                "completed",
                subtotal,
                invoice_discount,
                total,
                paid,
                change,
                method,
                "POS-1",
                when(),
                None,
                None,
            )
        )
        if len(sale_rows) >= 20_000:
            execute_values(cur, sales_insert, sale_rows, page_size=10_000)
            sale_rows.clear()
            execute_values(cur, line_insert, line_rows, page_size=10_000)
            line_rows.clear()

    if sale_rows:
        execute_values(cur, sales_insert, sale_rows, page_size=10_000)
    if line_rows:
        execute_values(cur, line_insert, line_rows, page_size=10_000)

    conn.commit()
    cur.execute("ANALYZE")
    conn.commit()
    cur.close()
    conn.close()
    print("  seed complete + ANALYZE", flush=True)


def _fixture(url: str) -> dict:
    """Pick the measurement operands out of the seeded database.

    The chosen product is topped up so the sale scenarios never fail on
    stock: a benchmark that trips a business rule is measuring the error
    path, not the SLO.
    """
    conn = p14._psycopg(url)
    cur = conn.cursor()
    cur.execute("SELECT id, price FROM products WHERE archived_at IS NULL LIMIT 1")
    product_id, price = cur.fetchone()
    cur.execute("UPDATE products SET quantity = 1000000 WHERE id = %s", (product_id,))
    cur.execute("SELECT id FROM sales ORDER BY sale_date DESC LIMIT 1")
    sale_id = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM products")
    n_products = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM sales")
    n_sales = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return {
        "product_id": str(product_id),
        "price": float(price),
        "sale_id": str(sale_id),
        "products": n_products,
        "sales": n_sales,
    }


# --------------------------------------------------------------------------
# measurement
# --------------------------------------------------------------------------


def _scenario_calls(fx: dict) -> dict[str, object]:
    today = datetime.now(timezone.utc).date()
    date_from = (today - timedelta(days=399)).isoformat()
    date_to = today.isoformat()

    def pos_lookup(client, headers):
        return client.get(
            "/api/v1/products/search", params={"q": "product", "limit": 20}, headers=headers
        ).status_code

    def pos_barcode(client, headers):
        return client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "B00000042"},
            headers=headers,
        ).status_code

    def product_page(client, headers):
        return client.get(
            "/api/v1/products", params={"page": 1, "page_size": 50}, headers=headers
        ).status_code

    def sale_command(client, headers):
        return client.post(
            "/api/v1/sales",
            json={
                "client_request_id": str(uuid.uuid4()),
                "items": [
                    {
                        "product_id": fx["product_id"],
                        "quantity": 1,
                        "unit_price": fx["price"],
                    }
                ],
                "payment_method": "cash",
                "paid": fx["price"],
            },
            headers=headers,
        ).status_code

    def dashboard(client, headers):
        return client.get("/api/v1/dashboard", headers=headers).status_code

    def daily_report(client, headers):
        return client.get(
            "/api/v1/reports/daily",
            params={"date_from": date_from, "date_to": date_to},
            headers=headers,
        ).status_code

    def receipt_start(client, headers):
        return client.post(
            "/api/v1/print",
            json={
                "document_type": "sale",
                "document_id": fx["sale_id"],
                "paper": "80mm",
                "locale": "ar",
            },
            headers=headers,
        ).status_code

    def export(client, headers):
        return client.post(
            "/api/v1/exports",
            json={
                "report": "daily",
                "format": "xlsx",
                "date_from": date_from,
                "date_to": date_to,
            },
            headers=headers,
        ).status_code

    return {
        "pos_lookup": pos_lookup,
        "pos_barcode": pos_barcode,
        "product_page": product_page,
        "sale_command": sale_command,
        "dashboard": dashboard,
        "daily_report": daily_report,
        "receipt_start": receipt_start,
        "export": export,
    }


def _percentile(values: list[float], pct: float) -> float:
    return p14._percentile(values, pct)


def _check(name: str, status: int) -> None:
    allowed = OK_STATUS.get(name, {200})
    if status not in allowed:
        raise SystemExit(f"{name}: HTTP {status} (expected {sorted(allowed)})")


def measure(client, headers: dict, fx: dict, iterations: int) -> list[dict]:
    calls = _scenario_calls(fx)
    results = []
    for name, call in calls.items():
        for _ in range(2):  # warm-up
            _check(name, call(client, headers))
        samples = []
        for _ in range(iterations):
            began = time.perf_counter()
            _check(name, call(client, headers))
            samples.append((time.perf_counter() - began) * 1000)
        results.append(
            {
                "scenario": name,
                "samples": len(samples),
                "p50_ms": round(statistics.median(samples), 1),
                "p95_ms": round(_percentile(samples, 0.95), 1),
                "max_ms": round(max(samples), 1),
                "budget_ms": BUDGETS_MS[name],
                "pass": _percentile(samples, 0.95) <= BUDGETS_MS[name],
            }
        )
        print(
            f"  {name:<14} p50={results[-1]['p50_ms']:>7.1f}ms"
            f"  p95={results[-1]['p95_ms']:>7.1f}ms"
            f"  budget={BUDGETS_MS[name]}ms  {'PASS' if results[-1]['pass'] else 'FAIL'}",
            flush=True,
        )
    return results


def measure_concurrent(
    http_base: str,
    headers: dict,
    fx: dict,
    tills: int,
    iterations: int,
    *,
    think_ms: int,
    label: str,
    budgeted: bool,
) -> list[dict]:
    """Several tills running lookup + sale at the same time.

    Runs against the real uvicorn server over HTTP: a till on the same LAN
    talks to a socket, not to an in-process ASGI test transport, so the
    numbers reflect the shipped deployment path.

    ``think_ms`` is the pause between a till's requests (the POS search box
    is debounced, so a real till never fires back-to-back queries).  With
    ``think_ms=0`` the tills saturate the single-process server; that block
    is recorded as ``saturation:*`` for the record and carries no budget.
    """
    import httpx

    calls = _scenario_calls(fx)
    picked = ("pos_lookup", "sale_command")
    collected: dict[str, list[float]] = {name: [] for name in picked}

    def till() -> None:
        with httpx.Client(base_url=http_base, timeout=60.0) as client:
            # Warm up (pool checkout, first-request JIT) before timing, so the
            # p95 reflects a till that is already open for business.
            for _ in range(3):
                for name in picked:
                    _check(name, calls[name](client, headers))
            for _ in range(iterations):
                for name in picked:
                    began = time.perf_counter()
                    _check(name, calls[name](client, headers))
                    collected[name].append((time.perf_counter() - began) * 1000)
                    if think_ms:
                        time.sleep(think_ms / 1000)

    mode = "think-time" if think_ms else "saturation"
    print(f"  {tills} concurrent tills x {iterations} iterations ({mode}) ...", flush=True)
    with ThreadPoolExecutor(max_workers=tills) as pool:
        list(pool.map(lambda _: till(), range(tills)))

    results = []
    for name in picked:
        samples = collected[name]
        budget = BUDGETS_MS[name] if budgeted else None
        ok = None if budget is None else _percentile(samples, 0.95) <= budget
        results.append(
            {
                "scenario": f"{label}:{name}",
                "samples": len(samples),
                "think_ms": think_ms,
                "p50_ms": round(statistics.median(samples), 1),
                "p95_ms": round(_percentile(samples, 0.95), 1),
                "max_ms": round(max(samples), 1),
                "budget_ms": budget,
                "pass": ok,
            }
        )
        verdict = "PASS" if ok else ("FAIL" if ok is False else "info")
        budget_text = f"{budget}ms" if budget is not None else "n/a"
        print(
            f"  {f'{label[:4]}:{name}':<14} p50={results[-1]['p50_ms']:>7.1f}ms"
            f"  p95={results[-1]['p95_ms']:>7.1f}ms"
            f"  budget={budget_text:<6} {verdict}",
            flush=True,
        )
    return results


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def _start_server(app, host: str = "127.0.0.1", port: int = 0):
    """Run the real app on a real socket so tills speak HTTP, not ASGI."""
    import socket
    import threading

    import uvicorn

    if port == 0:
        with socket.socket() as probe:
            probe.bind((host, 0))
            port = probe.getsockname()[1]
    config = uvicorn.Config(app, host=host, port=port, log_level="warning", access_log=False)
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True, name="bench-uvicorn")
    thread.start()
    deadline = time.time() + 30
    while not server.started:
        if time.time() > deadline or not thread.is_alive():
            raise SystemExit("benchmark server failed to start")
        time.sleep(0.05)
    return server, thread, f"http://{host}:{port}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 17 §17.8 performance audit")
    parser.add_argument("--products", type=int, default=10_000, help="products to seed")
    parser.add_argument("--sales", type=int, default=20_000, help="sales to seed")
    parser.add_argument("--iterations", type=int, default=30, help="samples per scenario")
    parser.add_argument("--tills", type=int, default=4, help="concurrent till count")
    parser.add_argument("--concurrent-iterations", type=int, default=20)
    parser.add_argument(
        "--think-ms",
        type=int,
        default=300,
        help="pause between a till's requests (POS search debounce)",
    )
    parser.add_argument(
        "--saturation-iterations",
        type=int,
        default=10,
        help="back-to-back iterations for the informational saturation block",
    )
    parser.add_argument("--skip-seed", action="store_true", help="reuse seeded data")
    parser.add_argument(
        "--out",
        type=Path,
        default=BACKEND_DIR / "docs" / "phase17_benchmark_results.json",
    )
    args = parser.parse_args()

    base = p14._base_url()
    p14.BENCH_DB_NAME = BENCH_DB_NAME
    bench = p14._bench_url(base)
    os.environ["DATABASE_URL"] = bench
    os.environ.setdefault("LAN_MODE", "0")
    os.environ.setdefault("DISCOVERY_ENABLED", "0")
    os.environ.setdefault("APP_ENV", "development")
    # Measure the shipped request path: the §17.7 dev-only SQL statement log
    # renders every statement, which is overhead a production install does
    # not carry (APP_ENV != development switches the listener off entirely).
    os.environ.setdefault("LOG_LEVEL", "WARNING")

    if not args.skip_seed:
        print(f"resetting database {BENCH_DB_NAME} ...")
        p14._reset_database(base)
        print("applying migrations ...")
        p14._migrate(bench)
        print(f"seeding {args.products} products / {args.sales} sales ...")
        seed(bench, args.products, args.sales)

    fx = _fixture(bench)

    from app.db.engine import get_engine
    from app.main import app

    get_engine().echo = False
    logging.disable(logging.INFO)

    server, thread, http_base = _start_server(app)
    try:
        import httpx

        with httpx.Client(base_url=http_base, timeout=60.0) as client:
            headers = p14._admin_headers(client)
            print(f"measuring {args.iterations} samples per scenario ...")
            results = measure(client, headers, fx, args.iterations)
        results += measure_concurrent(
            http_base,
            headers,
            fx,
            args.tills,
            args.concurrent_iterations,
            think_ms=args.think_ms,
            label="concurrent",
            budgeted=True,
        )
        results += measure_concurrent(
            http_base,
            headers,
            fx,
            args.tills,
            args.saturation_iterations,
            think_ms=0,
            label="saturation",
            budgeted=False,
        )
    finally:
        server.should_exit = True
        thread.join(timeout=15)

    run = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "products": fx["products"],
        "sales": fx["sales"],
        "iterations": args.iterations,
        "tills": args.tills,
        "think_ms": args.think_ms,
        "results": results,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.out.exists():
        previous = json.loads(args.out.read_text(encoding="utf-8"))
        runs = previous.get("runs", [previous])
    else:
        runs = []
    runs = [r for r in runs if r.get("products") != run["products"]] + [run]
    args.out.write_text(
        json.dumps({"generated_at": run["generated_at"], "runs": runs}, indent=2),
        encoding="utf-8",
    )
    print(f"wrote {args.out}")

    failed = [r["scenario"] for r in results if r["pass"] is False]
    if failed:
        print("OVER BUDGET: " + ", ".join(failed))
        return 1
    print("all scenarios within budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
