"""Request-size caps, strict bodies and rate limits."""

from __future__ import annotations

from dataclasses import replace

from testkit import HW_A


def test_an_oversized_body_is_rejected_before_parsing(client, admin_headers):
    huge = {
        "request_code": "SMPr1." + "A" * 20000,
    }
    response = client.post("/v1/licenses", json=huge, headers=admin_headers)
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "request_too_large"
    assert response.json()["error"]["details"]["max_bytes"] == 8192


def test_an_unknown_field_is_a_validation_error(client, admin_headers):
    response = client.post(
        "/v1/licenses",
        json={"hw_hash": HW_A, "expires_at": "2030-01-01"},
        headers=admin_headers,
    )
    assert response.status_code == 422
    body = response.json()["error"]
    assert body["code"] == "validation_error"
    assert "expires_at" in str(body["details"])


def test_a_code_field_cannot_exceed_the_contract_limit(client, admin_headers):
    response = client.post(
        "/v1/requests/parse",
        json={"request_code": "A" * 513},
        headers=admin_headers,
    )
    assert response.status_code == 422


def test_the_read_rate_limit_is_enforced(client_factory, settings, admin_headers):
    tight = replace(settings, rate_limit_per_minute=2)
    client = client_factory(settings_override=tight)
    for _ in range(2):
        assert client.get(f"/v1/devices/{HW_A}", headers=admin_headers).status_code == 404
    limited = client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "rate_limited"
    assert int(limited.headers["retry-after"]) >= 1


def test_the_issuance_rate_limit_is_separate_and_tighter(
    client_factory, settings, admin_headers
):
    tight = replace(settings, issue_rate_limit_per_minute=1)
    client = client_factory(settings_override=tight)
    first = client.post("/v1/licenses", json={"hw_hash": HW_A}, headers=admin_headers)
    assert first.status_code == 201
    second = client.post("/v1/licenses", json={"hw_hash": HW_A}, headers=admin_headers)
    assert second.status_code == 429
    # Reads are unaffected by the issuance window.
    assert client.get(f"/v1/devices/{HW_A}", headers=admin_headers).status_code == 200


def test_limits_are_per_administrator(client_factory, settings, admin_headers, stranger_headers):
    tight = replace(settings, rate_limit_per_minute=1)
    client = client_factory(settings_override=tight)
    client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert client.get(f"/v1/devices/{HW_A}", headers=admin_headers).status_code == 429
    # A different account has its own window (and is refused by the allowlist
    # rather than the limiter).
    assert client.get(f"/v1/devices/{HW_A}", headers=stranger_headers).status_code == 403
