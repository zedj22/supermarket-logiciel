"""``POST /v1/licenses/{license_id}/revoke`` — administrative revocation semantics."""

from __future__ import annotations

from service import shared
from service.service import REVOCATION_NOTICE
from testkit import HW_A, issue


def test_revocation_is_recorded_with_its_reason(client, admin_headers, repository):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    response = client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["license"]["status"] == "revoked"
    assert body["license"]["revoked_reason"] == "refund issued"
    assert body["license"]["revoked_at"] is not None
    assert repository.get_license(license_id).status == "revoked"


def test_the_response_states_that_a_lifetime_license_cannot_be_remotely_disabled(
    client, admin_headers
):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    body = client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    ).json()
    assert body["notice"] == REVOCATION_NOTICE
    assert "cannot remotely deactivate" in body["notice"]
    assert "keeps running" in body["notice"]


def test_revocation_does_not_invalidate_the_activation_code(
    client, admin_headers, keys_file
):
    """The signed code is offline material: revocation is a record, not a kill switch."""
    created = issue(client, admin_headers, HW_A)["license"]
    client.post(
        f"/v1/licenses/{created['license_id']}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    )
    payload = shared.verify_activation_code(
        created["activation_code"],
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=HW_A,
    )
    assert payload.license_id == created["license_id"]


def test_revocation_is_audited(client, admin_headers, repository):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    )
    events = [e for e in repository.audit_events if e.action == "license_revoked"]
    assert len(events) == 1
    assert events[0].license_id == license_id
    assert events[0].actor_uid == "admin-1"


def test_revoking_twice_is_idempotent(client, admin_headers, repository):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    first = client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    )
    second = client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "refund issued again"},
        headers=admin_headers,
    )
    assert second.status_code == 200
    assert second.json()["license"]["revoked_reason"] == "refund issued"
    assert repository.audit_actions().count("license_revoked") == 1
    assert first.json()["license"]["status"] == "revoked"


def test_a_superseded_license_cannot_be_revoked(client, admin_headers):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    client.post(
        f"/v1/licenses/{license_id}/reissue",
        json={"reason": "support replacement", "confirm": True},
        headers=admin_headers,
    )
    response = client.post(
        f"/v1/licenses/{license_id}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "license_conflict"


def test_resubmitting_a_revoked_fingerprint_never_mints_a_second_license(
    client, admin_headers, repository
):
    """The one-license rule still wins; the answer says the license is revoked."""
    original = issue(client, admin_headers, HW_A)['license']
    client.post(
        f"/v1/licenses/{original['license_id']}/revoke",
        json={"reason": "refund issued"},
        headers=admin_headers,
    )
    again = issue(client, admin_headers, HW_A)
    assert again["created"] is False
    assert again["license"]["license_id"] == original["license_id"]
    assert "revoked" in again["notice"].lower()
    assert len(repository.list_licenses_for_device(HW_A)) == 1


def test_revoking_an_unknown_license_is_a_controlled_404(client, admin_headers):
    response = client.post(
        "/v1/licenses/LIC-unknown/revoke",
        json={"reason": "nothing here"},
        headers=admin_headers,
    )
    assert response.status_code == 404


def test_a_reason_is_required(client, admin_headers):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    response = client.post(
        f"/v1/licenses/{license_id}/revoke", json={"reason": ""}, headers=admin_headers
    )
    assert response.status_code == 422
