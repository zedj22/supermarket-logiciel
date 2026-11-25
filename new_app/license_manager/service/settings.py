"""Runtime configuration for the License API.

Configuration is read from the environment only — never from source, never
from a Firestore document.  Secrets themselves are **names**, not values:
the signing seed and the activation-code encryption key are fetched at runtime
from the source named by ``LICENSE_API_SECRET_SOURCE`` — Google Cloud Secret
Manager (the default, unchanged Cloud Run path) or read-only mounted files
(Render).  See ``secrets.py``, ``signing.py`` and ``crypto.py``.

The two ``..._DEV_...`` variables exist so a developer can run the service
locally; both are refused outright when ``LICENSE_API_ENV=production``.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from service.bootstrap import BACKEND_ROOT

__all__ = ["Settings", "load_settings"]

#: The customer application's own packaged public key file.
DEFAULT_VERIFICATION_KEYS_FILE = BACKEND_ROOT / "app" / "licensing" / "verification_keys.json"

#: Every absolute path that *is* the production key file: the in-repo/default
#: location (development, Cloud Run image default) and the path the same file
#: has inside the production container.  A staging deployment must resolve to
#: neither, however the path is spelled.
PRODUCTION_VERIFICATION_KEYS_PATHS: tuple[str, ...] = (
    str(DEFAULT_VERIFICATION_KEYS_FILE),
    "/app/backend/app/licensing/verification_keys.json",
)


def path_identities(value: str | Path) -> frozenset[str]:
    """Every spelling-independent identity of one path.

    Two identities are produced: a lexical one (``.``/``..`` collapsed, case
    folded on Windows only) and, where the platform allows it, the
    symlink-resolved one.  Comparing *both* against the same pair computed for
    the known production paths means a path is recognised whether it is
    written with ``..``, as a relative path, or through a symlink.

    Comparison is deliberately local to one platform: a path is never equated
    across filesystems, so the same code is meaningful on Windows and Linux.
    """
    text = str(value or "").strip()
    if not text:
        return frozenset()
    expanded = os.path.expanduser(text)
    identities = {os.path.normcase(os.path.abspath(expanded))}
    try:
        identities.add(os.path.normcase(str(Path(expanded).resolve())))
    except (OSError, RuntimeError):  # pragma: no cover - unreadable parents
        pass
    return frozenset(identities)


def production_verification_keys_identities() -> frozenset[str]:
    """Identities of every known production verification-key path."""
    identities: set[str] = set()
    for candidate in PRODUCTION_VERIFICATION_KEYS_PATHS:
        identities |= path_identities(candidate)
    return frozenset(identities)


def _bool(raw: str | None, *, default: bool = False) -> bool:
    if raw is None or not raw.strip():
        return default
    value = raw.strip().lower()
    if value in ("1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    raise ValueError(f"expected a boolean flag, got {raw!r}")


def _csv(raw: str | None) -> frozenset[str]:
    if not raw:
        return frozenset()
    return frozenset(part.strip() for part in raw.split(",") if part.strip())


def _int(raw: str | None, *, default: int, minimum: int) -> int:
    if raw is None or not raw.strip():
        return default
    value = int(raw)
    if value < minimum:
        raise ValueError(f"expected at least {minimum}, got {value}")
    return value


@dataclass(frozen=True, slots=True)
class Settings:
    """Everything the service needs to start, minus the secret values."""

    env: str = "development"
    firebase_project_id: str = ""
    admin_uids: frozenset[str] = field(default_factory=frozenset)
    admin_emails: frozenset[str] = field(default_factory=frozenset)
    require_app_check: bool = False
    #: Firebase App Check project **number** (Console → Project settings).
    #: App Check tokens carry ``aud = "projects/<number>"``; pinning it here
    #: means a token minted for another Firebase project is refused even if the
    #: verifier's default app were ever misconfigured.  Required in production
    #: whenever enforcement is on.
    app_check_audience: str = ""
    firestore_database: str = ""

    #: Cloud Run service-to-service authentication for the Dashboard hop.
    #: When on, every ``/v1`` call must also carry a Google-signed OIDC token
    #: minted by the Dashboard's runtime service account for ``cloud_run_audience``
    #: (see ``service/cloud_run.py``).  Cloud Run IAM is the outer gate; this is
    #: the in-process second one.
    require_cloud_run_invoker: bool = False
    #: The API's own Cloud Run URL — the expected ``aud`` of that token.
    cloud_run_audience: str = ""
    #: Service-account e-mails allowed to call the API (normally exactly one:
    #: the Dashboard runtime identity).  Empty means "any verified caller", and
    #: production refuses that when the invoker check is on.
    cloud_run_invoker_emails: frozenset[str] = field(default_factory=frozenset)

    #: Where secret *values* come from: ``secretmanager`` (default, Cloud Run)
    #: or ``file`` (read-only mounted secret files, e.g. Render).  This names a
    #: backend, never a value, and there is no automatic fallback between them.
    secret_source: str = "secretmanager"
    #: Directory holding one file per secret, used only when
    #: ``secret_source == "file"``.  It is mounted by the host at runtime and is
    #: never part of an image.
    secret_dir: str = ""

    signing_secret_name: str = ""
    signing_secret_version: str = "latest"
    code_encryption_secret_name: str = ""
    code_encryption_secret_version: str = "latest"

    verification_keys_file: str = str(DEFAULT_VERIFICATION_KEYS_FILE)
    #: Staging isolation.  When on, the service **refuses to start** if
    #: ``verification_keys_file`` resolves to the packaged PRODUCTION key file.
    #: A staging deployment sets it so a missing or mistyped path cannot fall
    #: back to production's keys silently.  Production leaves it off: there the
    #: packaged file *is* the production file.
    require_staging_keys: bool = False
    #: The key id the staging key file must publish when the flag above is on
    #: (used by ``service/staging_keys.py`` at startup).  Ignored by
    #: production, where the flag is off.
    staging_key_id: str = "stg-2026-11"
    #: Staging signing-key match.  When on, startup derives the Ed25519 public
    #: key from the configured signing *seed* and compares it with the public
    #: key the keys file publishes for ``staging_key_id`` (constant time).  A
    #: seed copied from another keypair would otherwise sign codes the staging
    #: client can never verify — a failure that only shows up on the customer's
    #: screen.  Off by default, so the Cloud Run/production path is unchanged.
    require_signing_key_match: bool = False
    rate_limit_per_minute: int = 60
    issue_rate_limit_per_minute: int = 20
    max_body_bytes: int = 8192
    #: Take the client address for the audit trail from ``X-Forwarded-For``.
    #: Off by default: any authenticated caller can send that header, so the
    #: service must be told explicitly that a trusted proxy rewrites it.
    trust_proxy: bool = False

    #: Development only — refused when ``env == "production"``.
    dev_signing_seed_b64: str = ""
    dev_signing_key_id: str = "dev-local"
    dev_code_encryption_key_b64: str = ""
    #: Development only: accept ``Authorization: Bearer dev:<uid>`` as that uid,
    #: so the dashboard can be developed without a Firebase project.  The uid
    #: must still be on the allowlist.  Refused when ``env == "production"``.
    dev_auth_uid: str = ""

    def __post_init__(self) -> None:
        # The secret backend is an explicit choice.  A typo must stop the
        # process rather than silently leaving secret material unfetchable.
        object.__setattr__(self, "secret_source", (self.secret_source or "").strip().lower())
        if self.secret_source not in ("secretmanager", "file"):
            raise ValueError(
                "LICENSE_API_SECRET_SOURCE must be 'secretmanager' or 'file'"
            )
        object.__setattr__(self, "secret_dir", (self.secret_dir or "").strip())
        if self.secret_source == "file" and not self.secret_dir:
            raise ValueError(
                "LICENSE_API_SECRET_DIR is required when "
                "LICENSE_API_SECRET_SOURCE=file"
            )
        # A Cloud Run URL is sometimes written with a trailing slash; the OIDC
        # audience never carries one, and the comparison is exact.
        if self.cloud_run_audience:
            object.__setattr__(
                self, "cloud_run_audience", self.cloud_run_audience.strip().rstrip("/")
            )
        if self.app_check_audience:
            # Accept both "123456789" and "projects/123456789"; the token's
            # `aud` is always the latter, the Console shows the former.
            object.__setattr__(
                self,
                "app_check_audience",
                self.app_check_audience.strip().removeprefix("projects/"),
            )
        if self.env not in ("development", "testing", "production"):
            raise ValueError(
                "LICENSE_API_ENV must be development, testing or production"
            )
        if self.env == "production":
            if self.dev_signing_seed_b64 or self.dev_code_encryption_key_b64:
                raise ValueError(
                    "development signing/encryption material must never be set "
                    f"when LICENSE_API_ENV=production (LICENSE_API_ENV={self.env})"
                )
            if self.dev_auth_uid:
                raise ValueError(
                    "LICENSE_API_DEV_AUTH_UID must never be set when "
                    "LICENSE_API_ENV=production"
                )
            if not self.firebase_project_id:
                raise ValueError(
                    "LICENSE_API_FIREBASE_PROJECT_ID is required in production"
                )
            if self.require_app_check and not self.app_check_audience:
                raise ValueError(
                    "LICENSE_API_APP_CHECK_AUDIENCE is required in production when "
                    "LICENSE_API_REQUIRE_APP_CHECK is enabled: it is the Firebase "
                    "project number App Check tokens are minted for"
                )
            if self.require_cloud_run_invoker and not self.cloud_run_invoker_emails:
                raise ValueError(
                    "LICENSE_API_CLOUD_RUN_INVOKERS is required in production when "
                    "LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER is enabled: name the "
                    "Dashboard runtime service account"
                )
            if not self.signing_secret_name or not self.code_encryption_secret_name:
                raise ValueError(
                    "secret names are required in production "
                    "(LICENSE_API_SIGNING_SECRET, LICENSE_API_CODE_ENC_SECRET)"
                )
        # The invoker check is worthless without a pinned audience: the token
        # would be accepted for any Cloud Run service.  Refused in every
        # environment, not just production.
        if self.require_cloud_run_invoker and not self.cloud_run_audience:
            raise ValueError(
                "LICENSE_API_CLOUD_RUN_AUDIENCE is required when "
                "LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER is enabled: it is the "
                "audience the Dashboard service identity token is minted for"
            )
        # Staging isolation (Phase 8.4.2, Option B).  A staging deployment that
        # reads the packaged PRODUCTION keys would refuse every issuance with
        # ``503 signing_key_not_published`` (the staging key id is not in that
        # file) and would put both environments' public keys in one place.  The
        # opt-in flag turns that into a startup failure instead of a runtime
        # surprise; production does not set it, so its behaviour is unchanged.
        if self.require_staging_keys and self.uses_production_verification_keys:
            known = " or ".join(PRODUCTION_VERIFICATION_KEYS_PATHS)
            raise ValueError(
                "LICENSE_API_VERIFICATION_KEYS_FILE resolves to a known "
                f"production keys file ({known}) while "
                "LICENSE_API_REQUIRE_STAGING_KEYS is enabled: point it at the "
                "staging key file (see deploy/staging.env.template)"
            )

    @property
    def is_production(self) -> bool:
        return self.env == "production"

    @property
    def uses_production_verification_keys(self) -> bool:
        """True when the configured keys file *is* a known production file.

        Covers both the in-repo/default path and the production container path,
        and every equivalent spelling of either (``..``, relative, symlink) via
        :func:`path_identities`.  An empty value counts as production, because
        ``from_env`` would have fallen back to the packaged default.
        """
        configured = (self.verification_keys_file or "").strip()
        if not configured:
            return True
        return not path_identities(configured).isdisjoint(
            production_verification_keys_identities()
        )

    @property
    def verification_keys_path(self) -> Path:
        return Path(self.verification_keys_file)

    @property
    def secret_dir_path(self) -> Path | None:
        """The mounted secret directory, when the file backend is selected."""
        return Path(self.secret_dir) if self.secret_source == "file" else None

    @property
    def uses_secret_manager(self) -> bool:
        return self.secret_source == "secretmanager"

    @property
    def allowlist_is_empty(self) -> bool:
        """An empty administrator allowlist denies every request (fail-closed)."""
        return not self.admin_uids and not self.admin_emails

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if environ is None else environ
        return cls(
            env=(env.get("LICENSE_API_ENV") or "development").strip().lower(),
            firebase_project_id=(env.get("LICENSE_API_FIREBASE_PROJECT_ID") or "").strip(),
            admin_uids=_csv(env.get("LICENSE_API_ADMIN_UIDS")),
            admin_emails=frozenset(
                value.lower() for value in _csv(env.get("LICENSE_API_ADMIN_EMAILS"))
            ),
            require_app_check=_bool(env.get("LICENSE_API_REQUIRE_APP_CHECK")),
            app_check_audience=(
                env.get("LICENSE_API_APP_CHECK_AUDIENCE") or ""
            ).strip(),
            firestore_database=(env.get("LICENSE_API_FIRESTORE_DATABASE") or "").strip(),
            require_cloud_run_invoker=_bool(
                env.get("LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER")
            ),
            cloud_run_audience=(
                env.get("LICENSE_API_CLOUD_RUN_AUDIENCE") or ""
            ).strip().rstrip("/"),
            cloud_run_invoker_emails=frozenset(
                value.lower()
                for value in _csv(env.get("LICENSE_API_CLOUD_RUN_INVOKERS"))
            ),
            secret_source=(
                env.get("LICENSE_API_SECRET_SOURCE") or "secretmanager"
            ).strip(),
            secret_dir=(env.get("LICENSE_API_SECRET_DIR") or "").strip(),
            signing_secret_name=(env.get("LICENSE_API_SIGNING_SECRET") or "").strip(),
            signing_secret_version=(
                env.get("LICENSE_API_SIGNING_SECRET_VERSION") or "latest"
            ).strip(),
            code_encryption_secret_name=(
                env.get("LICENSE_API_CODE_ENC_SECRET") or ""
            ).strip(),
            code_encryption_secret_version=(
                env.get("LICENSE_API_CODE_ENC_SECRET_VERSION") or "latest"
            ).strip(),
            verification_keys_file=(
                env.get("LICENSE_API_VERIFICATION_KEYS_FILE")
                or str(DEFAULT_VERIFICATION_KEYS_FILE)
            ).strip(),
            require_staging_keys=_bool(env.get("LICENSE_API_REQUIRE_STAGING_KEYS")),
            staging_key_id=(
                env.get("LICENSE_API_STAGING_KEY_ID") or "stg-2026-11"
            ).strip(),
            require_signing_key_match=_bool(
                env.get("LICENSE_API_REQUIRE_SIGNING_KEY_MATCH")
            ),
            rate_limit_per_minute=_int(
                env.get("LICENSE_API_RATE_LIMIT_PER_MINUTE"), default=60, minimum=1
            ),
            issue_rate_limit_per_minute=_int(
                env.get("LICENSE_API_ISSUE_LIMIT_PER_MINUTE"), default=20, minimum=1
            ),
            max_body_bytes=_int(
                env.get("LICENSE_API_MAX_BODY_BYTES"), default=8192, minimum=512
            ),
            trust_proxy=_bool(env.get("LICENSE_API_TRUST_PROXY")),
            dev_signing_seed_b64=(env.get("LICENSE_API_DEV_SIGNING_SEED_B64") or "").strip(),
            dev_signing_key_id=(
                env.get("LICENSE_API_DEV_SIGNING_KEY_ID") or "dev-local"
            ).strip(),
            dev_code_encryption_key_b64=(
                env.get("LICENSE_API_DEV_CODE_ENC_KEY_B64") or ""
            ).strip(),
            dev_auth_uid=(env.get("LICENSE_API_DEV_AUTH_UID") or "").strip(),
        )


def load_settings(environ: Mapping[str, str] | None = None) -> Settings:
    """Read settings from the environment (the deployment's only input)."""
    return Settings.from_env(environ)
