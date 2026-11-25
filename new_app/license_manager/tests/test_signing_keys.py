"""Signing material, secret handling and at-rest code encryption."""

from __future__ import annotations

import base64
import json

import pytest

from service import shared
from service.container import load_code_cipher
from service.crypto import ActivationCodeCipher
from service.errors import SigningKeyError
from service.secrets import (
    EnvironmentSecretFetcher,
    SecretManagerFetcher,
    StaticSecretFetcher,
)
from service.settings import Settings
from service.signing import LicenseIssuer, SigningKey, load_signing_key
from testkit import HW_A


def _secret(key_id: str, seed: bytes) -> str:
    return json.dumps({"key_id": key_id, "seed_b64": base64.b64encode(seed).decode()})


# --------------------------------------------------------------------------- #
# Key loading
# --------------------------------------------------------------------------- #


def test_a_valid_signing_secret_loads(owner_key):
    key_id, seed, public = owner_key
    key = load_signing_key(_secret(key_id, seed))
    assert key.key_id == key_id
    assert key.public == public
    assert seed.hex() not in repr(key)  # no key material in a repr/log line


@pytest.mark.parametrize(
    "payload",
    [
        "not json",
        "[]",
        json.dumps({"key_id": "k1"}),
        json.dumps({"key_id": "k1", "seed_b64": "AAAA", "extra": 1}),
        json.dumps({"key_id": "bad id", "seed_b64": base64.b64encode(b"x" * 32).decode()}),
        json.dumps({"key_id": "k1", "seed_b64": "not-base64!!"}),
        json.dumps({"key_id": "k1", "seed_b64": base64.b64encode(b"short").decode()}),
        json.dumps({"key_id": "k1", "seed_b64": 42}),
    ],
)
def test_bad_signing_secrets_are_refused(payload):
    with pytest.raises(SigningKeyError):
        load_signing_key(payload)


def test_a_seed_of_the_wrong_length_is_refused():
    with pytest.raises(SigningKeyError):
        SigningKey.from_seed("k1", b"\x00" * 31)


def test_an_invalid_key_id_is_refused():
    with pytest.raises(SigningKeyError):
        SigningKey.from_seed("-bad", b"\x00" * 32)


def test_a_missing_secret_is_a_controlled_error():
    fetcher = StaticSecretFetcher({})
    with pytest.raises(SigningKeyError):
        fetcher.fetch("absent")


def test_environment_secrets_are_refused_in_production():
    with pytest.raises(SigningKeyError):
        EnvironmentSecretFetcher({"X": "1"}, env="production")


def test_secret_manager_reports_a_missing_sdk():
    try:
        import google.cloud.secretmanager  # noqa: F401
    except ImportError:
        pass
    else:  # pragma: no cover - only when the SDK is installed
        pytest.skip("google-cloud-secret-manager is installed")
    with pytest.raises(SigningKeyError):
        SecretManagerFetcher("demo-project")


def test_secret_manager_rejects_an_empty_project():
    with pytest.raises(SigningKeyError):
        SecretManagerFetcher("")


# --------------------------------------------------------------------------- #
# Settings guards
# --------------------------------------------------------------------------- #


def test_production_refuses_development_key_material(tmp_path):
    with pytest.raises(ValueError):
        Settings(
            env="production",
            firebase_project_id="demo",
            signing_secret_name="s",
            code_encryption_secret_name="c",
            dev_signing_seed_b64=base64.b64encode(b"\x00" * 32).decode(),
            verification_keys_file=str(tmp_path / "keys.json"),
        )


def test_production_requires_a_project_and_secret_names(tmp_path):
    with pytest.raises(ValueError):
        Settings(env="production", verification_keys_file=str(tmp_path / "keys.json"))
    with pytest.raises(ValueError):
        Settings(env="production", firebase_project_id="demo")


def test_an_unknown_environment_is_refused():
    with pytest.raises(ValueError):
        Settings(env="staging")


def test_settings_read_the_documented_variables():
    settings = Settings.from_env(
        {
            "LICENSE_API_ENV": "testing",
            "LICENSE_API_ADMIN_UIDS": "a, b ,c",
            "LICENSE_API_ADMIN_EMAILS": "Admin@Example.com",
            "LICENSE_API_REQUIRE_APP_CHECK": "true",
            "LICENSE_API_RATE_LIMIT_PER_MINUTE": "10",
            "LICENSE_API_MAX_BODY_BYTES": "4096",
        }
    )
    assert settings.admin_uids == frozenset({"a", "b", "c"})
    assert settings.admin_emails == frozenset({"admin@example.com"})
    assert settings.require_app_check is True
    assert settings.rate_limit_per_minute == 10
    assert settings.max_body_bytes == 4096


