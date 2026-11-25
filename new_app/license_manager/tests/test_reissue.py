"""``POST /v1/licenses/{license_id}/reissue`` — history-preserving replacement."""

from __future__ import annotations

from service import shared
from testkit import HW_A, issue


def test_reissue_creates_a_new_license_and_keeps_the_original(
    client, admin_headers, repository, keys_file
):
    original = issue(client, admin_headers, HW_A)["license"]
    response = client.post(
        f"/v1/licenses/{original['license_id']}/reissue",
        json={"reason": "mainboard replaced", "confirm": True},
        headers=admin_headers,
    )
    assert response.status_code == 200, response.text
    body = response.json()

    new = body["license"]
    assert new["license_id"] != original["license_id"]
    assert new["activation_code"] != original["activation_code"]
    assert new["reissued_from"] == original["license_id"]
    assert new["status"] == "active"
    assert body["previous"]["status"] == "superseded"
    assert body["previous"]["superseded_by"] == new["license_id"]

    # Both records survive: nothing was overwritten.
    previous_record = repository.get_license(original["license_id"])
    new_record = repository.get_license(new["license_id"])
    assert previous_record is not None and new_record is not None
    assert previous_record.activation_code == original["activation_code"]
    assert len(repository.list_licenses_for_device(HW_A)) == 2

    keys = shared.load_customer_verification_keys(str(keys_file))
    payload = shared.verify_activation_code(
        new["activation_code"], keys=keys, expected_hw_hash=HW_A
    )
    assert payload.license_id == new["license_id"]


def test_the_device_now_points_at_the_new_license(client, admin_headers, repository):
    original = issue(client, admin_headers, HW_A)["license"]
    new = client.post(
        f"/v1/licenses/{original['license_id']}/reissue",
        json={"reason": "support replacement", "confirm": True},
        headers=admin_headers,
    ).json()["license"]
    assert repository.get_device(HW_A).current_license_id == new["license_id"]


def test_reissue_is_fully_audited(client, admin_headers, repository):
    original = issue(client, admin_headers, HW_A)["license"]
    new = client.post(
        f"/v1/licenses/{original['license_id']}/reissue",
        json={"reason": "customer lost the code", "confirm": True},
        headers=admin_headers,
    ).json()["license"]
    actions = repository.audit_actions()
    assert "license_superseded" in actions
    assert "license_reissued" in actions
    assert "license_reissue_reason" in actions
    reason_event = [
        e for e in repository.audit_events if e.action == "license_reissue_reason"
    ][0]
    assert reason_event.details["reason"] == "customer lost the code"
    assert reason_event.details["previous_license_id"] == original["license_id"]
    assert reason_event.license_id == new["license_id"]


def test_the_superseded_code_still_verifies_cryptographically(
    client, admin_headers, keys_file
):
    """Superseded is a records state; the SMP1 code itself stays valid."""
    original = issue(client, admin_headers, HW_A)["license"]
    client.post(
        f"/v1/licenses/{original['license_id']}/reissue",
        json={"reason": "support replacement", "confirm": True},
        headers=admin_headers,
    )
    payload = shared.verify_activation_code(
        original["activation_code"],
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=HW_A,
    )
    assert payload.license_id == original["license_id"]


def test_reissue_requires_explicit_confirmation(client, admin_headers, repository):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    response = client.post(
        f"/v1/licenses/{license_id}/reissue",
        json={"reason": "no confirmation given", "confirm": False},
        headers=admin_headers,
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "confirmation_required"
    assert len(repository.list_licenses_for_device(HW_A)) == 1


def test_reissue_requires_a_reason(client, admin_headers):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    response = client.post(
        f"/v1/licenses/{license_id}/reissue",
        json={"reason": "no", "confirm": True},
        headers=admin_headers,
    )
    assert response.status_code == 422


def test_a_superseded_license_cannot_be_reissued_again(client, admin_headers):
    license_id = issue(client, admin_headers, HW_A)["license"]["license_id"]
    client.post(
        f"/v1/licenses/{license_id}/reissue",
        json={"reason": "first replacement", "confirm": True},
        headers=admin_headers,
    )
    second = client.post(
        f"/v1/licenses/{license_id}/reissue",
        json={"reason": "second replacement", "confirm": True},
        headers=admin_headers,
    )
    assert second.status_code == 409
    assert second.json()["error"]["code"] == "license_conflict"


def test_reissue_of_an_unknown_license_is_a_controlled_404(client, admin_headers):
    response = client.post(
        "/v1/licenses/LIC-unknown/reissue",
        json={"reason": "nothing to replace", "confirm": True},
        headers=admin_headers,
    )
    assert response.status_code == 404


def test_issuing_again_after_a_reissue_returns_the_current_license(
    client, admin_headers
):
    original = issue(client, admin_headers, HW_A)["license"]
    new = client.post(
        f"/v1/licenses/{original['license_id']}/reissue",
        json={"reason": "support replacement", "confirm": True},
        headers=admin_headers,
    ).json()["license"]
    repeated = issue(client, admin_headers, HW_A)
    assert repeated["created"] is False
    assert repeated["license"]["license_id"] == new["license_id"]
