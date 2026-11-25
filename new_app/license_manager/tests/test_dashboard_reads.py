"""Read-only dashboard endpoints: overview, lists, customer detail, audit.

These endpoints exist because the dashboard has to list and search devices,
licenses, customers and audit events, and show totals — the original API could
only fetch one device by its exact fingerprint.  The important properties
pinned here: they are administrator-only, they never return an activation code,
and the duplicate-issuance rules are unaffected.
"""

from __future__ import annotations

from service.service import LicenseService
from testkit import (
    ADMIN_TOKEN,
    HW_A,
    HW_B,
    STRANGER_TOKEN,
    issue,
    make_request_code,
)


def _issue_with_customer(client, headers, hw_hash, name):
    return issue(
        client,
        headers,
        hw_hash,
        customer={"name": name, "email": "owner@example.com"},
    )


def test_the_overview_starts_empty_and_authorised(client, admin_headers):
    response = client.get("/v1/overview", headers=admin_headers)
    assert response.status_code == 200
    body = response.json()
    assert body["counts"] == {
        "customers": 0,
        "devices": 0,
        "active_licenses": 0,
        "revoked_licenses": 0,
        "superseded_licenses": 0,
    }
    assert body["recent_licenses"] == []
    assert body["recent_events"] == []


def test_every_dashboard_read_requires_an_administrator(client, stranger_headers):
    for path in ("/v1/overview", "/v1/devices", "/v1/licenses", "/v1/customers", "/v1/audit"):
        assert client.get(path).status_code == 401
        assert client.get(path, headers=stranger_headers).status_code == 403


def test_the_overview_counts_reflect_issued_licenses(client, admin_headers):
    _issue_with_customer(client, admin_headers, HW_A, "Epicerie Al Noor")
    issue(client, admin_headers, HW_B)

    counts = client.get("/v1/overview", headers=admin_headers).json()["counts"]
    assert counts["devices"] == 2
    assert counts["active_licenses"] == 2
    assert counts["revoked_licenses"] == 0
    assert counts["customers"] == 1


def test_the_overview_lists_the_newest_licenses_first(client, admin_headers, clock):
    first = issue(client, admin_headers, HW_A)
    clock.advance(60)
    second = issue(client, admin_headers, HW_B)

    recent = client.get("/v1/overview", headers=admin_headers).json()["recent_licenses"]
    assert [entry["license_id"] for entry in recent] == [
        second["license"]["license_id"],
        first["license"]["license_id"],
    ]
    assert "activation_code" not in recent[0]


def test_the_overview_reports_recent_activity(client, admin_headers):
    issued = issue(client, admin_headers, HW_A)
    headers = admin_headers
    client.get(f"/v1/licenses/{issued['license']['license_id']}/code", headers=headers)

    events = client.get("/v1/overview", headers=admin_headers).json()["recent_events"]
    actions = [event["action"] for event in events]
    assert "activation_code_viewed" in actions
    assert "license_issued" in actions
    for event in events:
        assert set(event) >= {"event_id", "at", "action", "actor_uid", "hw_hash", "details"}
        assert "activation_code" not in event


def test_licenses_can_be_searched_and_filtered_by_status(client, admin_headers):
    issued = issue(client, admin_headers, HW_A)
    issue(client, admin_headers, HW_B)
    revoke = {"reason": "chargeback", "confirm": True}
    client.post(
        f"/v1/licenses/{issued['license']['license_id']}/revoke",
        json={"reason": revoke["reason"]},
        headers=admin_headers,
    )

    all_items = client.get("/v1/licenses", headers=admin_headers).json()
    assert all_items["total"] == 2
    assert all("activation_code" not in item for item in all_items["items"])

    revoked = client.get("/v1/licenses?status=revoked", headers=admin_headers).json()
    assert [item["license_id"] for item in revoked["items"]] == [
        issued["license"]["license_id"]
    ]

    found = client.get(f"/v1/licenses?query={HW_B[:8]}", headers=admin_headers).json()
    assert found["total"] == 1
    assert found["items"][0]["hw_hash"] == HW_B

    nothing = client.get("/v1/licenses?query=zzzzzzzz", headers=admin_headers).json()
    assert nothing == {"items": [], "total": 0}


