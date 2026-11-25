"""Production signing-key startup validation (production hardening R3).

Production has no staging flags to lean on, so the Render startup check must
itself prove that the seed the issuer will sign with belongs to a key id the
shipped customer package publishes, and that the derived public half is the
published one. These tests drive the real script entry point (``main``) through
its environment-driven settings, and pin:

* a matching seed + registry starts the deploy;
* a missing, malformed, unpublished-id or mismatched registry fails it;
* no message carries a seed, a key byte or file content;
* staging keeps its own validation path, and a plain development run still
  needs no production keys at all.

Every keypair here is throwaway material generated inside the test. No real
staging or production key is read, derived, printed or written.
"""

from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HERE = Path(__file__).resolve().parents[1]
SCRIPT = HERE / "scripts" / "render_startup_check.py"

SIGNING_NAME = "LICENSE_API_SIGNING_SECRET"
ENC_NAME = "LICENSE_API_CODE_ENC_SECRET"
KEY_ID = "prod-test-signing"
STAGING_KEY_ID = "stg-test-startup"
LABEL = "production signing key is published"

#: Every variable the checks below may set; cleared before each run so a value
#: leaking in from the host environment cannot change the outcome.
_MANAGED_ENV = (
    "LICENSE_API_ENV",
    "LICENSE_API_FIREBASE_PROJECT_ID",
    "LICENSE_API_SECRET_SOURCE",
    "LICENSE_API_SECRET_DIR",
    "LICENSE_API_SIGNING_SECRET",
    "LICENSE_API_CODE_ENC_SECRET",
    "LICENSE_API_SIGNING_SECRET_VERSION",
    "LICENSE_API_CODE_ENC_SECRET_VERSION",
    "LICENSE_API_VERIFICATION_KEYS_FILE",
    "LICENSE_API_REQUIRE_STAGING_KEYS",
    "LICENSE_API_STAGING_KEY_ID",
    "LICENSE_API_REQUIRE_SIGNING_KEY_MATCH",
    "LICENSE_API_DEV_SIGNING_SEED_B64",
    "LICENSE_API_DEV_SIGNING_KEY_ID",
    "LICENSE_API_DEV_CODE_ENC_KEY_B64",
    "LICENSE_API_DEV_AUTH_UID",
    "LICENSE_API_ADMIN_UIDS",
    "LICENSE_API_ADMIN_EMAILS",
)


