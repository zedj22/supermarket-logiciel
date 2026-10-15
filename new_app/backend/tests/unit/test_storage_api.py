"""Storage & data usage endpoint — authorization, shape and safety.

Covers:
- 401 unauthenticated, 403 for manager/cashier, 200 for admin
  (``settings_manage`` is admin-only under the seed role matrix)
- GET only: no mutating verb exists on this resource
- response shape: scope, categories in stable order, disk, totals
- aggregation: ``total_bytes`` equals the sum of the available
  categories exactly once (the server tree is a partition)
- no filesystem path, filename or connection detail leaks into JSON
- missing storage locations surface as unavailable categories with a
  reason instead of failing the request
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import app.services.storage as storage_module
from app.core.config import BACKEND_ROOT
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.schemas.storage import SERVER_CATEGORY_KEYS
from app.services.auth import AuthService

_STORAGE_PATH = "/api/v1/storage"


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
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
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


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": pin}
    )
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
def storage_tree(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    """Isolate the measurement on a small fake backend tree."""
    root = tmp_path / "backend"
    root.mkdir()
    (root / "app.py").write_bytes(b"a" * 10)
    (root / "backups").mkdir()
    (root / "backups" / "b1.sql").write_bytes(b"b" * 20)
    (root / "data").mkdir()
    (root / "data" / "server_id").write_bytes(b"c" * 5)
    (root / "__pycache__").mkdir()
    (root / "__pycache__" / "app.pyc").write_bytes(b"d" * 7)
    monkeypatch.setattr(storage_module, "BACKEND_ROOT", root)
    monkeypatch.setattr(
        storage_module,
        "settings",
        SimpleNamespace(
            BACKUP_DIR="",
            SERVER_ID_FILE=str(root / "data" / "server_id"),
        ),
    )
    return root


# ---------------------------------------------------------------------------
# Authorization
# ---------------------------------------------------------------------------


def test_storage_requires_authentication(client):
    resp = client.get(_STORAGE_PATH)
    assert resp.status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_storage_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    resp = client.get(_STORAGE_PATH, headers=headers)
    assert resp.status_code == 403
    body = resp.json()
    assert body["error"]["code"] == "FORBIDDEN"
    assert (
        body["error"]["details"]["required_permission"] == "settings_manage"
    )


def test_storage_rejects_mutating_verbs(client, admin_headers):
    resp = client.post(_STORAGE_PATH, headers=admin_headers)
    assert resp.status_code == 405
    resp = client.delete(_STORAGE_PATH, headers=admin_headers)
    assert resp.status_code == 405


# ---------------------------------------------------------------------------
# Response shape / aggregation / leakage
# ---------------------------------------------------------------------------


def test_admin_get_returns_expected_shape(client, admin_headers, storage_tree):
    resp = client.get(_STORAGE_PATH, headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()

    assert body["scope"] == "server"
    assert body["measured_at"]
    assert [c["key"] for c in body["categories"]] == list(
        SERVER_CATEGORY_KEYS
    )
    for category in body["categories"]:
        assert set(category) == {"key", "available", "bytes", "reason"}
    assert set(body["disk"]) == {
        "available",
        "total_bytes",
        "free_bytes",
        "reason",
    }
    assert isinstance(body["complete"], bool)
    assert isinstance(body["total_bytes"], int)


def test_total_counts_every_available_byte_exactly_once(
    client, admin_headers, storage_tree
):
    resp = client.get(_STORAGE_PATH, headers=admin_headers)
    body = resp.json()

    available = [c for c in body["categories"] if c["available"]]
    assert body["total_bytes"] == sum(c["bytes"] for c in available)
    # The tree partition adds up: 10 app + 20 backups + 5 data + 7 cache.
    tree_total = sum(
        c["bytes"]
        for c in available
        if c["key"] in {"application", "backups", "data", "cache_temp"}
    )
    assert tree_total == 42
    # The database is :memory: in unit tests — reported, not estimated.
    database = next(
        c for c in body["categories"] if c["key"] == "database"
    )
    assert database["available"] is False
    assert database["reason"] == "in_memory"
    assert body["complete"] is False


def test_response_never_exposes_paths_or_connection_details(
    client, admin_headers, storage_tree
):
    resp = client.get(_STORAGE_PATH, headers=admin_headers)
    text = resp.text

    assert str(storage_tree) not in text
    assert str(BACKEND_ROOT) not in text
    assert "server_id" not in text  # filenames are filesystem details
    assert "\\" not in text  # no Windows path escaped into JSON
    assert "postgresql" not in text
    assert "://" not in text  # no URLs / connection strings
    json.loads(text)


def test_logs_category_is_reported_as_not_stored(
    client, admin_headers, storage_tree
):
    resp = client.get(_STORAGE_PATH, headers=admin_headers)
    logs = next(
        c for c in resp.json()["categories"] if c["key"] == "logs"
    )
    assert logs["available"] is False
    assert logs["reason"] == "not_stored"
    assert logs["bytes"] is None


def test_missing_backup_dir_surfaces_as_unavailable(
    client, admin_headers, storage_tree
):
    # Remove the in-tree folder too, so nothing overlaps the missing path.
    shutil.rmtree(storage_tree / "backups")
    storage_module.settings.BACKUP_DIR = str(
        storage_tree.parent / "never_created"
    )
    resp = client.get(_STORAGE_PATH, headers=admin_headers)
    assert resp.status_code == 200  # graceful: a missing folder is not an error
    backups = next(
        c for c in resp.json()["categories"] if c["key"] == "backups"
    )
    assert backups["available"] is False
    assert backups["reason"] == "missing"
    application = next(
        c for c in resp.json()["categories"] if c["key"] == "application"
    )
    assert application["available"] is True
    assert application["bytes"] == 10


def test_disk_capacity_is_reported_with_the_tree(
    client, admin_headers, storage_tree
):
    resp = client.get(_STORAGE_PATH, headers=admin_headers)
    disk = resp.json()["disk"]
    assert disk["available"] is True
    assert disk["total_bytes"] > 0
    assert 0 <= disk["free_bytes"] <= disk["total_bytes"]
