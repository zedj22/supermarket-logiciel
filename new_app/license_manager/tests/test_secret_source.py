"""File-backed runtime secrets (Phase 8.3.2).

Render has no Secret Manager, and Firebase Spark does not provide one, so the
signing seed and the activation-code key can be mounted as read-only files.
These tests pin the safety properties of that backend: it reads only inside its
directory, it refuses names that are paths, symlinks and escapes, it fails
closed on missing/empty/unreadable material, and it never falls back to
environment values.

Every fixture writes throwaway material into ``tmp_path``. No real key is
generated, read or printed, and no assertion depends on a secret value.
"""

from __future__ import annotations

import base64
import json
import os
import stat
from pathlib import Path

import pytest

from service.container import _secret_fetcher, load_code_cipher, load_issuer_factory
from service.crypto import ActivationCodeCipher
from service.errors import SigningKeyError
from service.secrets import (
    EnvironmentSecretFetcher,
    FileSecretFetcher,
    SecretManagerFetcher,
    StaticSecretFetcher,
)
from service.settings import Settings
from service.signing import load_signing_key

SIGNING_NAME = "LICENSE_API_SIGNING_SECRET"
ENC_NAME = "LICENSE_API_CODE_ENC_SECRET"


def _write(directory: Path, name: str, payload: str) -> Path:
    path = directory / name
    path.write_text(payload, encoding="utf-8")
    return path


def _signing_payload(owner_key) -> str:
    key_id, seed, _ = owner_key
    return json.dumps({"key_id": key_id, "seed_b64": base64.b64encode(seed).decode()})


class _StubSecretManager:
    """Stands in for the Cloud SDK so no network client is constructed."""

    def __init__(self, project_id: str) -> None:
        self.project_id = project_id

    def fetch(self, name: str, version: str = "latest") -> str:  # pragma: no cover
        raise AssertionError("the stub is never called")


@pytest.fixture
def secret_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "secrets"
    directory.mkdir()
    return directory


@pytest.fixture
def production_file_settings(secret_dir: Path, keys_file: Path) -> Settings:
    return Settings(
        env="production",
        firebase_project_id="demo-project",
        admin_uids=frozenset({"admin-uid"}),
        secret_source="file",
        secret_dir=str(secret_dir),
        signing_secret_name=SIGNING_NAME,
        code_encryption_secret_name=ENC_NAME,
        verification_keys_file=str(keys_file),
    )


# --------------------------------------------------------------------------- #
# Happy paths
# --------------------------------------------------------------------------- #


def test_a_valid_file_backed_signing_secret_loads(secret_dir, owner_key):
    _write(secret_dir, SIGNING_NAME, _signing_payload(owner_key))

    fetcher = FileSecretFetcher(secret_dir)
    key = load_signing_key(fetcher.fetch(SIGNING_NAME))

    key_id, _, public = owner_key
    assert key.key_id == key_id
    assert key.public == public
    # The fetcher never holds or echoes secret material.
    assert key_id not in repr(fetcher)


def test_a_valid_file_backed_encryption_secret_loads(secret_dir):
    material = base64.b64encode(bytes(range(32))).decode()
    _write(secret_dir, ENC_NAME, material)

    cipher = ActivationCodeCipher.from_base64(FileSecretFetcher(secret_dir).fetch(ENC_NAME))
    sealed = cipher.seal(license_id="LIC-1", code="SMP1.AAAA.BBBB")
    assert cipher.open(license_id="LIC-1", envelope=sealed) == "SMP1.AAAA.BBBB"


def test_a_trailing_newline_from_a_mounted_file_is_tolerated(secret_dir):
    _write(secret_dir, ENC_NAME, base64.b64encode(b"\x07" * 32).decode() + "\r\n")
    payload = FileSecretFetcher(secret_dir).fetch(ENC_NAME)
    assert payload.endswith("=") or "=" not in payload
    assert "\n" not in payload and "\r" not in payload
    ActivationCodeCipher.from_base64(payload)


def test_the_production_file_backend_wires_both_consumers(secret_dir, owner_key, keys_file):
    _write(secret_dir, SIGNING_NAME, _signing_payload(owner_key))
    _write(secret_dir, ENC_NAME, base64.b64encode(b"\x03" * 32).decode())
    settings = Settings(
        env="production",
        firebase_project_id="demo-project",
        secret_source="file",
        secret_dir=str(secret_dir),
        signing_secret_name=SIGNING_NAME,
        code_encryption_secret_name=ENC_NAME,
        verification_keys_file=str(keys_file),
    )

    cipher = load_code_cipher(settings)
    assert cipher.open(license_id="x", envelope=cipher.seal(license_id="x", code="C")) == "C"

    issuer_factory = load_issuer_factory(settings)
    key_id, _, _ = owner_key
    assert issuer_factory().key_id == key_id


