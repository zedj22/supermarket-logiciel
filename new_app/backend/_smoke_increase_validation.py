"""Live smoke: INCREASE with empty reason/unit_cost/note + structured 422."""

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

        # Seed product qty=50 cost=40 → avg_cost=40
        bc = f"SMOKEINC-{uuid.uuid4().hex[:6].upper()}"
        r = c.post(
            f"{BASE}/products",
            json={
                "name": "Increase validation product",
                "barcode": bc,
                "price": "150",
                "cost": "40",
                "quantity": "50",
                "unit": "piece",
            },
            headers=h,
        )
        check(r.status_code == 201, f"create status={r.status_code}")
        if r.status_code != 201:
            print(r.text)
            return 1
        pid = r.json()["id"]
        check(r.json()["avg_cost"] == "40.000", f"create avg_cost={r.json()['avg_cost']}")

        # A: increase + unit_cost null + reason null + note null → 200, +10, PMP unchanged
        r = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "10",
                "unit_cost": None,
                "reason": None,
                "note": None,
            },
            headers=h,
        )
        check(r.status_code == 200, f"increase null fields status={r.status_code} body={r.text[:300]}")
        if r.status_code == 200:
            body = r.json()
            check(body["quantity"] == "60.000", f"qty after +10 = {body['quantity']}")
            check(body["avg_cost"] == "40.000", f"avg_cost after = {body['avg_cost']}")

        # B: empty-string reason → default stored
        r = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "1",
                "reason": "",
                "unit_cost": "",
                "note": "",
            },
            headers=h,
        )
        check(r.status_code == 200, f"increase empty-string fields status={r.status_code} body={r.text[:300]}")

        # Journal: non-empty reason + unit_cost null on null-unit_cost increase
        movs = c.get(
            f"{BASE}/inventory/movements/{pid}",
            headers=h,
        ).json()["items"]
        adjustments = [
            m for m in movs
            if m["movement_type"] == "adjustment"
            and m["reason"] != "Initial stock on product create"
        ]
        check(len(adjustments) >= 2, f"adjustments count={len(adjustments)}")
        check(
            all(m["reason"] and m["reason"].strip() for m in adjustments),
            f"all reasons non-empty: {[m['reason'] for m in adjustments]}",
        )
        # First null-unit_cost increase → unit_cost None, avg_cost_after 40
        null_uc = [m for m in adjustments if m["unit_cost"] is None]
        check(len(null_uc) >= 1, f"null unit_cost movements={len(null_uc)}")
        if null_uc:
            check(null_uc[0]["avg_cost_after"] == "40.000", f"avg_cost_after={null_uc[0]['avg_cost_after']}")

        # D: decrease without reason → 422 structured envelope
        r = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "decrease",
                "quantity": "1",
            },
            headers=h,
        )
        check(r.status_code == 422, f"decrease no reason status={r.status_code}")
        body = r.json()
        check("error" in body, f"422 has error envelope: {list(body.keys())}")
        if "error" in body:
            check(body["error"]["code"] == "VALIDATION_ERROR", f"code={body['error'].get('code')}")
            msg = body["error"].get("message", "")
            check("reason" in msg.lower(), f"message mentions reason: {msg}")
            check("request_id" in body["error"], "request_id present")

        # E: set without reason → 422 structured
        r = c.post(
            f"{BASE}/inventory/adjust",
            json={"product_id": pid, "operation": "set", "quantity": "0"},
            headers=h,
        )
        check(r.status_code == 422, f"set no reason status={r.status_code}")
        body = r.json()
        check(body.get("error", {}).get("code") == "VALIDATION_ERROR", f"set 422 body={body}")

        # Invalid unit_cost field → structured 422 (Pydantic)
        r = c.post(
            f"{BASE}/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "1",
                "unit_cost": "-5",
            },
            headers=h,
        )
        check(r.status_code == 422, f"negative unit_cost status={r.status_code}")
        body = r.json()
        check("error" in body and body["error"]["code"] == "VALIDATION_ERROR", f"unit_cost 422 body={body}")
        if "error" in body:
            check("unit_cost" in body["error"]["message"].lower(), f"msg={body['error']['message']}")

        print()
        if FAILURES:
            print(f"SMOKE FAILED — {len(FAILURES)} failure(s)")
            for f in FAILURES:
                print(" -", f)
            return 1
        print("SMOKE PASSED — all checks green")
        return 0


if __name__ == "__main__":
    sys.exit(main())
