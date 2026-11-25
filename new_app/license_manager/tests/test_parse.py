"""``POST /v1/requests/parse`` — strict SMPr1 reading and duplicate detection."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from service import shared
from testkit import HW_A, HW_B, issue, make_request_code


def test_a_valid_request_returns_the_digest_and_install_id(client, admin_headers):
    response = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_A, "install-abc")},
        headers=admin_headers,
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["hw_hash"] == HW_A
    assert body["install_id"] == "install-abc"
    assert body["existing_license"] is None
    assert body["device"] is None
    assert datetime.fromisoformat(
        body["requested_at"].replace("Z", "+00:00")
    ).tzinfo is not None


def test_the_display_code_is_the_existing_fingerprint_display_format():
    """The grouped Base32 form must equal the customer app's own display code."""
    from app.licensing.fingerprint import (
        HardwareFingerprintService,
        StaticHardwareInfoProvider,
    )

    service = HardwareFingerprintService(
        StaticHardwareInfoProvider(
            machine_guid="{8F0A1C3E-1111-4222-8333-944455556666}",
            system_volume_serial="0x1A2B-3C4D",
            hostname="CAISSE-PC",
        )
    )
    digest = service.fingerprint()
    assert shared.display_code_for(digest) == service.display_code()
    assert len(shared.display_code_for(digest).split("-")) == 13


def test_an_existing_license_is_detected_by_the_parse_endpoint(client, admin_headers):
    issued = issue(client, admin_headers, HW_A)
    response = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_A)},
        headers=admin_headers,
    )
    body = response.json()
    assert body["existing_license"]["license_id"] == issued["license"]["license_id"]
    assert body["existing_license"]["status"] == "active"
    assert body["device"]["hw_hash"] == HW_A
    # Parse is read-only: it never returns a code.
    assert "activation_code" not in body["existing_license"]


def test_an_unknown_fingerprint_reports_no_existing_license(client, admin_headers):
    response = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_B)},
        headers=admin_headers,
    )
    assert response.json()["existing_license"] is None


def test_the_parse_is_audited(client, admin_headers, repository):
    client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_A)},
        headers=admin_headers,
    )
    assert "license_request_parsed" in repository.audit_actions()
    event = repository.audit_events[0]
    assert event.actor_uid == "admin-1"
    assert event.hw_hash == HW_A
    # The request code itself is never written to the audit trail.
    assert "SMPr1" not in str(event.details)


@pytest.mark.parametrize(
    "code,reason",
    [
        ("", "empty"),
        ("SMP1.AAAA.BBBB", "a license is not a request"),
        ("SMPr1", "one segment"),
        ("smpr1.AAAA", "unknown prefix"),
        ("SMPr1.aaaa", "lowercase base32"),
        ("SMPr1.AAAA.BBBB", "three segments"),
        ("SMPr1.!!!!", "not base32"),
    ],
)
def test_malformed_requests_are_rejected(client, admin_headers, code, reason):
    response = client.post(
        "/v1/requests/parse", json={"request_code": code}, headers=admin_headers
    )
    assert response.status_code == 422, reason
    assert response.json()["error"]["code"] in (
        "request_format_invalid",
        "validation_error",
    )


def test_a_payload_with_an_extra_field_is_rejected(client, admin_headers):
    """The request field set is closed: unknown fields fail, never ride along."""
    import base64
    import json

    payload = {
        "v": 1,
        "install_id": "install-0001",
        "hw_hash": HW_A,
        "requested_at": "2026-02-28T09:30:00+00:00",
        "features": ["pos"],
    }
    encoded = base64.b32encode(json.dumps(payload).encode()).decode().rstrip("=")
    response = client.post(
        "/v1/requests/parse",
        json={"request_code": f"SMPr1.{encoded}"},
        headers=admin_headers,
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "request_format_invalid"
    assert "SMPr1." not in response.json()["error"]["message"]


def test_the_parser_is_the_existing_generator_parser():
    """The service must delegate to ``tools.license_generator`` verbatim."""
    from tools.license_generator import generator

    parsed = shared.parse_request_code(make_request_code(HW_A))
    reference = generator.parse_request_code(make_request_code(HW_A))
    assert parsed == reference
    assert parsed.requested_at.tzinfo is not None
    assert parsed.requested_at == datetime(2026, 2, 28, 9, 30, tzinfo=timezone.utc)
