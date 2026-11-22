"""First-run administrator setup: one page, one account, already signed in.

Contract under test:

* setup is needed exactly while no admin-role user exists (the database is
  the authority — never a local flag);
* a successful ``POST /auth/setup`` returns a working session for the new
  admin, so the first run lands on the dashboard without a second PIN
  prompt;
* PIN mismatch / invalid PIN / missing fields are rejected with clear 4xx;
* a second initial administrator can never be created (409), and the
  endpoint is not a public "create admin" back door afterwards;
* existing installations (an admin already present) skip setup entirely,
  and existing users/permissions are untouched.
"""

from __future__ import annotations

import threading
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.user import Role, User, UserRole
from app.services.auth import AuthService

SETUP = "/api/v1/auth/setup"
CHECK = "/api/v1/auth/setup/check"


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
def fresh_db(TestingSession):
    """Roles/permissions seeded, but NO user at all — a fresh install."""
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    yield session
    session.close()


@pytest.fixture()
def fresh_client(TestingSession, fresh_db):
    def override_get_db():
        session = TestingSession()
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


def _setup_payload(**over) -> dict:
    data = {"name": "Patron", "pin": "1234", "pin_confirm": "1234"}
    data.update(over)
    return data


def _admin_count(session) -> int:
    return int(
        session.scalar(
            select(func.count())
            .select_from(User)
            .join(UserRole)
            .join(Role)
            .where(Role.name == "admin")
        )
        or 0
    )


# ── fresh install ───────────────────────────────────────────────────────


def test_fresh_install_requires_setup(fresh_client):
    assert fresh_client.get(CHECK).json() == {"setup_needed": True}


def test_successful_setup_returns_a_working_admin_session(
    fresh_client, TestingSession, fresh_db
):
    resp = fresh_client.post(SETUP, json=_setup_payload())
    assert resp.status_code == 200, resp.text
    body = resp.json()

    assert body["name"] == "Patron"
    assert body["user_id"]
    assert body["access_token"], "setup must sign the new admin in"
    assert body["user"]["full_name"] == "Patron"
    assert any(r["name"] == "admin" for r in body["user"]["roles"])

    # The token is a real session: /auth/me answers with the admin's scopes.
    me = fresh_client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {body['access_token']}"},
    )
    assert me.status_code == 200, me.text
    assert "settings_manage" in me.json()["permissions"]

    # ... and /auth/verify accepts it too (the documented 200 contract).
    verify = fresh_client.post(
        "/api/v1/auth/verify",
        headers={"Authorization": f"Bearer {body['access_token']}"},
    )
    assert verify.status_code == 200, verify.text

    # Setup closes as soon as the account exists.
    assert fresh_client.get(CHECK).json() == {"setup_needed": False}
    with TestingSession() as session:
        assert _admin_count(session) == 1


def test_the_new_admin_can_log_in_with_the_same_pin_on_the_next_launch(
    fresh_client,
):
    created = fresh_client.post(SETUP, json=_setup_payload()).json()

    users = fresh_client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in users if i["full_name"] == "Patron")
    login = fresh_client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"}
    )
    assert login.status_code == 200, login.text
    assert login.json()["user"]["id"] == created["user_id"]


def test_pin_is_never_stored_in_plain_text(fresh_client, TestingSession):
    fresh_client.post(SETUP, json=_setup_payload(pin="4321", pin_confirm="4321"))
    with TestingSession() as session:
        user = session.scalars(select(User)).one()
        assert user.pin_hash != "4321"
        assert user.pin_hash.startswith("$argon2id$")


# ── validation ──────────────────────────────────────────────────────────


def test_pin_mismatch_is_rejected(fresh_client):
    resp = fresh_client.post(
        SETUP, json=_setup_payload(pin="1234", pin_confirm="5678")
    )
    assert resp.status_code == 422, resp.text
    assert "match" in resp.text.lower()


@pytest.mark.parametrize("pin", ["12", "1234567", "abcd", ""])
def test_invalid_pin_is_rejected(fresh_client, pin):
    resp = fresh_client.post(
        SETUP, json=_setup_payload(pin=pin, pin_confirm=pin)
    )
    assert resp.status_code == 422, resp.text


@pytest.mark.parametrize("missing", ["name", "pin", "pin_confirm"])
def test_missing_required_fields_are_rejected(fresh_client, missing):
    payload = _setup_payload()
    payload.pop(missing)
    resp = fresh_client.post(SETUP, json=payload)
    assert resp.status_code == 422, resp.text


def test_blank_username_is_rejected(fresh_client):
    resp = fresh_client.post(SETUP, json=_setup_payload(name="   "))
    assert resp.status_code == 422, resp.text


# ── only one initial administrator ──────────────────────────────────────


