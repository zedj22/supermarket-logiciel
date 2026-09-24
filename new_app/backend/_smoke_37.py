"""Phase 7 inventory/PMP live smoke against real backend 127.0.0.1:8000."""

from __future__ import annotations

import sys
import uuid

import httpx

BASE = "http://127.0.0.1:8000/api/v1"
FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("OK  " if cond else "FAIL") + " " + msg)
    if not cond:
        FAILURES.append(msg)


def login(c: httpx.Client, name: str, pin: str) -> dict:
    items = c.get(f"{BASE}/auth/login-users").json()["items"]
    uid = next(i["id"] for i in items if i["full_name"] == name)
    r = c.post(f"{BASE}/auth/login", json={"user_id": uid, "pin": pin})
    r.raise_for_status()
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def main() -> int:
    with httpx.Client(timeout=30.0) as c:
        h = login(c, "Admin", "1234")
        print("logged in as Admin")

        # 0. Unauthenticated inventory → 401
        r0 = c.get(f"{BASE}/inventory")
        check(r0.status_code == 401, f"unauth inventory status={r0.status_code}")

        # 1. Create product qty=1 cost=100 → seeds ADJUSTMENT + avg_cost=100
        bc = f"SMOKE37-{uuid.uuid4().hex[:6].upper()}"
        r = c.post(
            f"{BASE}/products",
            json={
                "name": "§37 PMP Product",
                "barcode": bc,
                "price": "150",
                "cost": "100",
                "quantity": "1",
                "unit": "piece",
                "low_stock_threshold": "5",
            },
            headers=h,
        )
        check(r.status_code == 201, f"create product status={r.status_code} body={r.text[:300]}")
        if r.status_code != 201:
            return 1
        pid = r.json()["id"]
        check(r.json()["avg_cost"] == "100.000", f"create avg_cost={r.json()['avg_cost']}")
        check(r.json()["quantity"] == "1.000", f"create quantity={r.json()['quantity']}")

        # 2. Inventory list shows PMP + valuation
        inv = c.get(f"{BASE}/inventory", params={"search": bc}, headers=h)
        check(inv.status_code == 200, f"inventory list status={inv.status_code}")
        item = next((i for i in inv.json()["items"] if i["barcode"] == bc), None)
        check(item is not None, "inventory list contains product")
        if item:
            check(item["avg_cost"] == "100.000", f"list avg_cost={item['avg_cost']}")
            check(item["stock_value"] == "100.000", f"list stock_value={item['stock_value']}")

        # 3. Acceptance A: increase 3 @ 200 → qty 4, value 700, PMP 175
        adj = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "3",
                "unit_cost": "200",
                "reason": "Phase7 smoke receive",
            },
            headers=h,
        )
        check(adj.status_code == 200, f"adjust increase status={adj.status_code} body={adj.text[:300]}")
        if adj.status_code == 200:
            body = adj.json()
            check(body["quantity"] == "4.000", f"after receive qty={body['quantity']}")
            check(body["avg_cost"] == "175.000", f"after receive PMP={body['avg_cost']}")
            check(body["stock_value"] == "700.000", f"after receive value={body['stock_value']}")

        # 4. Detail + movements for product
        det = c.get(f"{BASE}/inventory/{pid}", headers=h)
        check(det.status_code == 200, f"detail status={det.status_code}")
        if det.status_code == 200:
            d = det.json()
            check(d["quantity"] == "4.000", f"detail qty={d['quantity']}")
            check(d["avg_cost"] == "175.000", f"detail PMP={d['avg_cost']}")
            check(d["stock_value"] == "700.000", f"detail value={d['stock_value']}")
            check(len(d["recent_movements"]) >= 2, f"recent movements={len(d['recent_movements'])}")

        movs = c.get(f"{BASE}/inventory/movements/{pid}", headers=h)
        check(movs.status_code == 200, f"product movements status={movs.status_code}")
        if movs.status_code == 200:
            items = movs.json()["items"]
            check(len(items) == 2, f"movements total={movs.json()['total']}")
            types = [m["movement_type"] for m in items]
            check(types.count("adjustment") == 2, f"movement types={types}")
            # newest first (movement_date desc)
            check(items[0]["avg_cost_after"] == "175.000",
                  f"latest avg_cost_after={items[0]['avg_cost_after']}")
            check(items[0]["unit_cost"] == "200.000",
                  f"latest unit_cost={items[0]['unit_cost']}")

        # 5. Decrease without unit_cost never changes PMP
        dec = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "decrease",
                "quantity": "2",
                "reason": "Phase7 smoke decrease",
            },
            headers=h,
        )
        check(dec.status_code == 200, f"adjust decrease status={dec.status_code}")
        if dec.status_code == 200:
            body = dec.json()
            check(body["quantity"] == "2.000", f"after decrease qty={body['quantity']}")
            check(body["avg_cost"] == "175.000", f"after decrease PMP={body['avg_cost']}")
            check(body["stock_value"] == "350.000", f"after decrease value={body['stock_value']}")

        # 6. Set quantity zero → PMP unchanged; then receive into zero seeds cost
        st = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "set",
                "quantity": "0",
                "reason": "Phase7 stocktake zero",
            },
            headers=h,
        )
        check(st.status_code == 200, f"adjust set-zero status={st.status_code}")
        if st.status_code == 200:
            check(st.json()["quantity"] == "0.000", f"set-zero qty={st.json()['quantity']}")
            check(st.json()["avg_cost"] == "175.000", f"set-zero PMP={st.json()['avg_cost']}")

        seed = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "5",
                "unit_cost": "40",
                "reason": "Phase7 reseed",
            },
            headers=h,
        )
        check(seed.status_code == 200, f"reseed status={seed.status_code}")
        if seed.status_code == 200:
            check(seed.json()["avg_cost"] == "40.000",
                  f"zero-stock reseed PMP={seed.json()['avg_cost']}")

        # 7. Over-decrease (below zero, no negative stock) → business rule 422
        bad = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "decrease",
                "quantity": "9999",
                "reason": "should fail",
            },
            headers=h,
        )
        check(bad.status_code in (409, 422), f"over-decrease status={bad.status_code}")
        if bad.status_code >= 400:
            err = bad.json().get("error", {})
            check(bool(err.get("code")) and bool(err.get("message_key")),
                  f"structured error keys code={err.get('code')} message_key={err.get('message_key')}")

        # 8a. Increase without reason → 200 + neutral default
        inc_noreason = c.post(
            f"{BASE}/inventory/adjust",
            json={"product_id": pid, "operation": "increase", "quantity": "1.000"},
            headers=h,
        )
        check(
            inc_noreason.status_code == 200,
            f"increase without reason status={inc_noreason.status_code}",
        )
        mv = c.get(
            f"{BASE}/inventory/movements",
            params={"product_id": pid},
            headers=h,
        ).json()
        latest = mv["items"][0]
        check(
            latest.get("reason") == "Manual stock increase",
            f"increase default reason={latest.get('reason')!r}",
        )

        # 8b. Decrease without reason → 422 validation
        noreason = c.post(
            f"{BASE}/inventory/adjust",
            json={"product_id": pid, "operation": "decrease", "quantity": "1.000"},
            headers=h,
        )
        check(
            noreason.status_code == 422,
            f"decrease missing reason status={noreason.status_code}",
        )

        # 9. ProductUpdateRequest ignores quantity (stripped by Pydantic)
        put = c.put(
            f"{BASE}/products/{pid}",
            json={"quantity": "999", "price": "160"},
            headers=h,
        )
        check(put.status_code in (200, 204), f"product update status={put.status_code}")
        after = c.get(f"{BASE}/products/{pid}", headers=h).json()
        check(after["quantity"] == "6.000",
              f"quantity unchanged after PUT quantity=999 -> {after['quantity']}")
        check(after["price"] == "160.000", f"price updated to {after['price']}")

        # 10. Global movement journal
        gm = c.get(f"{BASE}/inventory/movements", params={"page_size": 20}, headers=h)
        check(gm.status_code == 200, f"global movements status={gm.status_code}")
        if gm.status_code == 200:
            check(gm.json()["total"] >= 5, f"global movements total={gm.json()['total']}")

        # 11. Cashier denied inventory_view / inventory_adjust
        users = c.get(f"{BASE}/auth/login-users").json()["items"]
        cashier = next((u for u in users if "zeblah" in u["full_name"].lower()
                        or "Cashier" in u["full_name"]), None)
        if cashier is None:
            print("SKIP cashier RBAC (no cashier user)")
        else:
            rr = c.post(f"{BASE}/auth/login",
                        json={"user_id": cashier["id"], "pin": "3333"})
            if rr.status_code != 200:
                print(f"SKIP cashier RBAC (login status={rr.status_code})")
            else:
                ch = {"Authorization": f"Bearer {rr.json()['access_token']}"}
                cv = c.get(f"{BASE}/inventory", headers=ch)
                check(cv.status_code in (401, 403),
                      f"cashier inventory_view status={cv.status_code}")
                ca = c.post(
                    f"{BASE}/inventory/adjust",
                    json={"product_id": pid, "operation": "increase",
                          "quantity": "1", "reason": "nope"},
                    headers=ch,
                )
                check(ca.status_code in (401, 403),
                      f"cashier inventory_adjust status={ca.status_code}")

        # 12. DB: avg_cost column + movement_date index + alembic head
        from sqlalchemy import create_engine, text

        from app.core.config import settings

        eng = create_engine(settings.DATABASE_URL)
        with eng.connect() as conn:
            col = conn.execute(
                text(
                    "SELECT is_nullable FROM information_schema.columns "
                    "WHERE table_name='products' AND column_name='avg_cost'"
                )
            ).scalar()
            check(col == "NO", f"products.avg_cost is_nullable={col} (expect NO)")
            uc = conn.execute(
                text(
                    "SELECT is_nullable FROM information_schema.columns "
                    "WHERE table_name='inventory_movements' AND column_name='unit_cost'"
                )
            ).scalar()
            check(uc == "YES", f"inventory_movements.unit_cost is_nullable={uc} (expect YES)")
            idx = conn.execute(
                text(
                    "SELECT indexname FROM pg_indexes "
                    "WHERE tablename='inventory_movements' AND indexname LIKE '%movement_date%'"
                )
            ).fetchone()
            check(idx is not None, f"movement_date index present={idx is not None}")
            ver = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
            check(ver == "f1a2b3c4d5e6", f"alembic_version={ver} (expect f1a2b3c4d5e6)")

            # persisted avg_cost matches live API
            row = conn.execute(
                text("SELECT avg_cost::text, quantity::text FROM products WHERE id = :pid"),
                {"pid": pid},
            ).fetchone()
            check(row is not None and row[0] == "40.000" and row[1] == "5.000",
                  f"DB product avg_cost/qty={row} (expect 40.000/5.000)")

            # PMP example A acceptance on a fresh product (1×100 + 3×200 → 175)
            row2 = conn.execute(
                text(
                    "SELECT avg_cost::text, quantity::text FROM products "
                    "WHERE barcode = :bc"
                ),
                {"bc": bc},
            ).fetchone()
            check(row2 == ("40.000", "5.000"), f"DB barcode row={row2}")

    print()
    if FAILURES:
        print(f"SMOKE FAILED ({len(FAILURES)}):")
        for f in FAILURES:
            print(" -", f)
        return 1
    print("SMOKE PASSED — all checks green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
