"""Phase L0: licensing state store — atomicity, integrity, DPAPI, fallback.

Covers the §12 L0 exit criteria for `StateStore`: create/read, atomic
updates, missing files, corrupted files (typed fail-closed errors),
Windows DPAPI sealing, and the safe plain fallback used in
development/test.
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import pytest

from app.licensing.state_store import (
    StateFileCorruptedError,
    StateProtectionUnavailableError,
    StateStore,
    StateStoreError,
    dpapi_available,
)

IS_WINDOWS = sys.platform == "win32"


@pytest.fixture()
def store(tmp_path: Path) -> StateStore:
    """Plain-fallback store — the explicit development/test path."""
    return StateStore(tmp_path, use_dpapi=False)


def _envelope(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _put_envelope(path: Path, envelope: dict) -> None:
    path.write_text(json.dumps(envelope), encoding="utf-8")


# ── create / read / missing ─────────────────────────────────────────────


def test_read_missing_state_returns_none(store: StateStore):
    assert store.read("trial") is None
    assert store.exists("trial") is False


def test_write_then_read_roundtrip(store: StateStore, tmp_path: Path):
    payload = {"seed": "abc-123", "started_at": "2026-11-03T00:00:00Z", "day": 1}
    path = store.write("trial", payload)

    assert path == tmp_path / "trial.state"
    assert store.exists("trial") is True
    assert store.read("trial") == payload


def test_write_creates_only_expected_files(store: StateStore, tmp_path: Path):
    store.write("trial", {"day": 1})
    assert sorted(p.name for p in tmp_path.iterdir()) == ["hmac.key", "trial.state"]


def test_delete(store: StateStore):
    store.write("trial", {"day": 1})
    assert store.delete("trial") is True
    assert store.read("trial") is None
    assert store.delete("trial") is False


# ── atomic updates ──────────────────────────────────────────────────────


def test_write_overwrites_previous_content(store: StateStore, tmp_path: Path):
    store.write("trial", {"day": 1})
    store.write("trial", {"day": 10, "seed": "rotated"})

    assert store.read("trial") == {"day": 10, "seed": "rotated"}
    assert len(list(tmp_path.glob("*.state"))) == 1
    assert not list(tmp_path.glob(".*.tmp"))


def test_failed_replace_preserves_previous_content(
    store: StateStore, monkeypatch: pytest.MonkeyPatch
):
    store.write("trial", {"day": 1})

    def _boom(src, dst):  # noqa: ANN001 - mirrors os.replace signature
        raise OSError("simulated disk failure")

    monkeypatch.setattr("app.licensing.state_store.os.replace", _boom)
    with pytest.raises(StateStoreError, match="atomic write failed"):
        store.write("trial", {"day": 2})
    monkeypatch.undo()

    assert store.read("trial") == {"day": 1}
    assert not list(store.root.glob(".*.tmp"))


def test_state_name_cannot_escape_directory(store: StateStore):
    for bad in ("", "..", "../evil", "/abs", "a/b", "a\\b", ".hidden", "-lead", "x" * 65):
        with pytest.raises(ValueError):
            store.path_for(bad)


def test_non_serializable_payload_is_typed_error(store: StateStore):
    with pytest.raises(StateStoreError, match="JSON-serializable"):
        store.write("trial", {"bad": object()})


def test_non_finite_number_is_rejected(store: StateStore):
    with pytest.raises(StateStoreError, match="JSON-serializable"):
        store.write("trial", {"value": float("nan")})


# ── corrupted files → typed fail-closed errors ─────────────────────────


def test_non_json_envelope_is_corrupted(store: StateStore):
    store.path_for("trial").write_text("definitely not json", encoding="utf-8")
    with pytest.raises(StateFileCorruptedError):
        store.read("trial")


def test_empty_file_is_corrupted(store: StateStore):
    store.path_for("trial").write_bytes(b"")
    with pytest.raises(StateFileCorruptedError):
        store.read("trial")


def test_envelope_must_be_an_object(store: StateStore):
    store.path_for("trial").write_text("[1, 2, 3]", encoding="utf-8")
    with pytest.raises(StateFileCorruptedError):
        store.read("trial")


def test_unsupported_envelope_version_is_corrupted(store: StateStore):
    store.write("trial", {"day": 1})
    path = store.path_for("trial")
    envelope = _envelope(path)
    envelope["v"] = 99
    _put_envelope(path, envelope)
    with pytest.raises(StateFileCorruptedError, match="version"):
        store.read("trial")


def test_unknown_protection_mode_is_corrupted(store: StateStore):
    store.write("trial", {"day": 1})
    path = store.path_for("trial")
    envelope = _envelope(path)
    envelope["protection"] = "rot13"
    _put_envelope(path, envelope)
    with pytest.raises(StateFileCorruptedError, match="protection"):
        store.read("trial")


def test_missing_envelope_fields_are_corrupted(store: StateStore):
    store.path_for("trial").write_text(
        json.dumps({"v": 1, "protection": "plain"}), encoding="utf-8"
    )
    with pytest.raises(StateFileCorruptedError, match="fields"):
        store.read("trial")


def test_tampered_payload_is_corrupted(store: StateStore):
    store.write("trial", {"day": 3})
    path = store.path_for("trial")
    envelope = _envelope(path)
    payload = bytearray(base64.b64decode(envelope["data"]))
    payload[0] ^= 0xFF
    envelope["data"] = base64.b64encode(bytes(payload)).decode("ascii")
    _put_envelope(path, envelope)

    with pytest.raises(StateFileCorruptedError, match="integrity"):
        store.read("trial")


def test_tampered_mac_is_corrupted(store: StateStore):
    store.write("trial", {"day": 3})
    path = store.path_for("trial")
    envelope = _envelope(path)
    envelope["mac"] = ("0" if envelope["mac"][0] != "0" else "1") + envelope["mac"][1:]
    _put_envelope(path, envelope)

    with pytest.raises(StateFileCorruptedError, match="integrity"):
        store.read("trial")


def test_malformed_mac_is_corrupted(store: StateStore):
    store.write("trial", {"day": 1})
    path = store.path_for("trial")
    envelope = _envelope(path)
    envelope["mac"] = "zz"
    _put_envelope(path, envelope)
    with pytest.raises(StateFileCorruptedError, match="mac"):
        store.read("trial")


def test_undecodable_data_is_corrupted(store: StateStore):
    store.write("trial", {"day": 1})
    path = store.path_for("trial")
    envelope = _envelope(path)
    envelope["data"] = "!!!not-base64!!!"
    _put_envelope(path, envelope)
    with pytest.raises(StateFileCorruptedError, match="undecodable"):
        store.read("trial")


def test_non_object_payload_is_corrupted(tmp_path: Path):
    key = b"k" * 32
    store = StateStore(tmp_path, use_dpapi=False, hmac_key=key)
    import hashlib
    import hmac as hmac_mod

    plaintext = json.dumps([1, 2], separators=(",", ":")).encode("utf-8")
    envelope = {
        "v": 1,
        "protection": "plain",
        "data": base64.b64encode(plaintext).decode("ascii"),
        "mac": hmac_mod.new(key, plaintext, hashlib.sha256).hexdigest(),
    }
    store.path_for("trial").write_text(json.dumps(envelope), encoding="utf-8")

    with pytest.raises(StateFileCorruptedError, match="not a JSON object"):
        store.read("trial")


# ── HMAC key lifecycle ──────────────────────────────────────────────────


def test_key_file_created_once_and_reused(tmp_path: Path):
    first = StateStore(tmp_path, use_dpapi=False)
    first.write("trial", {"day": 1})
    key_bytes = first.key_path.read_bytes()

    second = StateStore(tmp_path, use_dpapi=False)
    assert second.read("trial") == {"day": 1}
    second.write("trial", {"day": 2})
    assert second.key_path.read_bytes() == key_bytes


def test_missing_key_with_existing_state_is_corrupted(tmp_path: Path):
    StateStore(tmp_path, use_dpapi=False).write("trial", {"day": 1})
    (tmp_path / "hmac.key").unlink()

    reader = StateStore(tmp_path, use_dpapi=False)
    with pytest.raises(StateFileCorruptedError, match="hmac.key"):
        reader.read("trial")


def test_corrupted_key_file_is_corrupted(tmp_path: Path):
    StateStore(tmp_path, use_dpapi=False).write("trial", {"day": 1})
    (tmp_path / "hmac.key").write_text("!!! not base64 !!!", encoding="ascii")

    reader = StateStore(tmp_path, use_dpapi=False)
    with pytest.raises(StateFileCorruptedError, match="base64"):
        reader.read("trial")


def test_wrong_length_key_file_is_corrupted(tmp_path: Path):
    StateStore(tmp_path, use_dpapi=False).write("trial", {"day": 1})
    (tmp_path / "hmac.key").write_text(
        base64.b64encode(b"too-short").decode("ascii"), encoding="ascii"
    )

    reader = StateStore(tmp_path, use_dpapi=False)
    with pytest.raises(StateFileCorruptedError, match="length"):
        reader.read("trial")


def test_explicit_key_roundtrip_without_key_file(tmp_path: Path):
    key = b"x" * 32
    writer = StateStore(tmp_path, use_dpapi=False, hmac_key=key)
    writer.write("license", {"id": "L-1"})
    assert not writer.key_path.exists()

    reader = StateStore(tmp_path, use_dpapi=False, hmac_key=key)
    assert reader.read("license") == {"id": "L-1"}

    stranger = StateStore(tmp_path, use_dpapi=False, hmac_key=b"z" * 32)
    with pytest.raises(StateFileCorruptedError, match="integrity"):
        stranger.read("license")


def test_explicit_key_must_be_32_bytes(tmp_path: Path):
    with pytest.raises(StateStoreError, match="32"):
        StateStore(tmp_path, use_dpapi=False, hmac_key=b"short")


# ── DPAPI on Windows ────────────────────────────────────────────────────


@pytest.mark.skipif(not IS_WINDOWS, reason="DPAPI is Windows-only")
def test_dpapi_roundtrip_seals_payload_at_rest(tmp_path: Path):
    store = StateStore(tmp_path, use_dpapi=True)
    store.write("trial", {"seed": "super-secret-seed"})

    raw = store.path_for("trial").read_bytes()
    envelope = json.loads(raw)
    assert envelope["protection"] == "dpapi"
    assert b"super-secret-seed" not in raw
    assert store.read("trial") == {"seed": "super-secret-seed"}


@pytest.mark.skipif(not IS_WINDOWS, reason="DPAPI is Windows-only")
def test_dpapi_seals_the_hmac_key_file(tmp_path: Path):
    from app.licensing.state_store import _unprotect

    store = StateStore(tmp_path, use_dpapi=True)
    store.write("trial", {"day": 1})

    material = base64.b64decode(store.key_path.read_text(encoding="ascii").strip())
    assert len(material) > 32, "key file holds a DPAPI blob, not the raw key"
    assert len(_unprotect(material)) == 32


@pytest.mark.skipif(not IS_WINDOWS, reason="DPAPI is Windows-only")
def test_sealed_file_read_without_dpapi_is_protection_error(tmp_path: Path):
    StateStore(tmp_path, use_dpapi=True).write("trial", {"day": 1})

    plain_reader = StateStore(tmp_path, use_dpapi=False)
    with pytest.raises(StateProtectionUnavailableError):
        plain_reader.read("trial")


@pytest.mark.skipif(IS_WINDOWS, reason="DPAPI is available on Windows")
def test_dpapi_requested_but_unavailable_is_typed_error(tmp_path: Path):
    with pytest.raises(StateStoreError, match="dpapi"):
        StateStore(tmp_path, use_dpapi=True)


# ── safe plain fallback (development/test) ─────────────────────────────


def test_plain_fallback_is_an_explicit_choice(tmp_path: Path):
    store = StateStore(tmp_path, use_dpapi=False)
    store.write("trial", {"day": 3})

    envelope = _envelope(store.path_for("trial"))
    assert envelope["protection"] == "plain"
    assert base64.b64decode(envelope["data"]) == b'{"day":3}'
    assert store.read("trial") == {"day": 3}


def test_auto_mode_selects_platform_default(tmp_path: Path):
    store = StateStore(tmp_path)  # use_dpapi=None → auto
    store.write("trial", {"day": 1})

    envelope = _envelope(store.path_for("trial"))
    assert envelope["protection"] == ("dpapi" if dpapi_available() else "plain")
    assert store.read("trial") == {"day": 1}


def test_dpapi_available_is_boolean():
    assert isinstance(dpapi_available(), bool)
