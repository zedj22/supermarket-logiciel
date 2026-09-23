"""Phase 6 final manual-test live smoke against real backend 127.0.0.1:8000."""

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

        # 1. Atomic create with staged children
        bc = f"SMOKE35-{uuid.uuid4().hex[:6].upper()}"
        payload = {
            "name": "§35 Smoke Product",
            "barcode": bc,
            "price": "12.500",
            "cost": "8.000",
            "quantity": "48",
            "unit": "piece",
            "variants": [
                {"name": "Large", "barcode": f"{bc}-L", "price": "15.000"},
            ],
            "selling_units": [
                {
                    "name": "Piece",
                    "multiplier": "1",
                    "is_base_unit": True,
                    # selling_price omitted → NULL → inherit
                },
                {
                    "name": "Pack6",
                    "multiplier": "6",
                    "selling_price": "70.000",
                },
            ],
            "purchase_units": [
                {"name": "Box12", "unit_type": "piece", "multiplier": "12",
                 "is_default": True},
            ],
        }
        r = c.post(f"{BASE}/products", json=payload, headers=h)
        check(r.status_code == 201, f"create-with-children status={r.status_code} body={r.text[:300]}")
        if r.status_code != 201:
            return 1
        pid = r.json()["id"]

        # children persisted
        vs = c.get(f"{BASE}/products/{pid}/variants", headers=h).json()
        check(vs["total"] == 1, f"variants total={vs['total']}")
        sus = c.get(f"{BASE}/products/{pid}/selling-units", headers=h).json()
        check(sus["total"] == 2, f"selling-units total={sus['total']}")
        base = next(s for s in sus["items"] if s["is_base_unit"])
        check(base["selling_price"] is None, f"base selling_price={base['selling_price']!r} (expect None)")
        check(base["effective_price"] == "12.500",
              f"base effective_price={base['effective_price']} (inherit product 12.500)")
        pack = next(s for s in sus["items"] if s["name"] == "Pack6")
        check(pack["selling_price"] == "70.000", f"pack selling_price={pack['selling_price']}")
        check(pack["effective_price"] == "70.000", f"pack effective_price={pack['effective_price']}")
        pus = c.get(f"{BASE}/products/{pid}/purchase-units", headers=h).json()
        check(pus["total"] == 1, f"purchase-units total={pus['total']}")
        check(pus["items"][0]["is_default"] is True, "purchase unit is_default")

        # 2. Atomic rollback on duplicate staged child name
        rb = c.post(
            f"{BASE}/products",
            json={
                "name": "§35 Rollback",
                "barcode": f"{bc}-RB",
                "price": "1",
                "cost": "1",
                "quantity": "0",
                "unit": "piece",
                "variants": [{"name": "Dup"}, {"name": "Dup"}],
            },
            headers=h,
        )
        check(rb.status_code == 409, f"rollback duplicate staged name status={rb.status_code}")
        lst = c.get(f"{BASE}/products", params={"search": f"{bc}-RB"}, headers=h).json()
        check(lst["total"] == 0, f"rollback product persisted total={lst['total']} (expect 0)")

        # 3. selling_price NULL via dedicated create endpoint
        su = c.post(
            f"{BASE}/products/{pid}/selling-units",
            json={"name": "NullPrice", "multiplier": "3"},
            headers=h,
        )
        check(su.status_code == 201, f"create selling unit null price status={su.status_code}")
        body = su.json()
        check(body["selling_price"] is None, f"null selling_price={body['selling_price']!r}")
        check(body["effective_price"] == "12.500",
              f"null effective_price={body['effective_price']} (inherit)")

        # 4. Archive variant / selling unit / purchase unit
        vid = vs["items"][0]["id"]
        ar = c.delete(f"{BASE}/products/{pid}/variants/{vid}", headers=h)
        check(ar.status_code == 200 and ar.json().get("is_archived") is True,
              f"archive variant status={ar.status_code}")

        su_id = pack["id"]
        ar2 = c.delete(f"{BASE}/products/{pid}/selling-units/{su_id}", headers=h)
        check(ar2.status_code == 200 and ar2.json().get("is_archived") is True,
              f"archive selling unit status={ar2.status_code}")

        pu_id = pus["items"][0]["id"]
        ar3 = c.delete(f"{BASE}/products/{pid}/purchase-units/{pu_id}", headers=h)
        check(ar3.status_code == 204, f"archive purchase unit status={ar3.status_code}")

        # listed under include_archived
        sus_arch = c.get(
            f"{BASE}/products/{pid}/selling-units",
            params={"include_archived": True},
            headers=h,
        ).json()
        row = next(i for i in sus_arch["items"] if i["id"] == su_id)
        check(row["is_archived"] is True, "archived selling unit visible with include_archived")

        # 5. Barcode lookup still works for archived product barcode? (product still active)
        lu = c.get(f"{BASE}/products/barcode-lookup", params={"barcode": f"{bc}-L"}, headers=h)
        # variant archived → lookup may miss; check product barcode instead
        lu2 = c.get(f"{BASE}/products/barcode-lookup", params={"barcode": bc}, headers=h)
        check(lu2.status_code == 200 and lu2.json().get("found") is True,
              f"barcode lookup product found={lu2.json().get('found')}")

        # 6. RBAC: cashier cannot create with children (if cashier exists)
        try:
            users = c.get(f"{BASE}/auth/login-users").json()["items"]
            cashier = next(
                (u for u in users if "Cashier" in u["full_name"]), None
            )
            if cashier is None:
                print("SKIP cashier RBAC (no cashier user in this DB)")
            else:
                r = c.post(
                    f"{BASE}/auth/login",
                    json={"user_id": cashier["id"], "pin": "3333"},
                )
                if r.status_code != 200:
                    print(f"SKIP cashier RBAC (login status={r.status_code})")
                else:
                    ch = {"Authorization": f"Bearer {r.json()['access_token']}"}
                    cr = c.post(
                        f"{BASE}/products",
                        json={"name": "Nope", "price": "1", "cost": "1",
                              "quantity": "0", "unit": "piece",
                              "selling_units": [{"name": "X", "multiplier": "1"}]},
                        headers=ch,
                    )
                    check(cr.status_code in (401, 403),
                          f"cashier create-with-children status={cr.status_code}")
        except Exception as e:  # noqa: BLE001
            check(False, f"cashier RBAC check failed: {type(e).__name__}: {e}")

        # 7. DB column nullability + alembic head
        from sqlalchemy import create_engine, text
        from app.core.config import settings

        eng = create_engine(settings.DATABASE_URL)
        with eng.connect() as conn:
            col = conn.execute(
                text(
                    "SELECT is_nullable FROM information_schema.columns "
                    "WHERE table_name='product_selling_units' AND column_name='selling_price'"
                )
            ).scalar()
            check(col == "YES", f"selling_price is_nullable={col} (expect YES)")
            ver = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
            check(ver == "e5f6a7b8c9d0", f"alembic_version={ver} (expect e5f6a7b8c9d0)")

        # 8. DB row with NULL selling_price stored as NULL (not 0.000)
        with eng.connect() as conn:
            row = conn.execute(
                text(
                    "SELECT selling_price FROM product_selling_units "
                    "WHERE product_id = :pid AND name = 'Piece'"
                ),
                {"pid": pid},
            ).fetchone()
            check(row is not None and row[0] is None,
                  f"DB Piece selling_price={row[0] if row else None!r} (expect None)")

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
