"""Large-sale benchmark — POST /sales with 1000 / 5000 / 10 000 distinct lines.

Business rule under test (MAX_SALE_LINES): one invoice may hold up to
10 000 DISTINCT cart lines.  This script measures what that costs end to end
on an ISOLATED PostgreSQL database (``supermarket_bench_largesale``) — the
production database (``supermarket_pro``) is never touched.  The URL is
derived from ``.env`` exactly like ``scripts/benchmark_phase17.py``.

Measured per line count (N):

* ``payload_bytes``   raw JSON request size
* ``validation_ms``   Pydantic parse + schema validation of the payload
                      (rejects N > 10 000 before any DB work)
* ``service_ms``      ``SaleService.create_sale`` — line resolution, the ONE
                      atomic transaction, and response mapping
* ``db_statements`` / ``db_ms``   SQL statements issued + cumulative DB time
* ``tx_ms``           first write statement -> commit (transaction window)
* ``peak_memory_mb``  tracemalloc peak during a second, timed run
* ``http_total_ms``   real HTTP POST over a socket (uvicorn) — parse,
                      validation, service, JSON response, transfer
* plus read-back timings: ``GET /sales/{id}`` detail and
  ``GET /sales?page_size=10`` list (both load the sale's lines eagerly)

Usage::

    python scripts/benchmark_large_sale.py                       # full run
    python scripts/benchmark_large_sale.py --sizes 1000,5000
    python scripts/benchmark_large_sale.py --skip-seed           # reuse data

Exit code 1 when a sale request did not return 201.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import tracemalloc
import uuid
import warnings
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

warnings.filterwarnings("ignore")

BACKEND_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

import benchmark_reports_phase14 as p14  # noqa: E402  (shared harness)

BENCH_DB_NAME = "supermarket_bench_largesale"
DEFAULT_SIZES = (1_000, 5_000, 10_000)
DEFAULT_PRODUCTS = 10_000
STOCK_EACH = 1_000_000


# --------------------------------------------------------------------------
# seed / fixture
# --------------------------------------------------------------------------


def seed_products(url: str, n_products: int) -> None:
    """Bulk-insert ``n_products`` sellable rows (psycopg2 ``execute_values``)."""
    from psycopg2.extras import execute_values, register_uuid

    register_uuid()
    conn = p14._psycopg(url)
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM products")
    have = cur.fetchone()[0]
    if have >= n_products:
        print(f"  products already present ({have})", flush=True)
        cur.close()
        conn.close()
        return

    print(f"  products ({n_products}) ...", flush=True)
    rows = []
    for i in range(n_products):
        price = round(10 + (i % 490), 3)
        cost = round(price * 0.6, 3)
        rows.append(
            (
                uuid.uuid4(),
                f"LargeSale Product {i:06d}",
                f"LS{i:08d}",
                None,
                "piece",
                price,
                cost,
                float(STOCK_EACH),
                cost,
                5,
            )
        )
    execute_values(
        cur,
        "INSERT INTO products (id, name, barcode, category_id, unit, price, cost,"
        " quantity, avg_cost, low_stock_threshold) VALUES %s",
        rows,
        page_size=5_000,
    )
    conn.commit()
    cur.execute("ANALYZE products")
    conn.commit()
    cur.close()
    conn.close()
    print("  seed complete + ANALYZE", flush=True)


def product_rows(url: str, n: int) -> list[tuple[str, Decimal]]:
    """Distinct (product_id, price) pairs, oldest first."""
    conn = p14._psycopg(url)
    cur = conn.cursor()
    cur.execute(
        "SELECT id, price FROM products WHERE archived_at IS NULL "
        "ORDER BY created_at, id LIMIT %s",
        (n,),
    )
    rows = [(str(pid), price) for pid, price in cur.fetchall()]
    cur.close()
    conn.close()
    if len(rows) < n:
        raise SystemExit(f"only {len(rows)} products available, need {n}")
    return rows


def build_payload(
    rows: list[tuple[str, Decimal]], size: int, *, client_request_id: str | None = None
) -> tuple[dict, str]:
    """N distinct lines, qty 1 each; cash paid == exact server-side total."""
    items = [
        {"product_id": pid, "quantity": "1", "unit_price": str(price)}
        for pid, price in rows[:size]
    ]
    # qty 1 => line_total == unit_price (both NUMERIC 3dp), so the exact
    # total is the plain sum — paid matches what the server computes.
    total = sum((price for _, price in rows[:size]), Decimal("0"))
    payload = {
        "client_request_id": client_request_id or f"bench-large-{uuid.uuid4()}",
        "items": items,
        "payment_method": "cash",
        "paid": str(total),
    }
    return payload, str(total)


# --------------------------------------------------------------------------
# in-process measurements
# --------------------------------------------------------------------------


def _attach_listeners(engine):
    """Statement counters + tx window (first write -> commit)."""
    from sqlalchemy import event
    from sqlalchemy.orm import Session as SASession

    stats = {"statements": 0, "db_ms": 0.0, "first_write": None, "commit": None}
    started: dict[str, float] = {}

    def before(conn, cursor, statement, parameters, context, executemany):
        started["t"] = time.perf_counter()

    def after(conn, cursor, statement, parameters, context, executemany):
        t0 = started.pop("t", None)
        if t0 is not None:
            stats["db_ms"] += (time.perf_counter() - t0) * 1000
        stats["statements"] += 1
        if statement.lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE")):
            if stats["first_write"] is None:
                stats["first_write"] = time.perf_counter()

    def after_commit(session):
        stats["commit"] = time.perf_counter()

    event.listen(engine, "before_cursor_execute", before)
    event.listen(engine, "after_cursor_execute", after)
    event.listen(SASession, "after_commit", after_commit)
    return stats, (before, after, after_commit)


def _detach_listeners(engine, handlers) -> None:
    from sqlalchemy import event
    from sqlalchemy.orm import Session as SASession

    before, after, after_commit = handlers
    event.remove(engine, "before_cursor_execute", before)
    event.remove(engine, "after_cursor_execute", after)
    event.remove(SASession, "after_commit", after_commit)


def measure_validation(raw_json: str) -> float:
    """FastAPI-side parse + schema validation time (ms)."""
    from app.schemas.sale import CreateSaleRequest

    payload = json.loads(raw_json)
    t0 = time.perf_counter()
    CreateSaleRequest.model_validate(payload)
    return (time.perf_counter() - t0) * 1000


def _run_sale(items: list[dict], paid: str, client_request_id: str):
    from app.db.engine import get_session_factory
    from app.schemas.sale import CreateSaleRequest
    from app.services.sale import SaleService

    session = get_session_factory()()
    try:
        request = CreateSaleRequest.model_validate(
            {
                "client_request_id": client_request_id,
                "items": items,
                "payment_method": "cash",
                "paid": paid,
            }
        )
        service = SaleService(session)
        t0 = time.perf_counter()
        response = service.create_sale(request, user=None, device_id="BENCH-1")
        elapsed_ms = (time.perf_counter() - t0) * 1000
        return elapsed_ms, response
    finally:
        session.close()


def measure_service(engine, items: list[dict], paid: str) -> dict:
    """Service time + DB statement stats for one real checkout."""
    stats, handlers = _attach_listeners(engine)
    try:
        service_ms, response = _run_sale(items, paid, f"bench-large-{uuid.uuid4()}")
    finally:
        _detach_listeners(engine, handlers)
    first_write = stats["first_write"]
    commit = stats["commit"]
    tx_ms = (commit - first_write) * 1000 if first_write and commit else None
    return {
        "service_ms": service_ms,
        "db_statements": stats["statements"],
        "db_ms": stats["db_ms"],
        "tx_ms": tx_ms,
        "response_lines": len(response.lines),
    }


def measure_peak_memory(items: list[dict], paid: str) -> float:
    """tracemalloc peak (MB) for validation + service of one checkout."""
    tracemalloc.start()
    try:
        _run_sale(items, paid, f"bench-large-{uuid.uuid4()}")
        _peak = tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()
    return _peak / (1024 * 1024)


# --------------------------------------------------------------------------
# HTTP measurements (real socket)
# --------------------------------------------------------------------------


def _start_server(app, host: str = "127.0.0.1", port: int = 0):
    import socket
    import threading

    import uvicorn

    if port == 0:
        with socket.socket() as probe:
            probe.bind((host, 0))
            port = probe.getsockname()[1]
    config = uvicorn.Config(app, host=host, port=port, log_level="warning", access_log=False)
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True, name="large-sale-bench")
    thread.start()
    deadline = time.time() + 30
    while not server.started:
        if time.time() > deadline or not thread.is_alive():
            raise SystemExit("benchmark server failed to start")
        time.sleep(0.05)
    return server, thread, f"http://{host}:{port}"


def measure_http(http_base: str, sizes: list[int], rows) -> dict[int, dict]:
    import httpx

    out: dict[int, dict] = {}
    with httpx.Client(base_url=http_base, timeout=600.0) as client:
        headers = p14._admin_headers(client)
        for size in sizes:
            payload, _paid = build_payload(rows, size)
            t0 = time.perf_counter()
            resp = client.post("/api/v1/sales", json=payload, headers=headers)
            http_ms = (time.perf_counter() - t0) * 1000
            if resp.status_code != 201:
                raise SystemExit(
                    f"POST /sales ({size} lines) -> {resp.status_code}: {resp.text[:400]}"
                )
            body = resp.json()
            sale_id = body["id"]

            t0 = time.perf_counter()
            detail = client.get(f"/api/v1/sales/{sale_id}", headers=headers)
            detail_ms = (time.perf_counter() - t0) * 1000
            t0 = time.perf_counter()
            listing = client.get(
                "/api/v1/sales", params={"page_size": 10}, headers=headers
            )
            list_ms = (time.perf_counter() - t0) * 1000
            if detail.status_code != 200 or listing.status_code != 200:
                raise SystemExit(
                    f"read-back failed: detail={detail.status_code} "
                    f"list={listing.status_code}"
                )
            out[size] = {
                "http_total_ms": http_ms,
                "http_status": resp.status_code,
                "response_bytes": len(resp.content),
                "detail_ms": detail_ms,
                "detail_bytes": len(detail.content),
                "list10_ms": list_ms,
                "list10_bytes": len(listing.content),
            }
            print(
                f"    http {size:>6} lines: {http_ms:>8.1f} ms"
                f"  resp={len(resp.content) / 1024 / 1024:.2f} MB"
                f"  detail={detail_ms:.1f} ms  list10={list_ms:.1f} ms",
                flush=True,
            )
    return out


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="Large-sale (10k-line) benchmark")
    parser.add_argument(
        "--sizes",
        default=",".join(str(s) for s in DEFAULT_SIZES),
        help="comma-separated distinct-line counts (max products)",
    )
    parser.add_argument("--products", type=int, default=DEFAULT_PRODUCTS)
    parser.add_argument("--skip-seed", action="store_true", help="reuse seeded data")
    parser.add_argument("--skip-http", action="store_true", help="service layer only")
    parser.add_argument(
        "--out",
        type=Path,
        default=BACKEND_DIR / "docs" / "large_sale_benchmark_results.json",
    )
    args = parser.parse_args()
    sizes = sorted(int(s) for s in args.sizes.split(",") if s.strip())
    if max(sizes) > args.products:
        raise SystemExit("--products must be >= the largest size")

    base = p14._base_url()
    p14.BENCH_DB_NAME = BENCH_DB_NAME
    bench = p14._bench_url(base)
    os.environ["DATABASE_URL"] = bench
    os.environ.setdefault("LAN_MODE", "0")
    os.environ.setdefault("DISCOVERY_ENABLED", "0")
    os.environ.setdefault("APP_ENV", "development")
    # Shipped request path: the dev-only statement log is INFO-level noise a
    # production install does not carry (same rule as benchmark_phase17).
    os.environ.setdefault("LOG_LEVEL", "WARNING")

    if not args.skip_seed:
        print(f"resetting database {BENCH_DB_NAME} ...")
        p14._reset_database(base)
        print("applying migrations ...")
        p14._migrate(bench)
        print(f"seeding {args.products} products ...")
        seed_products(bench, args.products)

    rows = product_rows(bench, max(sizes))

    from app.db.engine import get_engine
    from app.main import app

    engine = get_engine()
    engine.echo = False
    logging.disable(logging.INFO)
    # structlog ignores logging.disable (its own wrapper class filters), and
    # the dev statement log renders every row — noise a production install
    # does not carry.  Filter it out so timings reflect the shipped path.
    import structlog

    structlog.configure(
        wrapper_class=structlog.make_filtering_bound_logger(logging.WARNING)
    )

    print("service-layer measurements (in-process) ...")
    results: list[dict] = []
    for size in sizes:
        payload, _paid = build_payload(rows, size)
        raw_json = json.dumps(payload)
        validation_ms = measure_validation(raw_json)
        service = measure_service(engine, payload["items"], payload["paid"])
        peak_mb = measure_peak_memory(payload["items"], payload["paid"])
        row = {
            "lines": size,
            "payload_bytes": len(raw_json.encode("utf-8")),
            "validation_ms": round(validation_ms, 1),
            "service_ms": round(service["service_ms"], 1),
            "db_statements": service["db_statements"],
            "db_ms": round(service["db_ms"], 1),
            "tx_ms": round(service["tx_ms"], 1) if service["tx_ms"] else None,
            "peak_memory_mb": round(peak_mb, 1),
            "response_lines": service["response_lines"],
        }
        results.append(row)
        print(
            f"  {size:>6} lines  payload={row['payload_bytes'] / 1024 / 1024:.2f} MB"
            f"  validation={row['validation_ms']:>7.1f} ms"
            f"  service={row['service_ms']:>8.1f} ms"
            f"  stmts={row['db_statements']:>6}"
            f"  db={row['db_ms']:>8.1f} ms"
            f"  tx={row['tx_ms']} ms"
            f"  peak={row['peak_memory_mb']:.1f} MB",
            flush=True,
        )

    if not args.skip_http:
        print("HTTP measurements (real uvicorn socket) ...")
        server, thread, http_base = _start_server(app)
        try:
            http_stats = measure_http(http_base, sizes, rows)
        finally:
            server.should_exit = True
            thread.join(timeout=15)
        for row in results:
            row.update(http_stats[row["lines"]])

    run = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "database": BENCH_DB_NAME,
        "products": args.products,
        "stock_each": STOCK_EACH,
        "results": results,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.out.exists():
        previous = json.loads(args.out.read_text(encoding="utf-8"))
        runs = previous.get("runs", [previous])
    else:
        runs = []
    sizes_key = ",".join(str(s) for s in sizes)
    runs = [r for r in runs if r.get("sizes_key") != sizes_key] + [
        {**run, "sizes_key": sizes_key}
    ]
    args.out.write_text(
        json.dumps({"generated_at": run["generated_at"], "runs": runs}, indent=2),
        encoding="utf-8",
    )
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
