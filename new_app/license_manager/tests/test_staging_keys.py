"""Staging verification-key isolation (Phases 8.4.2 / 8.4.3).

A staging deployment reads its **own** public-key file, must never resolve to a
production key file however that path is spelled, and refuses to start when its
staging file is missing, malformed or publishes the wrong key id.

Deliberately out of scope: the signing-seed ↔ published-public-key match, which
is a separate change and is not asserted here.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path

import pytest
from app.licensing.release_metadata import validate_release_metadata
from app.licensing.verification_keys import load_verification_keys

from service.api import create_app
from service.errors import SigningKeyError
from service.settings import (
    DEFAULT_VERIFICATION_KEYS_FILE,
    PRODUCTION_VERIFICATION_KEYS_PATHS,
    Settings,
    path_identities,
    production_verification_keys_identities,
)
from service.staging_keys import ensure_staging_keys

HERE = Path(__file__).resolve().parents[1]
STAGING_DIR = HERE / "deploy" / "staging"
STAGING_KEYS = STAGING_DIR / "verification_keys.staging.json"
STAGING_METADATA = STAGING_DIR / "release_metadata.staging.json"
STAGING_TEMPLATE = HERE / "deploy" / "staging.env.template"
PRODUCTION_TEMPLATE = HERE / "deploy" / "api.env.template"

STAGING_KEY_ID = "stg-2026-11"
#: The path the Render image must contain (docs/render-staging.md §3.1).
STAGING_IMAGE_PATH = (
    "/app/license_manager/deploy/staging/verification_keys.staging.json"
)
PRODUCTION_IMAGE_PATH = "/app/backend/app/licensing/verification_keys.json"

PRODUCTION_KEYS = Path(DEFAULT_VERIFICATION_KEYS_FILE)


def _public(seed_byte: int = 1) -> str:
    """A throwaway 32-byte public value (never a real key)."""
    return base64.b64encode(bytes([seed_byte]) * 32).decode("ascii")


def _write_keys(path: Path, entries: dict[str, str]) -> Path:
    path.write_text(json.dumps(entries), encoding="utf-8")
    return path


def _production_settings(**overrides) -> Settings:
    """A Settings object that satisfies every production guard."""
    values = {
        "env": "production",
        "firebase_project_id": "demo-staging",
        "signing_secret_name": "LICENSE_API_SIGNING_SECRET",
        "code_encryption_secret_name": "LICENSE_API_CODE_ENC_SECRET",
    }
    values.update(overrides)
    return Settings(**values)


def _staging_settings(keys_file: str | Path, **overrides) -> Settings:
    return _production_settings(
        verification_keys_file=str(keys_file),
        require_staging_keys=True,
        **overrides,
    )


# --------------------------------------------------------------------------- #
# The templates
# --------------------------------------------------------------------------- #


def test_the_staging_template_pins_staging_keys_and_never_the_production_file():
    text = STAGING_TEMPLATE.read_text(encoding="utf-8")
    lines = [line.strip() for line in text.splitlines()]

    assert f"LICENSE_API_VERIFICATION_KEYS_FILE={STAGING_IMAGE_PATH}" in lines
    assert "LICENSE_API_REQUIRE_STAGING_KEYS=1" in lines
    assert PRODUCTION_IMAGE_PATH not in text


def test_the_production_template_is_unchanged_and_knows_no_staging_keys():
    text = PRODUCTION_TEMPLATE.read_text(encoding="utf-8")

    assert f"LICENSE_API_VERIFICATION_KEYS_FILE={PRODUCTION_IMAGE_PATH}" in text
    assert "staging" not in text.lower()
    assert "LICENSE_API_REQUIRE_STAGING_KEYS" not in text


# --------------------------------------------------------------------------- #
# The committed staging files
# --------------------------------------------------------------------------- #


def test_the_staging_key_file_holds_only_the_staging_id():
    keys = load_verification_keys(STAGING_KEYS)

    assert set(keys) == {STAGING_KEY_ID}
    assert all(len(public) == 32 for public in keys.values())


def test_the_staging_pair_is_a_consistent_release_record():
    report = validate_release_metadata(STAGING_KEYS, STAGING_METADATA, strict=True)

    assert report.ok
    assert report.unrecorded == ()


def test_staging_and_production_key_ids_never_overlap():
    staging = set(load_verification_keys(STAGING_KEYS))
    production = set(load_verification_keys(PRODUCTION_KEYS))

    assert staging
    assert not staging & production, "a staging id must never be a production id"


# --------------------------------------------------------------------------- #
# Production paths are blocked — every known spelling
# --------------------------------------------------------------------------- #


def test_the_packaged_default_path_is_rejected():
    with pytest.raises(ValueError, match="LICENSE_API_REQUIRE_STAGING_KEYS"):
        _production_settings(require_staging_keys=True)


def test_the_production_image_path_is_rejected():
    with pytest.raises(ValueError, match="production keys file"):
        _staging_settings(PRODUCTION_IMAGE_PATH)


def test_every_known_production_path_is_covered():
    assert str(DEFAULT_VERIFICATION_KEYS_FILE) in PRODUCTION_VERIFICATION_KEYS_PATHS
    assert PRODUCTION_IMAGE_PATH in PRODUCTION_VERIFICATION_KEYS_PATHS

    for candidate in PRODUCTION_VERIFICATION_KEYS_PATHS:
        with pytest.raises(ValueError):
            _staging_settings(candidate)


def test_a_traversal_spelling_of_the_production_file_is_rejected():
    disguised = str(PRODUCTION_KEYS.parent / ".." / "licensing" / "verification_keys.json")

    assert _production_settings(verification_keys_file=disguised).uses_production_verification_keys
    with pytest.raises(ValueError):
        _staging_settings(disguised)


def test_a_relative_spelling_of_the_production_file_is_rejected():
    relative = os.path.relpath(PRODUCTION_KEYS)

    assert _production_settings(verification_keys_file=relative).uses_production_verification_keys
    with pytest.raises(ValueError):
        _staging_settings(relative)


def test_a_symlink_to_the_production_file_is_rejected(tmp_path):
    link = tmp_path / "looks-like-staging.json"
    try:
        link.symlink_to(PRODUCTION_KEYS)
    except (OSError, NotImplementedError, AttributeError):  # pragma: no cover
        pytest.skip("symlinks are not available for this account")

    assert _production_settings(verification_keys_file=str(link)).uses_production_verification_keys
    with pytest.raises(ValueError):
        _staging_settings(str(link))


# --------------------------------------------------------------------------- #
# The legitimate staging path is accepted
# --------------------------------------------------------------------------- #


def test_the_staging_image_path_is_accepted():
    settings = _staging_settings(STAGING_IMAGE_PATH)

    assert settings.verification_keys_path == Path(STAGING_IMAGE_PATH)
    assert settings.uses_production_verification_keys is False
    assert path_identities(STAGING_IMAGE_PATH).isdisjoint(
        production_verification_keys_identities()
    )


def test_the_committed_staging_file_is_accepted_at_startup():
    settings = _staging_settings(STAGING_KEYS)

    assert ensure_staging_keys(settings) == (STAGING_KEY_ID,)
    create_app(settings=settings)  # constructs the application without raising


# --------------------------------------------------------------------------- #
# Startup validation of the staging key file
# --------------------------------------------------------------------------- #


def test_a_valid_staging_file_is_accepted(tmp_path):
    keys_file = _write_keys(tmp_path / "keys.json", {STAGING_KEY_ID: _public()})

    assert ensure_staging_keys(_staging_settings(keys_file)) == (STAGING_KEY_ID,)


def test_a_missing_staging_file_fails_closed(tmp_path):
    settings = _staging_settings(tmp_path / "absent.json")

    with pytest.raises(SigningKeyError, match="missing"):
        ensure_staging_keys(settings)
    # The same refusal happens where the application is constructed (startup).
    with pytest.raises(SigningKeyError):
        create_app(settings=settings)


def test_a_malformed_staging_file_fails_closed(tmp_path):
    keys_file = tmp_path / "keys.json"
    keys_file.write_text('{"' + STAGING_KEY_ID + '": "not-json', encoding="utf-8")

    with pytest.raises(SigningKeyError, match="not a usable public key file"):
        ensure_staging_keys(_staging_settings(keys_file))


def test_an_empty_staging_key_set_fails_closed(tmp_path):
    keys_file = _write_keys(tmp_path / "keys.json", {})

    with pytest.raises(SigningKeyError, match="ships no key ids"):
        ensure_staging_keys(_staging_settings(keys_file))


def test_a_file_without_the_staging_key_id_fails_closed(tmp_path):
    other = _public(7)
    keys_file = _write_keys(tmp_path / "keys.json", {"k1": other})

    with pytest.raises(SigningKeyError, match="stg-2026-11") as refused:
        ensure_staging_keys(_staging_settings(keys_file))
    assert other not in str(refused.value), "no key material in the message"


def test_an_invalid_configured_staging_key_id_fails_closed(tmp_path):
    keys_file = _write_keys(tmp_path / "keys.json", {STAGING_KEY_ID: _public()})

    with pytest.raises(SigningKeyError, match="not a valid license key id"):
        ensure_staging_keys(_staging_settings(keys_file, staging_key_id="bad id"))


def test_a_wrong_key_length_fails_closed_without_echoing_the_value(tmp_path):
    short = base64.b64encode(b"short").decode("ascii")
    keys_file = _write_keys(tmp_path / "keys.json", {STAGING_KEY_ID: short})

    with pytest.raises(SigningKeyError) as refused:
        ensure_staging_keys(_staging_settings(keys_file))
    assert short not in str(refused.value)


# --------------------------------------------------------------------------- #
# Production defaults
# --------------------------------------------------------------------------- #


def test_production_defaults_are_unchanged_with_the_flag_disabled():
    settings = _production_settings()

    assert settings.require_staging_keys is False
    assert settings.staging_key_id == "stg-2026-11"  # inert unless the flag is on
    assert settings.verification_keys_path == PRODUCTION_KEYS
    assert settings.uses_production_verification_keys is True


def test_production_never_runs_the_staging_validation(tmp_path):
    """With the flag off, a production-style file is accepted without checks."""
    production_like = _write_keys(tmp_path / "production.json", {"k-prod": _public(9)})
    settings = _production_settings(verification_keys_file=str(production_like))

    create_app(settings=settings)  # no staging validation, no assertion about ids


def test_the_guard_is_read_from_the_environment():
    base = {
        "LICENSE_API_ENV": "production",
        "LICENSE_API_FIREBASE_PROJECT_ID": "demo-staging",
        "LICENSE_API_SIGNING_SECRET": "LICENSE_API_SIGNING_SECRET",
        "LICENSE_API_CODE_ENC_SECRET": "LICENSE_API_CODE_ENC_SECRET",
        "LICENSE_API_REQUIRE_STAGING_KEYS": "1",
    }

    staging = Settings.from_env(
        {**base, "LICENSE_API_VERIFICATION_KEYS_FILE": STAGING_IMAGE_PATH}
    )
    assert staging.require_staging_keys is True
    assert staging.staging_key_id == STAGING_KEY_ID
    assert staging.verification_keys_path == Path(STAGING_IMAGE_PATH)

    # An unset/empty variable falls back to the packaged default, which on this
    # machine *is* the production file - so the guard must refuse it.  (The
    # Linux image path only equals that default inside the container.)
    with pytest.raises(ValueError):
        Settings.from_env({**base, "LICENSE_API_VERIFICATION_KEYS_FILE": ""})

    production = Settings.from_env({**base, "LICENSE_API_REQUIRE_STAGING_KEYS": "0"})
    assert production.require_staging_keys is False
    assert production.uses_production_verification_keys is True
