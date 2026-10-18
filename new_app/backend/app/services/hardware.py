"""Connected-hardware discovery (Objective 3).

Honest Windows device enumeration for the **server PC** — the machine this
backend runs on.  Three rules shape every line here:

* **List-form subprocess only.**  PowerShell is invoked as
  ``subprocess.run([...], shell=False)``; no user input is ever
  interpolated into a ``-Command`` string except the test-action
  endpoints, where names are single-quote-escaped for a CIM filter and
  nothing else.
* **Never guessed.**  On a non-Windows host, or when ``powershell`` is
  missing, or when one query fails, the affected list is empty and a
  human-readable warning says why.  The UI shows the warning; it never
  shows a device that was not seen.
* **TTL cache.**  PnP enumeration is slow (hundreds of ms per query);
  results are cached process-wide for :data:`OVERVIEW_TTL_SECONDS` so a
  settings screen refresh does not re-walk the device tree each time.

Test actions (print a test page, ping a scanner, probe a COM port) are
deliberately **presence checks**, not destructive probes: opening a COM
port that the POS is using for a scale would disrupt live sales, so the
serial test only proves the port exists.
"""

from __future__ import annotations

import json
import platform
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

import structlog

from app.core.exceptions import (
    NotFoundError,
    ServiceUnavailableError,
)
from app.schemas.hardware import (
    HardwareOverview,
    PrinterInfo,
    PrinterTestPageResponse,
    ScannerInfo,
    ScannerTestResponse,
    SerialPort,
    SerialPortTestResponse,
    UsbDevice,
)

logger = structlog.get_logger(__name__)

#: How long one overview snapshot may be reused.  Long enough that
#: clicking around a settings screen costs one walk; short enough that
#: plugging in a scanner shows up within a minute.
OVERVIEW_TTL_SECONDS = 30.0

#: Hard cap on a single PowerShell invocation — a healthy run is well
#: under 5s; 15s means something is wedged.
POWERSHELL_TIMEOUT_SECONDS = 15

#: ``powershell.exe`` discovery order: explicit override, then PATH, then
#: the well-known System32 location (PATH can be stripped for services).
_POWERSHELL_OVERRIDE_ENV = "POWERSHELL_PATH"
_POWERSHELL_FALLBACK = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# -- scripts (static; the only dynamic bits are CIM filters built by the
#    test actions, where the value is single-quote-escaped) ---------------

_PRINTERS_SCRIPT = (
    "Get-CimInstance Win32_Printer | "
    "Select-Object Name,DriverName,PortName,PrinterStatus,Default,WorkOffline | "
    "ConvertTo-Json -Compress"
)

_SCANNERS_SCRIPT = (
    "Get-PnpDevice -Class Image,Camera,WPD -ErrorAction SilentlyContinue | "
    "Select-Object FriendlyName,Status,Class,InstanceId,Manufacturer | "
    "ConvertTo-Json -Compress"
)

_USB_SCRIPT = (
    "Get-PnpDevice -Class USB,HIDClass -ErrorAction SilentlyContinue | "
    "Select-Object FriendlyName,Status,Class,InstanceId,Manufacturer | "
    "ConvertTo-Json -Compress"
)

_SERIAL_SCRIPT = (
    "Get-CimInstance Win32_SerialPort | "
    "Select-Object DeviceID,Name,Description,Status,PNPDeviceID | "
    "ConvertTo-Json -Compress"
)

#: Win32_Printer.PrinterStatus codes → our stable vocabulary.
_PRINTER_STATUS = {
    1: "unknown",  # Other
    2: "unknown",  # Unknown
    3: "idle",
    4: "printing",
    5: "printing",  # Warmup
    6: "printing",  # Stopped Printing — still mid-job from the OS view
    7: "offline",
}