def _startup_check():
    """The Render startup script, loaded by path (it is not an importable package)."""
    spec = importlib.util.spec_from_file_location("render_startup_check_under_test", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _pair(key_id: str) -> tuple[str, bytes, bytes]:
    """A throwaway Ed25519 keypair: (key id, 32-byte seed, public half)."""
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
    return key_id, seed, public


def _b64(material: bytes) -> str:
    return base64.b64encode(material).decode("ascii")


def _secret_payload(key_id: str, seed: bytes) -> str:
    return json.dumps({"key_id": key_id, "seed_b64": _b64(seed)})


def _write_secret(secret_dir: Path, key_id: str, seed: bytes) -> Path:
    secret_dir.mkdir(exist_ok=True)
    path = secret_dir / SIGNING_NAME
    path.write_text(_secret_payload(key_id, seed), encoding="utf-8")
    return path


def _write_code_key(secret_dir: Path) -> None:
    secret_dir.mkdir(exist_ok=True)
    (secret_dir / ENC_NAME).write_text(_b64(bytes(range(32))), encoding="utf-8")


def _write_keys(path: Path, entries: dict[str, str]) -> Path:
    path.write_text(json.dumps(entries), encoding="utf-8")
    return path


def _apply_env(monkeypatch, values: dict[str, str]) -> None:
    for name in _MANAGED_ENV:
        monkeypatch.delenv(name, raising=False)
    for name, value in values.items():
        monkeypatch.setenv(name, value)


def _production_env(
    monkeypatch,
    tmp_path: Path,
    *,
    key_id: str = KEY_ID,
    published: dict[str, str] | None = None,
    keys_text: str | None = None,
    keys_name: str = "verification_keys.json",
    **overrides: str,
) -> tuple[Path, bytes]:
    """A production-shaped configuration; returns (keys path, seed)."""
    key_id, seed, public = _pair(key_id)
    secret_dir = tmp_path / "secrets"
    _write_secret(secret_dir, key_id, seed)
    _write_code_key(secret_dir)

    keys_file = tmp_path / keys_name
    if keys_text is not None:
        keys_file.write_text(keys_text, encoding="utf-8")
    else:
        _write_keys(keys_file, published if published is not None else {key_id: _b64(public)})

    values = {
        "LICENSE_API_ENV": "production",
        "LICENSE_API_FIREBASE_PROJECT_ID": "demo-production",
        "LICENSE_API_SECRET_SOURCE": "file",
        "LICENSE_API_SECRET_DIR": str(secret_dir),
        "LICENSE_API_SIGNING_SECRET": SIGNING_NAME,
        "LICENSE_API_CODE_ENC_SECRET": ENC_NAME,
        "LICENSE_API_VERIFICATION_KEYS_FILE": str(keys_file),
    }
    values.update(overrides)
    _apply_env(monkeypatch, values)
    return keys_file, seed


def _run(capsys) -> tuple[int, str]:
    status = _startup_check().main()
    captured = capsys.readouterr()
    return status, captured.out + captured.err


# --------------------------------------------------------------------------- #
# Passing material
# --------------------------------------------------------------------------- #


def test_a_published_matching_production_key_starts_the_deploy(monkeypatch, tmp_path, capsys):
    _production_env(monkeypatch, tmp_path)
    # No staging flag is involved: production is validated on its own.
    monkeypatch.delenv("LICENSE_API_REQUIRE_SIGNING_KEY_MATCH", raising=False)

    status, output = _run(capsys)

    assert status == 0
    assert f"[PASS] {LABEL} - key_id={KEY_ID}" in output
    assert "configuration is complete" in output


# --------------------------------------------------------------------------- #
# Failing material
# --------------------------------------------------------------------------- #


def test_a_missing_verification_keys_file_fails_closed(monkeypatch, tmp_path, capsys):
    keys_file, _ = _production_env(monkeypatch, tmp_path)
    keys_file.unlink()

    status, output = _run(capsys)

    assert status == 1
    assert f"[FAIL] {LABEL}" in output
    assert "refusing to start" in output


def test_a_malformed_verification_keys_file_fails_closed(monkeypatch, tmp_path, capsys):
    _production_env(monkeypatch, tmp_path, keys_text="{not-json")

    status, output = _run(capsys)

    assert status == 1
    assert f"[FAIL] {LABEL}" in output


def test_an_empty_registry_fails_closed(monkeypatch, tmp_path, capsys):
    _production_env(monkeypatch, tmp_path, published={})

    status, output = _run(capsys)

    assert status == 1
    assert f"[FAIL] {LABEL}" in output


def test_a_signing_key_id_absent_from_the_registry_fails_closed(
    monkeypatch, tmp_path, capsys
):
    _, _, other_public = _pair("someone-else")
    _production_env(monkeypatch, tmp_path, published={"someone-else": _b64(other_public)})

    status, output = _run(capsys)

    assert status == 1
    assert f"[FAIL] {LABEL}" in output


def test_a_public_key_mismatch_fails_closed(monkeypatch, tmp_path, capsys):
    # The registry publishes this key id, but with another keypair's public half.
    _, _, other_public = _pair(KEY_ID)
    _production_env(monkeypatch, tmp_path, published={KEY_ID: _b64(other_public)})

    status, output = _run(capsys)

    assert status == 1
    assert f"[FAIL] {LABEL}" in output


# --------------------------------------------------------------------------- #
# Secret safety
# --------------------------------------------------------------------------- #


def test_failure_messages_never_expose_secret_material(monkeypatch, tmp_path, capsys):
    _, _, other_public = _pair(KEY_ID)
    keys_file, seed = _production_env(
        monkeypatch, tmp_path, published={KEY_ID: _b64(other_public)}
    )

    status, output = _run(capsys)

    assert status == 1
    # Neither the seed, its base64 form, nor the secret document appears.
    assert seed.hex() not in output
    assert _b64(seed) not in output.lower().replace(" ", "")
    assert "seed_b64" not in output
    assert "private" not in output.lower()
    # Nor does the whole secret file content leak through the message.
    assert _secret_payload(KEY_ID, seed) not in output
    # The keys file is public material, but its raw content is not echoed either.
    assert keys_file.read_text(encoding="utf-8") not in output


def test_public_key_mismatch_mentions_only_the_public_key_id(monkeypatch, tmp_path, capsys):
    _, _, other_public = _pair(KEY_ID)
    _production_env(monkeypatch, tmp_path, published={KEY_ID: _b64(other_public)})

    _, output = _run(capsys)

    assert KEY_ID in output
    assert _b64(other_public) not in output


# --------------------------------------------------------------------------- #
# Staging and development are unchanged
# --------------------------------------------------------------------------- #


def test_staging_keeps_its_own_validation_path(monkeypatch, tmp_path, capsys):
    # A staging deployment: same production env, plus its own flags and file.
    _production_env(
        monkeypatch,
        tmp_path,
        key_id=STAGING_KEY_ID,
        keys_name="verification_keys.staging.json",
        LICENSE_API_REQUIRE_STAGING_KEYS="1",
        LICENSE_API_STAGING_KEY_ID=STAGING_KEY_ID,
        LICENSE_API_REQUIRE_SIGNING_KEY_MATCH="1",
    )

    status, output = _run(capsys)

    assert status == 0
    assert "[PASS] staging verification keys" in output
    assert "[PASS] signing seed matches the published key" in output
    # The production-only check does not run on a staging deployment.
    assert LABEL not in output


def test_development_starts_without_any_production_keys(monkeypatch, tmp_path, capsys):
    seed = _pair("dev-local")[1]
    _apply_env(
        monkeypatch,
        {
            "LICENSE_API_ENV": "development",
            "LICENSE_API_DEV_SIGNING_KEY_ID": "dev-local",
            "LICENSE_API_DEV_SIGNING_SEED_B64": _b64(seed),
            "LICENSE_API_DEV_CODE_ENC_KEY_B64": _b64(bytes(range(32))),
            "LICENSE_API_VERIFICATION_KEYS_FILE": str(tmp_path / "absent.json"),
        },
    )

    status, output = _run(capsys)

    assert status == 0
    assert LABEL not in output
    assert "configuration is complete" in output
