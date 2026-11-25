"""Real Firestore integration tests (only run when an emulator is configured).

These prove the *production* repository works against a real Firestore server
rather than the in-process fake:

    FIRESTORE_EMULATOR_HOST=127.0.0.1:8081 \
    FIRESTORE_EMULATOR_PROJECT=demo-klickpos \
    pytest tests/test_firestore_emulator.py -q

Skipped when ``FIRESTORE_EMULATOR_HOST`` is unset, so the normal suite stays
cloud-free.  Nothing here touches a real project: the emulator needs no
credentials and the project id is a local ``demo-*`` placeholder.
"""

from __future__ import annotations

import os
import threading
import uuid
from dataclasses import replace
from datetime import datetime, timezone

import pytest

from service import shared
from service.contracts import AuditEvent, LicenseDraft, Revocation
from service.errors import ApiError
from service.signing import LicenseIssuer

try:  # the SDK is optional; this whole module is skipped without an emulator
    from google.cloud.firestore_v1.base_query import FieldFilter
except ImportError:  # pragma: no cover - deployment dependency
    FieldFilter = None  # type: ignore[assignment,misc]

EMULATOR = os.environ.get("FIRESTORE_EMULATOR_HOST", "")

pytestmark = pytest.mark.skipif(
    not EMULATOR, reason="FIRESTORE_EMULATOR_HOST is not set"
)

PROJECT = os.environ.get("FIRESTORE_EMULATOR_PROJECT", "demo-klickpos")


def _digest() -> str:
    """A unique 64-hex fingerprint per test (no hardware is ever involved)."""
    return uuid.uuid4().hex + uuid.uuid4().hex


def _client():
    from google.cloud import firestore

    return firestore.Client(project=PROJECT)


def _where(collection, field: str, value):
    """Equality query through the supported ``filter=`` API.

    The positional ``where(field, op, value)`` overload is deprecated (and
    emits a FutureWarning from the SDK); tests use the same spelling as the
    production repository so a regression there is visible here too.
    """
    return collection.where(filter=FieldFilter(field, "==", value))


def _audit_factory(hw_hash: str):
    """A plain audit-event factory (no service, no principal)."""

    def make(action: str, license_id: str | None) -> AuditEvent:
        return AuditEvent(
            event_id=uuid.uuid4().hex,
            at=datetime(2026, 3, 1, tzinfo=timezone.utc),
            action=action,
            actor_uid="admin-1",
            license_id=license_id,
            hw_hash=hw_hash,
        )

    return make


def _draft(issuer: LicenseIssuer, hw_hash: str, **overrides) -> LicenseDraft:
    draft = LicenseDraft(
        hw_hash=hw_hash,
        issued=issuer.issue(hw_hash=hw_hash),
        created_at=datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc),
        created_by="admin-1",
        install_id="install-0001",
        request_code="SMPr1.AAAA",
    )
    return replace(draft, **overrides) if overrides else draft


@pytest.fixture
def real_repo(cipher, signing_key, keys_file, clock):
    from service.firestore_repository import FirestoreLicenseRepository

    client = _client()
    repository = FirestoreLicenseRepository(client, cipher, clock=clock)
    issuer = LicenseIssuer(
        key=signing_key,
        verification_keys=shared.load_customer_verification_keys(str(keys_file)),
        clock=clock,
    )
    return repository, client, issuer


def test_the_emulator_is_reachable(real_repo):
    _, client, _ = real_repo
    client.collection("_preflight").document("probe").set({"ok": True})
    assert client.collection("_preflight").document("probe").get().to_dict() == {
        "ok": True
    }


