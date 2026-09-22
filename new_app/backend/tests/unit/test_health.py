"""Tests for application startup and health endpoints."""


def test_app_starts(client):
    """Verify the FastAPI application starts and responds."""
    response = client.get("/api/v1/health/live")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "alive"


def test_liveness(client):
    """Test the liveness probe."""
    response = client.get("/api/v1/health/live")
    assert response.status_code == 200
    data = response.json()
    assert "status" in data
    assert data["status"] == "alive"


def test_readiness(client):
    """Test the readiness probe with database connectivity."""
    response = client.get("/api/v1/health/ready")
    assert response.status_code == 200
    data = response.json()
    assert "status" in data
    assert "database" in data
    assert data["database"] == "connected"


def test_health_check(client):
    """Test the full health endpoint returns version and environment info."""
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    assert "version" in data
    assert "environment" in data
    assert "database" in data
    assert "timestamp" in data


def test_health_does_not_expose_secrets(client):
    """Verify health endpoint does not expose sensitive information."""
    response = client.get("/api/v1/health")
    data = response.json()
    response_text = str(data)
    # Should not contain database URL, passwords, or secret keys
    assert "postgres:" not in response_text
    assert "change-me" not in response_text
    assert "secret" not in response_text.lower() or "jwt_secret" not in response_text.lower()
