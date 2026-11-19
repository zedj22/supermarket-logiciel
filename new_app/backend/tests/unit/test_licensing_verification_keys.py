"""Phase L0: public Ed25519 verification-key loader validation.

The loader must be tolerant of *absence* (no keys shipped yet → empty
mapping) and strict about *content* (anything malformed raises, never
silently degrades to "no keys").
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from app.licensing.verification_keys import (
    ED25519_PUBLIC_KEY_BYTES,
    VerificationKeysError,
    load_verification_keys,
)

RAW_KEY = bytes(range(ED25519_PUBLIC_KEY_BYTES))
KEY_B64 = base64.b64encode(RAW_KEY).decode("ascii")


def _write(path: Path, content: str) -> Path:
    path.write_text(content, encoding="utf-8")
    return path


# ── tolerant of absence ────────────────────────────────────────────────


def test_missing_file_loads_empty(tmp_path: Path):
    assert load_verification_keys(tmp_path / "verification_keys.json") == {}


def test_missing_parent_directory_loads_empty(tmp_path: Path):
    target = tmp_path / "nope" / "deeper" / "keys.json"
    assert load_verification_keys(target) == {}


def test_empty_object_loads_empty(tmp_path: Path):
    path = _write(tmp_path / "keys.json", "{}")
    assert load_verification_keys(path) == {}


# ── happy path ─────────────────────────────────────────────────────────


def test_valid_keys_load_as_raw_bytes(tmp_path: Path):
    other = base64.b64encode(b"\xff" * 32).decode("ascii")
    path = _write(
        tmp_path / "keys.json",
        json.dumps({"k1": KEY_B64, "k2": other}),
    )

    keys = load_verification_keys(path)
    assert keys == {"k1": RAW_KEY, "k2": b"\xff" * 32}
    assert all(isinstance(v, bytes) and len(v) == 32 for v in keys.values())


# ── malformed content → VerificationKeysError ──────────────────────────


def test_invalid_json_raises(tmp_path: Path):
    path = _write(tmp_path / "keys.json", "{not json")
    with pytest.raises(VerificationKeysError):
        load_verification_keys(path)


def test_non_utf8_file_raises(tmp_path: Path):
    path = tmp_path / "keys.json"
    path.write_bytes(b"\xff\xfe\x00broken")
    with pytest.raises(VerificationKeysError, match="UTF-8"):
        load_verification_keys(path)


@pytest.mark.parametrize("document", ["[1, 2]", '"a string"', "42", "null"])
def test_non_object_top_level_raises(tmp_path: Path, document: str):
    path = _write(tmp_path / "keys.json", document)
    with pytest.raises(VerificationKeysError, match="object"):
        load_verification_keys(path)


@pytest.mark.parametrize("n_bytes", [0, 1, 31, 33, 64])
def test_wrong_key_length_raises(tmp_path: Path, n_bytes: int):
    value = base64.b64encode(b"\x01" * n_bytes).decode("ascii")
    path = _write(tmp_path / "keys.json", json.dumps({"k1": value}))
    with pytest.raises(VerificationKeysError, match="32 bytes"):
        load_verification_keys(path)


def test_non_base64_value_raises(tmp_path: Path):
    path = _write(tmp_path / "keys.json", json.dumps({"k1": "not base64!!"}))
    with pytest.raises(VerificationKeysError, match="base64"):
        load_verification_keys(path)


@pytest.mark.parametrize("value", [42, None, ["a"], {"k": "v"}, True])
def test_non_string_value_raises(tmp_path: Path, value):
    path = _write(tmp_path / "keys.json", json.dumps({"k1": value}))
    with pytest.raises(VerificationKeysError, match="base64 string"):
        load_verification_keys(path)


@pytest.mark.parametrize(
    "key_id",
    ["", "bad id", "-leading", "_leading", "x" * 65, "a/b", "../x", "ké", "a.b"],
)
def test_invalid_key_id_raises(tmp_path: Path, key_id: str):
    path = _write(tmp_path / "keys.json", json.dumps({key_id: KEY_B64}))
    with pytest.raises(VerificationKeysError, match="key id"):
        load_verification_keys(path)


def test_duplicate_key_id_raises(tmp_path: Path):
    path = _write(
        tmp_path / "keys.json",
        f'{{"k1": "{KEY_B64}", "k1": "{KEY_B64}"}}',
    )
    with pytest.raises(VerificationKeysError, match="duplicate"):
        load_verification_keys(path)


def test_one_bad_key_rejects_the_whole_file(tmp_path: Path):
    path = _write(
        tmp_path / "keys.json",
        json.dumps({"k1": KEY_B64, "k2": base64.b64encode(b"short").decode("ascii")}),
    )
    with pytest.raises(VerificationKeysError):
        load_verification_keys(path)
