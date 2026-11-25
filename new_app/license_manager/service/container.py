"""Dependency container: settings, repository, verifier and the service.

Production builds everything from the environment and Secret Manager, on first
use (never at import time, so ``uvicorn service.api:app`` starts without
touching the network).  Tests pass an explicit ``ServiceContainer``, which is
why the whole API can be exercised without Firebase or Firestore installed.
"""

from __future__ import annotations

import base64
import binascii
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime

from service import shared
from service.auth import DevelopmentTokenVerifier, FirebaseTokenVerifier, TokenVerifier
from service.crypto import ActivationCodeCipher
from service.errors import SigningKeyError
from service.repository import LicenseRepository
from service.secrets import (
    EnvironmentSecretFetcher,
    FileSecretFetcher,
    SecretFetcher,
    SecretManagerFetcher,
)
from service.service import LicenseService
from service.settings import Settings
from service.signing import (
    LicenseIssuer,
    SigningKey,
    lazy_key_provider,
    load_signing_key_from_secret,
)

__all__ = [
    "LazyContainer",
    "ServiceContainer",
    "build_container",
    "load_code_cipher",
    "load_configured_signing_key",
    "load_issuer_factory",
]


@dataclass(frozen=True, slots=True)
class ServiceContainer:
    """Everything one application instance needs."""

    settings: Settings
    repository: LicenseRepository
    verifier: TokenVerifier
    service: LicenseService


def _secret_fetcher(settings: Settings, values: Mapping[str, str]) -> SecretFetcher:
    """Pick the backend the deployment named — never by accident.

    ``LICENSE_API_SECRET_SOURCE=file`` always means mounted files, in every
    environment: an operator who asks for files must not silently receive
    environment values instead.  Otherwise production uses Secret Manager
    (unchanged Cloud Run behaviour) and development uses environment values.
    """
    if settings.secret_source == "file":
        return FileSecretFetcher(settings.secret_dir)
    if settings.is_production:
        return SecretManagerFetcher(settings.firebase_project_id)
    return EnvironmentSecretFetcher(values, env=settings.env)


def load_code_cipher(
    settings: Settings, *, values: Mapping[str, str] | None = None
) -> ActivationCodeCipher:
    """The activation-code encryption key, in memory only."""
    if not settings.is_production and settings.dev_code_encryption_key_b64:
        return ActivationCodeCipher.from_base64(settings.dev_code_encryption_key_b64)
    if not settings.code_encryption_secret_name:
        raise SigningKeyError(
            "no activation-code encryption key is configured "
            "(LICENSE_API_CODE_ENC_SECRET)"
        )
    fetcher = _secret_fetcher(
        settings,
        {
            settings.code_encryption_secret_name: (
                values or {}
            ).get(settings.code_encryption_secret_name, "")
        },
    )
    payload = fetcher.fetch(
        settings.code_encryption_secret_name,
        settings.code_encryption_secret_version,
    )
    return ActivationCodeCipher.from_base64(payload)


