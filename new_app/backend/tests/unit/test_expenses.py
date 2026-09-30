"""Phase 13 tests — expenses.

Covers the decision-record gates:

- GATE  1  posted → cancelled is the whole state machine; never deleted
- GATE  5  paid_from_drawer is a classification flag only (no ledger)
- GATE  6  server-assigned id / expense_date / user_id / status
- GATE  7/8/9 admin, manager and cashier all hold the three scopes
- GATE 10  client_request_id idempotency (replay / conflict / race)
- GATE 11  status-guarded cancel: second cancel → 409, reason required
- GATE 12  list is filtered + paginated, newest first
- GATE 14/15 money stays Decimal, audit rows for CREATE and VOID

Defects fixed here: L1 (DOUBLE money), L2 (UI-only > 0), L3 (hard
delete), L4 (delete returned True on 0 rows), L7 (no attribution).
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta
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
from app.models.enums import PermissionScope
from app.models.expense import Expense
from app.models.user import Permission, Role, RolePermission, User
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
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    # No roles at all — must be denied on every expense scope.
    service.create_user(name="Guest No Roles", pin="9999", role_names=[])
    # Narrow custom role: expense_view only (list yes, create/cancel no).
    viewer = Role(name="viewer", description="read-only expenses")
    session.add(viewer)
    session.flush()
    perm = session.execute(
        select(Permission).where(
            Permission.scope == PermissionScope.EXPENSE_VIEW.value
        )
    ).scalar_one()
    session.add(RolePermission(role_id=viewer.id, permission_id=perm.id))
    session.flush()
    service.create_user(name="Viewer Vera", pin="5555", role_names=["viewer"])
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
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


@pytest.fixture()
def guest_headers(client):
    return _login(client, "Guest No Roles", "9999")


@pytest.fixture()
def viewer_headers(client):
    return _login(client, "Viewer Vera", "5555")


# ── Helpers ───────────────────────────────────────────────────────────────

_seq = {"n": 0}


def _next() -> int:
    _seq["n"] += 1
    return _seq["n"]


def _payload(**overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "title": f"Cleaning supplies {_next()}",
        "category": "supplies",
        "amount": "120.500",
    }
    payload.update(overrides)
    return payload


def _create(client, headers, payload: dict | None = None, **kwargs):
    body = payload if payload is not None else _payload(**kwargs)
    return client.post(
        "/api/v1/expenses",
        json=body,
        headers={**headers, "X-Device-ID": "POS-1"},
    )


def _create_ok(client, headers, payload: dict | None = None, **kwargs) -> dict:
    resp = _create(client, headers, payload, **kwargs)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _cancel(client, headers, expense_id: str, reason: str = "duplicate entry"):
    return client.post(
        f"/api/v1/expenses/{expense_id}/cancel",
        json={"reason": reason},
        headers=headers,
    )


def _rows(db) -> list[Expense]:
    db.expire_all()
    return list(db.execute(select(Expense)).scalars().all())


def _audit_rows(db, action: str, entity_id: str | None = None) -> list[AuditLog]:
    db.expire_all()
    stmt = select(AuditLog).where(
        AuditLog.action == action, AuditLog.entity_type == "expense"
    )
    if entity_id is not None:
        stmt = stmt.where(AuditLog.entity_id == uuid.UUID(entity_id))
    return list(db.execute(stmt).scalars().all())


def _full_name(db, headers) -> str:
    """Resolve the logged-in caller's display name from the audit rows."""
    user_id = _audit_rows(db, "create")[0].user_id
    db.expire_all()
    return db.get(User, user_id).full_name


# ── GATE 6/7/8/9: create ──────────────────────────────────────────────────


