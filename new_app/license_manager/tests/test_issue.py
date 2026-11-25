"""Lifetime license issuance — format, compatibility, binding, storage."""

from __future__ import annotations

import base64
import json
from datetime import datetime, timezone

import pytest

from service import shared
from testkit import HW_A, HW_B, issue, make_request_code

UTC = timezone.utc


def test_issuance_returns_a_signed_lifetime_code(client, admin_headers, keys_file):
    body = issue(client, admin_headers, HW_A)
    assert body["created"] is True
    assert body["notice"] is None
    license_ = body["license"]
    assert license_["license_id"].startswith("LIC-")
    assert license_["kind"] == "lifetime"
    assert license_["status"] == "active"
    assert license_["features"] == ["pos"]
    assert license_["activation_code"].startswith("SMP1.")
    assert license_["activation_code"].count(".") == 2

    # The customer's own verifier accepts it — no protocol change anywhere.
    payload = shared.verify_activation_code(
        license_["activation_code"],
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=HW_A,
    )
    assert payload.license_id == license_["license_id"]
    assert payload.kind == "lifetime"
    assert payload.hw_hash == HW_A


def test_the_signed_payload_is_exactly_the_smp1_v1_field_set(client, admin_headers):
    code = issue(client, admin_headers, HW_A)["license"]["activation_code"]
    _, payload_segment, _ = code.split(".")
    document = json.loads(
        base64.b32decode(payload_segment + "=" * (-len(payload_segment) % 8))
    )
    assert set(document) == set(shared.PAYLOAD_FIELDS)
    assert document["v"] == 1
    assert document["kind"] == "lifetime"
    # No expiry field exists, by contract.
    assert "expires_at" not in document
    assert "expiration" not in document


def test_issuance_is_byte_identical_to_the_existing_offline_generator(
    tmp_path, owner_key, signing_key, keys_file
):
    """The hosted API must produce the same bytes as ``tools.license_generator``.

    Same seed, same key id, same license id, same timestamp: the two code
    strings must be identical, character for character.
    """
    from tools.license_generator import generator, keystore

    from service.signing import LicenseIssuer

    key_id, seed, public = owner_key
    key_dir = tmp_path / "owner_keys"
    keystore.save_keystore(
        key_dir,
        {
            key_id: keystore.StoredKey(
                key_id=key_id,
                created_at="2026-01-01T00:00:00+00:00",
                label="test",
                private_seed=seed,
                public=public,
            )
        },
    )
    moment = datetime(2026, 3, 1, 12, 0, 0, tzinfo=UTC)

    reference = generator.issue_license(
        make_request_code(HW_A),
        key_id=key_id,
        key_dir=key_dir,
        license_id="LIC-FIXED0001",
        issued_at=moment,
    )

    issuer = LicenseIssuer(
        key=signing_key,
        verification_keys=shared.load_customer_verification_keys(str(keys_file)),
        clock=lambda: moment,
    )
    ours = issuer.issue(hw_hash=HW_A, license_id="LIC-FIXED0001", issued_at=moment)

    # The whole code — payload segment AND signature segment — is identical.
    assert ours.code == reference.code
    ours_payload, ours_signature = ours.code.split(".")[1:]
    ref_payload, ref_signature = reference.code.split(".")[1:]
    assert (ours_payload, ours_signature) == (ref_payload, ref_signature)
    # ... and the signed bytes are the contract's canonical encoding.
    assert ours.payload_bytes == shared.canonical_json(
        __import__("json").loads(ours.payload_bytes)
    )


def test_a_code_is_bound_to_its_hardware(client, admin_headers, keys_file):
    code = issue(client, admin_headers, HW_A)["license"]["activation_code"]
    keys = shared.load_customer_verification_keys(str(keys_file))
    with pytest.raises(shared.LicenseBoundElsewhereError):
        shared.verify_activation_code(code, keys=keys, expected_hw_hash=HW_B)


