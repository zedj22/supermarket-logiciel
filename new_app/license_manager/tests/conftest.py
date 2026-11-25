"""Shared fixtures for the License Manager test suite.

No cloud dependency is required: the repository is in-memory, the token
verifier is a fixed table and the signing key is a throwaway Ed25519 pair
generated per test.  Production keys are never generated, read or used.
"""

from __future__ import annotations

import base64
import json
import os
import sys
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[1]
NEW_APP_ROOT = SERVICE_ROOT.parent
BACKEND_ROOT = NEW_APP_ROOT / "backend"

for _path in (BACKEND_ROOT, SERVICE_ROOT):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

# The shared `app` package needs a DATABASE_URL to be importable; this service
# never opens a database (see service/bootstrap.py).
os.environ.setdefault(
    "DATABASE_URL", "postgresql+psycopg://license-manager:unused@127.0.0.1:1/unused"
)

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from fastapi.testclient import TestClient
from service import shared
from service.api import create_app
from service.auth import StaticTokenVerifier
from service.container import ServiceContainer, build_container
from service.crypto import ActivationCodeCipher
from service.repository import InMemoryLicenseRepository
from service.service import LicenseService
from service.settings import Settings
from service.signing import LicenseIssuer, SigningKey
from testkit import (
    ADMIN_CLAIMS,
    ADMIN_TOKEN,
    APP_CHECK_TOKEN,
    STRANGER_CLAIMS,
    STRANGER_TOKEN,
    Clock,
)


@pytest.fixture
def owner_key() -> tuple[str, bytes, bytes]:
    """A throwaway Ed25519 keypair: (key id, 32-byte seed, public half)."""
    private = Ed25519PrivateKey.generate()
    seed = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return "test-owner", seed, public


@pytest.fixture
def keys_file(tmp_path: Path, owner_key) -> Path:
    """A customer-style ``verification_keys.json`` carrying the test key."""
    key_id, _, public = owner_key
    path = tmp_path / "verification_keys.json"
    path.write_text(
        json.dumps({key_id: base64.b64encode(public).decode("ascii")}), encoding="utf-8"
    )
    return path


@pytest.fixture
def signing_key(owner_key) -> SigningKey:
    key_id, seed, _ = owner_key
    return SigningKey.from_seed(key_id, seed)


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def cipher() -> ActivationCodeCipher:
    return ActivationCodeCipher(bytes(range(32)))


@pytest.fixture
def settings(keys_file: Path) -> Settings:
    return Settings(
        env="testing",
        admin_uids=frozenset({ADMIN_CLAIMS["uid"]}),
        verification_keys_file=str(keys_file),
        rate_limit_per_minute=1000,
        issue_rate_limit_per_minute=1000,
        max_body_bytes=8192,
    )


@pytest.fixture
def verifier() -> StaticTokenVerifier:
    return StaticTokenVerifier(
        {ADMIN_TOKEN: ADMIN_CLAIMS, STRANGER_TOKEN: STRANGER_CLAIMS},
        {APP_CHECK_TOKEN: {"app_id": "demo-app"}},
    )


@pytest.fixture
def repository(cipher, clock) -> InMemoryLicenseRepository:
    return InMemoryLicenseRepository(cipher, clock=clock)


@pytest.fixture
def issuer(signing_key, keys_file, clock) -> LicenseIssuer:
    return LicenseIssuer(
        key=signing_key,
        verification_keys=shared.load_customer_verification_keys(str(keys_file)),
        clock=clock,
    )


@pytest.fixture
def container(settings, repository, verifier, issuer, clock) -> ServiceContainer:
    return build_container(
        settings,
        repository=repository,
        verifier=verifier,
        issuer_factory=lambda: issuer,
        clock=clock,
    )


@pytest.fixture
def service(container) -> LicenseService:
    return container.service


@pytest.fixture
def client(settings, container) -> TestClient:
    return TestClient(create_app(settings=settings, container=container))


@pytest.fixture
def client_factory(settings, repository, verifier, issuer, clock):
    """Build a client with overridden settings/verifier/repository."""

    def build(
        *,
        settings_override: Settings | None = None,
        verifier_override=None,
        repository_override=None,
    ) -> TestClient:
        resolved = settings_override or settings
        built = build_container(
            resolved,
            repository=repository_override or repository,
            verifier=verifier_override or verifier,
            issuer_factory=lambda: issuer,
            clock=clock,
        )
        return TestClient(create_app(settings=resolved, container=built))

    return build


@pytest.fixture
def admin_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {ADMIN_TOKEN}"}


@pytest.fixture
def stranger_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {STRANGER_TOKEN}"}