def test_devices_list_includes_the_current_license(client, admin_headers):
    issued = issue(client, admin_headers, HW_A)

    body = client.get("/v1/devices", headers=admin_headers).json()
    assert body["total"] == 1
    item = body["items"][0]
    assert item["device"]["hw_hash"] == HW_A
    assert item["current_license"]["license_id"] == issued["license"]["license_id"]
    assert "activation_code" not in item["current_license"]


def test_devices_can_be_searched_by_install_id(client, admin_headers):
    issue(client, admin_headers, HW_A)
    body = client.get(
        "/v1/devices", params={"query": "install-0001"}, headers=admin_headers
    ).json()
    assert body["total"] == 1
    empty = client.get(
        "/v1/devices", params={"query": "no-such-install"}, headers=admin_headers
    ).json()
    assert empty["total"] == 0


def test_customers_list_and_detail(client, admin_headers):
    issued = _issue_with_customer(client, admin_headers, HW_A, "Epicerie Al Noor")
    customer_id = issued["license"]["customer_id"]
    assert customer_id

    listed = client.get("/v1/customers", headers=admin_headers).json()
    assert listed["total"] == 1
    assert listed["items"][0]["name"] == "Epicerie Al Noor"

    searched = client.get(
        "/v1/customers", params={"query": "noor"}, headers=admin_headers
    ).json()
    assert searched["total"] == 1

    detail = client.get(f"/v1/customers/{customer_id}", headers=admin_headers)
    assert detail.status_code == 200
    body = detail.json()
    assert body["customer"]["email"] == "owner@example.com"
    assert [device["hw_hash"] for device in body["devices"]] == [HW_A]
    assert [license["license_id"] for license in body["licenses"]] == [
        issued["license"]["license_id"]
    ]
    assert "activation_code" not in body["licenses"][0]


def test_an_unknown_customer_is_a_404(client, admin_headers):
    response = client.get("/v1/customers/CUS-doesnotexist", headers=admin_headers)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "customer_not_found"


def test_the_audit_log_is_paginated_and_searchable(client, admin_headers):
    issue(client, admin_headers, HW_A)
    issue(client, admin_headers, HW_B)

    body = client.get("/v1/audit", headers=admin_headers).json()
    assert body["total"] >= 2
    assert body["items"][0]["at"] >= body["items"][-1]["at"]
    assert all(item["actor_uid"] == "admin-1" for item in body["items"])

    issued_only = client.get(
        "/v1/audit", params={"query": "license_issued"}, headers=admin_headers
    ).json()
    assert {item["action"] for item in issued_only["items"]} == {"license_issued"}
    assert issued_only["total"] == 2

    by_device = client.get(
        "/v1/audit", params={"query": HW_A}, headers=admin_headers
    ).json()
    assert by_device["total"] >= 1
    assert all(item["hw_hash"] == HW_A for item in by_device["items"])


def test_limits_and_status_parameters_are_validated(client, admin_headers):
    assert client.get("/v1/devices?limit=0", headers=admin_headers).status_code == 422
    assert client.get("/v1/licenses?limit=999", headers=admin_headers).status_code == 422


def test_reading_lists_does_not_issue_anything(client, admin_headers, repository):
    issue(client, admin_headers, HW_A)
    client.get("/v1/licenses", headers=admin_headers)
    client.get("/v1/devices", headers=admin_headers)
    client.get("/v1/overview", headers=admin_headers)
    assert repository.audit_actions().count("license_issued") == 1


def test_the_search_scan_bound_is_documented_for_the_dashboard():
    assert LicenseService is not None
    from service.service import MAX_SCAN

    assert MAX_SCAN >= 200


def test_parse_still_reports_an_existing_license_for_the_issue_page(client, admin_headers):
    issued = issue(client, admin_headers, HW_A)
    parsed = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_A)},
        headers=admin_headers,
    ).json()
    assert parsed["existing_license"]["license_id"] == issued["license"]["license_id"]
    assert parsed["device"]["current_license_id"] == issued["license"]["license_id"]


def test_a_dashboard_token_cannot_be_confused_with_the_admin_token(client_factory):
    stranger = client_factory()
    assert (
        stranger.get(
            "/v1/overview", headers={"Authorization": f"Bearer {STRANGER_TOKEN}"}
        ).status_code
        == 403
    )
    assert (
        stranger.get(
            "/v1/overview", headers={"Authorization": f"Bearer {ADMIN_TOKEN}"}
        ).status_code
        == 200
    )
