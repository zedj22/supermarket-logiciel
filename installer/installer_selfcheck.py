#!/usr/bin/env python3
"""Installer self-check: ACLs before the service starts, health after.

The installer used to declare success as soon as WinSW accepted ``start``,
while the backend was in fact crash-looping on an unreadable
``config\\secrets.env``.  This script is the missing gate and runs twice:

``--phase pre-service``
    Apply the ACL contract (:mod:`app.core.acl`) to ``config\\`` and
    ``logs\\``, verify it, and print the exact ``icacls`` command lines
    that were used.  PostgreSQL's data directory is never touched.

``--phase post-service``
    Wait for ``/api/v1/health`` to answer ``{"database": "connected"}``.
    On timeout, write the tails of the WinSW error log, ``backend.log``
    and the PostgreSQL log into ``<DATA_DIR>\\logs\\selfcheck.txt`` (the
    installer copies them into ``install_steps.log``) and exit non-zero,
    so the wizard cannot report success.

Exit codes: 0 ok, 1 self-check failed, 2 usage.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DIAGNOSTICS_NAME = "selfcheck.txt"
TAIL_LINES = 40


def _stamp(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


# ─────────────────────────────────────────────────────────────────────────
# pre-service: ACLs
# ─────────────────────────────────────────────────────────────────────────


def _describe_commands(data_dir: Path) -> list[str]:
    """The exact icacls command lines the contract applies (for the log)."""
    from app.core import acl

    lines: list[str] = []
    config = data_dir / "config"
    logs = data_dir / "logs"
    pairs: list[tuple[Path, "acl.AclSpec"]] = []
    if config.is_dir():
        for name in acl.CREDENTIAL_FILES:
            path = config / name
            if path.is_file():
                pairs.append((path, acl.credential_file_spec(path)))
        for name in acl.ADMIN_ONLY_FILES:
            path = config / name
            if path.is_file():
                pairs.append((path, acl.admin_file_spec(path)))
    if logs.is_dir():
        pairs.append((logs, acl.logs_dir_spec(logs)))
    for path, spec in pairs:
        lines.append(" ".join(acl.icacls_argv(path, spec)))
    return lines


def run_pre_service(data_dir: Path) -> int:
    from app.core import acl

    _stamp(f"ACL contract for {data_dir}")
    report = acl.harden_data_dir(data_dir)
    for line in _describe_commands(data_dir):
        print(f"  icacls> {line}")
    for path in report.applied:
        print(f"  applied  {path}")
    for problem in report.problems:
        print(f"  FAILED   {problem}", file=sys.stderr)

    admin = data_dir / "config" / "pg_admin.env"
    if admin.is_file():
        for problem in acl.verify_admin_file_not_readable_by_service(admin):
            print(f"  FAILED   {problem}", file=sys.stderr)
            report.problems.append(problem)

    verified = acl.verify_data_dir(data_dir)
    for path in verified.applied:
        print(f"  verified {path}")
    for problem in verified.problems:
        print(f"  FAILED   {problem}", file=sys.stderr)

    ok = report.ok and verified.ok
    print(
        "ACL-SELF-CHECK " + ("OK" if ok else "FAILED"),
        flush=True,
    )
    print(
        "note: postgres/ and data/ keep their own ACLs; no recursive "
        "(/T) grant is ever issued",
        flush=True,
    )
    return 0 if ok else 1


# ─────────────────────────────────────────────────────────────────────────
# post-service: health gate + diagnostics
# ─────────────────────────────────────────────────────────────────────────


def probe_health(url: str, timeout: float = 5.0) -> tuple[bool, str]:
    """One health probe: ``(connected, description)``."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            status = response.status
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001 - any transport failure is "not up"
        return False, f"{exc.__class__.__name__}: {exc}"
    try:
        payload = json.loads(body)
    except ValueError:
        return False, f"non-JSON answer ({status}): {body[:120]}"
    database = str(payload.get("database", "")).lower()
    if status == 200 and database == "connected":
        return True, "database connected"
    return False, f"HTTP {status}, database={payload.get('database')!r}"