# --------------------------------------------------------------------------- #
# Fail-closed paths
# --------------------------------------------------------------------------- #


def test_a_missing_secret_file_fails_closed(secret_dir):
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(SIGNING_NAME)


@pytest.mark.parametrize("payload", ["", "\n", "   \r\n"])
def test_an_empty_secret_file_fails_closed(secret_dir, payload):
    _write(secret_dir, ENC_NAME, payload)
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(ENC_NAME)


def test_a_missing_secret_directory_fails_closed(tmp_path):
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(tmp_path / "does-not-exist")


def test_an_empty_secret_directory_setting_fails_closed():
    with pytest.raises(SigningKeyError):
        FileSecretFetcher("")


def test_a_file_instead_of_a_directory_fails_closed(tmp_path):
    path = tmp_path / "not-a-dir"
    path.write_text("x", encoding="utf-8")
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(path)


def test_a_directory_named_like_a_secret_fails_closed(secret_dir):
    (secret_dir / ENC_NAME).mkdir()
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(ENC_NAME)


@pytest.mark.parametrize(
    "name",
    [
        "../outside",
        "..\\outside",
        "nested/SIGNING",
        "nested\\SIGNING",
        "..",
        ".",
        ".hidden",
        "",
        "   ",
    ],
)
def test_path_traversal_and_relative_names_are_refused(secret_dir, name):
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(name)


def test_an_absolute_path_is_refused(secret_dir, tmp_path):
    absolute = tmp_path / "elsewhere" / SIGNING_NAME
    absolute.parent.mkdir()
    absolute.write_text(_signing_payload(("key", b"\x00" * 32, b"")), encoding="utf-8")

    fetcher = FileSecretFetcher(secret_dir)
    with pytest.raises(SigningKeyError):
        fetcher.fetch(str(absolute))
    # A Windows drive-relative/absolute form is a path too, not a file name.
    with pytest.raises(SigningKeyError):
        fetcher.fetch("C:\\Windows\\win.ini")


def test_a_symlink_escape_is_refused(secret_dir, tmp_path):
    outside = tmp_path / "outside-secret"
    outside.write_text(_signing_payload(("key", b"\x01" * 32, b"")), encoding="utf-8")
    link = secret_dir / SIGNING_NAME
    try:
        os.symlink(outside, link)
    except (OSError, NotImplementedError):  # pragma: no cover - Windows privileges
        pytest.skip("this host cannot create symlinks")

    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(SIGNING_NAME)


@pytest.mark.skipif(os.name == "nt", reason="POSIX permission bits")
def test_an_unreadable_secret_file_fails_closed(secret_dir):
    path = _write(secret_dir, ENC_NAME, base64.b64encode(b"\x04" * 32).decode())
    path.chmod(0o000)
    try:
        with pytest.raises(SigningKeyError):
            FileSecretFetcher(secret_dir).fetch(ENC_NAME)
    finally:
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def test_a_non_utf8_secret_file_fails_closed(secret_dir):
    (secret_dir / ENC_NAME).write_bytes(b"\xff\xfe\x00binary")
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(ENC_NAME)


def test_an_oversized_secret_file_fails_closed(secret_dir):
    _write(secret_dir, ENC_NAME, "A" * (64 * 1024 + 2))
    with pytest.raises(SigningKeyError):
        FileSecretFetcher(secret_dir).fetch(ENC_NAME)


def test_an_invalid_secret_payload_fails_closed(secret_dir):
    _write(secret_dir, SIGNING_NAME, "{not json")
    payload = FileSecretFetcher(secret_dir).fetch(SIGNING_NAME)
    with pytest.raises(SigningKeyError):
        load_signing_key(payload)


def test_the_file_backend_never_falls_back_to_environment_values(
    secret_dir, monkeypatch
):
    # Environment values exist for the very same names, and must be ignored:
    # a missing mount is a configuration failure, not an invitation to guess.
    monkeypatch.setenv(SIGNING_NAME, _signing_payload(("key", b"\x05" * 32, b"")))
    monkeypatch.setenv(ENC_NAME, base64.b64encode(b"\x06" * 32).decode())

    fetcher = FileSecretFetcher(secret_dir)
    with pytest.raises(SigningKeyError):
        fetcher.fetch(SIGNING_NAME)


# --------------------------------------------------------------------------- #
# Settings and backend selection
# --------------------------------------------------------------------------- #


def test_the_default_secret_source_is_secret_manager():
    settings = Settings(env="testing")
    assert settings.secret_source == "secretmanager"
    assert settings.uses_secret_manager is True
    assert settings.secret_dir_path is None


