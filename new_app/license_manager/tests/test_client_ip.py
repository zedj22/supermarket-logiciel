"""Audit-trail client addresses must not be forgeable by the caller.

``X-Forwarded-For`` is trivially spoofable by anyone who can reach the service
while holding a valid administrator token, so it is honoured only when the
deployment declares a trusted proxy in front of it
(``LICENSE_API_TRUST_PROXY=1``).  The audit log is the record an investigation
would rely on; it must not record an address the caller chose.
"""

from __future__ import annotations

from dataclasses import replace

from service.settings import Settings
from testkit import HW_A, make_request_code


def _parse(client, headers) -> None:
    response = client.post(
        "/v1/requests/parse",
        json={"request_code": make_request_code(HW_A)},
        headers=headers,
    )
    assert response.status_code == 200, response.text


def test_a_forwarded_header_is_never_recorded_unless_the_proxy_is_trusted(
    client, admin_headers, repository
):
    _parse(client, {**admin_headers, "X-Forwarded-For": "203.0.113.9"})

    event = repository.audit_events[-1]
    assert event.action == "license_request_parsed"
    # Not the forged value, and not the ASGI peer either: uvicorn's
    # --proxy-headers may already have rewritten request.client from this header.
    assert event.client_ip is None


def test_a_request_without_a_forwarded_header_keeps_the_peer_address(
    client, admin_headers, repository
):
    _parse(client, admin_headers)
    assert repository.audit_events[-1].client_ip == "testclient"


def test_the_forwarded_header_is_used_when_the_proxy_is_trusted(
    client_factory, settings, admin_headers, repository
):
    trusting = replace(settings, trust_proxy=True)
    client = client_factory(settings_override=trusting)

    _parse(client, {**admin_headers, "X-Forwarded-For": "203.0.113.9, 10.0.0.1"})

    assert repository.audit_events[-1].client_ip == "203.0.113.9"


def test_the_trust_setting_is_read_from_the_environment(settings):
    environ = {
        "LICENSE_API_ENV": "development",
        "LICENSE_API_ADMIN_UIDS": "admin-1",
        "LICENSE_API_VERIFICATION_KEYS_FILE": settings.verification_keys_file,
        "LICENSE_API_TRUST_PROXY": "1",
    }
    assert Settings.from_env(environ).trust_proxy is True

    environ.pop("LICENSE_API_TRUST_PROXY")
    assert Settings.from_env(environ).trust_proxy is False
