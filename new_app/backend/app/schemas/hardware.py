"""Hardware discovery schemas (Objective 3 — connected devices).

Honest contract: these describe devices attached to the **server PC** (the
machine running this backend), discovered live via Windows CIM/PnP.  They
are *not* the LAN pairing registry (``/api/v1/devices``) — a paired POS
tablet is a client, a USB barcode scanner plugged into the server is
hardware.  On a non-Windows host the lists come back empty with an
explicit warning; nothing is ever guessed or faked.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import Field

from app.schemas.common import StrictBaseModel


class PrinterInfo(StrictBaseModel):
    """One print queue on the server PC (``Win32_Printer``)."""

    name: str = Field(description="Queue name as shown in Windows")
    driver_name: str | None = None
    port_name: str | None = Field(
        default=None, description="e.g. USB001, COM3, or an IP port"
    )
    status: str = Field(
        description="Mapped PrinterStatus: idle | printing | paused | offline | unknown"
    )
    is_default: bool = False
    is_offline: bool = False
    raw_status: int | None = Field(
        default=None, description="Win32_Printer PrinterStatus code, for debugging"
    )


class ScannerInfo(StrictBaseModel):
    """One scanner / imaging device present on the server PC (PnP)."""

    name: str = Field(description="Friendly name from PnP")
    status: str = Field(description="PnP status: OK | ERROR | UNKNOWN | ...")
    class_name: str | None = Field(
        default=None, description="PnP device class, e.g. Image, Camera, WPD"
    )
    instance_id: str | None = Field(
        default=None, description="PnP instance id (stable per physical device)"
    )
    manufacturer: str | None = None


class UsbDevice(StrictBaseModel):
    """One USB (or HID) device present on the server PC (PnP)."""

    name: str
    status: str
    class_name: str | None = Field(
        default=None, description="PnP class, e.g. USB, HIDClass, Net"
    )
    instance_id: str | None = None
    manufacturer: str | None = None


class SerialPort(StrictBaseModel):
    """One serial (COM) port on the server PC."""

    name: str = Field(description="Port name, e.g. COM3")
    description: str | None = None
    status: str | None = None
    instance_id: str | None = None
    pnp_device_id: str | None = None


class HardwareOverview(StrictBaseModel):
    """``GET /api/v1/hardware/overview`` — one snapshot of the server PC."""

    scanned_at: datetime = Field(description="When this snapshot was taken")
    platform: str = Field(
        description="os.name of the server: Windows, Linux, Darwin, ..."
    )
    cached: bool = Field(
        default=False,
        description="True when a still-fresh TTL-cached snapshot was returned",
    )
    printers: list[PrinterInfo] = Field(default_factory=list)
    scanners: list[ScannerInfo] = Field(default_factory=list)
    usb_devices: list[UsbDevice] = Field(default_factory=list)
    serial_ports: list[SerialPort] = Field(default_factory=list)
    warnings: list[str] = Field(
        default_factory=list,
        description=(
            "Per-category discovery problems (PowerShell missing, a query "
            "failed, non-Windows host) — never silently swallowed"
        ),
    )


class PrinterTestPageResponse(StrictBaseModel):
    """``POST /api/v1/hardware/printers/test-page``."""

    ok: bool = Field(description="True when Windows accepted the job")
    printer: str = Field(description="Queue name the job was sent to")
    message: str = ""


class ScannerTestResponse(StrictBaseModel):
    """``POST /api/v1/hardware/scanners/test``."""

    ok: bool = Field(
        description="True when the scanner answered a presence query"
    )
    scanner: str
    message: str = ""


class SerialPortTestResponse(StrictBaseModel):
    """``POST /api/v1/hardware/serial-ports/test``."""

    ok: bool = Field(
        description="True when the port exists and could be opened briefly"
    )
    port: str
    message: str = ""
