"""Cloud Run service-to-service authentication (Dashboard → API).

These tests pin the second gate added in Phase 6: a request must come from the
Dashboard's Cloud Run runtime service account *as well as* carry a valid
administrator Firebase token.  The Google OIDC verifier is stubbed, so the
suite stays offline; production uses ``google.oauth2.id_token`` unchanged.

Nothing here touches a real project, and no token is ever a real one.
"""

from __future__ import annotations

from dataclasses import replace

import pytest
from fastapi.testclient import TestClient
from google.oauth2 import id_token as google_id_token

from service.api import create_app
from service.cloud_run import SERVICE_IDENTITY_HEADER, ServiceIdentityVerifier
from service.errors import (
    ServiceIdentityNotAllowedError,
    ServiceIdentityRequiredError,
)
from service.settings import Settings

AUDIENCE = "https://klickpos-license-api-staging-abc123-ew.a.run.app"
DASHBOARD_SA = "klickpos-dashboard-staging@klickpos-license-manager.iam.gserviceaccount.com"


@pytest.fixture
def oidc(monkeypatch) -> dict[str, object]:
    """Stub ``verify_oauth2_token``; the real module is patched in place."""
    seen: dict[str, object] = {"calls": 0, "audience": None, "tokens": []}

    def fake(token, request, audience=None, **kwargs):
        seen["calls"] = int(seen["calls"]) + 1
        seen["audience"] = audience
        seen["tokens"].append(token)
        if token == "service-token":
            return {
                "iss": "https://accounts.google.com",
                "aud": audience,
                "email": DASHBOARD_SA,
                "email_verified": True,
                "sub": "1234567890",
            }
        if token == "foreign-service-token":
            return {
                "iss": "https://accounts.google.com",
                "aud": audience,
                "email": "another-service@klickpos-license-manager.iam.gserviceaccount.com",
                "email_verified": True,
            }
        if token == "unverified-email-token":
            return {
                "aud": audience,
                "email": DASHBOARD_SA,
                "email_verified": False,
            }
        # Signature/expiry/audience failures all surface as this.
        raise ValueError("Wrong recipient, payload audience != required audience")

    monkeypatch.setattr(google_id_token, "verify_oauth2_token", fake)
    return seen


def _settings(settings: Settings, **overrides) -> Settings:
    base = replace(
        settings,
        require_cloud_run_invoker=True,
        cloud_run_audience=AUDIENCE,
        cloud_run_invoker_emails=frozenset({DASHBOARD_SA}),
    )
    return replace(base, **overrides) if overrides else base


@pytest.fixture
def cloud_client(client_factory, settings) -> TestClient:
    """The same app and fakes, with the Cloud Run invoker gate enabled."""
    return client_factory(settings_override=_settings(settings))


# -- verifier unit level ---------------------------------------------------- #


def test_a_valid_service_token_is_accepted_and_the_audience_is_pinned(oidc):
    verifier = ServiceIdentityVerifier(AUDIENCE, frozenset({DASHBOARD_SA}))
    claims = verifier.verify("service-token")
    assert claims["email"] == DASHBOARD_SA
    # The token was checked against the API's own URL, not a caller-supplied one.
    assert oidc["audience"] == AUDIENCE


def test_a_token_for_another_audience_is_refused(oidc):
    verifier = ServiceIdentityVerifier(AUDIENCE, frozenset({DASHBOARD_SA}))
    with pytest.raises(ServiceIdentityRequiredError):
        verifier.verify("token-for-another-service")


def test_an_unverified_email_is_refused(oidc):
    verifier = ServiceIdentityVerifier(AUDIENCE, frozenset({DASHBOARD_SA}))
    with pytest.raises(ServiceIdentityRequiredError):
        verifier.verify("unverified-email-token")


def test_a_valid_token_from_an_unlisted_service_account_is_forbidden(oidc):
    verifier = ServiceIdentityVerifier(AUDIENCE, frozenset({DASHBOARD_SA}))
    with pytest.raises(ServiceIdentityNotAllowedError):
        verifier.verify("foreign-service-token")


def test_an_empty_caller_allowlist_accepts_any_verified_google_caller(oidc):
    """Development convenience only; production refuses this combination."""
    verifier = ServiceIdentityVerifier(AUDIENCE, frozenset())
    assert verifier.verify("foreign-service-token")["email"]


def test_a_non_bearer_header_is_not_a_service_identity(oidc):
    verifier = ServiceIdentityVerifier(AUDIENCE, frozenset({DASHBOARD_SA}))
    with pytest.raises(ServiceIdentityRequiredError):
        verifier.check(f"Basic {DASHBOARD_SA}")
    with pytest.raises(ServiceIdentityRequiredError):
        verifier.check(None)


