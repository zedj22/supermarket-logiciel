"""R2: the production launcher.

Covers the release requirements for ``run_production.py``:

* starts from an **unrelated current working directory** and still
  resolves the backend root, the production ``.env`` and the data root;
* uses the **configured host and port**;
* never uses ``--reload`` and always pins ``workers=1``;
* fails closed (distinct exit codes) on a missing ``DATA_DIR``, a
  missing production ``.env``, corrupted secrets and placeholder secrets;
* serves for real and performs a **graceful shutdown** (exit code 0)
  when WinSW-style Ctrl+Break arrives;
* never prints a secret value.

The development launch workflow (``python -m uvicorn app.main:app
--reload``) is untouched by construction: nothing here modifies it.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

import run_production
from app.core.config import BACKEND_ROOT

LAUNCHER = BACKEND_ROOT / "run_production.py"

#: Keys the test child must not inherit from the pytest process.
_INHERITED_KEYS = (
    "APP_ENV",
    "APP_SECRET_KEY",
    "JWT_SECRET_KEY",
    "DATABASE_URL",
    "LICENSE_STATE_DIR",
    "DATA_DIR",
    "LOG_DIR",
    "LOG_FILE_ENABLED",
    "HOST",
    "PORT",
    "LOG_LEVEL",
    "LAN_MODE",
    "DISCOVERY_ENABLED",
    "LICENSE_ENFORCEMENT",
    "SERVER_ID",
)


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _production_env(tmp_path: Path, *, port: int, host: str = "127.0.0.1") -> Path:
    """A minimal production layout: <DATA_DIR>/config/.env with secrets
    that are still the repository placeholders, so the launcher has to
    provision ``secrets.env`` itself."""
    data_dir = tmp_path / "ProgramData" / "SupermarketPro"
    (data_dir / "config").mkdir(parents=True)
    (data_dir / "config" / ".env").write_text(
        "APP_ENV=development\n"
        "DATABASE_URL=sqlite:///:memory:\n"
        "APP_SECRET_KEY=change-me-to-a-strong-random-value\n"
        "JWT_SECRET_KEY=change-me-to-another-strong-random-value\n"
        f"HOST={host}\n"
        f"PORT={port}\n"
        "LOG_LEVEL=INFO\n",
        encoding="utf-8",
    )
    return data_dir


def _child_env(data_dir: Path | None, **extra: str) -> dict[str, str]:
    env = os.environ.copy()
    for key in _INHERITED_KEYS:
        env.pop(key, None)
    env["PYTHONIOENCODING"] = "utf-8"
    if data_dir is not None:
        env["DATA_DIR"] = str(data_dir)
    env.update(extra)
    return env


def _run(data_dir: Path | None, *args: str, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(LAUNCHER), *args],
        cwd=str(cwd),
        env=_child_env(data_dir),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
    )


def _report(proc: subprocess.CompletedProcess) -> dict:
    assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
    return json.loads(proc.stdout)


# ---------------------------------------------------------------------------
# --check: unrelated CWD, configured host/port, no reload
# ---------------------------------------------------------------------------


def test_check_runs_from_an_unrelated_cwd(tmp_path):
    """The launcher must not care where the process was started from."""
    unrelated = tmp_path / "somewhere" / "else"
    unrelated.mkdir(parents=True)
    # Decoys: a .env and a data dir in the CWD must both be ignored.
    (unrelated / ".env").write_text(
        "DATABASE_URL=postgresql://decoy:decoy@localhost:9999/decoy\n"
        "HOST=10.9.9.9\n"
        "PORT=9999\n",
        encoding="utf-8",
    )
    (unrelated / "ProgramData").mkdir()

    data_dir = _production_env(tmp_path, port=8123)
    proc = _run(data_dir, "--check", cwd=unrelated)

    report = _report(proc)
    assert report["working_directory"] == str(BACKEND_ROOT)
    assert report["backend_root"] == str(BACKEND_ROOT)
    assert report["data_dir"] == str(data_dir)
    assert Path(report["env_file"]) == data_dir / "config" / ".env"
    assert Path(report["secrets_file"]) == data_dir / "config" / "secrets.env"
    # The CWD decoy never became the configuration.
    assert "9999" not in json.dumps({"port": report["port"], "host": report["host"]})
    assert report["port"] == 8123
    assert report["host"] == "127.0.0.1"


def test_check_uses_the_configured_host_and_port_and_never_reloads(tmp_path):
    data_dir = _production_env(tmp_path, port=8765, host="127.0.0.1")
    report = _report(_run(data_dir, "--check", cwd=tmp_path))

    assert report["host"] == "127.0.0.1"
    assert report["port"] == 8765
    assert report["app"] == "app.main:app"
    assert report["reload"] is False
    assert report["workers"] == 1

    # The real kwargs handed to uvicorn.run() — not just the report.
    kwargs = report["uvicorn"]
    assert kwargs["reload"] is False
    assert kwargs["workers"] == 1
    assert kwargs["host"] == "127.0.0.1"
    assert kwargs["port"] == 8765
    assert kwargs["log_config"] is None
    assert "reload_dirs" not in kwargs


def test_check_never_prints_a_secret_value(tmp_path):
    data_dir = _production_env(tmp_path, port=8123)
    proc = _run(data_dir, "--check", cwd=tmp_path)
    report = _report(proc)

    secrets_file = Path(report["secrets_file"])
    assert secrets_file.is_file()
    values = [
        line.split("=", 1)[1].strip()
        for line in secrets_file.read_text(encoding="utf-8").splitlines()
        if line.startswith(("APP_SECRET_KEY=", "JWT_SECRET_KEY="))
    ]
    assert values, "secrets.env must contain both keys"
    for value in values:
        assert value not in proc.stdout
        assert value not in proc.stderr
    assert "change-me" not in proc.stdout


def test_check_reports_the_operational_log_file(tmp_path):
    data_dir = _production_env(tmp_path, port=8123)
    report = _report(_run(data_dir, "--check", cwd=tmp_path))

    assert report["log_file_enabled"] is True  # DATA_DIR set -> auto on
    assert Path(report["log_dir"]) == data_dir / "logs"
    assert Path(report["log_file"]) == data_dir / "logs" / "backend.log"


# ---------------------------------------------------------------------------
# Fail-closed paths (distinct exit codes)
# ---------------------------------------------------------------------------


def test_missing_data_dir_is_a_usage_error(tmp_path):
    proc = _run(None, "--check", cwd=tmp_path)
    assert proc.returncode == run_production.EXIT_USAGE
    assert "DATA_DIR" in proc.stderr


def test_missing_production_dotenv_fails_closed(tmp_path):
    data_dir = tmp_path / "ProgramData" / "SupermarketPro"
    (data_dir / "config").mkdir(parents=True)
    proc = _run(data_dir, "--check", cwd=tmp_path)
    assert proc.returncode == run_production.EXIT_CONFIG_INVALID
    assert "config" in proc.stderr and ".env" in proc.stderr


def test_corrupted_secret_file_fails_closed_and_is_left_untouched(tmp_path):
    data_dir = _production_env(tmp_path, port=8123)
    secrets_file = data_dir / "config" / "secrets.env"
    garbage = "APP_SECRET_KEY=not-enough\n"
    secrets_file.write_text(garbage, encoding="utf-8")

    proc = _run(data_dir, "--check", cwd=tmp_path)

    assert proc.returncode == run_production.EXIT_SECRETS_FAILED
    assert "secrets.env" in proc.stderr
    # Fail closed: the file was neither regenerated nor edited.
    assert secrets_file.read_text(encoding="utf-8") == garbage
    assert "change-me" not in proc.stderr


def test_placeholder_secret_in_the_process_environment_is_rejected(tmp_path):
    """Even with a valid secrets.env, an exported placeholder must not
    serve: production startup refuses it (exit 4)."""
    data_dir = _production_env(tmp_path, port=8123)
    proc = subprocess.run(
        [sys.executable, str(LAUNCHER), "--check"],
        cwd=str(tmp_path),
        env=_child_env(data_dir, APP_SECRET_KEY="change-me-in-production"),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
    )
    assert proc.returncode == run_production.EXIT_CONFIG_INVALID
    assert "placeholder" in proc.stderr.lower()


def test_server_failure_after_configuration_exits_one(tmp_path):
    """Bind failure (unassignable address) -> exit 1, not a traceback.

    WinSW's <onfailure> must only see a genuinely failed process, and
    the failure must be reported rather than swallowed.  192.0.2.0/24 is
    RFC 5737 TEST-NET-1: never a local address, so the bind always fails.
    """
    port = _free_port()
    data_dir = _production_env(tmp_path, port=port, host="192.0.2.7")
    proc = _run(data_dir, cwd=tmp_path)

    assert proc.returncode == run_production.EXIT_SERVE_FAILED, (
        f"stdout={proc.stdout}\nstderr={proc.stderr}"
    )
    combined = (proc.stdout + proc.stderr).lower()
    assert "production_start" in proc.stdout
    assert "bind" in combined or "address" in combined


# ---------------------------------------------------------------------------
# In-process unit checks (no subprocess)
# ---------------------------------------------------------------------------
def test_uvicorn_kwargs_pin_single_worker_and_no_reload():
    class _Cfg:
        HOST = "0.0.0.0"
        PORT = 9001

    kwargs = run_production.build_uvicorn_kwargs(_Cfg())
    assert kwargs["reload"] is False
    assert kwargs["workers"] == 1
    assert kwargs["host"] == "0.0.0.0"
    assert kwargs["port"] == 9001
    assert kwargs["app"] == "app.main:app"


def test_launcher_source_never_passes_reload_to_uvicorn():
    """Guard against a future edit reintroducing --reload."""
    source = LAUNCHER.read_text(encoding="utf-8")
    assert '"reload": True' not in source
    assert "'reload': True" not in source
    assert "reload=True" not in source
    assert "uvicorn.run(" in source  # the single serve entry point


def test_launcher_forces_production_environment(tmp_path, monkeypatch):
    """_prepare_environment pins DATA_DIR, APP_ENV and the backend CWD."""
    data_dir = tmp_path / "data"
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("APP_ENV", raising=False)
    monkeypatch.delenv("PYTHONDONTWRITEBYTECODE", raising=False)

    run_production._prepare_environment(data_dir)

    assert os.environ["DATA_DIR"] == str(data_dir)
    assert os.environ["APP_ENV"] == "production"
    assert os.environ["PYTHONDONTWRITEBYTECODE"] == "1"
    assert Path.cwd() == BACKEND_ROOT


# ---------------------------------------------------------------------------
# Graceful shutdown against a real server process
# ---------------------------------------------------------------------------


def _wait_for_health(url: str, proc: subprocess.Popen, timeout: float = 60.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.3)
    return False


@pytest.mark.skipif(
    sys.platform != "win32", reason="CTRL_BREAK_EVENT is Windows-only"
)
def test_graceful_shutdown_on_ctrl_break_exits_zero(tmp_path):
    """WinSW stops the service with Ctrl+C; the launcher must exit 0.

    A non-zero exit after a clean stop would make the wrapper's
    <onfailure> policy restart the service on every manual stop.
    """
    port = _free_port()
    data_dir = _production_env(tmp_path, port=port)
    log_file = data_dir / "logs" / "backend.log"

    proc = subprocess.Popen(
        [sys.executable, str(LAUNCHER)],
        cwd=str(tmp_path),  # unrelated CWD on purpose
        env=_child_env(data_dir),
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    try:
        assert _wait_for_health(
            f"http://127.0.0.1:{port}/api/v1/health/live", proc
        ), "backend never became healthy"

        proc.send_signal(signal.CTRL_BREAK_EVENT)
        returncode = proc.wait(timeout=45)
    finally:
        if proc.poll() is None:  # pragma: no cover - cleanup safety net
            proc.kill()
            proc.wait(timeout=10)

    stdout = proc.stdout.read()
    stderr = proc.stderr.read()

    assert returncode == 0, f"stdout={stdout[-2000:]}\nstderr={stderr[-2000:]}"

    # The structured log exists under DATA_DIR\logs with a shutdown line.
    assert log_file.is_file()
    log_text = log_file.read_text(encoding="utf-8")
    assert "production_start" in log_text
    assert "Application shutdown complete" in log_text or "production_stopped" in log_text
    # No secret ever reaches the log.
    assert "change-me" not in log_text
    for line in log_text.splitlines():
        if "APP_SECRET_KEY" in line:
            raise AssertionError(f"secret key material in log: {line}")
