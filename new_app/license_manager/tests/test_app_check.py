"""Firebase App Check: the second gate's own rules.

The API has always refused a request without a verified App Check token when
enforcement is on (``tests/test_auth.py``).  These tests cover the parts that
were added in Phase 6.9 and that must not be taken on trust:

* the token is pinned to **this** Firebase project (``aud`` is the project
  number), so a token minted for another project is refused;
* the audience is normalised and, in production, required whenever enforcement
  is enabled — a deployment that turns App Check on without telling the service
  which project to trust fails at startup instead of accepting anything;
* the Admin SDK is the only verifier: nothing here trusts a claim that came
  from the browser without Firebase having signed it.
"""

from __future__ import annotations

import sys
import types

import pytest

from service.auth import FirebaseTokenVerifier
from service.errors import UnauthorizedError
from service.settings import Settings

PROJECT_NUMBER = "123456789012"


class _FakeAppCheck:
    """Stand-in for ``firebase_admin.app_check``."""

    def __init__(self, claims: dict | None = None, error: BaseException | None = None) -> None:
        self.claims = claims
        self.error = error
        self.calls: list[str] = []

    def verify_token(self, token: str, app=None):  # noqa: ANN001 - SDK shape
        self.calls.append(token)
        if self.error is not None:
            raise self.error
        return dict(self.claims or {})


def _install_fake_firebase(monkeypatch, app_check: _FakeAppCheck) -> None:
    """Make ``firebase_admin`` importable without the real SDK or credentials."""

    def _missing_app():
        raise ValueError("no default app")

    module = types.ModuleType("firebase_admin")
    module.get_app = _missing_app  # type: ignore[attr-defined]
    module.initialize_app = lambda *args, **kwargs: object()  # type: ignore[attr-defined]
    module.app_check = app_check  # type: ignore[attr-defined]

    credentials = types.ModuleType("firebase_admin.credentials")
    credentials.ApplicationDefault = lambda *a, **k: None  # type: ignore[attr-defined]

    app_check_module = types.ModuleType("firebase_admin.app_check")
    app_check_module.verify_token = app_check.verify_token  # type: ignore[attr-defined]

    monkeypatch.setitem(sys.modules, "firebase_admin", module)
    monkeypatch.setitem(sys.modules, "firebase_admin.credentials", credentials)
    monkeypatch.setitem(sys.modules, "firebase_admin.app_check", app_check_module)


def test_a_token_bound_to_the_expected_project_is_accepted(monkeypatch):
    app_check = _FakeAppCheck(
        {
            "aud": f"projects/{PROJECT_NUMBER}",
            "iss": f"https://firebaseappcheck.googleapis.com/{PROJECT_NUMBER}",
            "sub": f"projects/{PROJECT_NUMBER}",
            "app_id": "1:123:web:abc",
        }
    )
    _install_fake_firebase(monkeypatch, app_check)
    verifier = FirebaseTokenVerifier(
        "klickpos-license-manager",
        env="development",
        app_check_audience=PROJECT_NUMBER,
    )

    claims = verifier.verify_app_check_token("valid-app-check-token")

    assert claims["app_id"] == "1:123:web:abc"
    assert app_check.calls == ["valid-app-check-token"]


def test_a_token_for_another_project_is_refused(monkeypatch):
    app_check = _FakeAppCheck({"aud": "projects/999999999999", "app_id": "1:999:web:x"})
    _install_fake_firebase(monkeypatch, app_check)
    verifier = FirebaseTokenVerifier(
        "klickpos-license-manager",
        env="development",
        app_check_audience=PROJECT_NUMBER,
    )

    with pytest.raises(UnauthorizedError):
        verifier.verify_app_check_token("other-project-token")


def test_a_token_without_an_audience_is_refused_when_pinned(monkeypatch):
    _install_fake_firebase(monkeypatch, _FakeAppCheck({"app_id": "1:123:web:abc"}))
    verifier = FirebaseTokenVerifier(
        "klickpos-license-manager",
        env="development",
        app_check_audience=PROJECT_NUMBER,
    )

    with pytest.raises(UnauthorizedError):
        verifier.verify_app_check_token("no-audience")


def test_a_provider_rejection_is_never_reported_as_success(monkeypatch):
    _install_fake_firebase(monkeypatch, _FakeAppCheck(error=ValueError("bad token")))
    verifier = FirebaseTokenVerifier(
        "klickpos-license-manager",
        env="development",
        app_check_audience=PROJECT_NUMBER,
    )

    with pytest.raises(ValueError):
        verifier.verify_app_check_token("forged")


def test_without_a_pinned_audience_the_sdk_result_is_used_as_is(monkeypatch):
    """Local/testing runs: the Admin SDK's own project check remains the gate."""
    _install_fake_firebase(monkeypatch, _FakeAppCheck({"aud": "projects/any", "app_id": "x"}))
    verifier = FirebaseTokenVerifier("klickpos-license-manager", env="development")

    assert verifier.verify_app_check_token("token")["app_id"] == "x"


def test_the_projects_prefix_and_the_bare_number_are_both_accepted(monkeypatch):
    settings = Settings(app_check_audience=f"projects/{PROJECT_NUMBER}")
    assert settings.app_check_audience == PROJECT_NUMBER

    _install_fake_firebase(
        monkeypatch, _FakeAppCheck({"aud": f"projects/{PROJECT_NUMBER}"})
    )
    verifier = FirebaseTokenVerifier(
        "klickpos-license-manager",
        env="development",
        app_check_audience=settings.app_check_audience,
    )
    assert verifier.verify_app_check_token("token")["aud"].endswith(PROJECT_NUMBER)


def test_the_audience_is_read_from_the_environment():
    settings = Settings.from_env(
        {
            "LICENSE_API_ENV": "development",
            "LICENSE_API_REQUIRE_APP_CHECK": "1",
            "LICENSE_API_APP_CHECK_AUDIENCE": f"projects/{PROJECT_NUMBER}",
        }
    )
    assert settings.require_app_check is True
    assert settings.app_check_audience == PROJECT_NUMBER


def test_app_check_is_off_by_default():
    """Local development and the emulator suite keep working unchanged."""
    settings = Settings.from_env({"LICENSE_API_ENV": "development"})
    assert settings.require_app_check is False
    assert settings.app_check_audience == ""


def test_production_refuses_enforcement_without_an_audience():
    with pytest.raises(ValueError, match="LICENSE_API_APP_CHECK_AUDIENCE"):
        Settings(
            env="production",
            firebase_project_id="klickpos-license-manager",
            admin_uids=frozenset({"admin-1"}),
            require_app_check=True,
            signing_secret_name="signing",
            code_encryption_secret_name="codes",
        )


def test_production_accepts_enforcement_with_an_audience():
    settings = Settings(
        env="production",
        firebase_project_id="klickpos-license-manager",
        admin_uids=frozenset({"admin-1"}),
        require_app_check=True,
        app_check_audience=PROJECT_NUMBER,
        cloud_run_audience="https://api.example",
        require_cloud_run_invoker=True,
        cloud_run_invoker_emails=frozenset({"dashboard@example.iam.gserviceaccount.com"}),
        signing_secret_name="signing",
        code_encryption_secret_name="codes",
    )
    assert settings.require_app_check is True
    assert settings.app_check_audience == PROJECT_NUMBER
