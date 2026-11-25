"""Signing-secret exporter (`scripts/export_signing_secret.py`).

Every test builds a **synthetic** keystore in ``tmp_path`` from a throwaway
Ed25519 pair generated in-process.  The real external staging keystore is never
read, no real secret is exported, and no assertion prints key material: the
only values compared live in memory.
"""

from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from tools.license_generator import keystore as backend_keystore

SERVICE_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = SERVICE_ROOT / "scripts" / "export_signing_secret.py"
KEY_ID = "stg-2026-11"
OTHER_KEY_ID = "stg-2026-12"
SECRET_NAME = "LICENSE_API_SIGNING_SECRET"


def _load_exporter():
    spec = importlib.util.spec_from_file_location("export_signing_secret", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


exporter = _load_exporter()


@pytest.fixture
def key_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "owner_keys"
    directory.mkdir()
    return directory


def _write_keystore(directory: Path, key_id: str = KEY_ID) -> tuple[Path, bytes]:
    """Write a synthetic keystore in the backend's own format."""
    private = Ed25519PrivateKey.generate()
    seed = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    document = {
        "format": backend_keystore.KEY_STORE_FORMAT,
        "version": backend_keystore.KEY_STORE_VERSION,
        "keys": {
            key_id: {
                "created_at": "2026-01-01T00:00:00+00:00",
                "label": "synthetic-test-key",
                "private": base64.b64encode(seed).decode("ascii"),
                "public": base64.b64encode(public).decode("ascii"),
            }
        },
    }
    path = directory / backend_keystore.KEY_STORE_NAME
    path.write_text(json.dumps(document, indent=2), encoding="utf-8")
    return path, seed


def _run(key_dir: Path, out: Path, key_id: str = KEY_ID) -> int:
    return exporter.main(
        ["--key-dir", str(key_dir), "--key-id", key_id, "--out", str(out)]
    )


def test_export_writes_exactly_the_runtime_format(key_dir, tmp_path, capsys):
    keystore_path, seed = _write_keystore(key_dir)
    out = tmp_path / "runtime" / SECRET_NAME
    out.parent.mkdir()

    assert _run(key_dir, out) == 0

    document = json.loads(out.read_text(encoding="utf-8"))
    assert set(document) == {"key_id", "seed_b64"}
    assert document["key_id"] == KEY_ID
    assert base64.b64decode(document["seed_b64"], validate=True) == seed

    captured = capsys.readouterr()
    encoded = base64.b64encode(seed).decode("ascii")
    for stream in (captured.out, captured.err):
        assert encoded not in stream
        assert seed.hex() not in stream
    assert KEY_ID in captured.out
    assert "source keystore unchanged: yes" in captured.out
    assert keystore_path.exists()


def test_missing_keystore_is_refused(key_dir, tmp_path, capsys):
    out = tmp_path / SECRET_NAME
    out.parent.mkdir(exist_ok=True)

    assert _run(key_dir, out) == 2

    assert not out.exists()
    assert list(key_dir.iterdir()) == []
    assert "error:" in capsys.readouterr().err


def test_missing_key_id_is_refused(key_dir, tmp_path, capsys):
    keystore_path, _ = _write_keystore(key_dir, key_id=OTHER_KEY_ID)
    before = keystore_path.read_bytes()
    out = tmp_path / SECRET_NAME

    assert _run(key_dir, out) == 2

    assert not out.exists()
    assert keystore_path.read_bytes() == before
    assert "error:" in capsys.readouterr().err


def test_existing_output_file_is_refused(key_dir, tmp_path, capsys):
    keystore_path, _ = _write_keystore(key_dir)
    before = keystore_path.read_bytes()
    out = tmp_path / SECRET_NAME
    out.write_bytes(b"do not touch\n")

    assert _run(key_dir, out) == 2

    assert out.read_bytes() == b"do not touch\n"
    assert keystore_path.read_bytes() == before
    assert "error:" in capsys.readouterr().err


def test_success_preserves_the_original_keystore(key_dir, tmp_path):
    keystore_path, _ = _write_keystore(key_dir)
    original = keystore_path.read_bytes()
    before = keystore_path.stat()
    out = tmp_path / SECRET_NAME

    assert _run(key_dir, out) == 0

    after = keystore_path.stat()
    assert keystore_path.read_bytes() == original
    assert after.st_size == before.st_size
    assert after.st_mtime_ns == before.st_mtime_ns


@pytest.mark.parametrize(
    "document",
    [
        {"key_id": KEY_ID},  # missing seed_b64
        {"seed_b64": base64.b64encode(b"\x01" * 32).decode("ascii")},  # missing key_id
        {
            "key_id": KEY_ID,
            "seed_b64": base64.b64encode(b"\x01" * 32).decode("ascii"),
            "extra": 1,
        },
        {
            "key_id": OTHER_KEY_ID,
            "seed_b64": base64.b64encode(b"\x01" * 32).decode("ascii"),
        },
        {"key_id": KEY_ID, "seed_b64": "not-base64!!"},
        {
            "key_id": KEY_ID,
            "seed_b64": base64.b64encode(b"\x01" * 31).decode("ascii"),
        },
        {"key_id": KEY_ID, "seed_b64": 42},
    ],
)
def test_written_file_validation_rejects_malformed_output(tmp_path, document):
    out = tmp_path / SECRET_NAME
    out.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(exporter.ExportError):
        exporter._validate_output_file(out, KEY_ID)


def test_output_inside_the_project_is_refused(tmp_path):
    inside = SERVICE_ROOT / "tests" / "never-created.json"

    with pytest.raises(exporter.ExportError):
        exporter._guard_output(inside)

    assert not inside.exists()


def test_output_inside_a_git_work_tree_is_refused(tmp_path):
    work_tree = tmp_path / "checkout"
    (work_tree / ".git").mkdir(parents=True)

    with pytest.raises(exporter.ExportError):
        exporter._guard_output(work_tree / SECRET_NAME)
