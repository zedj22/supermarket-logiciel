"""Filter-based Firestore queries (Phase 6.9).

The SDK deprecated the positional ``where(field, op, value)`` overload in favour
of ``where(filter=FieldFilter(...))``; leaving it in place emits a
``FutureWarning`` on every query and will break on a future major version.

Two things are pinned here:

* the production repository only ever uses the filter form — the in-process fake
  **rejects** the positional spelling, so a regression fails the suite instead
  of just warning;
* the filtered queries keep their exact semantics (field, value, ordering and
  the status counts), so this cleanup cannot silently change results.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fakes import FakeClient, FakeCollection, FakeFieldFilter, FakeFirestoreModule

from service.firestore_repository import FirestoreLicenseRepository

AT = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)


def _license_doc(**overrides) -> dict:
    document = {
        "hw_hash": "a" * 64,
        "status": "active",
        "kind": "lifetime",
        "key_id": "test-owner",
        "issued_at": AT,
        "created_at": AT,
        "created_by": "admin-1",
        "features": ["pos"],
    }
    document.update(overrides)
    return document


@pytest.fixture
def repo(cipher, clock):
    client = FakeClient()
    repository = FirestoreLicenseRepository(
        client, cipher, firestore_module=FakeFirestoreModule(), clock=clock
    )
    return repository, client


def test_licenses_for_a_device_are_filtered_by_fingerprint(repo):
    repository, client = repo
    other = "b" * 64
    older = datetime(2026, 2, 1, tzinfo=timezone.utc)
    client.collection("licenses").document("lic-old").set(
        _license_doc(hw_hash="a" * 64, created_at=older)
    )
    client.collection("licenses").document("lic-new").set(
        _license_doc(hw_hash="a" * 64, status="superseded")
    )
    client.collection("licenses").document("lic-other").set(
        _license_doc(hw_hash=other)
    )

    records = repository.list_licenses_for_device("a" * 64)

    assert [record.license_id for record in records] == ["lic-new", "lic-old"]
    assert {record.hw_hash for record in records} == {"a" * 64}


def test_customer_queries_are_filtered_by_customer_id(repo):
    repository, client = repo
    client.collection("devices").document("a" * 64).set(
        {"hw_hash": "a" * 64, "customer_id": "cust-1", "current_license_id": "lic-1"}
    )
    client.collection("devices").document("b" * 64).set(
        {"hw_hash": "b" * 64, "customer_id": "cust-2"}
    )
    client.collection("licenses").document("lic-1").set(
        _license_doc(customer_id="cust-1")
    )
    client.collection("licenses").document("lic-2").set(
        _license_doc(hw_hash="b" * 64, customer_id="cust-2")
    )

    devices = repository.list_devices_for_customer("cust-1")
    licenses = repository.list_licenses_for_customer("cust-1")

    assert [device.hw_hash for device in devices] == ["a" * 64]
    assert [record.license_id for record in licenses] == ["lic-1"]


def test_status_counts_keep_their_meaning(repo):
    repository, client = repo
    client.collection("customers").document("cust-1").set({"name": "One"})
    client.collection("devices").document("a" * 64).set({"hw_hash": "a" * 64})
    for index, status in enumerate(
        ["active", "active", "revoked", "superseded"], start=1
    ):
        client.collection("licenses").document(f"lic-{index}").set(
            _license_doc(status=status)
        )

    counts = repository.counts()

    assert counts == {
        "customers": 1,
        "devices": 1,
        "active_licenses": 2,
        "revoked_licenses": 1,
        "superseded_licenses": 1,
    }


def test_the_fake_refuses_the_deprecated_positional_where():
    """The guard that makes a regression in the repository fail, not warn."""
    with pytest.raises(TypeError):
        FakeCollection({}, "licenses").where("hw_hash", "==", "a" * 64)


def test_the_fake_only_supports_equality_filters():
    query = FakeCollection({}, "licenses").where(
        filter=FakeFieldFilter("hw_hash", "==", "a" * 64)
    )
    assert list(query.stream()) == []