#: Injected in tests; production builds the real one lazily.
Runner = Callable[[str], str]


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class HardwareUnsupportedError(ServiceUnavailableError):
    """The host cannot answer hardware queries (non-Windows / no PowerShell)."""

    code = "hardware_unsupported"
    status_code = 503
    message_key = "errors.hardwareUnsupported"


# ---------------------------------------------------------------------------
# PowerShell plumbing
# ---------------------------------------------------------------------------


def find_powershell() -> str | None:
    """Locate ``powershell.exe``, honouring ``POWERSHELL_PATH``."""
    import os
    import shutil

    override = os.environ.get(_POWERSHELL_OVERRIDE_ENV, "").strip()
    if override:
        return override
    found = shutil.which("powershell") or shutil.which("powershell.exe")
    if found:
        return found
    from pathlib import Path

    fallback = Path(_POWERSHELL_FALLBACK)
    return str(fallback) if fallback.is_file() else None


def _run_powershell(script: str) -> str:
    """Run one static script; return stdout.  Never ``shell=True``."""
    exe = find_powershell()
    if exe is None:
        raise HardwareUnsupportedError(
            "powershell.exe was not found on this machine",
            details={"hint": f"set {_POWERSHELL_OVERRIDE_ENV}"},
        )
    completed = subprocess.run([
        exe,
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
    ], capture_output=True, text=True, timeout=POWERSHELL_TIMEOUT_SECONDS, check=False)
    if completed.returncode != 0:
        raise ServiceUnavailableError(
            "PowerShell device query failed",
            details={
                "returncode": completed.returncode,
                "stderr": (completed.stderr or "")[:500],
            },
        )
    return completed.stdout


def _parse_json_list(stdout: str) -> list[dict[str, Any]]:
    """PowerShell ``ConvertTo-Json`` emits ``[]``, ``null``, one object, or a list."""
    text = (stdout or "").strip()
    if not text or text == "null":
        return []
    try:
        parsed = json.loads(text)
    except ValueError:
        return []
    if isinstance(parsed, list):
        return [item for item in parsed if isinstance(item, dict)]
    if isinstance(parsed, dict):
        return [parsed]
    return []


def _cim_quote(value: str) -> str:
    """Escape a value for a single-quoted CIM/WQL filter literal."""
    return value.replace("'", "''")


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


