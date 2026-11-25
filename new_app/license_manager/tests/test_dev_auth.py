"""The development-only token path used to run the dashboard locally.

It accepts exactly one string (``dev:<uid>``) for one uid, the uid must still be
on the administrator allowlist, and it cannot be configured in production.
"""

from __future__ import annotations

import pytest

from service.auth import DevelopmentTokenVerifier, authenticate_admin
from service.errors import UnauthorizedError
from service.settings import Settings
from testkit import ADMIN_CLAIMS


def _authenticate(token: str, settings: Settings) -> str:
    principal = authenticate_admin(
        authorization=f"Bearer {token}",
        app_check_header=None,
        verifier=DevelopmentTokenVerifier(ADMIN_CLAIMS["uid"]),
        settings=settings,
    )
    return principal.uid


def test_the_development_token_authenticates_the_configured_uid(settings):
    assert _authenticate(f"dev:{ADMIN_CLAIMS['uid']}", settings) == ADMIN_CLAIMS["uid"]


def test_the_development_verifier_accepts_exactly_one_token():
    verifier = DevelopmentTokenVerifier("admin-1")
    assert verifier.verify_id_token("dev:admin-1")["uid"] == "admin-1"
    for token in ("admin-1", "dev:admin-2", "dev:", "Bearer dev:admin-1", ""):
        with pytest.raises(UnauthorizedError):
            verifier.verify_id_token(token)


def test_the_development_token_cannot_bypass_the_allowlist(settings):
    strict = Settings(
        env="testing",
        admin_uids=frozenset({"someone-else"}),
        verification_keys_file=settings.verification_keys_file,
    )
    with pytest.raises(Exception) as caught:
        _authenticate("dev:admin-1", strict)
    assert caught.value.status_code == 403  # noqa: SLF001 - documented contract


def test_the_development_token_is_refused_in_production():
    with pytest.raises(ValueError, match="LICENSE_API_DEV_AUTH_UID"):
        Settings(
            env="production",
            firebase_project_id="demo",
            signing_secret_name="signing",
            code_encryption_secret_name="codes",
            dev_auth_uid="admin-1",
        )


def test_the_development_setting_is_read_from_the_environment(settings):
    environ = {
        "LICENSE_API_ENV": "development",
        "LICENSE_API_ADMIN_UIDS": "admin-1",
        "LICENSE_API_VERIFICATION_KEYS_FILE": settings.verification_keys_file,
        "LICENSE_API_DEV_AUTH_UID": "admin-1",
    }
    assert Settings.from_env(environ).dev_auth_uid == "admin-1"


def test_the_container_wires_the_development_verifier_outside_production(
    settings, repository, issuer, clock
):
    from service.container import LazyContainer

    dev_settings = Settings(
        env="development",
        admin_uids=frozenset({ADMIN_CLAIMS["uid"]}),
        verification_keys_file=settings.verification_keys_file,
        dev_auth_uid=ADMIN_CLAIMS["uid"],
    )
    holder = LazyContainer(dev_settings)
    principal = authenticate_admin(
        authorization=f"Bearer dev:{ADMIN_CLAIMS['uid']}",
        app_check_header=None,
        verifier=holder.verifier,
        settings=dev_settings,
    )
    assert principal.uid == ADMIN_CLAIMS["uid"]
    assert issuer is not None and repository is not None and clock is not None
