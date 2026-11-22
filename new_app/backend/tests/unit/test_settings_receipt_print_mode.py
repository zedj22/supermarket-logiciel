"""Settings receipt-printing mode — API persistence regression tests.

Covers the reported bug end to end at the HTTP boundary:

* the two new columns are part of the ``GET``/``PUT /api/v1/settings``
  contract and survive a save + a later read;
* all four modes round-trip, and the threshold travels with them;
* a partial update (mode only) keeps the stored threshold;
* an installation that never saved a mode reads as ``disabled`` / ``0``;
* a request carrying a key the schema does not know is rejected (422)
  instead of being silently dropped — the failure mode that made a new
  setting look "saved" while the row never changed.

The file is self-contained (its own SQLite app + dependency overrides) so it
does not depend on the shared ``client`` fixture or on PostgreSQL.
"""

from __future__ import annotations

import pytest
from fastapi import FastAPI
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from starlette.testclient import TestClient

import app.models.settings  # noqa: F401  (registers app_settings)
import app.services.settings  # noqa: F401  (registers audit_logs)
from app.api.v1.settings import router as settings_router
from app.db.base import Base
from app.db.session import get_db

SETTINGS_URL = "/api/v1/settings"


class _Admin:
    """Minimal stand-in for the authenticated admin dependency."""

    id = None
    full_name = "admin"


@pytest.fixture()
def api(tmp_path):
    """A FastAPI app exposing only the settings router over a fresh SQLite DB."""
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'settings.db'}")
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine)

    def override_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app = FastAPI()
    app.include_router(settings_router, prefix=SETTINGS_URL)
    app.dependency_overrides[get_db] = override_db
    # Stub auth/permission dependencies; keep the DB and service providers.
    for route in app.routes:
        for dep in getattr(getattr(route, "dependant", None), "dependencies", []) or []:
            name = getattr(dep.call, "__name__", "")
            if dep.call is get_db or name == "_get_settings_service":
                continue
            app.dependency_overrides[dep.call] = lambda: _Admin()

    with TestClient(app) as client:
        yield client
    engine.dispose()


def test_defaults_are_disabled_and_zero(api):
    body = api.get(SETTINGS_URL).json()
    assert body["receipt_print_mode"] == "disabled"
    assert body["receipt_min_amount"] == 0


@pytest.mark.parametrize(
    ("mode", "amount"),
    [
        ("disabled", 0),
        ("ask", 0),
        ("ask", 250),
        ("auto_print", 0),
        ("auto_print", 250),
        ("ask_above_threshold", 500),
        ("ask_above_threshold", 0),
    ],
)
def test_every_mode_and_threshold_persists(api, mode, amount):
    put = api.put(
        SETTINGS_URL,
        json={"receipt_print_mode": mode, "receipt_min_amount": amount},
    )
    assert put.status_code == 200, put.text
    assert put.json()["receipt_print_mode"] == mode
    assert put.json()["receipt_min_amount"] == amount

    # A later read — a different request/session, i.e. what the screen does
    # when it is reopened, and what a restarted client sees.
    body = api.get(SETTINGS_URL).json()
    assert body["receipt_print_mode"] == mode
    assert body["receipt_min_amount"] == amount


def test_partial_update_of_the_mode_keeps_the_threshold(api):
    api.put(
        SETTINGS_URL,
        json={"receipt_print_mode": "ask_above_threshold", "receipt_min_amount": 750.5},
    )

    put = api.put(SETTINGS_URL, json={"receipt_print_mode": "auto_print"})
    assert put.status_code == 200, put.text
    assert put.json()["receipt_print_mode"] == "auto_print"
    assert put.json()["receipt_min_amount"] == 750.5

    body = api.get(SETTINGS_URL).json()
    assert body["receipt_print_mode"] == "auto_print"
    assert body["receipt_min_amount"] == 750.5


def test_saving_does_not_disturb_the_legacy_print_settings(api):
    api.put(
        SETTINGS_URL,
        json={
            "ask_before_print": True,
            "auto_print_invoice": False,
            "default_paper": "A4",
            "receipt_print_mode": "ask_above_threshold",
            "receipt_min_amount": 500,
        },
    )

    body = api.get(SETTINGS_URL).json()
    assert body["ask_before_print"] is True
    assert body["auto_print_invoice"] is False
    assert body["default_paper"] == "A4"
    assert body["receipt_print_mode"] == "ask_above_threshold"
    assert body["receipt_min_amount"] == 500


def test_unknown_setting_key_is_rejected_instead_of_silently_dropped(api):
    """A client newer than the server must fail loudly, never "succeed"."""
    resp = api.put(SETTINGS_URL, json={"receipt_print_mode_v2": "x"})
    assert resp.status_code == 422, resp.text


def test_unknown_mode_and_negative_threshold_are_rejected(api):
    assert (
        api.put(SETTINGS_URL, json={"receipt_print_mode": "print_always"}).status_code
        == 422
    )
    assert (
        api.put(SETTINGS_URL, json={"receipt_min_amount": -1}).status_code == 422
    )
