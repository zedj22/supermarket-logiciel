"""Production vs. emulator guards, and development-only key wiring.

These exist because the classic failure mode of a Firebase service is an
emulator variable (or a development signing seed) leaking into a production
deployment: auth would accept unsigned tokens, or licences would be written to
a database that only exists on a laptop.
"""

from __future__ import annotations

import base64

import pytest

from service.auth import FirebaseTokenVerifier
from service.container import _dev_signing_key
from service.errors import SigningKeyError, StoreUnavailableError
from service.firestore_repository import FirestoreLicenseRepository
from service.settings import Settings


def test_the_auth_emulator_is_refused_in_production(monkeypatch):
    monkeypatch.setenv("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
    with pytest.raises(SigningKeyError):
        FirebaseTokenVerifier("demo-project", env="production")


def test_the_auth_emulator_is_allowed_outside_production(monkeypatch):
    monkeypatch.setenv("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
    verifier = FirebaseTokenVerifier("demo-project", env="development")
    assert verifier is not None


def test_the_firestore_emulator_is_refused_in_production(monkeypatch):
    monkeypatch.setenv("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8081")
    with pytest.raises(StoreUnavailableError):
        FirestoreLicenseRepository.connect(None, env="production")


def test_the_firestore_emulator_is_allowed_outside_production(monkeypatch):
    monkeypatch.setenv("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8081")
    try:
        FirestoreLicenseRepository.connect(None, env="development")
    except StoreUnavailableError as exc:
        # Only acceptable reason here: the SDK is not installed in this venv.
        assert "not installed" in str(exc)
    except Exception as exc:  # noqa: BLE001
        pytest.fail(f"unexpected error type: {type(exc).__name__}")


def test_the_development_signing_key_id_is_configurable(tmp_path):
    settings = Settings(
        env="testing",
        dev_signing_seed_b64=base64.b64encode(b"\x05" * 32).decode(),
        dev_signing_key_id="local-qa",
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    assert _dev_signing_key(settings).key_id == "local-qa"


def test_the_default_development_key_id_is_used_when_unset(tmp_path):
    settings = Settings(
        env="testing",
        dev_signing_seed_b64=base64.b64encode(b"\x06" * 32).decode(),
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    assert _dev_signing_key(settings).key_id == "dev-local"


def test_production_still_rejects_development_signing_material(tmp_path):
    with pytest.raises(ValueError):
        Settings(
            env="production",
            firebase_project_id="demo",
            signing_secret_name="s",
            code_encryption_secret_name="c",
            dev_signing_seed_b64=base64.b64encode(b"\x00" * 32).decode(),
            verification_keys_file=str(tmp_path / "keys.json"),
        )
