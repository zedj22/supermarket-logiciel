"""Tests for request ID / correlation ID middleware.

Verifies:
- Every response has X-Request-ID header
- Client-provided X-Request-ID is preserved
- Generated IDs are valid UUIDs
- Request ID appears in error responses
"""

import uuid


def test_response_has_request_id_header(client):
    """Every response should include X-Request-ID header."""
    response = client.get("/api/v1/health/live")
    assert response.status_code == 200
    assert "x-request-id" in response.headers
    rid = response.headers["x-request-id"]
    # Should be a valid UUID
    uuid.UUID(rid)


def test_client_request_id_preserved(client):
    """If client sends X-Request-ID, it should be preserved in response."""
    custom_id = str(uuid.uuid4())
    response = client.get(
        "/api/v1/health/live",
        headers={"X-Request-ID": custom_id},
    )
    assert response.headers["x-request-id"] == custom_id


def test_generated_request_id_is_valid_uuid(client):
    """Auto-generated request IDs should be valid UUIDs."""
    response = client.get("/api/v1/health/live")
    rid = response.headers["x-request-id"]
    parsed = uuid.UUID(rid)
    assert str(parsed) == rid


def test_error_response_includes_request_id(client):
    """Error responses should include request_id in the body."""
    response = client.get("/api/v1/nonexistent")
    body = response.json()
    assert "error" in body
    assert body["error"]["request_id"] is not None
    # And it should match the header
    assert body["error"]["request_id"] == response.headers["x-request-id"]


def test_health_endpoint_has_request_id(client):
    """Health endpoint should also have request IDs."""
    response = client.get("/api/v1/health")
    assert "x-request-id" in response.headers
    uuid.UUID(response.headers["x-request-id"])


def test_liveness_has_request_id(client):
    """Liveness endpoint should have request IDs."""
    response = client.get("/api/v1/health/live")
    assert "x-request-id" in response.headers


def test_readiness_has_request_id(client):
    """Readiness endpoint should have request IDs."""
    response = client.get("/api/v1/health/ready")
    assert "x-request-id" in response.headers


def test_system_info_has_request_id(client):
    """System info endpoint should have request IDs."""
    response = client.get("/api/v1/system/info")
    assert "x-request-id" in response.headers