def test_documents_are_created_with_the_documented_shape(real_repo):
    repository, client, issuer = real_repo
    hw = _digest()

    outcome = repository.create_or_get_license(
        hw_hash=hw,
        build=lambda: _draft(issuer, hw),
        make_audit=_audit_factory(hw),
    )
    assert outcome.created is True
    license_id = outcome.license.license_id

    license_doc = client.collection("licenses").document(license_id).get().to_dict()
    assert license_doc["kind"] == "lifetime"
    assert license_doc["status"] == "active"
    assert license_doc["hw_hash"] == hw
    assert license_doc["key_id"] == "test-owner"
    assert license_doc["features"] == ["pos"]
    assert license_doc["created_by"] == "admin-1"
    assert license_doc["activation_code_sealed"].startswith("gcm1:")
    assert "SMP1" not in license_doc["activation_code_sealed"]

    device_doc = client.collection("devices").document(hw).get().to_dict()
    assert device_doc["current_license_id"] == license_id
    assert device_doc["install_id"] == "install-0001"

    audits = list(
        _where(client.collection("audit_log"), "license_id", license_id).stream()
    )
    assert len(audits) == 1
    assert audits[0].to_dict()["action"] == "license_issued"


def test_the_code_reads_back_through_a_second_client(real_repo, cipher, keys_file):
    """A separate client — the state a restart would find on the server."""
    repository, _, issuer = real_repo
    hw = _digest()
    outcome = repository.create_or_get_license(
        hw_hash=hw, build=lambda: _draft(issuer, hw), make_audit=_audit_factory(hw)
    )

    from service.firestore_repository import FirestoreLicenseRepository

    fresh = FirestoreLicenseRepository(_client(), cipher)
    fetched = fresh.get_license(outcome.license.license_id)
    assert fetched is not None
    assert fetched.activation_code == outcome.license.activation_code

    # And that stored code still satisfies the customer's verifier.
    payload = shared.verify_activation_code(
        fetched.activation_code,
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=hw,
    )
    assert payload.license_id == outcome.license.license_id


def test_duplicate_prevention_uses_a_real_transaction(real_repo):
    repository, client, issuer = real_repo
    hw = _digest()
    builds: list[int] = []

    def build() -> LicenseDraft:
        builds.append(1)
        return _draft(issuer, hw)

    audit = _audit_factory(hw)
    first = repository.create_or_get_license(hw_hash=hw, build=build, make_audit=audit)
    second = repository.create_or_get_license(hw_hash=hw, build=build, make_audit=audit)

    assert first.created is True
    assert second.created is False
    assert second.license.license_id == first.license.license_id
    assert len(builds) == 1
    assert len(list(_where(client.collection("licenses"), "hw_hash", hw).stream())) == 1


def test_concurrent_requests_create_exactly_one_license(real_repo):
    repository, client, issuer = real_repo
    hw = _digest()
    ids: list[str] = []
    errors: list[BaseException] = []
    barrier = threading.Barrier(5)
    audit = _audit_factory(hw)

    def attempt() -> None:
        try:
            barrier.wait(timeout=20)
            outcome = repository.create_or_get_license(
                hw_hash=hw, build=lambda: _draft(issuer, hw), make_audit=audit
            )
            ids.append(outcome.license.license_id)
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=attempt) for _ in range(5)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=60)

    assert not errors, errors
    assert len(set(ids)) == 1
    assert len(list(_where(client.collection("licenses"), "hw_hash", hw).stream())) == 1


