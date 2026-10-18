"""Objective 3 — connected-hardware discovery (server PC).

Covers:
- every route is authenticated and admin-only (``device_manage``): 401 /
  403 for manager and cashier, 200 for admin
- discovery on a non-Windows host returns empty lists **and** an explicit
  warning (never guessed devices)
- a fake runner's raw CIM/PnP JSON is mapped into the typed schema
  (printer status codes, single-row vs list ``ConvertTo-Json`` output)
- per-category failures (unsupported / unavailable / timeout) become
  warnings with empty lists — one broken query never fails the overview
- the TTL cache: second overview is ``cached: true``; ``force`` (the
  refresh endpoint) re-walks the device tree
- test actions: presence → ``ok: true``; absent → 404; rejection →
  ``ok: false`` with the reason; names are CIM-escaped (a ``'`` never
  closes the filter)
- the serial-port test never opens the port (by construction: the script
  only reads ``Win32_SerialPort``)

No test shells out: ``HardwareService`` takes an injected runner.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.services.auth import AuthService
from app.services.hardware import (
    OVERVIEW_TTL_SECONDS,
    HardwareService,
    HardwareUnsupportedError,
    _cim_quote,
    _parse_json_list,
    reset_hardware_cache,
)

# ── canned PowerShell payloads (exactly what ConvertTo-Json emits) ──────

PRINTERS_JSON = (
    '[{"Name":"HP LaserJet","DriverName":"HP Universal","PortName":"USB001",'
    '"PrinterStatus":3,"Default":true,"WorkOffline":false},'
    '{"Name":"EPSON TM-T20","DriverName":"Epson","PortName":"COM3",'
    '"PrinterStatus":7,"Default":false,"WorkOffline":true}]'
)
SCANNERS_JSON = (
    '{"FriendlyName":"Canon LiDE 400","Status":"OK","Class":"Image",'
    '"InstanceId":"USB\\\\VID_04A9&PID_1900","Manufacturer":"Canon"}'
)
USB_JSON = (
    '[{"FriendlyName":"Honeywell Barcode Scanner","Status":"OK",'
    '"Class":"HIDClass","InstanceId":"HID\\\\VID_0C2E","Manufacturer":"Honeywell"}]'
)
SERIAL_JSON = (
    '[{"DeviceID":"COM3","Name":"Communications Port (COM3)",'
    '"Description":"Standard serial","Status":"OK",'
    '"PNPDeviceID":"PNP0501"}]'
)


def make_runner(mapping: dict[str, str] | None = None, default: str = "null"):
    """A fake ``powershell``: keyed by a marker found in the script."""
    calls: list[str] = []

    def runner(script: str) -> str:
        calls.append(script)
        if mapping:
            for marker, output in mapping.items():
                if marker in script:
                    return output
        return default

    runner.calls = calls  # type: ignore[attr-defined]
    return runner


class FailingRunner:
    """Raises the given exception for every query (and records scripts)."""

    def __init__(self, exc: Exception):
        self.exc = exc
        self.calls: list[str] = []

    def __call__(self, script: str) -> str:
        self.calls.append(script)
        raise self.exc


# ── fixtures ───────────────────────────────────────────────────────────


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
    yield session
    session.close()


@pytest.fixture()
def runner():
    """Default runner: discovery returns one canned row per category and
    every test action reports success.  Order matters — ``make_runner``
    returns on the first marker found, so the specific test-action markers
    must precede the broader discovery ones."""
    return make_runner({
        "PrintTestPage": "RESULT:0",
        "FriendlyName -eq": "STATUS:OK",
        "DeviceID='": "FOUND:COM3",
        "Win32_Printer": PRINTERS_JSON,
        "-Class Image": SCANNERS_JSON,
        "-Class USB": USB_JSON,
        "Win32_SerialPort": SERIAL_JSON,
    })


@pytest.fixture()
def service(runner):
    reset_hardware_cache()
    svc = HardwareService(runner=runner)
    yield svc
    reset_hardware_cache()


@pytest.fixture()
def client(engine, testing_session, db, runner, monkeypatch):
    """App client wired to the SAME canned runner the tests assert on."""
    reset_hardware_cache()

    monkeypatch.setattr(
        "app.services.hardware._shared",
        HardwareService(runner=runner),
    )

    def override_get_db():
        session = testing_session()
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
        reset_hardware_cache()


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


# ── access control ─────────────────────────────────────────────────────


def test_overview_requires_authentication(client):
    assert client.get("/api/v1/hardware/overview").status_code == 401


@pytest.mark.parametrize("fixture_name", ["manager_headers", "cashier_headers"])
def test_overview_is_admin_only(client, request, fixture_name):
    headers = request.getfixturevalue(fixture_name)
    assert (
        client.get("/api/v1/hardware/overview", headers=headers).status_code
        == 403
    )


@pytest.mark.parametrize(
    "path,method",
    [
        ("/api/v1/hardware/overview", "get"),
        ("/api/v1/hardware/overview/refresh", "post"),
        ("/api/v1/hardware/printers/test-page", "post"),
        ("/api/v1/hardware/scanners/test", "post"),
        ("/api/v1/hardware/serial-ports/test", "post"),
    ],
)
def test_every_hardware_route_is_gated(client, path, method):
    assert getattr(client, method)(path).status_code == 401


# ── parsing helpers ────────────────────────────────────────────────────


def test_parse_json_list_handles_all_powershell_shapes():
    assert _parse_json_list("") == []
    assert _parse_json_list("null") == []
    assert _parse_json_list("not json at all") == []
    assert _parse_json_list('{"a":1}') == [{"a": 1}]
    assert _parse_json_list('[{"a":1},{"b":2}]') == [{"a": 1}, {"b": 2}]
    # ConvertTo-Json can emit a bare scalar for one-property rows
    assert _parse_json_list('"just a string"') == []


def test_cim_quote_doubles_single_quotes():
    assert _cim_quote("O'Brien Printer") == "O''Brien Printer"
    assert _cim_quote("clean") == "clean"


# ── overview mapping ───────────────────────────────────────────────────


def test_overview_maps_printers_scanners_usb_and_serial(service):
    overview = service.overview()

    assert {p.name for p in overview.printers} == {
        "HP LaserJet",
        "EPSON TM-T20",
    }
    hp = next(p for p in overview.printers if p.name == "HP LaserJet")
    assert hp.status == "idle"
    assert hp.is_default is True
    assert hp.is_offline is False
    epson = next(p for p in overview.printers if p.name == "EPSON TM-T20")
    assert epson.status == "offline"
    assert epson.is_offline is True

    assert len(overview.scanners) == 1
    assert overview.scanners[0].name == "Canon LiDE 400"
    assert overview.scanners[0].status == "OK"

    assert len(overview.usb_devices) == 1
    assert overview.usb_devices[0].name == "Honeywell Barcode Scanner"

    assert len(overview.serial_ports) == 1
    assert overview.serial_ports[0].name == "COM3"

    assert overview.platform  # honest about the host OS
    assert overview.cached is False


def test_overview_flags_when_running_off_windows(service, monkeypatch):
    """Non-Windows ⇒ empty lists + a warning, never fabricated devices."""
    monkeypatch.setattr("app.services.hardware.sys.platform", "linux")
    overview = service.overview()
    assert overview.printers == []
    assert overview.scanners == []
    assert overview.usb_devices == []
    assert overview.serial_ports == []
    assert any("Windows" in w for w in overview.warnings)


def test_category_failure_becomes_a_warning_not_an_error(runner):
    """One broken query empties its list and warns; the rest still load."""
    from app.core.exceptions import ServiceUnavailableError

    def selective(script: str) -> str:
        if "Win32_Printer" in script:
            raise ServiceUnavailableError("WMI repository unavailable")
        if "-Class Image" in script:
            raise HardwareUnsupportedError("powershell.exe was not found")
        if "-Class USB" in script:
            import subprocess

            raise subprocess.TimeoutExpired(cmd="powershell", timeout=15)
        if "Win32_SerialPort" in script:
            return SERIAL_JSON
        return "null"

    overview = HardwareService(runner=selective).overview()
    assert overview.printers == []
    assert overview.scanners == []
    assert overview.usb_devices == []
    assert len(overview.serial_ports) == 1
    assert len(overview.warnings) == 3
    assert any("WMI" in w for w in overview.warnings)
    assert any("powershell" in w for w in overview.warnings)
    assert any("timed out" in w for w in overview.warnings)


# ── TTL cache ──────────────────────────────────────────────────────────


def test_overview_is_ttl_cached(service, runner):
    first = service.overview()
    second = service.overview()
    assert first.cached is False
    assert second.cached is True
    # Same object payload, one walk: the fake runner saw every category
    # exactly once.
    scripts = runner.calls
    assert sum("Win32_Printer" in s for s in scripts) == 1
    assert sum("-Class Image" in s for s in scripts) == 1


def test_force_bypasses_the_cache(service, runner):
    service.overview()
    assert service.overview(force=True).cached is False
    assert sum("Win32_Printer" in s for s in runner.calls) == 2


def test_ttl_expiry_forces_a_rescan(service, monkeypatch):
    service.overview()
    # Pretend the cache entry is older than the TTL.
    import app.services.hardware as hw

    monkeypatch.setattr(hw, "OVERVIEW_TTL_SECONDS", 0.0)
    result = service.overview()
    # TTL 0 ⇒ every call is a miss; the flag reflects the fresh walk.
    assert result.cached is False


def test_refresh_endpoint_drops_the_cache(client, admin_headers):
    first = client.get("/api/v1/hardware/overview", headers=admin_headers).json()
    again = client.get("/api/v1/hardware/overview", headers=admin_headers).json()
    assert first["cached"] is False
    assert again["cached"] is True

    refreshed = client.post(
        "/api/v1/hardware/overview/refresh", headers=admin_headers
    ).json()
    assert refreshed["cached"] is False


# ── API shape ──────────────────────────────────────────────────────────


def test_overview_endpoint_returns_all_categories(client, admin_headers):
    resp = client.get("/api/v1/hardware/overview", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    for key in (
        "scanned_at",
        "platform",
        "cached",
        "printers",
        "scanners",
        "usb_devices",
        "serial_ports",
        "warnings",
    ):
        assert key in body, key
    assert len(body["printers"]) == 2
    assert body["printers"][0]["name"] in {"HP LaserJet", "EPSON TM-T20"}


# ── test actions ───────────────────────────────────────────────────────


def test_printer_test_page_ok(client, admin_headers, runner):
    resp = client.post(
        "/api/v1/hardware/printers/test-page",
        json={"name": "HP LaserJet"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["printer"] == "HP LaserJet"
    # The name rode in a single-quoted CIM filter, escaped.
    script = next(s for s in runner.calls if "PrintTestPage" in s)
    assert "Name='HP LaserJet'" in script


def test_printer_test_page_404_when_absent(client, admin_headers):
    canned = make_runner({"PrintTestPage": "NOT_FOUND"})
    import app.services.hardware as hw

    original = hw._shared
    hw._shared = HardwareService(runner=canned)
    try:
        resp = client.post(
            "/api/v1/hardware/printers/test-page",
            json={"name": "Ghost Printer"},
            headers=admin_headers,
        )
        assert resp.status_code == 404
    finally:
        hw._shared = original


def test_printer_test_page_reports_rejection(client, admin_headers):
    canned = make_runner({"PrintTestPage": "RESULT:5"})
    import app.services.hardware as hw

    original = hw._shared
    hw._shared = HardwareService(runner=canned)
    try:
        resp = client.post(
            "/api/v1/hardware/printers/test-page",
            json={"name": "HP LaserJet"},
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["ok"] is False
        assert "RESULT:5" in resp.json()["message"]
    finally:
        hw._shared = original


def test_scanner_test_ok(client, admin_headers, runner):
    resp = client.post(
        "/api/v1/hardware/scanners/test",
        json={"name": "Canon LiDE 400"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["ok"] is True
    script = next(s for s in runner.calls if "FriendlyName -eq" in s)
    assert "'Canon LiDE 400'" in script


def test_scanner_test_not_ok_when_pnp_reports_error(client, admin_headers):
    canned = make_runner({"FriendlyName -eq": "STATUS:ERROR"})
    import app.services.hardware as hw

    original = hw._shared
    hw._shared = HardwareService(runner=canned)
    try:
        resp = client.post(
            "/api/v1/hardware/scanners/test",
            json={"name": "Canon LiDE 400"},
            headers=admin_headers,
        )
        assert resp.json()["ok"] is False
        assert "ERROR" in resp.json()["message"]
    finally:
        hw._shared = original


def test_serial_test_ok_and_never_opens_the_port(client, admin_headers, runner):
    resp = client.post(
        "/api/v1/hardware/serial-ports/test",
        json={"name": "COM3"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["ok"] is True

    port_script = next(s for s in runner.calls if "Win32_SerialPort" in s and "DeviceID='" in s)
    # Presence query only — no System.IO.Ports, no .Open().
    assert ".Open()" not in port_script
    assert "System.IO.Ports" not in port_script


def test_serial_test_404_when_port_absent(client, admin_headers):
    canned = make_runner({"DeviceID='": "NOT_FOUND"})
    import app.services.hardware as hw

    original = hw._shared
    hw._shared = HardwareService(runner=canned)
    try:
        resp = client.post(
            "/api/v1/hardware/serial-ports/test",
            json={"name": "COM9"},
            headers=admin_headers,
        )
        assert resp.status_code == 404
    finally:
        hw._shared = original


def test_test_endpoints_reject_an_empty_name(client, admin_headers):
    for path in (
        "/api/v1/hardware/printers/test-page",
        "/api/v1/hardware/scanners/test",
        "/api/v1/hardware/serial-ports/test",
    ):
        resp = client.post(path, json={"name": ""}, headers=admin_headers)
        assert resp.status_code == 422, path


def test_hostile_name_never_breaks_out_of_the_cim_filter(service, runner):
    """A quote in the printer name is doubled, never closes the filter."""
    try:
        service.test_printer_page("Bad'name\"; Remove-Item x; #")
    except Exception:  # noqa: BLE001 - the fake returns canned output
        pass
    script = next(s for s in runner.calls if "PrintTestPage" in s)
    assert "Name='Bad''name" in script
    # The raw quote is not present unescaped inside the filter.
    assert "Name='Bad'name" not in script


def test_ttl_constant_is_sane():
    assert 0 < OVERVIEW_TTL_SECONDS <= 300