def test_an_unknown_secret_source_is_refused():
    with pytest.raises(ValueError):
        Settings(env="testing", secret_source="vault")


def test_the_file_source_requires_a_directory():
    with pytest.raises(ValueError):
        Settings(env="testing", secret_source="file")


def test_settings_read_the_secret_source_variables():
    settings = Settings.from_env(
        {
            "LICENSE_API_ENV": "testing",
            "LICENSE_API_SECRET_SOURCE": " FILE ",
            "LICENSE_API_SECRET_DIR": " /run/secrets ",
        }
    )
    assert settings.secret_source == "file"
    assert settings.secret_dir == "/run/secrets"
    assert settings.secret_dir_path is not None


def test_production_still_requires_secret_names_with_the_file_source(tmp_path):
    with pytest.raises(ValueError):
        Settings(
            env="production",
            firebase_project_id="demo",
            secret_source="file",
            secret_dir=str(tmp_path),
            verification_keys_file=str(tmp_path / "keys.json"),
        )


def test_production_still_refuses_development_key_material_with_files(
    secret_dir, tmp_path
):
    with pytest.raises(ValueError):
        Settings(
            env="production",
            firebase_project_id="demo",
            secret_source="file",
            secret_dir=str(secret_dir),
            signing_secret_name=SIGNING_NAME,
            code_encryption_secret_name=ENC_NAME,
            dev_signing_seed_b64=base64.b64encode(b"\x00" * 32).decode(),
            verification_keys_file=str(tmp_path / "keys.json"),
        )


def test_production_still_refuses_the_auth_emulator_with_files(
    secret_dir, tmp_path, monkeypatch
):
    monkeypatch.setenv("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
    from service.auth import FirebaseTokenVerifier

    with pytest.raises(SigningKeyError):
        FirebaseTokenVerifier("demo", env="production", app_check_audience="")


def test_production_still_refuses_the_firestore_emulator_with_files(
    secret_dir, tmp_path, monkeypatch
):
    from service.errors import StoreUnavailableError
    from service.firestore_repository import FirestoreLicenseRepository

    monkeypatch.setenv("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8081")
    with pytest.raises(StoreUnavailableError):
        FirestoreLicenseRepository.connect(None, env="production")


def test_the_container_uses_secret_manager_by_default_in_production(
    monkeypatch,
):
    monkeypatch.setattr("service.container.SecretManagerFetcher", _StubSecretManager)
    settings = Settings(
        env="production",
        firebase_project_id="demo-project",
        signing_secret_name=SIGNING_NAME,
        code_encryption_secret_name=ENC_NAME,
    )
    fetcher = _secret_fetcher(settings, {})
    assert isinstance(fetcher, _StubSecretManager)
    assert fetcher.project_id == "demo-project"


def test_the_container_uses_mounted_files_for_the_file_source(production_file_settings):
    fetcher = _secret_fetcher(production_file_settings, {})
    assert isinstance(fetcher, FileSecretFetcher)
    assert fetcher.directory == Path(production_file_settings.secret_dir).resolve()


def test_development_values_are_not_used_when_files_are_requested(
    secret_dir, tmp_path
):
    settings = Settings(
        env="development",
        secret_source="file",
        secret_dir=str(secret_dir),
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    fetcher = _secret_fetcher(settings, {SIGNING_NAME: "from-environment"})
    assert isinstance(fetcher, FileSecretFetcher)


def test_development_still_uses_environment_values(secret_dir, tmp_path):
    settings = Settings(
        env="development",
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    fetcher = _secret_fetcher(settings, {SIGNING_NAME: "from-environment"})
    assert isinstance(fetcher, EnvironmentSecretFetcher)
    assert fetcher.fetch(SIGNING_NAME) == "from-environment"


def test_secret_manager_behaviour_is_unchanged(monkeypatch):
    """The Cloud Run path is still the Cloud SDK client, by name and version."""
    monkeypatch.setattr("service.container.SecretManagerFetcher", _StubSecretManager)
    settings = Settings(
        env="production",
        firebase_project_id="prod-project",
        signing_secret_name=SIGNING_NAME,
        code_encryption_secret_name=ENC_NAME,
    )
    assert isinstance(_secret_fetcher(settings, {}), _StubSecretManager)
    assert SecretManagerFetcher is not _StubSecretManager  # the real class is intact


def test_a_static_fetcher_is_never_selected_by_the_container(secret_dir, tmp_path):
    settings = Settings(
        env="development",
        secret_source="file",
        secret_dir=str(secret_dir),
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    assert not isinstance(_secret_fetcher(settings, {}), StaticSecretFetcher)
