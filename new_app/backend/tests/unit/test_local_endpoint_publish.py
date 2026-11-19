"""Hardening pass — the local endpoint descriptor published by run_production.

Covers the R1-aligned publish locations, the atomic write contract, the
locale-proof ``BUILTIN\\Users`` read grant on the data-root descriptor
and the fail-open contract (a broken publish must never stop the
server).  The Flutter probe order itself lives in
``lib/features/devices/device_identity.dart`` and is pinned by
``test/unit/endpoint_discovery_test.dart``.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

import run_production


class _Cfg:
    """Minimal settings stand-in for _publish_local_endpoint."""

    def __init__(
        self,
        *,
        data_dir: str = "",
        host: str = "127.0.0.1",
        port: int = 8000,
    ) -> None:
        self.DATA_DIR = data_dir
        self.HOST = host
        self.PORT = port


@pytest.fixture()
def isolated_layout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Backend root inside tmp so the sibling ``app/`` decoy is controlled."""
    backend = tmp_path / "backend"
    backend.mkdir()
    monkeypatch.setattr(run_production, "BACKEND_ROOT", backend)
    return tmp_path


def _read(target: Path) -> dict:
    return json.loads(target.read_text(encoding="utf-8"))


def test_publish_writes_the_data_dir_config_descriptor(isolated_layout: Path):
    data_dir = isolated_layout / "data"
    (data_dir / "config").mkdir(parents=True)

    result = run_production._publish_local_endpoint(
        _Cfg(data_dir=str(data_dir), host="0.0.0.0", port=8123)
    )

    target = data_dir / "config" / "supermarket_endpoint.json"
    assert str(target) in result["written"], result
    assert result["failed"] == []
    # Wildcard bind normalizes to loopback so the local app can connect.
    assert _read(target) == {
        "base_url": "http://127.0.0.1:8123",
        "host": "127.0.0.1",
        "port": 8123,
    }


def test_publish_writes_the_sibling_app_descriptor(isolated_layout: Path):
    # BACKEND_ROOT is <isolated_layout>/backend → sibling is <layout>/app.
    (isolated_layout / "app").mkdir()

    result = run_production._publish_local_endpoint(_Cfg(port=8443))

    target = isolated_layout / "app" / "supermarket_endpoint.json"
    assert str(target) in result["written"], result
    assert _read(target)["base_url"] == "http://127.0.0.1:8443"


def test_publish_writes_both_locations_when_both_exist(isolated_layout: Path):
    data_dir = isolated_layout / "data"
    (data_dir / "config").mkdir(parents=True)
    (isolated_layout / "app").mkdir()

    result = run_production._publish_local_endpoint(
        _Cfg(data_dir=str(data_dir), port=8001)
    )

    assert str(data_dir / "config" / "supermarket_endpoint.json") in result["written"]
    assert str(isolated_layout / "app" / "supermarket_endpoint.json") in result["written"]


def test_publish_leaves_no_temp_files_behind(isolated_layout: Path):
    data_dir = isolated_layout / "data"
    (data_dir / "config").mkdir(parents=True)
    (isolated_layout / "app").mkdir()

    run_production._publish_local_endpoint(_Cfg(data_dir=str(data_dir)))

    leftovers = [
        p
        for p in isolated_layout.rglob("*")
        if p.is_file() and p.name.endswith(".tmp")
    ]
    assert leftovers == []


def test_publish_is_fail_open_when_the_target_is_impossible(isolated_layout: Path):
    # DATA_DIR points at a *file*: creating config/ under it raises OSError.
    blocker = isolated_layout / "not-a-dir"
    blocker.write_text("x", encoding="utf-8")

    result = run_production._publish_local_endpoint(
        _Cfg(data_dir=str(blocker), port=8000)
    )

    assert result["written"] == []
    assert len(result["failed"]) == 1
    assert "supermarket_endpoint.json" in result["failed"][0]


def test_publish_skips_the_data_dir_target_without_data_dir(isolated_layout: Path):
    (isolated_layout / "app").mkdir()

    result = run_production._publish_local_endpoint(_Cfg(data_dir="", port=8000))

    assert len(result["written"]) == 1
    assert result["written"][0].endswith("supermarket_endpoint.json")


def test_publish_grants_users_read_only_on_the_data_dir_descriptor(
    isolated_layout: Path, monkeypatch: pytest.MonkeyPatch
):
    data_dir = isolated_layout / "data"
    (data_dir / "config").mkdir(parents=True)
    (isolated_layout / "app").mkdir()
    grants: list[Path] = []

    def fake_grant(path: Path) -> bool:
        grants.append(path)
        return True

    monkeypatch.setattr(run_production, "_grant_users_read", fake_grant)

    run_production._publish_local_endpoint(_Cfg(data_dir=str(data_dir)))

    assert len(grants) == 1
    # Granted on the temp file *before* the atomic rename, so the final
    # descriptor carries the ACE from the instant it exists.
    assert grants[0].name.startswith(".supermarket_endpoint.json.")


@pytest.mark.skipif(shutil.which("icacls") is None, reason="Windows only")
def test_publish_result_is_readable_by_standard_users(isolated_layout: Path):
    """Real icacls round-trip: the data-dir descriptor ends up Users:R.

    Also pins that ``os.replace`` preserves the security descriptor of
    the temp file the grant was applied to.
    """
    data_dir = isolated_layout / "data"
    (data_dir / "config").mkdir(parents=True)

    run_production._publish_local_endpoint(_Cfg(data_dir=str(data_dir), port=8002))

    target = data_dir / "config" / "supermarket_endpoint.json"
    assert target.is_file()
    out = subprocess.run(
        ["icacls", str(target)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    ).stdout
    # Well-known SID renders localized (Users / Utilisateurs) or raw.
    assert any(
        marker in out
        for marker in ("S-1-5-32-545", "Users:", "Utilisateurs:")
    ), out
