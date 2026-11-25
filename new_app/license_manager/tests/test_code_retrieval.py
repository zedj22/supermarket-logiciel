"""``GET /v1/licenses/{license_id}/code`` — audited retrieval of the original code."""

from __future__ import annotations

from service.service import REVOKED_CODE_WARNING
from testkit import HW_A, issue


def test_the_original_code_is_returned_unchanged(client, admin_headers, repository):
    created = issue(client, admin_headers, HW_A)["license"]
    response = client.get(
        f"/v1/licenses/{created['license_id']}/code", headers=admin_headers
    )
    assert response.status_code == 200
    body = response.json()
    assert body["activation_code"] == created["activation_code"]
    assert body["license_id"] == created["license_id"]
    assert body["hw_hash"] == HW_A
    assert body["status"] == "active"
    assert body["warning"] is None


def test_code_responses_are_never_cached(client, admin_headers):
    created = issue(client, admin_headers, HW_A)["license"]
    response = client.get(
        f"/v1/licenses/{created['license_id']}/code", headers=admin_headers
    )
    assert response.headers["cache-control"] == "no-store"


def test_every_retrieval_is_audited(client, admin_headers, repository):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    client.get(f"/v1/licenses/{license_id}/code", headers=admin_headers)
    client.get(f"/v1/licenses/{license_id}/code", headers=admin_headers)

    events = [e for e in repository.audit_events if e.action == "activation_code_viewed"]
    assert len(events) == 2
    assert all(event.license_id == license_id for event in events)
    assert all(event.actor_uid == "admin-1" for event in events)
    # The audit trail never carries the code itself.
    assert all("SMP1" not in str(event.details) for event in events)


def test_an_unknown_license_is_a_controlled_404(client, admin_headers):
    response = client.get("/v1/licenses/LIC-nope/code", headers=admin_headers)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "license_not_found"


def test_a_superseded_license_keeps_its_code(client, admin_headers):
    original = issue(client, admin_headers, HW_A)["license"]
    client.post(
        f"/v1/licenses/{original['license_id']}/reissue",
        json={"reason": "customer lost the code", "confirm": True},
        headers=admin_headers,
    )
    response = client.get(
        f"/v1/licenses/{original['license_id']}/code", headers=admin_headers
    )
    assert response.status_code == 200
    assert response.json()["status"] == "superseded"
    assert response.json()["activation_code"] == original["activation_code"]


def test_a_revoked_license_code_comes_back_with_a_warning(client, admin_headers):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "chargeback"},
        headers=admin_headers,
    )
    body = client.get(f"/v1/licenses/{license_id}/code", headers=admin_headers).json()
    assert body["status"] == "revoked"
    assert body["warning"] == REVOKED_CODE_WARNING


def test_the_code_is_served_from_the_sealed_record(client, admin_headers, repository):
    created = issue(client, admin_headers, HW_A)["license"]
    stored = repository.get_license(created["license_id"])
    assert stored.activation_code == created["activation_code"]
    # And it is the same code independent of any in-memory cache.
    again = client.get(
        f"/v1/licenses/{created['license_id']}/code", headers=admin_headers
    ).json()
    assert again["activation_code"] == stored.activation_code
