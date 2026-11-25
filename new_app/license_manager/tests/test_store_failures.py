"""Storage failures and the production Firestore code path.

The Firestore repository is exercised against a small in-process fake
(``tests/fakes.py``) so transactions, document mapping, sealing and status
transitions are covered without the SDK or an emulator.
"""

from __future__ import annotations

import uuid

import pytest
from fakes import FakeClient, FakeFirestoreModule, FlakyFirestoreModule
from fastapi.testclient import TestClient

from service import shared
from service.api import create_app
from service.container import build_container
from service.contracts import LicenseDraft
from service.errors import StoreUnavailableError
from service.firestore_repository import FirestoreLicenseRepository
from service.repository import InMemoryLicenseRepository
from service.signing import LicenseIssuer
from testkit import HW_A, HW_B


class BrokenRepository(InMemoryLicenseRepository):
    """Raises on the first read, to prove the API fails closed."""

    def __init__(self, cipher, *, error: BaseException) -> None:
        super().__init__(cipher)
        self._error = error

    def get_device(self, hw_hash):
        raise self._error


def _client_with(settings, verifier, repository, issuer, clock) -> TestClient:
    container = build_container(
        settings,
        repository=repository,
        verifier=verifier,
        issuer_factory=lambda: issuer,
        clock=clock,
    )
    # `raise_server_exceptions=False`: we assert on the 500 envelope, not on a
    # re-raised traceback.
    return TestClient(
        create_app(settings=settings, container=container),
        raise_server_exceptions=False,
    )


def test_a_store_outage_is_a_controlled_503(
    settings, verifier, issuer, clock, cipher, admin_headers
):
    client = _client_with(
        settings, verifier, BrokenRepository(cipher, error=StoreUnavailableError("down")),
        issuer, clock,
    )
    response = client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "store_unavailable"


def test_an_unexpected_store_error_does_not_leak_internals(
    settings, verifier, issuer, clock, cipher, admin_headers
):
    client = _client_with(
        settings,
        verifier,
        BrokenRepository(cipher, error=RuntimeError("firestore://internal-host/db")),
        issuer,
        clock,
    )
    response = client.get(f"/v1/devices/{HW_A}", headers=admin_headers)
    assert response.status_code == 500
    assert response.json()["error"]["code"] == "internal_error"
    assert "internal-host" not in response.text


def test_firestore_support_must_be_installed():
    try:
        import google.cloud.firestore  # noqa: F401
    except ImportError:
        pass
    else:  # pragma: no cover - only when the SDK is installed
        pytest.skip("google-cloud-firestore is installed")
    with pytest.raises(StoreUnavailableError):
        FirestoreLicenseRepository.connect(None)  # type: ignore[arg-type]


def test_provider_errors_are_mapped_to_the_controlled_error(cipher):
    class ProviderError(Exception):
        pass

    repository = FirestoreLicenseRepository(
        FakeClient(), cipher, firestore_module=FakeFirestoreModule()
    )
    repository._storage_errors = (ProviderError,)

    class Angry(FakeClient):
        def collection(self, name):
            raise ProviderError("quota exceeded on project/xyz")

    broken = FirestoreLicenseRepository(
        Angry(), cipher, firestore_module=FakeFirestoreModule()
    )
    broken._storage_errors = (ProviderError,)
    with pytest.raises(StoreUnavailableError) as excinfo:
        broken.get_device(HW_A)
    assert "quota exceeded" not in str(excinfo.value)
    assert repository.get_device(HW_A) is None


# --------------------------------------------------------------------------- #
# The production Firestore repository, against the fake
# --------------------------------------------------------------------------- #


@pytest.fixture
def firestore_repo(cipher, signing_key, keys_file, clock):
    client = FakeClient()
    repository = FirestoreLicenseRepository(
        client, cipher, firestore_module=FakeFirestoreModule(), clock=clock
    )
    issuer = LicenseIssuer(
        key=signing_key,
        verification_keys=shared.load_customer_verification_keys(str(keys_file)),
        clock=clock,
    )
    return repository, client, issuer


def _audit_factory(action_sink):
    from datetime import datetime, timezone

    from service.contracts import AuditEvent

    def make(action: str, license_id: str | None) -> AuditEvent:
        action_sink.append((action, license_id))
        return AuditEvent(
            event_id=uuid.uuid4().hex,
            at=datetime(2026, 3, 1, tzinfo=timezone.utc),
            action=action,
            actor_uid="admin-1",
            license_id=license_id,
            hw_hash=HW_A,
        )

    return make


def _draft(issuer, hw_hash=HW_A) -> LicenseDraft:
    from datetime import datetime, timezone

    return LicenseDraft(
        hw_hash=hw_hash,
        issued=issuer.issue(hw_hash=hw_hash),
        created_at=datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc),
        created_by="admin-1",
        request_code="SMPr1.AAAA",
        install_id="install-0001",
    )


