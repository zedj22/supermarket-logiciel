"""Staging signing seed ↔ published public key match (Phase 8.4.4).

The staging keys file proves which *public* key the client will trust; it says
nothing about the *private* seed the API will sign with.  These tests pin the
opt-in startup guard that compares the two: match, mismatch, missing or
malformed material, the disabled-by-default behaviour, and that no secret byte
ever reaches a message or a log record.

Every keypair here is throwaway material generated inside the test.  No real
staging or production key is read, derived or printed.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest
from app.licensing.verification_keys import load_verification_keys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from service.api import create_app
from service.container import load_issuer_factory
from service.errors import SigningKeyError
from service.settings import Settings
from service.signing_key_match import ensure_signing_key_matches

HERE = Path(__file__).resolve().parents[1]
STAGING_KEYS = HERE / "deploy" / "staging" / "verification_keys.staging.json"
STAGING_KEY_ID = "stg-2026-11"

SIGNING_NAME = "LICENSE_API_SIGNING_SECRET"
ENC_NAME = "LICENSE_API_CODE_ENC_SECRET"
KEY_ID = "stg-test-match"


def _pair(key_id: str = KEY_ID) -> tuple[str, bytes, bytes]:
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


def _secret_payload(key_id: str, seed: bytes) -> str:
    return json.dumps({"key_id": key_id, "seed_b64": base64.b64encode(seed).decode()})


def _b64(material: bytes) -> str:
    return base64.b64encode(material).decode("ascii")


def _write_secret(secret_dir: Path, payload: str) -> Path:
    path = secret_dir / SIGNING_NAME
    path.write_text(payload, encoding="utf-8")
    return path


def _write_keys(path: Path, entries: dict[str, object]) -> Path:
    path.write_text(json.dumps(entries), encoding="utf-8")
    return path


def _secret_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "secrets"
    directory.mkdir(exist_ok=True)
    return directory


def _settings(
    secret_dir: Path,
    keys_file: Path,
    **overrides,
) -> Settings:
    """A staging-shaped configuration (production guards, mounted files)."""
    values: dict[str, object] = {
        "env": "production",
        "firebase_project_id": "demo-staging",
        "secret_source": "file",
        "secret_dir": str(secret_dir),
        "signing_secret_name": SIGNING_NAME,
        "code_encryption_secret_name": ENC_NAME,
        "verification_keys_file": str(keys_file),
        "require_signing_key_match": True,
        "staging_key_id": KEY_ID,
    }
    values.update(overrides)
    return Settings(**values)


def _matching(tmp_path: Path) -> tuple[Settings, tuple[str, bytes, bytes]]:
    """Settings whose mounted seed and published key are the same keypair."""
    key_id, seed, public = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(key_id, seed))
    keys_file = _write_keys(tmp_path / "keys.json", {key_id: _b64(public)})
    return _settings(directory, keys_file), (key_id, seed, public)


# --------------------------------------------------------------------------- #
# Matching material
# --------------------------------------------------------------------------- #


def test_a_matching_seed_and_published_key_is_accepted(tmp_path):
    settings, (key_id, _, _) = _matching(tmp_path)

    assert ensure_signing_key_matches(settings) == key_id
    # The same check runs where the application is constructed: a match starts.
    create_app(settings=settings)
    # The keypair the guard verified is exactly the one the issuer will use.
    issuer = load_issuer_factory(settings)()
    assert issuer.key_id == key_id
    assert issuer.is_published() is True


def test_the_issuer_can_publish_a_code_with_the_verified_key(tmp_path):
    key_id, seed, public = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(key_id, seed))
    keys_file = _write_keys(tmp_path / "keys.json", {key_id: _b64(public)})
    settings = _settings(directory, keys_file)

    assert ensure_signing_key_matches(settings) == key_id
    assert load_issuer_factory(settings)().is_published() is True


# --------------------------------------------------------------------------- #
# Mismatch and malformed material — all fail closed at startup
# --------------------------------------------------------------------------- #


def test_a_seed_from_another_keypair_fails_closed(tmp_path):
    _, foreign_seed, _ = _pair()
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, foreign_seed))
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})
    settings = _settings(directory, keys_file)

    with pytest.raises(SigningKeyError, match="does not match") as refused:
        ensure_signing_key_matches(settings)
    assert _b64(foreign_seed) not in str(refused.value)
    assert foreign_seed.hex() not in str(refused.value)
    assert _b64(published) not in str(refused.value)


def test_startup_fails_before_the_application_accepts_requests(tmp_path):
    _, foreign_seed, _ = _pair()
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, foreign_seed))
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})

    # `create_app` is the import-time entry point: raising here means no ASGI
    # application exists to serve a request, so the process never comes up.
    with pytest.raises(SigningKeyError):
        create_app(settings=_settings(directory, keys_file))


def test_a_missing_signing_secret_fails_closed(tmp_path):
    _, _, published = _pair()
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})
    settings = _settings(_secret_dir(tmp_path), keys_file)

    with pytest.raises(SigningKeyError, match="missing"):
        ensure_signing_key_matches(settings)
    with pytest.raises(SigningKeyError):
        create_app(settings=settings)


def test_a_seed_of_the_wrong_length_fails_safely(tmp_path):
    short = b"\x01" * 31
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, short))
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})

    with pytest.raises(SigningKeyError, match="33 bytes|32 bytes") as refused:
        ensure_signing_key_matches(_settings(directory, keys_file))
    assert _b64(short) not in str(refused.value)


def test_a_non_base64_seed_fails_safely(tmp_path):
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(
        directory, json.dumps({"key_id": KEY_ID, "seed_b64": "not-base64!!"})
    )
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})

    with pytest.raises(SigningKeyError, match="not valid base64") as refused:
        ensure_signing_key_matches(_settings(directory, keys_file))
    assert "not-base64!!" not in str(refused.value)


def test_a_malformed_signing_secret_fails_safely(tmp_path):
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, "{not json")
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})

    with pytest.raises(SigningKeyError, match="not valid JSON"):
        ensure_signing_key_matches(_settings(directory, keys_file))


def test_a_secret_for_another_key_id_fails_closed(tmp_path):
    _, seed, _ = _pair()
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload("stg-other", seed))
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})

    with pytest.raises(SigningKeyError, match="belongs to key id"):
        ensure_signing_key_matches(_settings(directory, keys_file))


def test_a_published_key_with_the_wrong_length_fails_closed(tmp_path):
    _, seed, _ = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, seed))
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(b"\x02" * 31)})

    with pytest.raises(SigningKeyError, match="not a usable public key file"):
        ensure_signing_key_matches(_settings(directory, keys_file))


def test_a_keys_file_without_the_staging_id_fails_closed(tmp_path):
    _, seed, _ = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, seed))
    _, _, other_public = _pair("stg-other")
    keys_file = _write_keys(tmp_path / "keys.json", {"stg-other": _b64(other_public)})

    with pytest.raises(SigningKeyError, match="does not publish") as refused:
        ensure_signing_key_matches(_settings(directory, keys_file))
    assert _b64(other_public) not in str(refused.value)


def test_an_empty_keys_file_fails_closed(tmp_path):
    _, seed, _ = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, seed))
    keys_file = _write_keys(tmp_path / "keys.json", {})

    with pytest.raises(SigningKeyError, match="ships no key ids"):
        ensure_signing_key_matches(_settings(directory, keys_file))


def test_an_invalid_configured_key_id_fails_closed(tmp_path):
    settings, _ = _matching(tmp_path)

    with pytest.raises(SigningKeyError, match="not a valid license key id"):
        ensure_signing_key_matches(
            _settings(
                Path(settings.secret_dir),
                settings.verification_keys_path,
                staging_key_id="bad id",
            )
        )


def test_the_committed_staging_file_rejects_a_foreign_seed(tmp_path):
    """The real staging pair is public; a throwaway seed must not match it."""
    published = load_verification_keys(STAGING_KEYS)
    assert set(published) == {STAGING_KEY_ID}

    _, foreign_seed, _ = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(STAGING_KEY_ID, foreign_seed))

    with pytest.raises(SigningKeyError, match="does not match"):
        ensure_signing_key_matches(
            _settings(directory, STAGING_KEYS, staging_key_id=STAGING_KEY_ID)
        )


# --------------------------------------------------------------------------- #
# No secret material anywhere
# --------------------------------------------------------------------------- #


def test_no_key_material_reaches_a_message_or_a_log(tmp_path, caplog):
    _, foreign_seed, _ = _pair()
    _, _, published = _pair()
    seed_b64 = _b64(foreign_seed)
    public_b64 = _b64(published)
    with caplog.at_level("DEBUG"):
        directory = _secret_dir(tmp_path)
        _write_secret(directory, _secret_payload(KEY_ID, foreign_seed))
        keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: public_b64})

        with pytest.raises(SigningKeyError) as refused:
            create_app(settings=_settings(directory, keys_file))

    message = str(refused.value)
    logged = "\n".join(record.getMessage() for record in caplog.records)
    for material in (seed_b64, foreign_seed.hex(), public_b64):
        assert material not in message
        assert material not in logged
    # The refusal still names the key id: diagnosable without the material.
    assert KEY_ID in message


# --------------------------------------------------------------------------- #
# Disabled by default — production behaviour unchanged
# --------------------------------------------------------------------------- #


def test_the_guard_is_off_by_default():
    settings = Settings(
        env="production",
        firebase_project_id="demo",
        signing_secret_name=SIGNING_NAME,
        code_encryption_secret_name=ENC_NAME,
    )

    assert settings.require_signing_key_match is False
    assert Settings(env="testing").require_signing_key_match is False


def test_the_guard_is_read_from_the_environment():
    base = {
        "LICENSE_API_ENV": "production",
        "LICENSE_API_FIREBASE_PROJECT_ID": "demo",
        "LICENSE_API_SIGNING_SECRET": SIGNING_NAME,
        "LICENSE_API_CODE_ENC_SECRET": ENC_NAME,
    }

    enabled = Settings.from_env(
        {**base, "LICENSE_API_REQUIRE_SIGNING_KEY_MATCH": "1"}
    )
    disabled = Settings.from_env(
        {**base, "LICENSE_API_REQUIRE_SIGNING_KEY_MATCH": "0"}
    )
    assert enabled.require_signing_key_match is True
    assert disabled.require_signing_key_match is False
    assert Settings.from_env(base).require_signing_key_match is False


def test_a_mismatch_is_accepted_when_the_guard_is_disabled(tmp_path):
    """The pre-existing lazy, id-only path is untouched by this flag."""
    _, foreign_seed, _ = _pair()
    _, _, published = _pair()
    directory = _secret_dir(tmp_path)
    _write_secret(directory, _secret_payload(KEY_ID, foreign_seed))
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(published)})
    settings = _settings(directory, keys_file, require_signing_key_match=False)

    create_app(settings=settings)  # no startup comparison
    issuer = load_issuer_factory(settings)()
    assert issuer.key_id == KEY_ID
    assert issuer.is_published() is True  # id-only, as before


def test_a_disabled_guard_never_reads_the_signing_secret(tmp_path):
    keys_file = _write_keys(tmp_path / "keys.json", {KEY_ID: _b64(b"\x03" * 32)})
    settings = _settings(
        tmp_path / "no-such-secret-dir",
        keys_file,
        require_signing_key_match=False,
    )

    # The secret directory does not exist; startup must not care, because the
    # seed is still fetched only on first use (unchanged production laziness).
    create_app(settings=settings)