class TestExpenseCreate:
    def test_server_assigns_identity_fields(self, client, admin_headers, db):
        body = _payload(
            expense_id=str(uuid.uuid4()),
            expense_date="2020-01-01T00:00:00",
            status="cancelled",
            user_id=str(uuid.uuid4()),
            created_at="2020-01-01T00:00:00",
        )
        created = _create_ok(client, admin_headers, body)

        assert created["status"] == "posted"
        assert created["id"] != body["expense_id"]
        assert created["expense_date"][:4] == str(date.today().year)
        assert created["created_at"][:4] == str(date.today().year)
        assert Decimal(created["amount"]) == Decimal("120.500")
        assert created["client_request_id"] == body["client_request_id"]
        assert created["idempotent_replay"] is False
        assert created["device_id"] == "POS-1"
        assert created["note"] is None

        caller = _full_name(db, admin_headers)
        assert caller == "Admin"
        row = _rows(db)[0]
        assert row.user_id is not None
        assert row.status == "posted"
        # never backdated — the server clock owns expense_date
        assert row.expense_date.year == date.today().year

    def test_paid_from_drawer_defaults_to_true(self, client, admin_headers):
        created = _create_ok(client, admin_headers)
        assert created["paid_from_drawer"] is True

        explicit = _create_ok(
            client, admin_headers, _payload(paid_from_drawer=False)
        )
        assert explicit["paid_from_drawer"] is False

    def test_blank_note_becomes_none(self, client, admin_headers):
        created = _create_ok(client, admin_headers, _payload(note="   "))
        assert created["note"] is None

    def test_requires_authentication(self, client):
        resp = client.post("/api/v1/expenses", json=_payload())
        assert resp.status_code == 401

    @pytest.mark.parametrize(
        "override",
        [
            {"client_request_id": None},
            {"client_request_id": "   "},
            {"title": "x" * 201},
            {"category": "not_a_category"},
            {"amount": "0"},
            {"amount": "-1.000"},
            {"amount": "1000000000000.000"},
        ],
        ids=[
            "missing_key",
            "blank_key",
            "title_too_long",
            "unknown_category",
            "zero_amount",
            "negative_amount",
            "amount_over_money_max",
        ],
    )
    def test_validation_rejects_bad_input(
        self, client, admin_headers, override
    ):
        """B1-B4 + GATE 10: the schema (not the UI) enforces the rules."""
        payload = _payload()
        if override.get("client_request_id") is None:
            payload.pop("client_request_id")
        else:
            payload.update(override)
        resp = _create(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_invalid_category_message_lists_allowed_values(
        self, client, admin_headers
    ):
        resp = _create(client, admin_headers, _payload(category="groceries"))
        assert resp.status_code == 422
        message = resp.json()["error"]["details"]["category"]
        assert "rent" in message and "utilities" in message

    def test_create_writes_audit_row(self, client, admin_headers, db):
        created = _create_ok(client, admin_headers)
        audits = _audit_rows(db, "create", created["id"])
        assert len(audits) == 1
        assert audits[0].entity_type == "expense"
        assert audits[0].user_id is not None
        assert "120.500" in audits[0].details


# ── Fix Round 2: title optional (B1) ──────────────────────────────────────


class TestExpenseTitleOptional:
    """Fix Round 2 — the expense title is OPTIONAL (decision record B1).

    Omitted / ``null`` / blank / whitespace-only title is stored as
    NULL; a supplied title is trimmed and still capped at 200. No fake
    default title is ever invented.
    """

    def test_title_omitted_returns_201_and_stores_null(
        self, client, admin_headers, db
    ):
        payload = _payload()
        payload.pop("title")
        created = _create_ok(client, admin_headers, payload)

        assert created["title"] is None
        assert _rows(db)[0].title is None

    def test_title_null_returns_201_and_stores_null(
        self, client, admin_headers, db
    ):
        created = _create_ok(client, admin_headers, _payload(title=None))

        assert created["title"] is None
        assert _rows(db)[0].title is None

    @pytest.mark.parametrize("blank", ["   ", "\t\n ", ""])
    def test_blank_title_normalized_to_null(
        self, client, admin_headers, db, blank
    ):
        created = _create_ok(client, admin_headers, _payload(title=blank))

        assert created["title"] is None
        assert _rows(db)[0].title is None, "blank must be stored as NULL"

    def test_supplied_title_is_trimmed(self, client, admin_headers):
        created = _create_ok(client, admin_headers, _payload(title="  Rent  "))
        assert created["title"] == "Rent"

    def test_title_over_200_chars_rejected(self, client, admin_headers):
        resp = _create(client, admin_headers, _payload(title="x" * 201))

        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_title_at_200_chars_accepted(self, client, admin_headers):
        created = _create_ok(client, admin_headers, _payload(title="x" * 200))
        assert created["title"] == "x" * 200

    def test_existing_titled_expense_still_works(self, client, admin_headers, db):
        created = _create_ok(client, admin_headers, _payload(title="Office rent"))

        assert created["title"] == "Office rent"
        assert _rows(db)[0].title == "Office rent"

    def test_untitled_expense_appears_in_list_and_summary(
        self, client, admin_headers
    ):
        payload = _payload()
        payload.pop("title")
        created = _create_ok(client, admin_headers, payload)

        listing = client.get(
            "/api/v1/expenses", params={"category": "supplies"},
            headers=admin_headers,
        ).json()
        assert [item["id"] for item in listing["items"]] == [created["id"]]
        assert listing["items"][0]["title"] is None

        summary = client.get(
            "/api/v1/expenses/summary", headers=admin_headers
        ).json()
        assert summary["count"] == 1
        assert Decimal(summary["total_amount"]) == Decimal("120.500")

    def test_blank_title_and_null_title_share_one_idempotency_key(
        self, client, admin_headers, db
    ):
        """Fix Round 2: the signature normalizes titles both ways."""
        key = str(uuid.uuid4())
        first = _create_ok(
            client, admin_headers, _payload(client_request_id=key, title=None)
        )
        second = _create_ok(
            client, admin_headers, _payload(client_request_id=key, title="   ")
        )

        assert second["id"] == first["id"]
        assert second["idempotent_replay"] is True
        assert len(_rows(db)) == 1

    def test_untitled_replay_with_same_payload_replays(
        self, client, admin_headers, db
    ):
        payload = _payload(title="  ")
        first = _create_ok(client, admin_headers, payload)
        second = _create_ok(client, admin_headers, payload)

        assert second["id"] == first["id"]
        assert second["idempotent_replay"] is True
        assert len(_rows(db)) == 1

    def test_same_key_null_vs_titled_payload_is_409(
        self, client, admin_headers, db
    ):
        key = str(uuid.uuid4())
        _create_ok(client, admin_headers, _payload(client_request_id=key))
        conflicting = _payload(client_request_id=key, title=None)

        resp = _create(client, admin_headers, conflicting)
        assert resp.status_code == 409
        assert resp.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"
        assert len(_rows(db)) == 1

    def test_cancel_works_for_untitled_expense(self, client, admin_headers, db):
        payload = _payload()
        payload.pop("title")
        created = _create_ok(client, admin_headers, payload)

        resp = _cancel(client, admin_headers, created["id"])
        assert resp.status_code == 200, resp.text
        assert resp.json()["status"] == "cancelled"
        assert _rows(db)[0].status == "cancelled"

    def test_untitled_expense_writes_audit_row(self, client, admin_headers, db):
        payload = _payload()
        payload.pop("title")
        created = _create_ok(client, admin_headers, payload)

        audits = _audit_rows(db, "create", created["id"])
        assert len(audits) == 1
        assert "untitled" in audits[0].details

    def test_q_matches_note_of_untitled_and_title_of_titled(
        self, client, admin_headers
    ):
        """B12 keeps working with a NULL title (three-valued OR)."""
        untitled = _create_ok(
            client, admin_headers, _payload(note="office supplies")
        )
        titled = _create_ok(client, admin_headers, _payload(title="Electricity"))

        by_note = client.get(
            "/api/v1/expenses",
            params={"q": "office supplies"},
            headers=admin_headers,
        ).json()
        assert [i["id"] for i in by_note["items"]] == [untitled["id"]]

        by_title = client.get(
            "/api/v1/expenses",
            params={"q": "electric"},
            headers=admin_headers,
        ).json()
        assert [i["id"] for i in by_title["items"]] == [titled["id"]]


# ── GATE 10: idempotency ──────────────────────────────────────────────────


class TestExpenseIdempotency:
    def test_same_key_and_payload_replays_the_original_row(
        self, client, admin_headers, db
    ):
        payload = _payload()
        first = _create_ok(client, admin_headers, payload)
        second = _create_ok(client, admin_headers, payload)

        assert second["id"] == first["id"]
        assert second["idempotent_replay"] is True
        assert first["idempotent_replay"] is False
        assert len(_rows(db)) == 1

        audits = _audit_rows(db, "create", first["id"])
        assert len(audits) == 1, "a replay must not double-audit"

    def test_money_format_difference_still_replays(
        self, client, admin_headers, db
    ):
        """Decimal('100') and NUMERIC '100.000' are the same money (L1)."""
        key = str(uuid.uuid4())
        base = _payload(client_request_id=key, amount="100")
        first = _create_ok(client, admin_headers, base)
        second = _create_ok(
            client,
            admin_headers,
            {**base, "amount": "100.000"},
        )
        assert second["id"] == first["id"]
        assert second["idempotent_replay"] is True
        assert len(_rows(db)) == 1

    def test_same_key_different_payload_is_409(
        self, client, admin_headers, db
    ):
        payload = _payload()
        _create_ok(client, admin_headers, payload)
        conflicting = {**payload, "amount": "999.000"}

        resp = _create(client, admin_headers, conflicting)
        assert resp.status_code == 409
        error = resp.json()["error"]
        assert error["code"] == "IDEMPOTENCY_CONFLICT"
        assert len(_rows(db)) == 1

    def test_different_keys_create_different_rows(
        self, client, admin_headers, db
    ):
        first = _create_ok(client, admin_headers)
        second = _create_ok(client, admin_headers)
        assert first["id"] != second["id"]
        assert len(_rows(db)) == 2


# ── GATE 12: list ─────────────────────────────────────────────────────────


class TestExpenseList:
    def test_returns_posted_only_by_default(self, client, admin_headers, db):
        keep = _create_ok(client, admin_headers)
        dropped = _create_ok(client, admin_headers, _payload(title="To cancel"))
        assert _cancel(client, admin_headers, dropped["id"]).status_code == 200

        listed = client.get("/api/v1/expenses", headers=admin_headers)
        assert listed.status_code == 200, listed.text
        body = listed.json()
        assert body["total"] == 1
        assert body["page"] == 1
        assert [i["id"] for i in body["items"]] == [keep["id"]]

        cancelled = client.get(
            "/api/v1/expenses",
            params={"status": "cancelled"},
            headers=admin_headers,
        )
        assert cancelled.json()["total"] == 1
        assert cancelled.json()["items"][0]["status"] == "cancelled"

        everything = client.get(
            "/api/v1/expenses",
            params={"status": "all"},
            headers=admin_headers,
        )
        assert everything.json()["total"] == 2

    def test_newest_first_and_monotonic_dates(self, client, admin_headers):
        ids = [
            _create_ok(client, admin_headers, _payload(amount="10.000"))["id"]
            for _ in range(3)
        ]
        body = client.get("/api/v1/expenses", headers=admin_headers).json()
        assert sorted(i["id"] for i in body["items"]) == sorted(ids)

        dates = [
            datetime.fromisoformat(i["expense_date"]) for i in body["items"]
        ]
        assert dates == sorted(dates, reverse=True)

    def test_q_category_and_drawer_filters(self, client, admin_headers):
        _create_ok(client, admin_headers, _payload(title="Electricity bill", category="utilities"))
        _create_ok(client, admin_headers, _payload(title="Office rent", category="rent"))
        _create_ok(
            client,
            admin_headers,
            _payload(title="Driver fuel", category="transport", paid_from_drawer=False),
        )

        def list_(**params):
            return client.get(
                "/api/v1/expenses", params=params, headers=admin_headers
            ).json()

        assert list_(q="electric")["total"] == 1
        assert list_(q="ELECTRIC")["total"] == 1, "search must be case-insensitive"
        assert list_(category="rent")["total"] == 1
        assert list_(paid_from_drawer=False)["total"] == 1
        assert list_(paid_from_drawer=True)["total"] == 2
        assert list_(q="nope")["total"] == 0

    def test_date_range_is_inclusive_of_the_whole_day(
        self, client, admin_headers
    ):
        created = _create_ok(client, admin_headers)
        day = date.fromisoformat(created["expense_date"][:10])

        def list_(**params):
            return client.get(
                "/api/v1/expenses", params=params, headers=admin_headers
            ).json()

        assert list_(date_from=day.isoformat(), date_to=day.isoformat())["total"] == 1
        assert list_(date_from=(day + timedelta(days=1)).isoformat())["total"] == 0
        assert list_(date_to=(day - timedelta(days=1)).isoformat())["total"] == 0

    def test_reversed_date_range_is_422(self, client, admin_headers):
        resp = client.get(
            "/api/v1/expenses",
            params={"date_from": "2026-02-01", "date_to": "2026-01-01"},
            headers=admin_headers,
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_unknown_status_is_422(self, client, admin_headers):
        resp = client.get(
            "/api/v1/expenses",
            params={"status": "deleted"},
            headers=admin_headers,
        )
        assert resp.status_code == 422

    def test_pagination_counts_and_pages(self, client, admin_headers):
        for n in range(5):
            _create_ok(client, admin_headers, _payload(amount=f"{10 + n}.000"))

        page1 = client.get(
            "/api/v1/expenses",
            params={"page": 1, "page_size": 2},
            headers=admin_headers,
        ).json()
        page3 = client.get(
            "/api/v1/expenses",
            params={"page": 3, "page_size": 2},
            headers=admin_headers,
        ).json()

        assert page1["total"] == 5
        assert page1["pages"] == 3
        assert len(page1["items"]) == 2
        assert len(page3["items"]) == 1

    def test_empty_store_returns_an_empty_page(self, client, admin_headers):
        body = client.get("/api/v1/expenses", headers=admin_headers).json()
        assert body == {"items": [], "total": 0, "page": 1, "page_size": 40, "pages": 1}


# ── W2: summary ───────────────────────────────────────────────────────────


class TestExpenseSummary:
    @pytest.fixture()
    def seed(self, client, admin_headers):
        a = _create_ok(client, admin_headers, _payload(amount="100.000"))
        b = _create_ok(client, admin_headers, _payload(amount="50.000"))
        c = _create_ok(
            client,
            admin_headers,
            _payload(amount="30.000", paid_from_drawer=False),
        )
        return a, b, c

    def test_counts_and_drawer_split(self, client, admin_headers, seed):
        body = client.get("/api/v1/expenses/summary", headers=admin_headers).json()
        assert body["count"] == 3
        assert Decimal(body["total_amount"]) == Decimal("180.000")
        assert Decimal(body["drawer_amount"]) == Decimal("150.000")
        assert Decimal(body["external_amount"]) == Decimal("30.000")
        assert (
            Decimal(body["drawer_amount"]) + Decimal(body["external_amount"])
            == Decimal(body["total_amount"])
        )

    def test_cancelled_rows_leave_the_default_summary(
        self, client, admin_headers, seed
    ):
        a, b, _ = seed
        assert _cancel(client, admin_headers, b["id"]).status_code == 200

        default = client.get(
            "/api/v1/expenses/summary", headers=admin_headers
        ).json()
        assert default["count"] == 2
        assert Decimal(default["total_amount"]) == Decimal("130.000")
        assert Decimal(default["drawer_amount"]) == Decimal("100.000")

        all_rows = client.get(
            "/api/v1/expenses/summary",
            params={"status": "all"},
            headers=admin_headers,
        ).json()
        assert all_rows["count"] == 3
        assert Decimal(all_rows["total_amount"]) == Decimal("180.000")

        cancelled_only = client.get(
            "/api/v1/expenses/summary",
            params={"status": "cancelled"},
            headers=admin_headers,
        ).json()
        assert cancelled_only["count"] == 1
        assert Decimal(cancelled_only["total_amount"]) == Decimal("50.000")

    def test_summary_respects_the_same_filters(
        self, client, admin_headers, seed
    ):
        body = client.get(
            "/api/v1/expenses/summary",
            params={"paid_from_drawer": False},
            headers=admin_headers,
        ).json()
        assert body["count"] == 1
        assert Decimal(body["total_amount"]) == Decimal("30.000")

        by_category = client.get(
            "/api/v1/expenses/summary",
            params={"category": "supplies"},
            headers=admin_headers,
        ).json()
        assert by_category["count"] == 3

    def test_summary_never_returns_floats(self, client, admin_headers, seed):
        body = client.get("/api/v1/expenses/summary", headers=admin_headers).json()
        for field in ("total_amount", "drawer_amount", "external_amount"):
            assert isinstance(body[field], str), field
            Decimal(body[field])


# ── GATE 1/11: cancel ─────────────────────────────────────────────────────


class TestExpenseCancel:
    def test_cancel_records_attribution_and_keeps_the_row(
        self, client, admin_headers, manager_headers, db
    ):
        created = _create_ok(client, admin_headers, _payload(amount="75.000"))
        snapshot = dict(created)

        resp = _cancel(client, manager_headers, created["id"], "duplicate")
        assert resp.status_code == 200, resp.text
        body = resp.json()

        assert body["status"] == "cancelled"
        assert body["cancelled_at"] is not None
        assert body["cancelled_by"] is not None
        assert body["cancel_reason"] == "duplicate"

        # the money and the original record are frozen (L3: no delete)
        assert Decimal(body["amount"]) == Decimal(snapshot["amount"])
        assert body["title"] == snapshot["title"]
        assert body["expense_date"] == snapshot["expense_date"]
        rows = _rows(db)
        assert len(rows) == 1
        assert rows[0].status == "cancelled"

        audits = _audit_rows(db, "void", created["id"])
        assert len(audits) == 1
        assert "duplicate" in audits[0].details

    def test_cancel_is_terminal(self, client, admin_headers):
        created = _create_ok(client, admin_headers)
        first = _cancel(client, admin_headers, created["id"])
        assert first.status_code == 200, first.text

        second = _cancel(client, admin_headers, created["id"], "again")
        assert second.status_code == 409
        assert second.json()["error"]["code"] == "EXPENSE_ALREADY_CANCELLED"
        assert second.json()["error"]["details"]["expense_id"] == created["id"]

    def test_reason_is_mandatory(self, client, admin_headers, db):
        created = _create_ok(client, admin_headers)

        blank = _cancel(client, admin_headers, created["id"], "   ")
        assert blank.status_code == 422
        assert blank.json()["error"]["code"] == "VALIDATION_ERROR"

        missing = client.post(
            f"/api/v1/expenses/{created['id']}/cancel",
            json={},
            headers=admin_headers,
        )
        assert missing.status_code == 422

        # the rejected attempts left the expense posted and unaudited
        row = _rows(db)[0]
        assert row.status == "posted"
        assert _audit_rows(db, "void") == []

    def test_unknown_expense_is_404(self, client, admin_headers):
        resp = _cancel(client, admin_headers, str(uuid.uuid4()))
        assert resp.status_code == 404
        assert resp.json()["error"]["code"] == "EXPENSE_NOT_FOUND"

    def test_cancel_drops_it_from_the_list_but_not_from_history(
        self, client, admin_headers
    ):
        created = _create_ok(client, admin_headers)
        assert _cancel(client, admin_headers, created["id"]).status_code == 200

        listed = client.get("/api/v1/expenses", headers=admin_headers).json()
        assert listed["total"] == 0
        by_id = client.get(
            "/api/v1/expenses",
            params={"status": "all"},
            headers=admin_headers,
        ).json()
        assert [i["id"] for i in by_id["items"]] == [created["id"]]

    def test_cancel_never_touches_the_amount(
        self, client, admin_headers, db
    ):
        created = _create_ok(client, admin_headers, _payload(amount="250.750"))
        _cancel(client, admin_headers, created["id"], "mistake")

        row = _rows(db)[0]
        assert row.amount == Decimal("250.750")
        assert row.cancel_reason == "mistake"


# ── GATE 7/8/9: permissions ───────────────────────────────────────────────


class TestExpensePermissions:
    @pytest.mark.parametrize(
        "headers_fixture,expected_user",
        [
            ("admin_headers", "Admin"),
            ("manager_headers", "Manager Mo"),
            ("cashier_headers", "Cashier Ali"),
        ],
    )
    def test_every_seeded_role_holds_the_three_scopes(
        self, client, db, request, headers_fixture, expected_user
    ):
        headers = request.getfixturevalue(headers_fixture)

        created = _create_ok(client, headers)
        assert _cancel(client, headers, created["id"]).status_code == 200

        listed = client.get("/api/v1/expenses", headers=headers)
        assert listed.status_code == 200
        summary = client.get("/api/v1/expenses/summary", headers=headers)
        assert summary.status_code == 200

        assert _full_name(db, headers) == expected_user

    @pytest.mark.parametrize(
        "endpoint,expected_scope",
        [
            ("list", "expense_view"),
            ("summary", "expense_view"),
            ("create", "expense_create"),
            ("cancel", "expense_cancel"),
        ],
    )
    def test_role_without_scopes_is_forbidden(
        self, client, admin_headers, guest_headers, db, endpoint, expected_scope
    ):
        target = _create_ok(client, admin_headers)

        if endpoint == "list":
            resp = client.get("/api/v1/expenses", headers=guest_headers)
        elif endpoint == "summary":
            resp = client.get("/api/v1/expenses/summary", headers=guest_headers)
        elif endpoint == "create":
            resp = _create(client, guest_headers, _payload())
        else:
            resp = _cancel(client, guest_headers, target["id"])

        assert resp.status_code == 403, resp.text
        assert (
            resp.json()["error"]["details"]["required_permission"]
            == expected_scope
        )
        # the expense the guest tried to cancel stays posted and untouched
        assert _rows(db)[0].status == "posted"
        assert _audit_rows(db, "void") == []

    def test_view_only_role_can_read_but_not_write(
        self, client, viewer_headers, admin_headers, db
    ):
        _create_ok(client, admin_headers)

        assert client.get(
            "/api/v1/expenses", headers=viewer_headers
        ).status_code == 200
        assert client.get(
            "/api/v1/expenses/summary", headers=viewer_headers
        ).status_code == 200

        created = _create(client, viewer_headers, _payload())
        assert created.status_code == 403
        assert (
            created.json()["error"]["details"]["required_permission"]
            == "expense_create"
        )

        target = _create_ok(client, admin_headers)
        blocked = _cancel(client, viewer_headers, target["id"])
        assert blocked.status_code == 403
        assert (
            blocked.json()["error"]["details"]["required_permission"]
            == "expense_cancel"
        )

        # nothing was written by the blocked attempts
        assert len(_rows(db)) == 2

    def test_authentication_is_required_for_every_endpoint(self, client):
        expense_id = str(uuid.uuid4())
        assert client.get("/api/v1/expenses").status_code == 401
        assert client.get("/api/v1/expenses/summary").status_code == 401
        assert client.post("/api/v1/expenses", json=_payload()).status_code == 401
        assert (
            client.post(
                f"/api/v1/expenses/{expense_id}/cancel",
                json={"reason": "x"},
            ).status_code
            == 401
        )
