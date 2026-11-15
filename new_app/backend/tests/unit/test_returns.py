"""Phase 12 tests — returns (linked and independent).

Covers the decision-record gates:

- GATE  2/3   posted immediately; linked (sale-scoped) vs independent
- GATE  4     cumulative per-source-line ceiling -> RETURN_EXCEEDS_SOLD
- GATE  5/12  refund valued from the persisted sale line economics
- GATE  6     PMP (avg_cost) never moves on a return
- GATE  7     RETURN movements with source_document_type/id
- GATE  8     capped debt reversal, shortfall written into the note
- GATE 10     voided sales cannot be returned (SALE_ALREADY_VOID)
- GATE 11/12  pack components restored from the SALE's own lines
              (never today's pack_items), variant-only restore
- GATE 13     selling-unit snapshot -> quantity_base
- GATE 14     pro-rata refund + invoice-discount share that conserves
- GATE 16     client_request_id idempotency + IDEMPOTENCY_CONFLICT
- GATE 21     pos_return permission (cashier has it, unauthenticated 401)
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.catalog import Pack, PackItem, Product, ProductVariant
from app.models.debt import DebtLedgerEntry
from app.models.inventory import InventoryMovement
from app.models.party import Customer
from app.models.return_doc import Return
from app.services.auth import AuthService

# ── Fixtures ──────────────────────────────────────────────────────────────


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def testing_session(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, testing_session):
    session = testing_session()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    session.commit()
    yield session
    session.close()


@pytest.fixture()
def client(engine, testing_session, db):
    def override_get_db():
        session = testing_session()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


_seq = {"n": 0}


def _next() -> int:
    _seq["n"] += 1
    return _seq["n"]


def _create_product(client, headers, **overrides) -> dict:
    n = _next()
    payload = {
        "name": overrides.pop("name", f"Return Product {n}"),
        "barcode": overrides.pop("barcode", f"RTN{n:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "10.000"),
        "unit": overrides.pop("unit", "piece"),
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_variant(client, headers, product_id: str, **overrides) -> dict:
    payload = {"name": overrides.pop("name", f"Var {_next()}")}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/variants",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_selling_unit(client, headers, product_id: str, **overrides) -> dict:
    payload = {
        "name": overrides.pop("name", f"Unit {_next()}"),
        "multiplier": overrides.pop("multiplier", "1"),
        "is_base_unit": overrides.pop("is_base_unit", False),
    }
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/selling-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, name: str) -> dict:
    resp = client.post(
        "/api/v1/customers", json={"name": name}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale_payload(items, **overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": items,
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": "100000.000",
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _post_sale(client, headers, payload: dict):
    return client.post("/api/v1/sales", json=payload, headers=headers)


def _sell(client, headers, product_id: str, quantity: str, **overrides) -> dict:
    """One-line cash sale; returns the committed sale body."""
    payload = _sale_payload(
        [
            {
                "product_id": product_id,
                "quantity": quantity,
                "unit_price": overrides.pop("unit_price", "100.000"),
                "line_discount": "0.000",
            }
        ],
        **overrides,
    )
    resp = _post_sale(client, headers, payload)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _return_payload(lines, **overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "reason": "defective",
        "lines": lines,
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _post_return(client, headers, payload: dict):
    return client.post("/api/v1/returns", json=payload, headers=headers)


def _stock(client, headers, product_id: str) -> Decimal:
    resp = client.get(f"/api/v1/products/{product_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return Decimal(resp.json()["quantity"])


def _sale(client, headers, sale_id: str) -> dict:
    resp = client.get(f"/api/v1/sales/{sale_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _product_line(sale: dict) -> dict:
    return next(ln for ln in sale["lines"] if ln["product_id"] is not None)


def _movements(db, **filters) -> list[InventoryMovement]:
    db.expire_all()
    stmt = select(InventoryMovement)
    for attr, value in filters.items():
        stmt = stmt.where(getattr(InventoryMovement, attr) == value)
    return list(db.execute(stmt).scalars().all())


# ── GATE 2/3/5/7: linked return ───────────────────────────────────────────


class TestLinkedReturn:
    def test_full_line_return_restores_stock_and_journals(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "3.000")
        assert _stock(client, admin_headers, p["id"]) == Decimal("7.000")

        line = _product_line(sale)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "3.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # stock is fully restored
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")

        # GATE 5: refund comes from the persisted line, not today's price
        assert Decimal(body["refund_total"]) == Decimal(line["line_total"])
        assert Decimal(body["return"]["total"]) == Decimal(line["line_total"])
        assert Decimal(body["credit_reversed"]) == Decimal("0.000")
        assert Decimal(body["cash_pending"]) == Decimal(body["refund_total"])

        # GATE 7: typed RETURN movement pointing at the return document
        moves = _movements(db, product_id=uuid.UUID(p["id"]), movement_type="return")
        assert len(moves) == 1
        assert moves[0].source_document_type == "return"
        assert moves[0].source_document_id == uuid.UUID(body["return"]["id"])
        assert Decimal(str(moves[0].quantity_change)) == Decimal("3.000")

        # one audit row for the operation (GATE 21)
        db.expire_all()
        audits = list(
            db.execute(
                select(AuditLog).where(AuditLog.entity_type == "return")
            ).scalars().all()
        )
        assert len(audits) == 1
        assert audits[0].action == "return"

    def test_sale_snapshot_is_never_rewritten(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "2.000")
        line = _product_line(sale)

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text

        after = _sale(client, admin_headers, sale["id"])
        assert after["status"] == "completed"
        assert Decimal(after["total"]) == Decimal(sale["total"])
        assert Decimal(after["paid"]) == Decimal(sale["paid"])
        assert Decimal(after["subtotal"]) == Decimal(sale["subtotal"])
        assert after["voided_at"] is None

    def test_source_line_must_exist_and_be_requested(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], "1.000")

        # unknown source line
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": str(uuid.uuid4()), "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "RETURN_LINE_INVALID"

        # linked return without sale_line_id is not addressable
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"product_id": p["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "RETURN_LINE_INVALID"

    def test_customer_mismatch_is_rejected(self, client, admin_headers, db):
        c = _create_customer(client, admin_headers, "Return Customer")
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], "1.000", customer_id=c["id"])
        line = _product_line(sale)

        other = _create_customer(client, admin_headers, "Someone Else")
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
                customer_id=other["id"],
            ),
        )
        assert resp.status_code == 422

    def test_linked_return_without_reason_is_accepted(
        self, client, admin_headers, db
    ):
        """Phase 12 fix round 1: reason is optional on linked returns."""
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], "1.000")
        line = _product_line(sale)

        payload = _return_payload(
            [{"sale_line_id": line["id"], "quantity": "1.000"}],
            sale_id=sale["id"],
        )
        payload.pop("reason")  # omitted entirely

        resp = _post_return(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["return"]["reason"] is None

        db.expire_all()
        stored = db.get(Return, uuid.UUID(body["return"]["id"]))
        assert stored is not None
        assert stored.reason is None

        # stock + refund semantics unchanged by the optional reason
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")
        assert Decimal(body["refund_total"]) == Decimal("100.000")


# ── GATE 4/16: ceiling and idempotency ────────────────────────────────────


class TestCeilingAndIdempotency:
    def test_cumulative_ceiling_per_source_line(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "3.000")
        line = _product_line(sale)

        first = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "2.000"}],
                sale_id=sale["id"],
            ),
        )
        assert first.status_code == 201, first.text
        assert Decimal(first.json()["refund_total"]) == Decimal("200.000")

        # 2 already returned + 2 requested > 3 sold
        second = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "2.000"}],
                sale_id=sale["id"],
            ),
        )
        assert second.status_code == 409
        error = second.json()["error"]
        assert error["code"] == "RETURN_EXCEEDS_SOLD"
        assert error["details"]["sold"] == "3.000"
        assert error["details"]["already_returned"] == "2.000"
        assert error["details"]["requested"] == "2.000"

        # the remaining unit is still returnable
        third = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert third.status_code == 201, third.text
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")

    def test_duplicate_request_lines_are_merged_before_the_ceiling(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "1.000")
        line = _product_line(sale)

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [
                    {"sale_line_id": line["id"], "quantity": "1.000"},
                    {"sale_line_id": line["id"], "quantity": "1.000"},
                ],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 409
        assert resp.json()["error"]["code"] == "RETURN_EXCEEDS_SOLD"

    def test_replay_returns_the_same_document(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "2.000")
        line = _product_line(sale)
        payload = _return_payload(
            [{"sale_line_id": line["id"], "quantity": "1.000"}],
            sale_id=sale["id"],
        )

        first = _post_return(client, admin_headers, payload)
        assert first.status_code == 201, first.text
        assert first.json()["idempotent_replay"] is False
        stock_after_first = _stock(client, admin_headers, p["id"])

        replay = _post_return(client, admin_headers, payload)
        assert replay.status_code == 201, replay.text
        assert replay.json()["idempotent_replay"] is True
        assert replay.json()["return"]["id"] == first.json()["return"]["id"]
        assert Decimal(replay.json()["refund_total"]) == Decimal(
            first.json()["refund_total"]
        )

        # stock was restored exactly once
        assert _stock(client, admin_headers, p["id"]) == stock_after_first
        db.expire_all()
        assert len(list(db.execute(select(Return)).scalars().all())) == 1

    def test_same_key_different_payload_conflicts(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "3.000")
        line = _product_line(sale)
        key = str(uuid.uuid4())

        first = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
                client_request_id=key,
            ),
        )
        assert first.status_code == 201, first.text

        second = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "2.000"}],
                sale_id=sale["id"],
                client_request_id=key,
            ),
        )
        assert second.status_code == 409
        assert second.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"

    def test_replay_matches_short_and_persisted_quantity_forms(
        self, client, admin_headers, db
    ):
        """An exact replay typed as '1' must match the stored '1.000'.

        The UI sends whole quantities (``2``, not ``2.000``); comparing raw
        ``str(Decimal)`` reported a false IDEMPOTENCY_CONFLICT on the retry.
        """
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "3.000")
        line = _product_line(sale)

        linked = _return_payload(
            [{"sale_line_id": line["id"], "quantity": "1"}],
            sale_id=sale["id"],
        )
        first = _post_return(client, admin_headers, linked)
        assert first.status_code == 201, first.text
        assert first.json()["idempotent_replay"] is False
        replay = _post_return(client, admin_headers, linked)
        assert replay.status_code == 201, replay.text
        assert replay.json()["idempotent_replay"] is True
        assert replay.json()["return"]["id"] == first.json()["return"]["id"]

        # Independent line, short quantity form.
        stock_before = _stock(client, admin_headers, p["id"])
        independent = {
            "client_request_id": str(uuid.uuid4()),
            "lines": [{"product_id": p["id"], "quantity": "2"}],
        }
        first_i = _post_return(client, admin_headers, independent)
        assert first_i.status_code == 201, first_i.text
        assert _stock(client, admin_headers, p["id"]) == stock_before + Decimal("2")
        stock_after = _stock(client, admin_headers, p["id"])

        replay_i = _post_return(client, admin_headers, independent)
        assert replay_i.status_code == 201, replay_i.text
        assert replay_i.json()["idempotent_replay"] is True
        assert replay_i.json()["return"]["id"] == first_i.json()["return"]["id"]
        db.expire_all()
        assert _stock(client, admin_headers, p["id"]) == stock_after

        # A genuinely different quantity still conflicts (short form).
        conflict = {
            "client_request_id": independent["client_request_id"],
            "lines": [{"product_id": p["id"], "quantity": "3"}],
        }
        third = _post_return(client, admin_headers, conflict)
        assert third.status_code == 409
        assert third.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"


# ── GATE 3/4: independent return ──────────────────────────────────────────


class TestIndependentReturn:
    def test_uses_current_price_and_has_no_ceiling(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="0.000")
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"product_id": p["id"], "quantity": "2.000"}],
                reason="customer_change",
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        assert _stock(client, admin_headers, p["id"]) == Decimal("2.000")
        assert Decimal(body["refund_total"]) == Decimal("200.000")
        assert body["return"]["sale_id"] is None
        assert body["return"]["subtotal"] == body["return"]["total"]

        # no sale to reverse against -> nothing owed back as credit
        assert Decimal(body["credit_reversed"]) == Decimal("0.000")
        assert Decimal(body["cash_pending"]) == Decimal("200.000")

    def test_product_id_and_pack_rules(self, client, admin_headers):
        resp = _post_return(
            client,
            admin_headers,
            _return_payload([{"quantity": "1.000"}], reason="other"),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "RETURN_LINE_INVALID"

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"pack_id": str(uuid.uuid4()), "quantity": "1.000"}],
                reason="other",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "RETURN_LINE_INVALID"

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"product_id": str(uuid.uuid4()), "quantity": "1.000"}],
                reason="other",
            ),
        )
        assert resp.status_code == 404

    def test_reason_is_optional_and_persists_as_null(
        self, client, admin_headers, db
    ):
        """Phase 12 fix round 1: an independent return needs no reason."""
        p = _create_product(client, admin_headers)
        resp = client.post(
            "/api/v1/returns",
            json={
                "client_request_id": str(uuid.uuid4()),
                "lines": [{"product_id": p["id"], "quantity": "1.000"}],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["return"]["reason"] is None

        db.expire_all()
        stored = db.get(Return, uuid.UUID(body["return"]["id"]))
        assert stored is not None
        assert stored.reason is None

        # stock restoration is unchanged by the missing reason
        assert _stock(client, admin_headers, p["id"]) == Decimal("11.000")

    @pytest.mark.parametrize("reason", [None, "", "   "])
    def test_null_and_blank_reason_are_treated_as_absent(
        self, client, admin_headers, reason
    ):
        p = _create_product(client, admin_headers)
        payload = {
            "client_request_id": str(uuid.uuid4()),
            "reason": reason,
            "lines": [{"product_id": p["id"], "quantity": "1.000"}],
        }
        resp = _post_return(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert resp.json()["return"]["reason"] is None

    def test_supplied_valid_reason_is_persisted(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        payload = _return_payload(
            [{"product_id": p["id"], "quantity": "1.000"}],
            reason="expired",
        )
        resp = _post_return(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert resp.json()["return"]["reason"] == "expired"

    def test_supplied_invalid_reason_is_rejected(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        payload = _return_payload(
            [{"product_id": p["id"], "quantity": "1.000"}],
            reason="damaged_in_transit",
        )
        resp = _post_return(client, admin_headers, payload)
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_multi_line_return_is_one_document_with_n_lines(
        self, client, admin_headers, db
    ):
        """One submission = one independent return with N return_lines."""
        a = _create_product(client, admin_headers, quantity="5.000")
        b = _create_product(client, admin_headers, quantity="5.000")
        c = _create_product(client, admin_headers, quantity="5.000")

        resp = _post_return(
            client,
            admin_headers,
            {
                "client_request_id": str(uuid.uuid4()),
                "lines": [
                    {"product_id": a["id"], "quantity": "2.000"},
                    {"product_id": b["id"], "quantity": "1.000"},
                    {"product_id": c["id"], "quantity": "4.000"},
                ],
            },
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["return"]["sale_id"] is None
        assert len(body["return"]["lines"]) == 3

        db.expire_all()
        docs = list(db.execute(select(Return)).scalars().all())
        assert len(docs) == 1
        assert len(docs[0].lines) == 3

        # each line restored its own product, atomically
        assert _stock(client, admin_headers, a["id"]) == Decimal("7.000")
        assert _stock(client, admin_headers, b["id"]) == Decimal("6.000")
        assert _stock(client, admin_headers, c["id"]) == Decimal("9.000")

    def test_repeated_target_lines_are_merged_into_one_line(
        self, client, admin_headers, db
    ):
        """Rescanning the same product merges quantities server-side."""
        p = _create_product(client, admin_headers, quantity="5.000")

        resp = _post_return(
            client,
            admin_headers,
            {
                "client_request_id": str(uuid.uuid4()),
                "lines": [
                    {"product_id": p["id"], "quantity": "1.000"},
                    {"product_id": p["id"], "quantity": "2.000"},
                ],
            },
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert len(body["return"]["lines"]) == 1
        assert Decimal(body["return"]["lines"][0]["quantity"]) == Decimal(
            "3.000"
        )
        assert _stock(client, admin_headers, p["id"]) == Decimal("8.000")

    def test_piece_quantities_must_be_whole(self, client, admin_headers):
        p = _create_product(client, admin_headers, unit="piece")
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"product_id": p["id"], "quantity": "0.500"}], reason="other"
            ),
        )
        assert resp.status_code == 422

        weight = _create_product(client, admin_headers, unit="kg")
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"product_id": weight["id"], "quantity": "1.500"}], reason="other"
            ),
        )
        assert resp.status_code == 201, resp.text


# ── GATE 8: debt reversal ─────────────────────────────────────────────────


class TestDebtReversal:
    def _credit_sale(self, client, headers, customer_id: str, quantity: str) -> dict:
        p = _create_product(client, headers, quantity="20.000")
        payload = _sale_payload(
            [
                {
                    "product_id": p["id"],
                    "quantity": quantity,
                    "unit_price": "100.000",
                }
            ],
            payment_method="credit",
            paid="0.000",
            customer_id=customer_id,
        )
        resp = _post_sale(client, headers, payload)
        assert resp.status_code == 201, resp.text
        return resp.json()

    def test_credit_return_reverses_the_matching_debt(
        self, client, admin_headers, db
    ):
        c = _create_customer(client, admin_headers, "Debt Return")
        sale = self._credit_sale(client, admin_headers, c["id"], "4.000")
        db.expire_all()
        assert Decimal(str(db.get(Customer, uuid.UUID(c["id"])).balance)) == Decimal(
            "400.000"
        )

        line = _product_line(sale)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        assert Decimal(body["credit_reversed"]) == Decimal("100.000")
        assert Decimal(body["cash_pending"]) == Decimal("0.000")

        db.expire_all()
        customer = db.get(Customer, uuid.UUID(c["id"]))
        assert Decimal(str(customer.balance)) == Decimal("300.000")

        entries = list(
            db.execute(
                select(DebtLedgerEntry).where(
                    DebtLedgerEntry.reference_sale_id == uuid.UUID(sale["id"])
                )
            ).scalars().all()
        )
        refund_entries = [e for e in entries if e.entry_type == "sale_refund"]
        assert len(refund_entries) == 1
        assert Decimal(str(refund_entries[0].amount)) == Decimal("100.000")
        assert (
            refund_entries[0].client_request_id
            == body["return"]["client_request_id"]
        )

    def test_reversal_is_capped_and_shortfall_is_written(
        self, client, admin_headers, db
    ):
        # 100.000 total, 60.000 paid in cash -> only 40.000 on credit
        c = _create_customer(client, admin_headers, "Partial Debt")
        p = _create_product(client, admin_headers, quantity="20.000")
        sale = _sell(
            client,
            admin_headers,
            p["id"],
            "1.000",
            payment_method="partial",
            paid="60.000",
            customer_id=c["id"],
        )
        db.expire_all()
        assert Decimal(str(db.get(Customer, uuid.UUID(c["id"])).balance)) == Decimal(
            "40.000"
        )

        line = _product_line(sale)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # refund is the whole line (100), only the 40 credit is forgiven
        assert Decimal(body["refund_total"]) == Decimal("100.000")
        assert Decimal(body["credit_reversed"]) == Decimal("40.000")
        assert Decimal(body["cash_pending"]) == Decimal("60.000")

        db.expire_all()
        customer = db.get(Customer, uuid.UUID(c["id"]))
        assert Decimal(str(customer.balance)) == Decimal("0.000")

        entry = next(
            e
            for e in db.execute(select(DebtLedgerEntry)).scalars().all()
            if e.entry_type == "sale_refund"
        )
        assert "shortfall 60.000" in entry.note

    def test_cash_sale_return_writes_no_ledger_row(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "1.000")
        line = _product_line(sale)

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        assert Decimal(resp.json()["credit_reversed"]) == Decimal("0.000")

        db.expire_all()
        entries = list(
            db.execute(
                select(DebtLedgerEntry).where(
                    DebtLedgerEntry.reference_sale_id == uuid.UUID(sale["id"])
                )
            ).scalars().all()
        )
        assert entries == []


# ── GATE 11: pack returns ─────────────────────────────────────────────────


class TestPackReturn:
    @pytest.fixture()
    def pack_setup(self, client, admin_headers):
        rice = _create_product(
            client, admin_headers, name=f"Rice {_next()}", quantity="20.000"
        )
        oil = _create_product(
            client, admin_headers, name=f"Oil {_next()}", quantity="20.000"
        )
        components = [
            {"product_id": rice["id"], "quantity": "2.000"},
            {"product_id": oil["id"], "quantity": "1.000"},
        ]
        resp = client.post(
            "/api/v1/packs",
            json={
                "name": f"Family Pack {_next()}",
                "barcode": f"PKR{_next():06d}",
                "price": "500.000",
                "components": components,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        pack = resp.json()

        payload = _sale_payload(
            [
                {
                    "pack_id": pack["id"],
                    "quantity": "1.000",
                    "unit_price": "500.000",
                }
            ],
            paid="500.000",
        )
        sale_resp = _post_sale(client, admin_headers, payload)
        assert sale_resp.status_code == 201, sale_resp.text
        return {
            "pack": pack,
            "rice": rice,
            "oil": oil,
            "sale": sale_resp.json(),
        }

    def test_pack_return_is_whole_packs_only(self, client, admin_headers, pack_setup):
        summary = next(
            ln for ln in pack_setup["sale"]["lines"] if ln["product_id"] is None
        )
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": summary["id"], "quantity": "0.500"}],
                sale_id=pack_setup["sale"]["id"],
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "RETURN_PACK_NOT_WHOLE"

    def test_pack_components_cannot_be_returned_directly(
        self, client, admin_headers, pack_setup
    ):
        component = next(
            ln
            for ln in pack_setup["sale"]["lines"]
            if ln["product_id"] is not None
        )
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": component["id"], "quantity": "1.000"}],
                sale_id=pack_setup["sale"]["id"],
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "RETURN_LINE_INVALID"

    def test_pack_return_restores_sale_components_not_current_pack(
        self, client, admin_headers, db, pack_setup
    ):
        pack, rice, oil, sale = (
            pack_setup["pack"],
            pack_setup["rice"],
            pack_setup["oil"],
            pack_setup["sale"],
        )
        assert _stock(client, admin_headers, rice["id"]) == Decimal("18.000")
        assert _stock(client, admin_headers, oil["id"]) == Decimal("19.000")

        # The pack composition changes AFTER the sale: history must win.
        db.expire_all()
        for item in list(
            db.execute(
                select(PackItem).where(PackItem.pack_id == uuid.UUID(pack["id"]))
            ).scalars().all()
        ):
            db.delete(item)
        db.commit()

        summary = next(ln for ln in sale["lines"] if ln["product_id"] is None)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": summary["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # GATE 11: the sale's own components come back (2 rice + 1 oil)
        assert _stock(client, admin_headers, rice["id"]) == Decimal("20.000")
        assert _stock(client, admin_headers, oil["id"]) == Decimal("20.000")

        # the return line mirrors the pack summary shape
        assert len(body["return"]["lines"]) == 1
        rline = body["return"]["lines"][0]
        assert rline["product_id"] is None
        assert rline["pack_id"] == pack["id"]
        assert rline["quantity_base"] is None
        assert Decimal(rline["quantity"]) == Decimal("1.000")
        assert Decimal(rline["line_total"]) == Decimal("500.000")

        # one movement per component product, none for the summary
        moves = _movements(db, movement_type="return")
        assert {m.product_id for m in moves} == {
            uuid.UUID(rice["id"]),
            uuid.UUID(oil["id"]),
        }
        db.expire_all()
        pack_row = db.get(Pack, uuid.UUID(pack["id"]))
        assert pack_row is not None  # the pack itself is untouched


# ── GATE 6/12/13: variants, selling units, PMP ────────────────────────────


class TestVariantUnitsAndCost:
    def test_variant_return_touches_the_variant_only(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        v = _create_variant(
            client, admin_headers, p["id"], price="150.000", quantity="5.000"
        )
        db.expire_all()
        assert Decimal(str(db.get(ProductVariant, uuid.UUID(v["id"])).quantity)) == (
            Decimal("5.000")
        )

        payload = _sale_payload(
            [
                {
                    "product_id": p["id"],
                    "variant_id": v["id"],
                    "quantity": "1.000",
                    "unit_price": "150.000",
                }
            ],
            paid="150.000",
        )
        sale_resp = _post_sale(client, admin_headers, payload)
        assert sale_resp.status_code == 201, sale_resp.text
        sale = sale_resp.json()

        db.expire_all()
        variant_before = db.get(ProductVariant, uuid.UUID(v["id"]))
        assert Decimal(str(variant_before.quantity)) == Decimal("4.000")
        assert Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity)) == Decimal(
            "10.000"
        )

        line = _product_line(sale)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text

        db.expire_all()
        assert Decimal(str(db.get(ProductVariant, uuid.UUID(v["id"])).quantity)) == (
            Decimal("5.000")
        )
        # parent stock was never touched by sale or return (Phase 8/12)
        assert Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity)) == Decimal(
            "10.000"
        )
        moves = _movements(db, movement_type="return")
        assert moves and moves[0].variant_id == uuid.UUID(v["id"])

    def test_selling_unit_return_restores_base_quantity(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, quantity="10.000", unit="kg")
        unit = _create_selling_unit(
            client, admin_headers, p["id"], multiplier="2.500"
        )
        payload = _sale_payload(
            [
                {
                    "product_id": p["id"],
                    "selling_unit_id": unit["id"],
                    "quantity": "1.000",
                    "unit_price": "100.000",
                }
            ],
            paid="100.000",
        )
        sale_resp = _post_sale(client, admin_headers, payload)
        assert sale_resp.status_code == 201, sale_resp.text
        sale = sale_resp.json()
        assert _stock(client, admin_headers, p["id"]) == Decimal("7.500")

        line = _product_line(sale)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        rline = body["return"]["lines"][0]
        assert Decimal(rline["selling_unit_multiplier"]) == Decimal("2.500")
        assert Decimal(rline["quantity_base"]) == Decimal("2.500")
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")

    def test_pmp_is_unchanged_by_a_return(self, client, admin_headers, db):
        p = _create_product(
            client, admin_headers, cost="60.000", price="100.000", quantity="10.000"
        )
        sale = _sell(client, admin_headers, p["id"], "2.000")

        db.expire_all()
        cost_before = Decimal(str(db.get(Product, uuid.UUID(p["id"])).avg_cost))
        assert cost_before == Decimal("60.000")

        line = _product_line(sale)
        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "2.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text

        db.expire_all()
        product = db.get(Product, uuid.UUID(p["id"]))
        assert Decimal(str(product.avg_cost)) == cost_before

        moves = _movements(db, movement_type="return")
        assert Decimal(str(moves[0].avg_cost_after)) == cost_before


# ── GATE 14: discount conservation ────────────────────────────────────────


class TestInvoiceDiscountShare:
    def test_discount_is_shared_pro_rata_and_conserved(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        payload = _sale_payload(
            [
                {
                    "product_id": p["id"],
                    "quantity": "2.000",
                    "unit_price": "100.000",
                }
            ],
            invoice_discount="20.000",
            paid="180.000",
        )
        sale_resp = _post_sale(client, admin_headers, payload)
        assert sale_resp.status_code == 201, sale_resp.text
        sale = sale_resp.json()
        assert Decimal(sale["total"]) == Decimal("180.000")

        line = _product_line(sale)
        first = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert first.status_code == 201, first.text
        fbody = first.json()
        assert Decimal(fbody["return"]["subtotal"]) == Decimal("100.000")
        assert Decimal(fbody["return"]["discount"]) == Decimal("10.000")
        assert Decimal(fbody["return"]["total"]) == Decimal("90.000")

        second = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert second.status_code == 201, second.text
        sbody = second.json()
        assert Decimal(sbody["return"]["total"]) == Decimal("90.000")

        # GATE 14: the two refunds plus their shares equal the invoice total
        assert Decimal(fbody["return"]["total"]) + Decimal(
            sbody["return"]["total"]
        ) == Decimal(sale["total"])


# ── GATE 10/21: exclusion, history, permissions ───────────────────────────


class TestHistoryAndPermissions:
    def test_return_of_a_voided_sale_is_rejected(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "1.000")
        line = _product_line(sale)

        void = client.post(
            f"/api/v1/sales/{sale['id']}/void",
            json={"reason": "mistaken checkout"},
            headers=admin_headers,
        )
        assert void.status_code == 200, void.text

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 409
        assert resp.json()["error"]["code"] == "SALE_ALREADY_VOID"

    def test_history_filters_and_detail(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "1.000")
        line = _product_line(sale)
        posted = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "1.000"}],
                sale_id=sale["id"],
            ),
        )
        assert posted.status_code == 201, posted.text
        return_id = posted.json()["return"]["id"]

        listing = client.get(
            "/api/v1/returns",
            params={"invoice_number": sale["invoice_number"]},
            headers=admin_headers,
        )
        assert listing.status_code == 200, listing.text
        body = listing.json()
        assert body["total"] == 1
        assert body["items"][0]["id"] == return_id
        assert body["items"][0]["invoice_number"] == sale["invoice_number"]

        by_sale = client.get(
            "/api/v1/returns", params={"sale_id": sale["id"]}, headers=admin_headers
        )
        assert by_sale.json()["total"] == 1

        detail = client.get(f"/api/v1/returns/{return_id}", headers=admin_headers)
        assert detail.status_code == 200, detail.text
        assert detail.json()["return_number"].startswith("RET-")

        empty = client.get(
            "/api/v1/returns",
            params={"reason": "expired"},
            headers=admin_headers,
        )
        assert empty.json()["total"] == 0

    def test_cashier_with_pos_return_can_post(self, client, admin_headers, cashier_headers):
        # product_create is admin-only; the return itself is pos_return
        p = _create_product(client, admin_headers, quantity="10.000")
        resp = _post_return(
            client,
            cashier_headers,
            _return_payload(
                [{"product_id": p["id"], "quantity": "1.000"}], reason="defective"
            ),
        )
        assert resp.status_code == 201, resp.text

    def test_authentication_is_required(self, client):
        resp = client.post("/api/v1/returns", json={})
        assert resp.status_code == 401


# ── Method 2 (automatic sell-unit) money lifecycle ────────────────────────


class TestAutomaticBundlePricing:
    """The POS Method 2 payload priced 5 units at 500 with a 100 discount.

    The cart, the persisted sale, the invoice and a return must all carry the
    same 2 400 for that line: the discount is a stored line discount, never a
    display-only adjustment.
    """

    def _bundle_sale(self, client, admin_headers, *, quantity="5.000"):
        p = _create_product(
            client, admin_headers, price="500.000", quantity="20.000"
        )
        payload = _sale_payload(
            [
                {
                    "product_id": p["id"],
                    "quantity": quantity,
                    "unit_price": "500.000",
                    # floor(5/4)=1 bundle → 5×500 − 1900 = 100 saved.
                    "line_discount": "100.000",
                }
            ],
            paid="2400.000",
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        return p, resp.json()

    def test_sale_persists_the_cart_amount(self, client, admin_headers):
        p, sale = self._bundle_sale(client, admin_headers)

        assert Decimal(sale["subtotal"]) == Decimal("2500.000")
        assert Decimal(sale["discount"]) == Decimal("0.000")
        assert Decimal(sale["total"]) == Decimal("2400.000")

        line = _product_line(sale)
        assert Decimal(line["quantity"]) == Decimal("5.000")
        assert Decimal(line["unit_price"]) == Decimal("500.000")
        assert Decimal(line["line_discount"]) == Decimal("100.000")
        assert Decimal(line["line_total"]) == Decimal("2400.000")
        # Stock is decremented by the BASE quantity (no selling-unit link).
        assert _stock(client, admin_headers, p["id"]) == Decimal("15.000")

    def test_full_return_refunds_the_paid_amount(self, client, admin_headers):
        p, sale = self._bundle_sale(client, admin_headers)
        line = _product_line(sale)

        resp = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "5.000"}],
                sale_id=sale["id"],
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()["return"]
        # A linked return is valued from the CHARGED line (2 400), never from
        # the undiscounted gross — the bundle saving is not refunded back to
        # the shop.
        assert Decimal(body["subtotal"]) == Decimal("2400.000")
        assert Decimal(body["total"]) == Decimal("2400.000")
        assert _stock(client, admin_headers, p["id"]) == Decimal("20.000")

    def test_partial_returns_conserve_the_discount(self, client, admin_headers):
        _p, sale = self._bundle_sale(client, admin_headers)
        line = _product_line(sale)

        first = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "2.000"}],
                sale_id=sale["id"],
            ),
        )
        assert first.status_code == 201, first.text
        # 2/5 of 2 400 = 960 (the bundle rate is shared pro rata).
        assert Decimal(first.json()["return"]["total"]) == Decimal("960.000")

        second = _post_return(
            client,
            admin_headers,
            _return_payload(
                [{"sale_line_id": line["id"], "quantity": "3.000"}],
                sale_id=sale["id"],
            ),
        )
        assert second.status_code == 201, second.text
        assert Decimal(second.json()["return"]["total"]) == Decimal("1440.000")

        assert Decimal(first.json()["return"]["total"]) + Decimal(
            second.json()["return"]["total"]
        ) == Decimal(sale["total"])

    def test_discount_above_the_line_gross_is_rejected(
        self, client, admin_headers
    ):
        p = _create_product(
            client, admin_headers, price="500.000", quantity="20.000"
        )
        payload = _sale_payload(
            [
                {
                    "product_id": p["id"],
                    "quantity": "5.000",
                    "unit_price": "500.000",
                    "line_discount": "2600.000",  # gross is 2 500
                }
            ]
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code in (400, 422), resp.text
        # Nothing was persisted and no stock moved.
        assert _stock(client, admin_headers, p["id"]) == Decimal("20.000")
