"""Isolated staging trust profile (key id ``stg-2026-11``) — Phase L2-A.

The official package ships ``app/licensing/verification_keys.json`` and
trusts only its own key ids.  A license issued under the staging key
``stg-2026-11`` therefore fails with ``license_invalid_key`` — that is the
"built without the signing key" activation failure.

This module pins the isolated staging configuration:

* ``verification_keys.staging.json`` publishes exactly the staging public
  key, byte-identical to the License Manager's staging verification config;
* ``LICENSE_TRUST_PROFILE`` selects it (default ``production``, so the
  official trust set is unchanged);
* with that registry the unchanged actor still accepts a valid code,
  rejects a modified signature, rejects an unknown key id and rejects a
  code bound to another device — no verification rule is relaxed;
* the production registry neither carries nor trusts the staging key;
* the staging bundle is written to its own directory/exe name and the
  official release directory and Installer tree are never written.

Signature-acceptance cases use a throwaway in-process Ed25519 keypair
published under the same key id into a temporary registry: the real staging
private key is (by design) not available to any test.
"""

from __future__ import annotations

import base64
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pydantic import ValidationError

from app.core.config import Settings
from app.licensing.activation_code import canonical_json, encode_activation_code
from app.licensing.errors import (
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
)
from app.licensing.fingerprint import HardwareFingerprintService, StaticHardwareInfoProvider
from app.licensing.license_manager import LicenseManager
from app.licensing.verification_keys import load_verification_keys

BACKEND_ROOT = Path(__file__).resolve().parents[2]
NEW_APP_ROOT = BACKEND_ROOT.parent
LICENSING_DIR = BACKEND_ROOT / "app" / "licensing"
PRODUCTION_KEYS = LICENSING_DIR / "verification_keys.json"
STAGING_KEYS = LICENSING_DIR / "verification_keys.staging.json"
STAGING_KEY_ID = "stg-2026-11"
PRODUCTION_KEY_ID = "test-2026"

STAGING_SCRIPT = NEW_APP_ROOT / "staging" / "build_staging_bundle.ps1"
OFFICIAL_RELEASE_DIR = NEW_APP_ROOT / "build" / "windows" / "x64" / "runner" / "Release"
STAGING_OUT_DIR = NEW_APP_ROOT / "dist" / "KlickPOS-Staging"

_SAMPLE_SETTINGS = {
    "DATABASE_URL": "sqlite:///:memory:",
    "APP_SECRET_KEY": "staging-profile-app-secret-00000",
    "JWT_SECRET_KEY": "staging-profile-jwt-secret-00000",
    "LICENSE_STATE_DIR": "",
    "LICENSE_VERIFICATION_KEYS_FILE": "",
}

PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-staging-profile",
    system_volume_serial="SERIAL-STAGING",
    hostname="staging-pc",
)
HW = HardwareFingerprintService(PROVIDER).fingerprint()

OTHER_PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-other-pc",
    system_volume_serial="SERIAL-OTHER",
    hostname="other-pc",
)
OTHER_HW = HardwareFingerprintService(OTHER_PROVIDER).fingerprint()


# ── the shipped registries ──────────────────────────────────────────────────


def test_the_staging_registry_publishes_only_the_staging_key() -> None:
    keys = load_verification_keys(STAGING_KEYS)

    assert set(keys) == {STAGING_KEY_ID}
    assert len(keys[STAGING_KEY_ID]) == 32


def test_the_staging_registry_matches_the_license_manager_staging_config() -> None:
    source = (
        NEW_APP_ROOT
        / "license_manager"
        / "deploy"
        / "staging"
        / "verification_keys.staging.json"
    )
    if not source.is_file():
        pytest.skip(f"staging verification config not present: {source}")

    assert load_verification_keys(STAGING_KEYS) == load_verification_keys(source)


def test_the_production_registry_is_unchanged_and_does_not_trust_staging() -> None:
    production = load_verification_keys(PRODUCTION_KEYS)

    assert set(production) == {"prod-2026-11", "test-2026"}
    assert PRODUCTION_KEY_ID in production
    assert STAGING_KEY_ID not in production


# ── profile selection ──────────────────────────────────────────────────────


def test_the_default_profile_keeps_the_production_registry() -> None:
    cfg = Settings(**_SAMPLE_SETTINGS)

    assert cfg.LICENSE_TRUST_PROFILE == "production"
    assert Path(cfg.LICENSE_VERIFICATION_KEYS_FILE) == PRODUCTION_KEYS


def test_the_staging_profile_selects_the_staging_registry() -> None:
    cfg = Settings(LICENSE_TRUST_PROFILE="staging", **_SAMPLE_SETTINGS)

    assert Path(cfg.LICENSE_VERIFICATION_KEYS_FILE) == STAGING_KEYS


