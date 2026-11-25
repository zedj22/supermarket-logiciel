"""Staging AES-256-GCM integration (Phase 8.4.5).

The activation code at rest is sealed with AES-256-GCM (`service/crypto.py`);
the key is the ``LICENSE_API_CODE_ENC_SECRET`` secret, read on Render by
``FileSecretFetcher`` from a mounted file.  These tests pin the properties the
staging deployment depends on:

* a test code round-trips;
* every seal uses a fresh 12-byte nonce (no ciphertext repetition);
* a changed ciphertext **or** authentication tag is refused;
* the key must decode to exactly 32 bytes, and missing/invalid material fails
  closed with a message that carries no key byte;
* the file backend reads the deployment's own external secret directory when
  one is supplied (``KLICKPOS_STAGING_KEYS_DIR``; skipped otherwise);
* production still selects Secret Manager, by default, unchanged.

No real key material is printed, compared to a literal, or asserted on.  The
external-directory test only proves the value loads and round-trips.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path

import pytest

from service.container import load_code_cipher
from service.crypto import CIPHER_VERSION, ActivationCodeCipher
from service.errors import SigningKeyError
from service.secrets import FileSecretFetcher
from service.settings import Settings

ENC_NAME = "LICENSE_API_CODE_ENC_SECRET"
SIGNING_NAME = "LICENSE_API_SIGNING_SECRET"
CODE = "SMP1.TESTPAYLOAD.SIGNATURE"

#: Optional real staging secret directory (never a value, only a location).
EXTERNAL_KEYS_DIR = os.environ.get("KLICKPOS_STAGING_KEYS_DIR", "")


def _key(marker: int = 0x2A) -> bytes:
    """A throwaway 32-byte key for one test."""
    return bytes([marker]) * 32


def _envelope_parts(envelope: str) -> tuple[str, bytes, bytes]:
    version, nonce_b64, sealed_b64 = envelope.split(":", 2)
    return (
        version,
        base64.b64decode(nonce_b64, validate=True),
        base64.b64decode(sealed_b64, validate=True),
    )


def _rebuild(nonce: bytes, sealed: bytes) -> str:
    return ":".join(
        (
            CIPHER_VERSION,
            base64.b64encode(nonce).decode("ascii"),
            base64.b64encode(sealed).decode("ascii"),
        )
    )


def _settings(secret_dir: Path, **overrides) -> Settings:
    values: dict[str, object] = {
        "env": "production",
        "firebase_project_id": "demo-staging",
        "secret_source": "file",
        "secret_dir": str(secret_dir),
        "signing_secret_name": SIGNING_NAME,
        "code_encryption_secret_name": ENC_NAME,
    }
    values.update(overrides)
    return Settings(**values)


def _write_secret(directory: Path, payload: str) -> Path:
    path = directory / ENC_NAME
    path.write_text(payload, encoding="utf-8")
    return path


# --------------------------------------------------------------------------- #
# 1. Round trip
# --------------------------------------------------------------------------- #


def test_an_activation_code_round_trips_through_aes_gcm():
    cipher = ActivationCodeCipher(_key())

    sealed = cipher.seal(license_id="LIC-1", code=CODE)

    assert CODE not in sealed
    assert cipher.open(license_id="LIC-1", envelope=sealed) == CODE


def test_the_envelope_carries_a_12_byte_nonce_and_authenticated_payload():
    cipher = ActivationCodeCipher(_key())
    version, nonce, sealed = _envelope_parts(
        cipher.seal(license_id="LIC-1", code=CODE)
    )

    assert version == CIPHER_VERSION == "gcm1"
    assert len(nonce) == 12
    # AES-GCM appends a 16-byte tag to the ciphertext.
    assert len(sealed) == len(CODE.encode()) + 16


# --------------------------------------------------------------------------- #
# 2. Fresh nonce per encryption
# --------------------------------------------------------------------------- #


def test_repeated_encryption_uses_a_new_nonce_and_a_new_ciphertext():
    cipher = ActivationCodeCipher(_key())

    first = cipher.seal(license_id="LIC-1", code=CODE)
    second = cipher.seal(license_id="LIC-1", code=CODE)
    _, nonce_a, sealed_a = _envelope_parts(first)
    _, nonce_b, sealed_b = _envelope_parts(second)

    assert first != second
    assert nonce_a != nonce_b
    assert sealed_a != sealed_b
    assert cipher.open(license_id="LIC-1", envelope=first) == CODE
    assert cipher.open(license_id="LIC-1", envelope=second) == CODE


# --------------------------------------------------------------------------- #
# 3 and 4. Tampering: ciphertext and authentication tag
# --------------------------------------------------------------------------- #


def test_a_modified_ciphertext_is_rejected():
    cipher = ActivationCodeCipher(_key())
    nonce, sealed = _envelope_parts(cipher.seal(license_id="LIC-1", code=CODE))[1:]
    corrupted = bytes([sealed[0] ^ 0x01]) + sealed[1:]

    with pytest.raises(SigningKeyError, match="could not be decrypted"):
        cipher.open(license_id="LIC-1", envelope=_rebuild(nonce, corrupted))


def test_a_modified_authentication_tag_is_rejected():
    cipher = ActivationCodeCipher(_key())
    nonce, sealed = _envelope_parts(cipher.seal(license_id="LIC-1", code=CODE))[1:]
    # The tag is the final 16 bytes; flip the last one only.
    corrupted = sealed[:-1] + bytes([sealed[-1] ^ 0x80])

    with pytest.raises(SigningKeyError, match="could not be decrypted"):
        cipher.open(license_id="LIC-1", envelope=_rebuild(nonce, corrupted))


def test_a_code_bound_to_another_license_is_rejected():
    cipher = ActivationCodeCipher(_key())
    sealed = cipher.seal(license_id="LIC-1", code=CODE)

    with pytest.raises(SigningKeyError, match="could not be decrypted"):
        cipher.open(license_id="LIC-2", envelope=sealed)


# --------------------------------------------------------------------------- #
# 5. Key length
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize("length", [0, 16, 24, 31, 33, 64])
def test_a_key_of_the_wrong_length_is_rejected(length):
    with pytest.raises(SigningKeyError, match="exactly 32 bytes"):
        ActivationCodeCipher(b"\x07" * length)


def test_a_base64_key_that_decodes_to_the_wrong_length_is_rejected():
    with pytest.raises(SigningKeyError, match="exactly 32 bytes"):
        ActivationCodeCipher.from_base64(base64.b64encode(b"\x07" * 31).decode())


# --------------------------------------------------------------------------- #
# 6 and 7. Missing and malformed material through the file backend
# --------------------------------------------------------------------------- #


def test_a_missing_secret_file_fails_safely(tmp_path):
    with pytest.raises(SigningKeyError, match="missing"):
        load_code_cipher(_settings(tmp_path))


def test_an_invalid_base64_secret_fails_safely(tmp_path):
    _write_secret(tmp_path, "not-base64!!")

    with pytest.raises(SigningKeyError, match="not valid base64") as refused:
        load_code_cipher(_settings(tmp_path))
    assert "not-base64!!" not in str(refused.value)


def test_a_secret_of_the_wrong_length_fails_safely(tmp_path):
    _write_secret(tmp_path, base64.b64encode(b"\x08" * 31).decode())

    with pytest.raises(SigningKeyError, match="exactly 32 bytes"):
        load_code_cipher(_settings(tmp_path))


def test_a_valid_mounted_secret_round_trips(tmp_path):
    _write_secret(tmp_path, base64.b64encode(_key()).decode())

    cipher = load_code_cipher(_settings(tmp_path))
    assert cipher.open(license_id="x", envelope=cipher.seal(license_id="x", code=CODE)) == CODE


# --------------------------------------------------------------------------- #
# 8. No secret material in messages or logs
# --------------------------------------------------------------------------- #


def test_no_key_material_reaches_a_message_or_a_log(tmp_path, caplog):
    material_b64 = base64.b64encode(b"\x09" * 24).decode()  # decodes to 24 bytes
    _write_secret(tmp_path, material_b64)

    with caplog.at_level("DEBUG"):
        with pytest.raises(SigningKeyError) as refused:
            load_code_cipher(_settings(tmp_path))

    message = str(refused.value)
    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert material_b64 not in message
    assert material_b64 not in logged
    assert b"\x09" * 24 not in str(refused.value).encode()


def test_an_invalid_base64_key_never_echoes_the_input():
    supplied = "AAAA" + "not-base64!!"
    with pytest.raises(SigningKeyError) as refused:
        ActivationCodeCipher.from_base64(supplied)
    assert supplied not in str(refused.value)


def test_a_cipher_never_renders_its_key(cipher):
    assert bytes(range(32)).hex() not in repr(cipher)
    assert base64.b64encode(bytes(range(32))).decode() not in repr(cipher)


# --------------------------------------------------------------------------- #
# 9. The deployment's external staging secret (opt-in, location only)
# --------------------------------------------------------------------------- #


@pytest.mark.skipif(
    not EXTERNAL_KEYS_DIR or not Path(EXTERNAL_KEYS_DIR).is_dir(),
    reason="KLICKPOS_STAGING_KEYS_DIR is not set to an existing directory",
)
def test_the_external_staging_secret_loads_through_file_secret_fetcher():
    directory = Path(EXTERNAL_KEYS_DIR)

    # Reads through the same class and rules the container uses on Render.
    payload = FileSecretFetcher(directory).fetch(ENC_NAME)
    cipher = ActivationCodeCipher.from_base64(payload)
    sealed = cipher.seal(license_id="staging-probe", code=CODE)

    assert CODE not in sealed
    assert cipher.open(license_id="staging-probe", envelope=sealed) == CODE
    # The same path must resolve through the container's own loader.
    settings = _settings(directory)
    assert load_code_cipher(settings).open(
        license_id="staging-probe", envelope=sealed
    ) == CODE


# --------------------------------------------------------------------------- #
# 10. Production secret loading is unchanged
# --------------------------------------------------------------------------- #


class _StubSecretManager:
    """Stands in for the Cloud SDK without constructing a network client."""

    instances: list[_StubSecretManager] = []

    def __init__(self, project_id: str) -> None:
        self.project_id = project_id
        self.used: list[tuple[str, str]] = []
        _StubSecretManager.instances.append(self)

    def fetch(self, name: str, version: str = "latest") -> str:
        self.used.append((name, version))
        return base64.b64encode(_key(0x0B)).decode()


def test_production_still_reads_the_encryption_key_from_secret_manager(
    monkeypatch, tmp_path
):
    _StubSecretManager.instances.clear()
    monkeypatch.setattr("service.container.SecretManagerFetcher", _StubSecretManager)
    settings = Settings(
        env="production",
        firebase_project_id="demo-project",
        signing_secret_name=SIGNING_NAME,
        code_encryption_secret_name=ENC_NAME,
        code_encryption_secret_version="7",
    )

    cipher = load_code_cipher(settings)

    assert len(_StubSecretManager.instances) == 1
    client = _StubSecretManager.instances[0]
    assert client.project_id == "demo-project"
    assert client.used == [(ENC_NAME, "7")]
    assert cipher.open(license_id="x", envelope=cipher.seal(license_id="x", code=CODE)) == CODE


def test_the_default_secret_source_is_still_secret_manager():
    settings = Settings(env="testing")

    assert settings.secret_source == "secretmanager"
    assert settings.uses_secret_manager is True
    assert settings.secret_dir_path is None
