"""POS customer search — minimal endpoint tests (Phase 8 Step 3)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.party import Customer
from app.services.auth import AuthService


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
def TestingSession(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, TestingSession):
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    session.commit()
    yield session
    session.close()


@pytest.fixture()
def client(engine, TestingSession, db):
    def override_get_db():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _login(client: TestClient) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


class TestCustomerSearch:
    def test_search_by_name(self, client, db):
        headers = _login(client)
        db.add(Customer(name="Alice Market", phone="0555000001"))
        db.add(Customer(name="Bob Store", phone="0555000002"))
        db.commit()

        resp = client.get(
            "/api/v1/customers/search",
            params={"q": "Alice"},
            headers=headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["total"] == 1
        assert body["items"][0]["name"] == "Alice Market"
        assert body["items"][0]["phone"] == "0555000001"

    def test_search_by_phone(self, client, db):
        headers = _login(client)
        db.add(Customer(name="Phone Guy", phone="0555123456"))
        db.commit()

        resp = client.get(
            "/api/v1/customers/search",
            params={"q": "0555123"},
            headers=headers,
        )
        assert resp.status_code == 200
        assert resp.json()["total"] == 1
        assert resp.json()["items"][0]["name"] == "Phone Guy"

    def test_empty_q_returns_active_page(self, client, db):
        headers = _login(client)
        db.add(Customer(name="Active One"))
        archived = Customer(name="Gone")
        archived.archived_at = __import__("datetime").datetime.utcnow()
        db.add(archived)
        db.commit()

        resp = client.get("/api/v1/customers/search", headers=headers)
        assert resp.status_code == 200
        body = resp.json()
        assert body["total"] == 1
        assert body["items"][0]["name"] == "Active One"

    def test_requires_auth(self, client):
        resp = client.get("/api/v1/customers/search", params={"q": "x"})
        assert resp.status_code == 401

    def test_list_endpoint(self, client, db):
        headers = _login(client)
        db.add(Customer(name="Listed"))
        db.commit()
        resp = client.get("/api/v1/customers", headers=headers)
        assert resp.status_code == 200
        assert resp.json()["total"] >= 1