def test_an_explicit_keys_file_wins_over_the_profile(tmp_path: Path) -> None:
    explicit = tmp_path / "verification_keys.json"
    cfg = Settings(
        LICENSE_TRUST_PROFILE="staging",
        **{**_SAMPLE_SETTINGS, "LICENSE_VERIFICATION_KEYS_FILE": str(explicit)},
    )

    assert cfg.LICENSE_VERIFICATION_KEYS_FILE == str(explicit)


def test_an_unknown_profile_is_rejected() -> None:
    with pytest.raises(ValidationError):
        Settings(LICENSE_TRUST_PROFILE="staging-2", **_SAMPLE_SETTINGS)


# ── the unchanged verification path under the staging registry ─────────────


def _raw_public(private: Ed25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def _write_registry(path: Path, private: Ed25519PrivateKey, key_id: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({key_id: base64.b64encode(_raw_public(private)).decode("ascii")}),
        encoding="utf-8",
    )
    return path


def make_code(
    private: Ed25519PrivateKey,
    *,
    key_id: str = STAGING_KEY_ID,
    hw_hash: str = HW,
    license_id: str = "LIC-STAGING-0001",
    signature_over: bytes | None = None,
) -> str:
    body = {
        "v": 1,
        "key_id": key_id,
        "license_id": license_id,
        "kind": "lifetime",
        "issued_at": "2026-11-01T00:00:00+00:00",
        "hw_hash": hw_hash,
        "features": ["pos"],
    }
    payload = canonical_json(body)
    signature = private.sign(signature_over if signature_over is not None else payload)
    return encode_activation_code(body, signature)


@pytest.fixture()
def staging(tmp_path: Path) -> tuple[Path, Ed25519PrivateKey]:
    """A staging registry holding a throwaway keypair under stg-2026-11."""

    private = Ed25519PrivateKey.generate()
    keys = _write_registry(
        tmp_path / "verification_keys.staging.json", private, STAGING_KEY_ID
    )
    return keys, private


def _manager(keys: Path, state_dir: Path):
    return LicenseManager(
        state_dir=state_dir,
        keys_path=keys,
        fingerprint=HardwareFingerprintService(PROVIDER),
    )


def test_a_code_signed_for_the_staging_key_is_accepted(
    staging, tmp_path: Path
) -> None:
    keys, private = staging
    manager = _manager(keys, tmp_path / "license")

    status = manager.activate(make_code(private))

    assert status.key_id == STAGING_KEY_ID
    assert status.license_id == "LIC-STAGING-0001"
    assert status.license_type == "lifetime"
    assert status.hw_hash == HW
    assert _manager(keys, tmp_path / "license").status() == status


def test_a_modified_signature_is_rejected(staging, tmp_path: Path) -> None:
    keys, private = staging
    manager = _manager(keys, tmp_path / "license")

    tampered = make_code(private, signature_over=b"a different message")

    with pytest.raises(LicenseInvalidError):
        manager.activate(tampered)
    assert manager.status() is None


def test_an_unknown_key_id_is_rejected(staging, tmp_path: Path) -> None:
    keys, private = staging
    manager = _manager(keys, tmp_path / "license")

    with pytest.raises(LicenseInvalidKeyError):
        manager.activate(make_code(private, key_id="stg-2026-12"))


def test_a_code_bound_to_another_device_is_rejected(
    staging, tmp_path: Path
) -> None:
    keys, private = staging
    manager = _manager(keys, tmp_path / "license")

    with pytest.raises(LicenseBoundElsewhereError):
        manager.activate(make_code(private, hw_hash=OTHER_HW))
    assert manager.status() is None


def test_the_production_registry_does_not_trust_the_staging_key(
    staging, tmp_path: Path
) -> None:
    _keys, private = staging
    manager = _manager(PRODUCTION_KEYS, tmp_path / "license")

    with pytest.raises(LicenseInvalidKeyError):
        manager.activate(make_code(private))


# ── build isolation ────────────────────────────────────────────────────────


def test_the_staging_build_targets_a_separate_directory_and_executable() -> None:
    assert STAGING_OUT_DIR != OFFICIAL_RELEASE_DIR
    assert STAGING_OUT_DIR.name == "KlickPOS-Staging"
    assert (STAGING_OUT_DIR / "KlickPOS-Staging.exe").name != "supermarket_pos.exe"
    assert STAGING_SCRIPT.is_file()


@pytest.mark.skipif(sys.platform != "win32", reason="PowerShell build script (Windows)")
def test_the_build_plan_never_targets_the_official_release_or_installer() -> None:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        pytest.skip("PowerShell is not available")

    result = subprocess.run(
        [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(STAGING_SCRIPT),
            "-Plan",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )

    assert result.returncode == 0, result.stderr
    line = next(
        (item for item in result.stdout.splitlines() if item.startswith("STAGING_PLAN ")),
        None,
    )
    assert line, result.stdout

    # Absolute paths may contain spaces, so split on the fixed field
    # boundaries instead of on whitespace.
    fields = re.fullmatch(
        r"out=(?P<out>.+) source=(?P<source>.+) exe=(?P<exe>\S+) "
        r"trust_profile=(?P<profile>\S+) key_id=(?P<key>\S+) "
        r"writes_outside_staging=(?P<outside>\S+)",
        line[len("STAGING_PLAN ") :],
    )
    assert fields, line

    planned = Path(fields.group("out")).resolve()
    assert planned == STAGING_OUT_DIR.resolve()
    assert planned != OFFICIAL_RELEASE_DIR.resolve()
    assert Path(fields.group("source")).resolve() == OFFICIAL_RELEASE_DIR.resolve()
    assert (NEW_APP_ROOT / "installer") not in (STAGING_OUT_DIR, *STAGING_OUT_DIR.parents)
    assert fields.group("exe") == "KlickPOS-Staging.exe"
    assert fields.group("profile") == "staging"
    assert fields.group("key") == STAGING_KEY_ID
    assert fields.group("outside") == "no"


# ── C-2 (Phase 0-A): production refuses the staging trust profile ──────────


def _production(**overrides: object) -> Settings:
    """Settings for a production install, with the sample test secrets."""
    return Settings(APP_ENV="production", **{**_SAMPLE_SETTINGS, **overrides})


def test_production_with_the_production_profile_succeeds() -> None:
    cfg = _production(LICENSE_TRUST_PROFILE="production")

    assert cfg.APP_ENV == "production"
    assert cfg.LICENSE_TRUST_PROFILE == "production"
    assert Path(cfg.LICENSE_VERIFICATION_KEYS_FILE) == PRODUCTION_KEYS


def test_production_with_the_staging_profile_fails_closed() -> None:
    with pytest.raises(
        ValidationError, match="LICENSE_TRUST_PROFILE must be 'production'"
    ):
        _production(LICENSE_TRUST_PROFILE="staging")


def test_production_with_no_profile_defaults_to_production() -> None:
    cfg = _production()

    assert "LICENSE_TRUST_PROFILE" not in cfg.model_fields_set
    assert cfg.LICENSE_TRUST_PROFILE == "production"
    assert Path(cfg.LICENSE_VERIFICATION_KEYS_FILE).name == "verification_keys.json"


def test_production_with_an_explicit_staging_registry_still_fails(
    tmp_path: Path,
) -> None:
    # The staging profile plus any explicit registry path is refused before the
    # path is even considered.
    explicit = tmp_path / "verification_keys.staging.json"
    explicit.write_text("{}", encoding="utf-8")
    with pytest.raises(
        ValidationError, match="LICENSE_TRUST_PROFILE must be 'production'"
    ):
        _production(
            LICENSE_TRUST_PROFILE="staging",
            LICENSE_VERIFICATION_KEYS_FILE=str(explicit),
        )

    # And the production profile cannot be paired with the staging registry:
    # an explicit override must not bypass the restriction.
    with pytest.raises(ValidationError, match="staging registry"):
        _production(LICENSE_VERIFICATION_KEYS_FILE=str(explicit))
    with pytest.raises(ValidationError, match="staging registry"):
        _production(LICENSE_VERIFICATION_KEYS_FILE=str(STAGING_KEYS))


def test_production_still_honours_an_explicit_production_registry(
    tmp_path: Path,
) -> None:
    explicit = tmp_path / "verification_keys.json"
    explicit.write_text("{}", encoding="utf-8")

    cfg = _production(LICENSE_VERIFICATION_KEYS_FILE=str(explicit))

    assert cfg.LICENSE_VERIFICATION_KEYS_FILE == str(explicit)


def test_development_with_the_staging_profile_still_works() -> None:
    cfg = Settings(
        APP_ENV="development",
        LICENSE_TRUST_PROFILE="staging",
        **_SAMPLE_SETTINGS,
    )

    assert cfg.LICENSE_TRUST_PROFILE == "staging"
    assert Path(cfg.LICENSE_VERIFICATION_KEYS_FILE) == STAGING_KEYS


def test_development_can_still_point_at_an_explicit_staging_registry(
    tmp_path: Path,
) -> None:
    """The staging workflow's explicit override is untouched."""
    explicit = tmp_path / "verification_keys.staging.json"
    explicit.write_text("{}", encoding="utf-8")

    cfg = Settings(
        APP_ENV="development",
        LICENSE_TRUST_PROFILE="staging",
        **{**_SAMPLE_SETTINGS, "LICENSE_VERIFICATION_KEYS_FILE": str(explicit)},
    )

    assert cfg.LICENSE_VERIFICATION_KEYS_FILE == str(explicit)
