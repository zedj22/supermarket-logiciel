"""One license per hardware fingerprint — including under concurrency."""

from __future__ import annotations

import threading

from fastapi.testclient import TestClient

from service import shared
from service.api import create_app
from service.container import build_container
from service.service import EXISTING_LICENSE_NOTICE
from service.signing import LicenseIssuer
from testkit import ADMIN_PRINCIPAL, ADMIN_TOKEN, HW_A, HW_B, issue, make_request_code


def test_a_second_submission_returns_the_original_license(client, admin_headers):
    first = issue(client, admin_headers, HW_A)
    second = issue(client, admin_headers, HW_A)  # different request code, same digest

    assert second["created"] is False
    assert second["notice"] == EXISTING_LICENSE_NOTICE
    assert second["license"]["license_id"] == first["license"]["license_id"]
    assert second["license"]["activation_code"] == first["license"]["activation_code"]
    assert second["license"]["issued_at"] == first["license"]["issued_at"]


def test_a_second_submission_creates_no_second_document(client, admin_headers, repository):
    issue(client, admin_headers, HW_A)
    issue(client, admin_headers, HW_A)
    assert len(repository.list_licenses_for_device(HW_A)) == 1
    assert repository.audit_actions().count("license_issued") == 1
    assert repository.audit_actions().count("license_existing_returned") == 1


def test_two_fingerprints_get_two_independent_licenses(client, admin_headers, repository):
    first = issue(client, admin_headers, HW_A)
    second = issue(client, admin_headers, HW_B)
    assert first["license"]["license_id"] != second["license"]["license_id"]
    assert first["license"]["activation_code"] != second["license"]["activation_code"]
    assert len(repository.list_licenses_for_device(HW_A)) == 1
    assert len(repository.list_licenses_for_device(HW_B)) == 1


def test_the_parse_endpoint_reports_the_original_display_code(client, admin_headers):
    issue(client, admin_headers, HW_A)
    parsed = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_A)},
        headers=admin_headers,
    ).json()
    assert parsed["device"]["fingerprint_display_code"] == shared.display_code_for(HW_A)


def test_concurrent_service_calls_create_exactly_one_license(service, repository):
    results: list[str] = []
    errors: list[BaseException] = []
    barrier = threading.Barrier(8)

    def attempt() -> None:
        try:
            barrier.wait(timeout=10)
            results.append(service.issue(ADMIN_PRINCIPAL, hw_hash=HW_A).license.license_id)
        except BaseException as exc:  # noqa: BLE001 - reported below
            errors.append(exc)

    threads = [threading.Thread(target=attempt) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert not errors, errors
    assert len(results) == 8
    assert len(set(results)) == 1
    assert len(repository.list_licenses_for_device(HW_A)) == 1


def test_concurrent_http_requests_sign_only_once(
    settings, repository, verifier, clock, signing_key, keys_file
):
    """The duplicate check happens *before* signing, so only one code is minted."""
    signing_calls: list[str] = []
    lock = threading.Lock()

    class CountingIssuer(LicenseIssuer):
        def issue(self, **kwargs):
            with lock:
                signing_calls.append(kwargs["hw_hash"])
            return super().issue(**kwargs)

    container = build_container(
        settings,
        repository=repository,
        verifier=verifier,
        issuer_factory=lambda: CountingIssuer(
            key=signing_key,
            verification_keys=shared.load_customer_verification_keys(str(keys_file)),
            clock=clock,
        ),
        clock=clock,
    )
    client = TestClient(create_app(settings=settings, container=container))
    barrier = threading.Barrier(6)

    def attempt() -> None:
        barrier.wait(timeout=10)
        client.post(
            "/v1/licenses",
            json={"hw_hash": HW_A},
            headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
        )

    threads = [threading.Thread(target=attempt) for _ in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert len(signing_calls) == 1
    assert len(repository.list_licenses_for_device(HW_A)) == 1
