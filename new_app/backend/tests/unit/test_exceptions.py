"""Tests for exception handling."""


def test_404_returns_structured_error(client):
    """Verify unknown endpoints return a structured 404 error."""
    response = client.get("/api/v1/nonexistent")
    assert response.status_code == 404


def test_405_method_not_allowed(client):
    """Verify wrong HTTP method returns appropriate error."""
    response = client.post("/api/v1/health")
    assert response.status_code == 405