def test_the_verifier_refuses_to_exist_without_an_audience():
    with pytest.raises(ValueError):
        ServiceIdentityVerifier("", frozenset({DASHBOARD_SA}))


# -- API level -------------------------------------------------------------- #


def test_the_dashboard_service_identity_and_the_admin_token_are_both_required(
    oidc, cloud_client, admin_headers
):
    both = cloud_client.get(
        "/v1/overview",
        headers={
            **admin_headers,
            SERVICE_IDENTITY_HEADER: "Bearer service-token",
        },
    )
    assert both.status_code == 200, both.text

    without_caller = cloud_client.get("/v1/overview", headers=admin_headers)
    assert without_caller.status_code == 401
    assert without_caller.json()["error"]["code"] == "service_identity_required"

    without_admin = cloud_client.get(
        "/v1/overview",
        headers={SERVICE_IDENTITY_HEADER: "Bearer service-token"},
    )
    assert without_admin.status_code == 401
    assert without_admin.json()["error"]["code"] == "unauthorized"


def test_the_service_identity_is_checked_before_the_firebase_token(oidc, cloud_client):
    """No credentials at all must not reveal whether an admin is signed in."""
    response = cloud_client.get("/v1/overview")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "service_identity_required"


def test_a_foreign_service_account_is_forbidden_even_with_a_valid_admin(
    oidc, cloud_client, admin_headers
):
    response = cloud_client.get(
        "/v1/overview",
        headers={
            **admin_headers,
            SERVICE_IDENTITY_HEADER: "Bearer foreign-service-token",
        },
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "service_identity_not_allowed"


def test_the_invoker_check_is_off_unless_configured(container, settings, admin_headers):
    """Local runs keep working: the gate exists only when the operator asks."""
    client = TestClient(create_app(settings=settings, container=container))
    assert client.get("/v1/overview", headers=admin_headers).status_code == 200


# -- configuration fail-closed --------------------------------------------- #


def test_an_invoker_check_without_an_audience_is_refused(settings):
    with pytest.raises(ValueError, match="CLOUD_RUN_AUDIENCE"):
        replace(
            settings,
            require_cloud_run_invoker=True,
            cloud_run_audience="",
        )


def test_production_refuses_an_unknown_caller_allowlist(tmp_path):
    with pytest.raises(ValueError, match="CLOUD_RUN_INVOKERS"):
        Settings(
            env="production",
            firebase_project_id="klickpos-license-manager",
            signing_secret_name="LICENSE_API_SIGNING_SECRET",
            code_encryption_secret_name="LICENSE_API_CODE_ENC_SECRET",
            require_cloud_run_invoker=True,
            cloud_run_audience=AUDIENCE,
            verification_keys_file=str(tmp_path / "keys.json"),
        )


def test_production_accepts_a_pinned_dashboard_identity(tmp_path):
    settings = Settings(
        env="production",
        firebase_project_id="klickpos-license-manager",
        signing_secret_name="LICENSE_API_SIGNING_SECRET",
        code_encryption_secret_name="LICENSE_API_CODE_ENC_SECRET",
        require_cloud_run_invoker=True,
        cloud_run_audience=AUDIENCE + "/",
        cloud_run_invoker_emails=frozenset({DASHBOARD_SA}),
        verification_keys_file=str(tmp_path / "keys.json"),
    )
    # The trailing slash of a Cloud Run URL is normalised away: the audience
    # must match the token's ``aud`` exactly, which never carries one.
    assert settings.cloud_run_audience == AUDIENCE


def test_environment_variables_are_read_for_the_invoker_check():
    settings = Settings.from_env(
        {
            "LICENSE_API_ENV": "production",
            "LICENSE_API_FIREBASE_PROJECT_ID": "klickpos-license-manager",
            "LICENSE_API_SIGNING_SECRET": "LICENSE_API_SIGNING_SECRET",
            "LICENSE_API_CODE_ENC_SECRET": "LICENSE_API_CODE_ENC_SECRET",
            "LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER": "1",
            "LICENSE_API_CLOUD_RUN_AUDIENCE": AUDIENCE,
            "LICENSE_API_CLOUD_RUN_INVOKERS": f"{DASHBOARD_SA},other@x.iam.gserviceaccount.com",
        }
    )
    assert settings.require_cloud_run_invoker is True
    assert settings.cloud_run_invoker_emails == frozenset(
        {DASHBOARD_SA, "other@x.iam.gserviceaccount.com"}
    )