# --------------------------------------------------------------------------- #
# Issuer guards
# --------------------------------------------------------------------------- #


def test_the_issuer_refuses_a_key_the_package_does_not_ship(signing_key):
    issuer = LicenseIssuer(key=signing_key, verification_keys={})
    assert issuer.is_published() is False
    from service.errors import SigningKeyNotPublishedError

    with pytest.raises(SigningKeyNotPublishedError):
        issuer.issue(hw_hash=HW_A)


def test_the_issuer_refuses_an_invalid_fingerprint(signing_key, keys_file):
    issuer = LicenseIssuer(
        key=signing_key,
        verification_keys=shared.load_customer_verification_keys(str(keys_file)),
    )
    from service.errors import ValidationFailedError

    with pytest.raises(ValidationFailedError):
        issuer.issue(hw_hash="NOT-A-HASH")


def test_an_issued_code_passes_both_self_checks(signing_key, keys_file):
    keys = shared.load_customer_verification_keys(str(keys_file))
    issuer = LicenseIssuer(key=signing_key, verification_keys=keys)
    assert issuer.is_published() is True
    issued = issuer.issue(hw_hash=HW_A)
    assert issued.key_id == signing_key.key_id
    assert shared.verify_activation_code(
        issued.code, keys=keys, expected_hw_hash=HW_A
    ).license_id == issued.license_id


# --------------------------------------------------------------------------- #
# Activation-code encryption at rest
# --------------------------------------------------------------------------- #


def test_a_code_round_trips_through_the_sealed_envelope(cipher):
    sealed = cipher.seal(license_id="LIC-1", code="SMP1.AAAA.BBBB")
    assert sealed.startswith("gcm1:")
    assert "SMP1" not in sealed
    assert cipher.open(license_id="LIC-1", envelope=sealed) == "SMP1.AAAA.BBBB"


def test_a_sealed_code_cannot_be_moved_to_another_license(cipher):
    sealed = cipher.seal(license_id="LIC-1", code="SMP1.AAAA.BBBB")
    with pytest.raises(SigningKeyError):
        cipher.open(license_id="LIC-2", envelope=sealed)


def test_a_tampered_envelope_is_refused(cipher):
    sealed = cipher.seal(license_id="LIC-1", code="SMP1.AAAA.BBBB")
    version, nonce, payload = sealed.split(":")
    tampered = ":".join((version, nonce, payload[:-4] + "AAAA"))
    with pytest.raises(SigningKeyError):
        cipher.open(license_id="LIC-1", envelope=tampered)


@pytest.mark.parametrize("envelope", ["", "plaintext", "v9:aa:bb", "gcm1:!!:!!"])
def test_malformed_envelopes_are_refused(cipher, envelope):
    with pytest.raises(SigningKeyError):
        cipher.open(license_id="LIC-1", envelope=envelope)


def test_the_encryption_key_must_be_32_bytes():
    with pytest.raises(SigningKeyError):
        ActivationCodeCipher(b"\x00" * 16)
    with pytest.raises(SigningKeyError):
        ActivationCodeCipher.from_base64("bm90LWEta2V5")


def test_a_different_key_cannot_open_a_previous_envelope(cipher):
    sealed = cipher.seal(license_id="LIC-1", code="SMP1.AAAA.BBBB")
    other = ActivationCodeCipher(b"\x01" * 32)
    with pytest.raises(SigningKeyError):
        other.open(license_id="LIC-1", envelope=sealed)


def test_the_development_encryption_key_is_used_when_configured(tmp_path):
    key = base64.b64encode(b"\x02" * 32).decode()
    settings = Settings(
        env="testing",
        dev_code_encryption_key_b64=key,
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    cipher = load_code_cipher(settings)
    assert cipher.open(license_id="x", envelope=cipher.seal(license_id="x", code="C")) == "C"


def test_no_configured_encryption_key_is_a_controlled_error(tmp_path):
    settings = Settings(env="testing", verification_keys_file=str(tmp_path / "keys.json"))
    with pytest.raises(SigningKeyError):
        load_code_cipher(settings)