def test_second_initial_administrator_is_refused(fresh_client):
    assert fresh_client.post(SETUP, json=_setup_payload()).status_code == 200

    again = fresh_client.post(
        SETUP, json=_setup_payload(name="Autre", pin="5678", pin_confirm="5678")
    )
    assert again.status_code == 409, again.text
    # No credential is handed out by the refused call.
    assert "access_token" not in again.json()


def test_setup_endpoint_cannot_add_a_second_admin_after_the_fact(
    fresh_client, TestingSession
):
    fresh_client.post(SETUP, json=_setup_payload())
    for _ in range(2):
        resp = fresh_client.post(
            SETUP, json=_setup_payload(name="Intruder", pin="9999", pin_confirm="9999")
        )
        assert resp.status_code in (409, 429), resp.text

    with TestingSession() as session:
        assert _admin_count(session) == 1
        names = {u.full_name for u in session.scalars(select(User)).all()}
        assert names == {"Patron"}


# ── existing installations ──────────────────────────────────────────────


def test_existing_installation_with_an_admin_skips_setup(fresh_client):
    fresh_client.post(SETUP, json=_setup_payload())
    assert fresh_client.get(CHECK).json() == {"setup_needed": False}

    # The endpoint is closed, so an upgraded install never sees the wizard
    # and can never be told to recreate its administrator.
    assert (
        fresh_client.post(
            SETUP, json=_setup_payload(name="Again", pin="1111", pin_confirm="1111")
        ).status_code
        == 409
    )


def test_existing_users_and_permissions_are_preserved(TestingSession, fresh_db):
    service = AuthService(fresh_db)
    cashier = service.create_user(name="Caissier", pin="1111", role_names=["cashier"])
    cashier_id = cashier.id

    service.setup_first_admin(name="Patron", pin="1234", pin_confirm="1234")
    fresh_db.expire_all()

    with TestingSession() as session:
        still_there = session.get(User, cashier_id)
        assert still_there is not None
        assert still_there.is_active is True
        assert [r.name for r in still_there.roles] == ["cashier"]
        assert _admin_count(session) == 1


def test_a_cashier_only_database_still_needs_setup(TestingSession, fresh_db):
    AuthService(fresh_db).create_user(
        name="Caissier", pin="1111", role_names=["cashier"]
    )
    fresh_db.expire_all()
    assert AuthService(fresh_db).is_setup_needed() is True


# ── concurrency (requires PostgreSQL row locking) ───────────────────────


def test_concurrent_setup_requests_create_exactly_one_admin():
    """Two simultaneous setups: one 200, one 409 — never two admins.

    SQLite ignores ``SELECT … FOR UPDATE``, so this proof needs the real
    PostgreSQL engine the product runs on.

    The fixture lives in its OWN throwaway PostgreSQL schema: the shared
    test database is used by the migration suite (which owns its DDL) and
    must never be recreated from ``Base.metadata`` here.
    """
    from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

    if not PG_IS_AVAILABLE:
        pytest.skip("PostgreSQL test database is not available")

    schema = f"setup_race_{uuid.uuid4().hex[:10]}"
    admin_engine = create_engine(PG_TEST_URL)
    with admin_engine.connect() as conn:
        conn.execute(text(f'CREATE SCHEMA "{schema}"'))
        conn.commit()

    # `public` stays on the search path only so the pg_trgm extension's
    # operator class is visible to the CREATE INDEX statements; every table
    # itself is created in the throwaway schema (first on the path).
    engine = create_engine(
        PG_TEST_URL, connect_args={"options": f"-csearch_path={schema},public"}
    )
    factory = sessionmaker(bind=engine)
    results: list[int] = []
    try:
        Base.metadata.create_all(engine)
        with factory() as session:
            from app.core.seed import seed_roles_and_permissions

            seed_roles_and_permissions(session)
            session.commit()

        def override_get_db():
            session = factory()
            try:
                yield session
            finally:
                session.close()

        app.dependency_overrides[get_db] = override_get_db
        lock = threading.Lock()

        def attempt(name: str) -> None:
            with TestClient(app, raise_server_exceptions=False) as c:
                resp = c.post(
                    SETUP,
                    json={"name": name, "pin": "1234", "pin_confirm": "1234"},
                )
                with lock:
                    results.append(resp.status_code)

        threads = [
            threading.Thread(target=attempt, args=(f"Admin {i}",)) for i in range(2)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=30)

        assert sorted(results) == [200, 409], results
        with factory() as session:
            assert _admin_count(session) == 1
    finally:
        app.dependency_overrides.clear()
        engine.dispose()
        with admin_engine.connect() as conn:
            conn.execute(text(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'))
            conn.commit()
        admin_engine.dispose()
