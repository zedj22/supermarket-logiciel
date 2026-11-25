"""Firebase ID token -> allowlist -> App Check."""

from __future__ import annotations

from dataclasses import replace

import pytest

from service.auth import StaticTokenVerifier
from testkit import APP_CHECK_TOKEN, HW_A, issue


def test_health_is_the_only_public_route(client):
    assert client.get("/healthz").status_code == 200


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Basic abc"},
        {"Authorization": "Bearer"},
        {"Authorization": "Bearer not-a-real-token"},
    ],
)
def test_requests_without_a_valid_token_are_401(client, headers):
    response = client.get(f"/v1/devices/{HW_A}", headers=headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_authentication_is_required_on_every_license_route(client):
    for method, path, body in (
        ("post", "/v1/requests/parse", {"request_code": "SMPr1.AAAA"}),
        ("post", "/v1/licenses", {"hw_hash": HW_A}),
        ("get", f"/v1/devices/{HW_A}", None),
        ("get", "/v1/licenses/LIC-x/code", None),
        ("post", "/v1/licenses/LIC-x/reissue", {"reason": "why not", "confirm": True}),
        ("post", "/v1/licenses/LIC-x/revoke", {"reason": "why not"}),
    ):
        response = getattr(client, method)(path, **({"json": body} if body else {}))
        assert response.status_code == 401, path


def test_an_authenticated_but_unknown_account_is_403(client, stranger_headers):
    response = client.get(f"/v1/devices/{HW_A}", headers=stranger_headers)
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_not_allowlisted"


def test_an_admin_is_allowed(client, admin_headers):
    issue(client, admin_headers, HW_A)
    response = client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert response.status_code == 200


def test_an_empty_allowlist_denies_everyone(client_factory, settings, admin_headers):
    empty = replace(settings, admin_uids=frozenset(), admin_emails=frozenset())
    client = client_factory(settings_override=empty)
    response = client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_not_allowlisted"


def test_the_allowlist_can_be_email_based(client_factory, settings, admin_headers):
    by_email = replace(
        settings, admin_uids=frozenset(), admin_emails=frozenset({"admin@example.com"})
    )
    client = client_factory(settings_override=by_email)
    issue(client, admin_headers, HW_A)
    assert client.get(f"/v1/devices/{HW_A}", headers=admin_headers).status_code == 200


def test_the_email_allowlist_is_case_insensitive(client_factory, settings):
    by_email = replace(
        settings, admin_uids=frozenset(), admin_emails=frozenset({"admin@example.com"})
    )
    verifier = StaticTokenVerifier({"tok": {"uid": "x", "email": "ADMIN@Example.COM"}})
    client = client_factory(settings_override=by_email, verifier_override=verifier)
    response = client.get(f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer tok"})
    assert response.status_code == 404  # allowed through, device simply unknown


def test_app_check_is_required_when_configured(client_factory, settings, admin_headers):
    guarded = replace(settings, require_app_check=True)
    client = client_factory(settings_override=guarded)
    response = client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "app_check_failed"


def test_a_valid_app_check_token_satisfies_the_gate(
    client_factory, settings, admin_headers
):
    guarded = replace(settings, require_app_check=True)
    client = client_factory(settings_override=guarded)
    headers = {**admin_headers, "X-Firebase-AppCheck": APP_CHECK_TOKEN}
    assert client.get(f"/v1/devices/{HW_A}", headers=headers).status_code == 404
    issue(client, headers, HW_A)
    assert client.get(f"/v1/devices/{HW_A}", headers=headers).status_code == 200


def test_an_invalid_app_check_token_is_refused(client_factory, settings, admin_headers):
    guarded = replace(settings, require_app_check=True)
    client = client_factory(settings_override=guarded)
    headers = {**admin_headers, "X-Firebase-AppCheck": "forged"}
    response = client.get(f"/v1/devices/{HW_A}", headers=headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "app_check_failed"


def test_app_check_never_replaces_the_id_token(client_factory, settings):
    """A valid App Check token alone is not an identity."""
    guarded = replace(settings, require_app_check=True)
    client = client_factory(settings_override=guarded)
    response = client.get(
        f"/v1/devices/{HW_A}", headers={"X-Firebase-AppCheck": APP_CHECK_TOKEN}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_a_bad_id_token_is_still_401_with_a_valid_app_check_token(
    client_factory, settings, admin_headers
):
    guarded = replace(settings, require_app_check=True)
    client = client_factory(settings_override=guarded)
    headers = {
        "Authorization": "Bearer not-a-real-token",
        "X-Firebase-AppCheck": APP_CHECK_TOKEN,
    }
    response = client.get(f"/v1/devices/{HW_A}", headers=headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


def test_the_allowlist_is_still_enforced_with_app_check(
    client_factory, settings, stranger_headers, admin_headers
):
    guarded = replace(settings, require_app_check=True)
    client = client_factory(settings_override=guarded)
    headers = {**stranger_headers, "X-Firebase-AppCheck": APP_CHECK_TOKEN}
    response = client.get(f"/v1/devices/{HW_A}", headers=headers)
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_not_allowlisted"


def test_an_app_check_header_is_ignored_when_enforcement_is_off(
    client_factory, settings, admin_headers
):
    """Local development: the setting, not the header, decides."""
    client = client_factory(settings_override=replace(settings, require_app_check=False))
    issue(client, admin_headers, HW_A)
    assert client.get(f"/v1/devices/{HW_A}", headers=admin_headers).status_code == 200
    forged = {**admin_headers, "X-Firebase-AppCheck": "forged"}
    assert client.get(f"/v1/devices/{HW_A}", headers=forged).status_code == 200


def test_a_provider_failure_is_a_generic_401(client_factory, settings):
    class ExplodingVerifier:
        def verify_id_token(self, token):
            raise RuntimeError("internal project detail: projects/secret-thing")

        def verify_app_check_token(self, token):
            raise RuntimeError("internal detail")

    client = client_factory(verifier_override=ExplodingVerifier())
    response = client.get(
        f"/v1/devices/{HW_A}", headers={"Authorization": "Bearer anything"}
    )
    assert response.status_code == 401
    body = response.text
    assert "internal project detail" not in body
    assert "secret-thing" not in body
    assert "RuntimeError" not in body
