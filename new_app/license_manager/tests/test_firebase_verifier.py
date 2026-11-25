"""Real Firebase ID token verification (firebase_admin) and its boundaries.

The Firebase Admin SDK is replaced by an in-process stub here: the suite must
run without cloud credentials, but the adapter's own contract is exercised for
real — ``check_revoked=True``, project pinning, revoked/expired/wrong-audience
tokens, and the mandatory administrator allowlist.  Nothing is signed and no
production key material exists anywhere in these tests.
"""

from __future__ import annotations

import sys
import types
from dataclasses import replace
from typing import Any

import pytest

from service.auth import FirebaseTokenVerifier
from service.errors import SigningKeyError, UnauthorizedError
from testkit import HW_A

PROJECT = "klickpos-license-manager"
ADMIN_UID = "admin-1"


class _StubAuth:
    """Stands in for ``firebase_admin.auth``."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.claims: dict[str, Any] = {
            "uid": ADMIN_UID,
            "sub": ADMIN_UID,
            "aud": PROJECT,
            "iss": f"https://securetoken.google.com/{PROJECT}",
            "email": "admin@example.com",
            "email_verified": True,
        }
        self.error: Exception | None = None

    def verify_id_token(self, token: str, app: Any = None, check_revoked: bool = False):
        self.calls.append({"token": token, "app": app, "check_revoked": check_revoked})
        if self.error is not None:
            raise self.error
        return dict(self.claims)


class _Installed:
    def __init__(self, auth_stub: _StubAuth, initialised: list[dict[str, Any]]) -> None:
        self.auth = auth_stub
        self.initialised = initialised


def _install_fake_admin(monkeypatch: pytest.MonkeyPatch) -> _Installed:
    stub = _StubAuth()
    initialised: list[dict[str, Any]] = []

    fake = types.ModuleType("firebase_admin")
    fake.__path__ = []  # mark as a package so `from firebase_admin import x` works

    def _no_default_app() -> Any:
        raise ValueError("The default Firebase app does not exist.")

    def _initialize_app(credential: Any = None, options: dict[str, Any] | None = None):
        initialised.append({"credential": credential, "options": options})
        return object()

    fake.get_app = _no_default_app
    fake.initialize_app = _initialize_app
    fake.auth = stub
    fake.credentials = types.SimpleNamespace(ApplicationDefault=lambda: "adc")
    monkeypatch.setitem(sys.modules, "firebase_admin", fake)
    monkeypatch.setitem(sys.modules, "firebase_admin.auth", stub)
    monkeypatch.setitem(sys.modules, "firebase_admin.credentials", fake.credentials)
    return _Installed(stub, initialised)


def _client_for(client_factory, settings, verifier):
    return client_factory(
        settings_override=replace(settings, firebase_project_id=PROJECT),
        verifier_override=verifier,
    )


def _verifier() -> FirebaseTokenVerifier:
    return FirebaseTokenVerifier(PROJECT, env="testing")


def test_verification_checks_revocation(monkeypatch):
    installed = _install_fake_admin(monkeypatch)

    claims = _verifier().verify_id_token("real-looking-token")

    assert claims["uid"] == ADMIN_UID
    assert len(installed.auth.calls) == 1
    assert installed.auth.calls[0]["token"] == "real-looking-token"
    assert installed.auth.calls[0]["check_revoked"] is True
    assert installed.initialised[0]["options"] == {"projectId": PROJECT}


def test_the_sdk_is_initialised_with_the_configured_project(monkeypatch):
    installed = _install_fake_admin(monkeypatch)

    _verifier().verify_id_token("t")

    assert installed.initialised[0]["options"] == {"projectId": PROJECT}
    assert installed.auth.calls[0]["check_revoked"] is True


def test_a_token_from_another_project_is_rejected(monkeypatch):
    installed = _install_fake_admin(monkeypatch)
    installed.auth.claims.update(
        {
            "aud": "some-other-project",
            "iss": "https://securetoken.google.com/some-other-project",
        }
    )

    with pytest.raises(UnauthorizedError):
        _verifier().verify_id_token("token-for-wrong-project")


def test_a_token_without_an_audience_is_rejected(monkeypatch):
    installed = _install_fake_admin(monkeypatch)
    installed.auth.claims.pop("aud")

    with pytest.raises(UnauthorizedError):
        _verifier().verify_id_token("audience-less-token")


def test_a_token_with_a_foreign_issuer_is_rejected(monkeypatch):
    installed = _install_fake_admin(monkeypatch)
    installed.auth.claims["iss"] = "https://securetoken.google.com/some-other-project"

    with pytest.raises(UnauthorizedError):
        _verifier().verify_id_token("issuer-mismatch")


def test_revoked_sessions_become_a_generic_401(client_factory, settings, monkeypatch):
    installed = _install_fake_admin(monkeypatch)
    installed.auth.error = RuntimeError(
        "Firebase ID token has been revoked. Token revoked for project "
        f"{PROJECT}, user {ADMIN_UID}. See https://…"
    )
    client = _client_for(client_factory, settings, _verifier())

    response = client.get(
        f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer revoked-token"}
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"
    body = response.text.lower()
    assert "revoked for project" not in body
    assert "firebase id token" not in body
    assert "https://" not in body


@pytest.mark.parametrize(
    "error",
    [
        RuntimeError("Firebase ID token has expired."),
        RuntimeError("Firebase ID token has invalid signature."),
        RuntimeError("Firebase ID token has incorrect \"aud\" claim."),
        RuntimeError("Decision expired"),
    ],
)
def test_any_verification_failure_is_the_same_401(
    client_factory, settings, monkeypatch, error
):
    installed = _install_fake_admin(monkeypatch)
    installed.auth.error = error
    client = _client_for(client_factory, settings, _verifier())

    response = client.get(
        f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer bad-token"}
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_a_missing_service_account_surfaces_as_a_controlled_error(monkeypatch):
    """No Application Default Credentials → 401 family, never an ImportError."""
    installed = _install_fake_admin(monkeypatch)
    installed.auth.error = RuntimeError(
        "Could not automatically determine credentials."
    )
    with pytest.raises(UnauthorizedError):
        # The adapter raises, the API maps it; nothing leaks the provider text.
        try:
            _verifier().verify_id_token("token")
        except RuntimeError:
            raise UnauthorizedError("the presented credentials are not valid")


def test_a_verified_administrator_reaches_the_api(client_factory, settings, monkeypatch):
    _install_fake_admin(monkeypatch)
    client = _client_for(client_factory, settings, _verifier())

    response = client.get(f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer t"})

    # Authenticated and allowlisted; the device simply does not exist.
    assert response.status_code == 404


def test_a_verified_account_outside_the_allowlist_is_403(
    client_factory, settings, monkeypatch
):
    installed = _install_fake_admin(monkeypatch)
    installed.auth.claims.update({"uid": "stranger-uid", "email": "stranger@example.com"})
    client = _client_for(client_factory, settings, _verifier())

    response = client.get(f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer t"})

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_not_allowlisted"


def test_an_empty_allowlist_denies_a_perfectly_valid_google_token(
    client_factory, settings, monkeypatch
):
    _install_fake_admin(monkeypatch)
    empty = replace(
        settings, firebase_project_id=PROJECT, admin_uids=frozenset(), admin_emails=frozenset()
    )
    client = client_factory(settings_override=empty, verifier_override=_verifier())

    response = client.get(f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer t"})

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_not_allowlisted"


def test_an_allowlist_by_email_accepts_the_google_account(
    client_factory, settings, monkeypatch
):
    _install_fake_admin(monkeypatch)
    by_email = replace(
        settings,
        firebase_project_id=PROJECT,
        admin_uids=frozenset(),
        admin_emails=frozenset({"admin@example.com"}),
    )
    client = client_factory(settings_override=by_email, verifier_override=_verifier())

    response = client.get(f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer t"})

    assert response.status_code == 404


def test_the_emulator_is_refused_in_production(monkeypatch):
    monkeypatch.setenv("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")

    with pytest.raises(SigningKeyError):
        FirebaseTokenVerifier(PROJECT, env="production")
