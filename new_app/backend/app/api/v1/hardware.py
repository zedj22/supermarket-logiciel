"""Connected-hardware API (Objective 3).

Discovery of devices physically attached to the **server PC** — printers,
scanners, USB/HID peripherals and COM ports — plus presence-test actions
an operator can run from the settings screen.

Endpoints (all ``device_manage`` — admin only, same gate as the pairing
registry):

    GET  /api/v1/hardware/overview          one TTL-cached snapshot of
                                             every category
    POST /api/v1/hardware/overview/refresh  force a fresh walk (cache drop)
    POST /api/v1/hardware/printers/test-page  body {name} — spool a Windows
                                             test page
    POST /api/v1/hardware/scanners/test     body {name} — presence check
    POST /api/v1/hardware/serial-ports/test body {name} — presence check
                                             (never opens the port)

This is *not* ``/api/v1/devices`` (the LAN pairing registry): a paired
tablet is a client, a barcode scanner plugged into the server is
hardware.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.api.dependencies import require_permission
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.hardware import (
    HardwareOverview,
    PrinterTestPageResponse,
    ScannerTestResponse,
    SerialPortTestResponse,
)
from app.services.hardware import (
    HardwareService,
    get_hardware_service,
    reset_hardware_cache,
)

router = APIRouter()


def _admin(
    user: User = Depends(require_permission(PermissionScope.DEVICE_MANAGE)),
) -> User:
    """Shared gate: every route here is admin-only (device_manage)."""
    return user


class NameRequest(BaseModel):
    """Body for the test endpoints — one device name, nothing else."""

    name: str = Field(min_length=1, max_length=260)


@router.get(
    "/overview",
    response_model=HardwareOverview,
    summary="Discover printers, scanners, USB and serial devices on the server",
    tags=["hardware"],
)
def hardware_overview(
    _: User = Depends(_admin),
    service: HardwareService = Depends(get_hardware_service),
) -> HardwareOverview:
    """One snapshot of the server PC's attached hardware.

    TTL-cached for :data:`OVERVIEW_TTL_SECONDS`; ``cached: true`` marks a
    reused snapshot.  Category failures never fail the request — they
    land in ``warnings`` with an empty list beside them.
    """
    return service.overview()


@router.post(
    "/overview/refresh",
    response_model=HardwareOverview,
    summary="Drop the TTL cache and re-walk the device tree",
    tags=["hardware"],
)
def hardware_refresh(
    _: User = Depends(_admin),
    service: HardwareService = Depends(get_hardware_service),
) -> HardwareOverview:
    """Explicit refresh (the UI's ``↻`` button)."""
    reset_hardware_cache()
    return service.overview(force=True)


@router.post(
    "/printers/test-page",
    response_model=PrinterTestPageResponse,
    summary="Spool a Windows test page to a printer",
    tags=["hardware"],
)
def printer_test_page(
    body: NameRequest,
    _: User = Depends(_admin),
    service: HardwareService = Depends(get_hardware_service),
) -> PrinterTestPageResponse:
    """Ask Windows to print one test page on the named queue."""
    return service.test_printer_page(body.name)


@router.post(
    "/scanners/test",
    response_model=ScannerTestResponse,
    summary="Presence-check a scanner",
    tags=["hardware"],
)
def scanner_test(
    body: NameRequest,
    _: User = Depends(_admin),
    service: HardwareService = Depends(get_hardware_service),
) -> ScannerTestResponse:
    """Is the named scanner still present and reporting OK?"""
    return service.test_scanner(body.name)


@router.post(
    "/serial-ports/test",
    response_model=SerialPortTestResponse,
    summary="Presence-check a COM port (never opens it)",
    tags=["hardware"],
)
def serial_port_test(
    body: NameRequest,
    _: User = Depends(_admin),
    service: HardwareService = Depends(get_hardware_service),
) -> SerialPortTestResponse:
    """Does the named COM port exist?  The port is not opened — the POS
    may hold it for a scale or customer display mid-sale."""
    return service.test_serial_port(body.name)