def wait_for_health(url: str, timeout: float) -> tuple[bool, str]:
    deadline = time.monotonic() + timeout
    attempt = 0
    last = "no attempt"
    while True:
        attempt += 1
        connected, detail = probe_health(url)
        if connected:
            _stamp(f"health OK after {attempt} attempt(s): {detail}")
            return True, detail
        last = detail
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            _stamp(f"health FAILED after {attempt} attempt(s): {last}")
            return False, last
        _stamp(f"waiting for {url} (attempt {attempt}): {detail}")
        time.sleep(min(3.0, remaining))


def _candidate_logs(data_dir: Path) -> list[Path]:
    """The logs that explain a failed start, newest first."""
    candidates: list[Path] = []
    logs = data_dir / "logs"
    for name in (
        "SupermarketProBackend.err.log",
        "SupermarketProBackend.out.log",
        "backend.log",
    ):
        path = logs / name
        if path.is_file():
            candidates.append(path)
    for pattern in ("logs/*.err.log", "logs/backend*.log"):
        for path in data_dir.glob(pattern):
            if path.is_file() and path not in candidates:
                candidates.append(path)
    pg_logs = data_dir / "postgres" / "data" / "log"
    if pg_logs.is_dir():
        files = sorted(
            (p for p in pg_logs.iterdir() if p.is_file()),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        candidates.extend(files[:1])
    return candidates


def _tail(path: Path, lines: int = TAIL_LINES) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"<cannot read {path}: {exc}>"
    return "\n".join(text.splitlines()[-lines:])


def write_diagnostics(data_dir: Path, url: str, detail: str) -> Path:
    """Collect the evidence the installer quotes in ``install_steps.log``."""
    target = data_dir / "logs" / DIAGNOSTICS_NAME
    target.parent.mkdir(parents=True, exist_ok=True)
    parts = [
        f"self-check failed at {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"health url: {url}",
        f"last answer: {detail}",
        "",
    ]
    for path in _candidate_logs(data_dir):
        parts.append(f"--- tail of {path} ---")
        parts.append(_tail(path))
        parts.append("")
    try:
        target.write_text("\n".join(parts) + "\n", encoding="utf-8", errors="replace")
    except OSError as exc:  # pragma: no cover - disk problem
        print(f"warning: cannot write {target}: {exc}", file=sys.stderr)
    return target


def run_post_service(data_dir: Path, url: str, timeout: float) -> int:
    ok, detail = wait_for_health(url, timeout)
    if ok:
        print("HEALTH-SELF-CHECK OK", flush=True)
        return 0
    target = write_diagnostics(data_dir, url, detail)
    print(f"HEALTH-SELF-CHECK FAILED: {detail}", file=sys.stderr, flush=True)
    print(f"diagnostics written to {target}", file=sys.stderr, flush=True)
    return 1


# ─────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="installer_selfcheck.py",
        description="Installer self-check (ACLs before start, health after).",
    )
    parser.add_argument("--data-dir", required=True)
    parser.add_argument(
        "--phase", choices=("pre-service", "post-service"), required=True
    )
    parser.add_argument("--url", default="http://127.0.0.1:8000/api/v1/health")
    parser.add_argument("--health-timeout", type=float, default=60.0)
    args = parser.parse_args(argv)

    # Staged next to the application package (<app>ackendpp), so the
    # script's own directory is where `app.core.acl` resolves from.
    script_dir = str(Path(__file__).resolve().parent)
    for candidate in (script_dir, os.getcwd()):
        if candidate not in sys.path:
            sys.path.insert(0, candidate)

    data_dir = Path(args.data_dir)
    if not data_dir.is_dir():
        print(f"data dir not found: {data_dir}", file=sys.stderr)
        return 2
    if args.phase == "pre-service":
        return run_pre_service(data_dir)
    return run_post_service(data_dir, args.url, args.health_timeout)


if __name__ == "__main__":
    sys.exit(main())