class HardwareService:
    """Live view of the server PC's printers / scanners / USB / COM ports."""

    def __init__(self, runner: Runner | None = None):
        self._runner = runner
        self._cache: tuple[float, HardwareOverview] | None = None
        self._lock = threading.Lock()

    # -- runner (injectable for tests) ------------------------------------

    @property
    def runner(self) -> Runner:
        return self._runner if self._runner is not None else _run_powershell

    # -- overview -----------------------------------------------------------

    def overview(self, *, force: bool = False) -> HardwareOverview:
        """One snapshot of every category, TTL-cached process-wide."""
        now = time.monotonic()
        if not force and self._cache is not None:
            cached_at, snapshot = self._cache
            if now - cached_at < OVERVIEW_TTL_SECONDS:
                return snapshot.model_copy(update={"cached": True})

        with self._lock:
            # Double-checked: another request may have filled it while we
            # waited on the lock.
            if not force and self._cache is not None:
                cached_at, snapshot = self._cache
                if now - cached_at < OVERVIEW_TTL_SECONDS:
                    return snapshot.model_copy(update={"cached": True})
            snapshot = self._scan()
            self._cache = (time.monotonic(), snapshot)
            return snapshot

    def _scan(self) -> HardwareOverview:
        warnings: list[str] = []
        printers: list[PrinterInfo] = []
        scanners: list[ScannerInfo] = []
        usb_devices: list[UsbDevice] = []
        serial_ports: list[SerialPort] = []

        if sys.platform != "win32":
            warnings.append(
                "Hardware discovery only runs on Windows; this server is "
                f"{platform.system()}. Every list is empty on purpose."
            )
        else:
            printers = self._collect_printers(warnings)
            scanners = self._collect_scanners(warnings)
            usb_devices = self._collect_usb(warnings)
            serial_ports = self._collect_serial(warnings)

        return HardwareOverview(
            scanned_at=datetime.now(timezone.utc),
            platform=platform.system(),
            printers=printers,
            scanners=scanners,
            usb_devices=usb_devices,
            serial_ports=serial_ports,
            warnings=warnings,
        )

    def _query(self, script: str, category: str, warnings: list[str]) -> list[dict[str, Any]]:
        try:
            return _parse_json_list(self.runner(script))
        except HardwareUnsupportedError as exc:
            warnings.append(f"{category}: {exc.message}")
        except ServiceUnavailableError as exc:
            warnings.append(f"{category}: {exc.message}")
        except subprocess.TimeoutExpired:
            warnings.append(
                f"{category}: PowerShell timed out after "
                f"{POWERSHELL_TIMEOUT_SECONDS}s"
            )
        return []

    def _collect_printers(self, warnings: list[str]) -> list[PrinterInfo]:
        rows = self._query(_PRINTERS_SCRIPT, "printers", warnings)
        out: list[PrinterInfo] = []
        for row in rows:
            name = str(row.get("Name") or "").strip()
            if not name:
                continue
            raw_status = row.get("PrinterStatus")
            status_code = int(raw_status) if isinstance(raw_status, (int, float)) else None
            work_offline = bool(row.get("WorkOffline"))
            out.append(PrinterInfo(
                name=name,
                driver_name=row.get("DriverName"),
                port_name=row.get("PortName"),
                status=_PRINTER_STATUS.get(status_code or -1, "offline" if work_offline else "unknown"),
                is_default=bool(row.get("Default")),
                is_offline=work_offline or status_code == 7,
                raw_status=status_code,
            ))
        return out

    def _collect_scanners(self, warnings: list[str]) -> list[ScannerInfo]:
        rows = self._query(_SCANNERS_SCRIPT, "scanners", warnings)
        return [
            ScannerInfo(
                name=str(row.get("FriendlyName") or "").strip() or "unnamed scanner",
                status=str(row.get("Status") or "UNKNOWN"),
                class_name=row.get("Class"),
                instance_id=row.get("InstanceId"),
                manufacturer=row.get("Manufacturer"),
            )
            for row in rows
            if row.get("FriendlyName")
        ]

    def _collect_usb(self, warnings: list[str]) -> list[UsbDevice]:
        rows = self._query(_USB_SCRIPT, "usb devices", warnings)
        return [
            UsbDevice(
                name=str(row.get("FriendlyName") or "").strip() or "unnamed device",
                status=str(row.get("Status") or "UNKNOWN"),
                class_name=row.get("Class"),
                instance_id=row.get("InstanceId"),
                manufacturer=row.get("Manufacturer"),
            )
            for row in rows
            if row.get("FriendlyName")
        ]

    def _collect_serial(self, warnings: list[str]) -> list[SerialPort]:
        rows = self._query(_SERIAL_SCRIPT, "serial ports", warnings)
        return [
            SerialPort(
                name=str(row.get("DeviceID") or "").strip() or "unknown",
                description=row.get("Description"),
                status=row.get("Status"),
                instance_id=row.get("PNPDeviceID"),
                pnp_device_id=row.get("PNPDeviceID"),
            )
            for row in rows
            if row.get("DeviceID")
        ]

    # -- test actions --------------------------------------------------------

    def test_printer_page(self, printer_name: str) -> PrinterTestPageResponse:
        """Ask Windows to spool one test page to the named queue.

        Presence-only: if the queue does not exist, 404; if Windows
        rejects the job, an honest ``ok: false`` with the reason.
        """
        if sys.platform != "win32":
            raise HardwareUnsupportedError(
                "Test pages can only be sent from a Windows server"
            )
        escaped = _cim_quote(printer_name.strip())
        script = (
            f"$p = Get-CimInstance Win32_Printer -Filter \"Name='{escaped}'\"; "
            "if ($null -eq $p) { Write-Output 'NOT_FOUND'; exit 0 }; "
            "$r = Invoke-CimMethod -InputObject $p -MethodName PrintTestPage; "
            "Write-Output ('RESULT:' + $r.ReturnValue)"
        )
        stdout = self.runner(script)
        if "NOT_FOUND" in stdout:
            raise NotFoundError(
                f"Printer '{printer_name}' is not installed on the server",
                details={"printer": printer_name},
            )
        if "RESULT:0" in stdout:
            return PrinterTestPageResponse(
                ok=True,
                printer=printer_name,
                message="Windows accepted the test page job",
            )
        return PrinterTestPageResponse(
            ok=False,
            printer=printer_name,
            message=f"Windows rejected the job: {stdout.strip()[:200]}",
        )

    def test_scanner(self, scanner_name: str) -> ScannerTestResponse:
        """Presence check: is the named scanner still OK in PnP?"""
        if sys.platform != "win32":
            raise HardwareUnsupportedError(
                "Scanner checks can only run on a Windows server"
            )
        escaped = _cim_quote(scanner_name.strip())
        script = (
            f"$d = Get-PnpDevice | Where-Object {{ $_.FriendlyName -eq '{escaped}' }}; "
            "if ($null -eq $d) { Write-Output 'NOT_FOUND'; exit 0 }; "
            "Write-Output ('STATUS:' + $d.Status)"
        )
        stdout = self.runner(script)
        if "NOT_FOUND" in stdout:
            raise NotFoundError(
                f"Scanner '{scanner_name}' is not present on the server",
                details={"scanner": scanner_name},
            )
        if "STATUS:OK" in stdout:
            return ScannerTestResponse(
                ok=True,
                scanner=scanner_name,
                message="Scanner is present and reporting OK",
            )
        return ScannerTestResponse(
            ok=False,
            scanner=scanner_name,
            message=f"Scanner is present but not OK: {stdout.strip()[:200]}",
        )

    def test_serial_port(self, port_name: str) -> SerialPortTestResponse:
        """Presence check for a COM port.

        Deliberately does **not** open the port: the POS may be holding
        it open for a customer-display or scale, and stealing it would
        break live sales mid-transaction.
        """
        if sys.platform != "win32":
            raise HardwareUnsupportedError(
                "Serial-port checks can only run on a Windows server"
            )
        escaped = _cim_quote(port_name.strip())
        script = (
            f"$p = Get-CimInstance Win32_SerialPort -Filter \"DeviceID='{escaped}'\"; "
            "if ($null -eq $p) { Write-Output 'NOT_FOUND'; exit 0 }; "
            "Write-Output ('FOUND:' + $p.DeviceID)"
        )
        stdout = self.runner(script)
        if "NOT_FOUND" in stdout:
            raise NotFoundError(
                f"Serial port '{port_name}' does not exist on the server",
                details={"port": port_name},
            )
        if f"FOUND:{port_name.strip()}" in stdout or "FOUND:COM" in stdout:
            return SerialPortTestResponse(
                ok=True,
                port=port_name,
                message="Port exists (not opened — the POS may be using it)",
            )
        return SerialPortTestResponse(
            ok=False,
            port=port_name,
            message=f"Unexpected reply: {stdout.strip()[:200]}",
        )


# ---------------------------------------------------------------------------
# Shared service + cache reset for tests
# ---------------------------------------------------------------------------

_shared = HardwareService()


def get_hardware_service() -> HardwareService:
    """Process-wide singleton so the TTL cache spans requests."""
    return _shared


def reset_hardware_cache() -> None:
    """Drop the TTL cache (used by tests and by an explicit UI refresh)."""
    with _shared._lock:
        _shared._cache = None


__all__ = [
    "HardwareService",
    "HardwareUnsupportedError",
    "OVERVIEW_TTL_SECONDS",
    "get_hardware_service",
    "reset_hardware_cache",
]