def test_firestore_issuance_writes_license_device_and_audit(firestore_repo):
    repository, client, issuer = firestore_repo
    actions: list[tuple[str, str | None]] = []
    outcome = repository.create_or_get_license(
        hw_hash=HW_A, build=lambda: _draft(issuer), make_audit=_audit_factory(actions)
    )
    assert outcome.created is True
    license_id = outcome.license.license_id

    license_doc = client.data[("licenses", license_id)]
    assert license_doc["kind"] == "lifetime"
    assert license_doc["status"] == "active"
    assert license_doc["hw_hash"] == HW_A
    assert license_doc["activation_code_sealed"].startswith("gcm1:")
    assert outcome.license.activation_code not in license_doc["activation_code_sealed"]

    device_doc = client.data[("devices", HW_A)]
    assert device_doc["current_license_id"] == license_id
    assert device_doc["install_id"] == "install-0001"
    assert actions == [("license_issued", license_id)]
    assert len(client.documents("audit_log")) == 1


def test_firestore_duplicate_returns_the_existing_document(firestore_repo):
    repository, client, issuer = firestore_repo
    build_calls: list[int] = []

    def build() -> LicenseDraft:
        build_calls.append(1)
        return _draft(issuer)

    first = repository.create_or_get_license(
        hw_hash=HW_A, build=build, make_audit=_audit_factory([])
    )
    second = repository.create_or_get_license(
        hw_hash=HW_A, build=build, make_audit=_audit_factory([])
    )
    assert first.created is True and second.created is False
    assert second.license.license_id == first.license.license_id
    assert len(build_calls) == 1  # the second path never signs anything
    assert len(client.documents("licenses")) == 1


def test_firestore_reissue_preserves_the_original(firestore_repo):
    repository, client, issuer = firestore_repo
    first = repository.create_or_get_license(
        hw_hash=HW_A, build=lambda: _draft(issuer), make_audit=_audit_factory([])
    )

    def reissue_draft() -> LicenseDraft:
        draft = _draft(issuer)
        from dataclasses import replace

        return replace(draft, reissued_from=first.license.license_id)

    previous, new = repository.reissue_license(
        previous_license_id=first.license.license_id,
        build=reissue_draft,
        make_audit=_audit_factory([]),
    )
    assert previous.status == "superseded"
    assert previous.superseded_by == new.license_id
    old_doc = client.data[("licenses", first.license.license_id)]
    assert old_doc["status"] == "superseded"
    assert old_doc["activation_code_sealed"]  # the original code is preserved
    assert client.data[("devices", HW_A)]["current_license_id"] == new.license_id
    assert len(client.documents("licenses")) == 2


def test_firestore_revocation_marks_only_the_current_license(firestore_repo):
    repository, client, issuer = firestore_repo
    outcome = repository.create_or_get_license(
        hw_hash=HW_A, build=lambda: _draft(issuer), make_audit=_audit_factory([])
    )
    from datetime import datetime, timezone

    from service.contracts import Revocation

    revoked = repository.revoke_license(
        license_id=outcome.license.license_id,
        revocation=Revocation(
            reason="refund",
            revoked_at=datetime(2026, 3, 2, tzinfo=timezone.utc),
            revoked_by="admin-1",
        ),
        make_audit=_audit_factory([]),
    )
    assert revoked.status == "revoked"
    assert revoked.revoked_reason == "refund"
    assert client.data[("licenses", outcome.license.license_id)]["status"] == "revoked"


def test_firestore_lists_licenses_for_a_device(firestore_repo):
    repository, _, issuer = firestore_repo
    repository.create_or_get_license(
        hw_hash=HW_A, build=lambda: _draft(issuer), make_audit=_audit_factory([])
    )
    repository.create_or_get_license(
        hw_hash=HW_B, build=lambda: _draft(issuer, HW_B), make_audit=_audit_factory([])
    )
    assert len(repository.list_licenses_for_device(HW_A)) == 1
    assert len(repository.list_licenses_for_device(HW_B)) == 1


def test_the_sealed_code_reads_back_through_the_repository(firestore_repo):
    repository, _, issuer = firestore_repo
    outcome = repository.create_or_get_license(
        hw_hash=HW_A, build=lambda: _draft(issuer), make_audit=_audit_factory([])
    )
    fetched = repository.get_license(outcome.license.license_id)
    assert fetched.activation_code == outcome.license.activation_code
    assert fetched.activation_code.startswith("SMP1.")


def test_a_transient_transaction_failure_is_not_masked(firestore_repo):
    repository, client, issuer = firestore_repo
    flaky = FirestoreLicenseRepository(
        client, repository._cipher, firestore_module=FlakyFirestoreModule()
    )
    with pytest.raises(RuntimeError):
        flaky.create_or_get_license(
            hw_hash=HW_A, build=lambda: _draft(issuer), make_audit=_audit_factory([])
        )