def test_the_http_api_works_end_to_end_against_real_firestore(
    settings, cipher, signing_key, keys_file, verifier, clock
):
    """HTTP -> service -> real Firestore, with no production signing material."""
    from fastapi.testclient import TestClient

    from service.api import create_app
    from service.container import build_container
    from service.firestore_repository import FirestoreLicenseRepository
    from testkit import ADMIN_TOKEN, make_request_code

    repository = FirestoreLicenseRepository(_client(), cipher, clock=clock)
    issuer = LicenseIssuer(
        key=signing_key,
        verification_keys=shared.load_customer_verification_keys(str(keys_file)),
        clock=clock,
    )
    built = build_container(
        settings,
        repository=repository,
        verifier=verifier,
        issuer_factory=lambda: issuer,
        clock=clock,
    )
    client = TestClient(create_app(settings=settings, container=built))
    headers = {"Authorization": f"Bearer {ADMIN_TOKEN}"}
    hw = _digest()

    parsed = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(hw)},
        headers=headers,
    )
    assert parsed.status_code == 200
    assert parsed.json()["hw_hash"] == hw

    first = client.post(
        "/v1/licenses", json={"request_code": make_request_code(hw)}, headers=headers
    )
    assert first.status_code == 201, first.text
    license_id = first.json()["license"]["license_id"]
    code = first.json()["license"]["activation_code"]

    second = client.post(
        "/v1/licenses", json={"request_code": make_request_code(hw)}, headers=headers
    )
    assert second.status_code == 200
    assert second.json()["created"] is False
    assert second.json()["license"]["activation_code"] == code

    retrieved = client.get(f"/v1/licenses/{license_id}/code", headers=headers)
    assert retrieved.status_code == 200
    assert retrieved.headers["cache-control"] == "no-store"
    assert retrieved.json()["activation_code"] == code

    # The code the API just issued satisfies the customer's own verifier.
    payload = shared.verify_activation_code(
        code,
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=hw,
    )
    assert payload.license_id == license_id

    # And the audit trail is really in Firestore.
    actions = {
        document.to_dict()["action"]
        for document in _where(
            _client().collection("audit_log"), "license_id", license_id
        ).stream()
    }
    assert {"license_issued", "activation_code_viewed"} <= actions


def test_reissue_and_revocation_against_real_firestore(real_repo):
    repository, client, issuer = real_repo
    hw = _digest()
    audit = _audit_factory(hw)

    first = repository.create_or_get_license(
        hw_hash=hw, build=lambda: _draft(issuer, hw), make_audit=audit
    )

    previous, new = repository.reissue_license(
        previous_license_id=first.license.license_id,
        build=lambda: _draft(issuer, hw, reissued_from=first.license.license_id),
        make_audit=audit,
    )
    assert previous.status == "superseded"
    assert previous.superseded_by == new.license_id
    assert client.collection("licenses").document(first.license.license_id).get().to_dict()[
        "status"
    ] == "superseded"
    assert client.collection("devices").document(hw).get().to_dict()[
        "current_license_id"
    ] == new.license_id
    assert len(list(_where(client.collection("licenses"), "hw_hash", hw).stream())) == 2

    revoked = repository.revoke_license(
        license_id=new.license_id,
        revocation=Revocation(
            reason="refund",
            revoked_at=datetime(2026, 3, 2, tzinfo=timezone.utc),
            revoked_by="admin-1",
        ),
        make_audit=audit,
    )
    assert revoked.status == "revoked"
    stored = client.collection("licenses").document(new.license_id).get().to_dict()
    assert stored["status"] == "revoked"
    assert stored["revoked_reason"] == "refund"


def test_listings_do_not_decrypt_activation_codes(real_repo):
    """The dashboard lists metadata only, so a stale seal cannot break a page.

    A record encrypted with an older key still lists (status visible); only the
    audited code read fails closed.
    """
    repository, client, issuer = real_repo
    hw = _digest()
    outcome = repository.create_or_get_license(
        hw_hash=hw, build=lambda: _draft(issuer, hw), make_audit=_audit_factory(hw)
    )
    license_id = outcome.license.license_id
    client.collection("licenses").document(license_id).update(
        {"activation_code_sealed": "gcm1:stale-envelope"}
    )

    listed = [
        record
        for record in repository.list_licenses(500)
        if record.license_id == license_id
    ]
    assert listed, "the dashboard listing must still contain the record"
    assert listed[0].status == "active"
    assert listed[0].activation_code == ""

    with pytest.raises(ApiError):
        repository.get_license(license_id)