def test_the_api_refuses_to_emit_a_code_signed_by_an_unpublished_key(
    tmp_path, settings, repository, verifier, clock, signing_key
):
    """A key the customer package does not ship would fail on the customer's PC."""
    from fastapi.testclient import TestClient

    from service.api import create_app
    from service.container import build_container
    from service.signing import LicenseIssuer

    empty_keys = tmp_path / "empty_keys.json"
    empty_keys.write_text("{}", encoding="utf-8")
    issuer = LicenseIssuer(
        key=signing_key, verification_keys={}, clock=clock
    )
    broken = build_container(
        settings,
        repository=repository,
        verifier=verifier,
        issuer_factory=lambda: issuer,
        clock=clock,
    )
    client = TestClient(create_app(settings=settings, container=broken))
    response = client.post(
        "/v1/licenses",
        json={"request_code": make_request_code(HW_A)},
        headers={"Authorization": "Bearer admin-token"},
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "signing_key_not_published"
    assert repository.get_device(HW_A) is None
    assert repository.list_licenses_for_device(HW_A) == []


def test_the_device_and_license_documents_are_written(client, admin_headers, repository):
    body = issue(client, admin_headers, HW_A)
    device = repository.get_device(HW_A)
    assert device is not None
    assert device.current_license_id == body["license"]["license_id"]
    assert device.install_id == "install-0001"
    assert device.request_code is not None and device.request_code.startswith("SMPr1.")
    assert device.fingerprint_display_code.count("-") == 12

    record = repository.get_license(body["license"]["license_id"])
    assert record.activation_code == body["license"]["activation_code"]
    assert record.created_by == "admin-1"
    assert record.kind == "lifetime"


def test_the_stored_code_is_sealed_at_rest(client, admin_headers, cipher, repository):
    """Nothing stores the plaintext code outside the encrypted envelope."""
    body = issue(client, admin_headers, HW_A)
    license_id = body["license"]["license_id"]
    sealed = cipher.seal(license_id=license_id, code=body["license"]["activation_code"])
    assert body["license"]["activation_code"] not in sealed
    assert sealed.startswith("gcm1:")
    assert cipher.open(license_id=license_id, envelope=sealed) == body["license"][
        "activation_code"
    ]


def test_a_bare_fingerprint_is_accepted_without_a_request_code(client, admin_headers):
    response = client.post(
        "/v1/licenses", json={"hw_hash": HW_A}, headers=admin_headers
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["license"]["hw_hash"] == HW_A
    assert body["license"]["install_id"] is None


def test_exactly_one_of_request_code_and_hw_hash_is_required(client, admin_headers):
    neither = client.post("/v1/licenses", json={}, headers=admin_headers)
    assert neither.status_code == 422
    both = client.post(
        "/v1/licenses",
        json={"request_code": make_request_code(HW_A), "hw_hash": HW_A},
        headers=admin_headers,
    )
    assert both.status_code == 422


def test_an_invalid_fingerprint_is_rejected(client, admin_headers):
    for value in ("a" * 63, "a" * 65, "z" * 64, "not-a-hash", " ", "0x" + "a" * 64):
        response = client.post(
            "/v1/licenses", json={"hw_hash": value}, headers=admin_headers
        )
        assert response.status_code == 422, value


def test_uppercase_hex_is_normalised_to_the_signed_lowercase_digest(
    client, admin_headers, repository
):
    """An administrator pasting uppercase hex must not create a second device."""
    lower = issue(client, admin_headers, HW_A)
    upper = client.post(
        "/v1/licenses", json={"hw_hash": HW_A.upper()}, headers=admin_headers
    )
    assert upper.status_code == 200
    assert upper.json()["created"] is False
    assert upper.json()["license"]["license_id"] == lower["license"]["license_id"]
    assert repository.get_device(HW_A).hw_hash == HW_A


@pytest.mark.parametrize(
    "features",
    [["POS"], ["bad token"], ["pos", "pos"], ["x" * 33], ["pos"] * 33],
)
def test_invalid_feature_grants_are_rejected(client, admin_headers, features):
    response = client.post(
        "/v1/licenses",
        json={"request_code": make_request_code(HW_A), "features": features},
        headers=admin_headers,
    )
    assert response.status_code == 422


def test_multiple_features_are_signed(client, admin_headers, keys_file):
    body = issue(client, admin_headers, HW_A, features=["pos", "inventory"])
    payload = shared.verify_activation_code(
        body["license"]["activation_code"],
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=HW_A,
    )
    assert payload.features == ("pos", "inventory")


def test_customer_details_are_stored_with_the_license(client, admin_headers, repository):
    body = issue(
        client,
        admin_headers,
        HW_A,
        customer={"name": "Epicerie Al Noor", "email": "owner@example.com"},
    )
    record = repository.get_license(body["license"]["license_id"])
    assert record.customer_id is not None
    stored = repository.get_customer(record.customer_id)
    assert stored["name"] == "Epicerie Al Noor"
    assert stored["email"] == "owner@example.com"


def test_an_unknown_customer_id_is_rejected(client, admin_headers):
    response = client.post(
        "/v1/licenses",
        json={"request_code": make_request_code(HW_A), "customer_id": "CUS-does-not-exist"},
        headers=admin_headers,
    )
    assert response.status_code == 422


def test_issuance_is_audited(client, admin_headers, repository):
    body = issue(client, admin_headers, HW_A)
    assert "license_issued" in repository.audit_actions()
    event = [e for e in repository.audit_events if e.action == "license_issued"][0]
    assert event.license_id == body["license"]["license_id"]
    assert event.actor_uid == "admin-1"
    assert "SMP1" not in json.dumps(event.details)