def _dev_signing_key(settings: Settings) -> SigningKey:
    try:
        seed = base64.b64decode(settings.dev_signing_seed_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SigningKeyError(
            "the development signing seed is not valid base64"
        ) from exc
    return SigningKey.from_seed(settings.dev_signing_key_id or "dev-local", seed)


def _key_from_fetcher(settings: Settings, fetcher: SecretFetcher) -> SigningKey:
    """Parse the signing secret one backend returned."""
    return load_signing_key_from_secret(
        fetcher,
        name=settings.signing_secret_name,
        version=settings.signing_secret_version,
    )


def load_configured_signing_key(
    settings: Settings, *, values: Mapping[str, str] | None = None
) -> SigningKey:
    """The keypair the issuer will sign with, loaded **now**.

    Same branch as :func:`load_issuer_factory` (a development seed first,
    otherwise the configured secret through the chosen provider) but eager, so
    the staging startup guard can compare the derived public key before the
    service accepts a request.  Nothing is logged or cached to disk.
    """
    if not settings.is_production and settings.dev_signing_seed_b64:
        return _dev_signing_key(settings)
    if not settings.signing_secret_name:
        raise SigningKeyError(
            "no signing secret is configured (LICENSE_API_SIGNING_SECRET)"
        )
    fetcher = _secret_fetcher(
        settings,
        {
            settings.signing_secret_name: (values or {}).get(
                settings.signing_secret_name, ""
            )
        },
    )
    return _key_from_fetcher(settings, fetcher)


def load_issuer_factory(
    settings: Settings, *, values: Mapping[str, str] | None = None
) -> Callable[[], LicenseIssuer]:
    """Signing issuer factory: the private seed is fetched on first use only."""
    if not settings.is_production and settings.dev_signing_seed_b64:
        provider = lazy_key_provider(lambda: _dev_signing_key(settings))
    else:
        if not settings.signing_secret_name:
            raise SigningKeyError(
                "no signing secret is configured (LICENSE_API_SIGNING_SECRET)"
            )
        fetcher = _secret_fetcher(
            settings,
            {
                settings.signing_secret_name: (values or {}).get(
                    settings.signing_secret_name, ""
                )
            },
        )
        provider = lazy_key_provider(lambda: _key_from_fetcher(settings, fetcher))

    def factory() -> LicenseIssuer:
        key = provider.load()
        keys = shared.load_customer_verification_keys(
            str(settings.verification_keys_path)
        )
        return LicenseIssuer(key=key, verification_keys=keys)

    return factory


class LazyContainer:
    """Build the real container on first request; retry after a failure.

    A cold start with a transient Secret Manager or Firestore problem must not
    produce a permanently broken instance, so a failed build is retried on the
    next request instead of being cached.
    """

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._lock = threading.Lock()
        self._container: ServiceContainer | None = None
        self._verifier: TokenVerifier | None = None

    @property
    def verifier(self) -> TokenVerifier:
        """Cheap and cloud-free at construction: a rejected token needs no store.

        Kept separate from :meth:`get` so an unauthenticated request is answered
        ``401`` without touching Secret Manager or Firestore — a misconfigured
        secret must never turn a bad token into a ``503``.
        """
        if self._verifier is None:
            if self.settings.dev_auth_uid and not self.settings.is_production:
                # Local development without a Firebase project.  `Settings`
                # refuses this value in production, so it cannot leak.
                self._verifier = DevelopmentTokenVerifier(self.settings.dev_auth_uid)
            else:
                self._verifier = FirebaseTokenVerifier(
                    self.settings.firebase_project_id,
                    env=self.settings.env,
                    app_check_audience=self.settings.app_check_audience,
                )
        return self._verifier

    def _build(self) -> ServiceContainer:
        from service.firestore_repository import FirestoreLicenseRepository

        cipher = load_code_cipher(self.settings)
        repository = FirestoreLicenseRepository.connect(
            cipher,
            project_id=self.settings.firebase_project_id,
            database=self.settings.firestore_database,
            env=self.settings.env,
        )
        return build_container(
            self.settings, repository=repository, verifier=self.verifier
        )

    def get(self) -> ServiceContainer:
        with self._lock:
            if self._container is None:
                self._container = self._build()
            return self._container


def build_container(
    settings: Settings,
    *,
    repository: LicenseRepository,
    verifier: TokenVerifier,
    issuer_factory: Callable[[], LicenseIssuer] | None = None,
    clock: Callable[[], datetime] | None = None,
) -> ServiceContainer:
    """Assemble a container from explicit parts (tests and scripted runs)."""
    service = LicenseService(
        repository,
        issuer_factory=issuer_factory or load_issuer_factory(settings),
        settings=settings,
        clock=clock,
    )
    return ServiceContainer(
        settings=settings,
        repository=repository,
        verifier=verifier,
        service=service,
    )
