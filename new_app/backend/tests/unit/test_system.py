"""Tests for system info endpoint (Phase 3 foundation demo).

Verifies:
- Response structure
- Database status is reported
- Request ID is present
- Version and environment are included
"""


def test_system_info_returns_200(client):
    response = client.get("/api/v1/system/info")
    assert response.status_code == 200


def test_system_info_response_structure(client):
    body = client.get("/api/v1/system/info").json()
    assert "name" in body
    assert "version" in body
    assert "environment" in body
    assert "database_status" in body
    assert "timestamp" in body


def test_system_info_database_connected(client):
    body = client.get("/api/v1/system/info").json()
    assert body["database_status"] == "connected"


def test_system_info_has_version(client):
    body = client.get("/api/v1/system/info").json()
    assert body["version"] is not None
    assert len(body["version"]) > 0


def test_system_info_has_environment(client):
    body = client.get("/api/v1/system/info").json()
    assert body["environment"] in ("development", "testing", "production")


def test_system_info_has_request_id(client):
    response = client.get("/api/v1/system/info")
    assert "x-request-id" in response.headers
