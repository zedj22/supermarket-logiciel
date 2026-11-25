"""Firebase Authentication, App Check and the server-side allowlist.

Three gates, in order, and each fails closed:

1. **ID token** — ``firebase_admin.auth.verify_id_token(..., check_revoked=True)``.
   Any failure (missing, malformed, expired, wrong project, revoked session) is
   the same ``401 unauthorized``; the provider's message is never echoed.
2. **Administrator allowlist** — the verified ``uid``/``email`` must appear in
   ``LICENSE_API_ADMIN_UIDS`` / ``LICENSE_API_ADMIN_EMAILS``.  The lists live
   in the service environment, never in the browser and never in Firestore.  An
   **empty allowlist denies everyone** — a misconfigured deployment is closed,
   not wide open.
3. **App Check** — when ``LICENSE_API_REQUIRE_APP_CHECK=1`` a verified
   ``X-Firebase-AppCheck`` token is also required, so a stolen ID token is not
   enough on its own.

The Firebase SDK is imported lazily: the whole test suite runs without it, and
a missing SDK surfaces as the controlled ``401``/``503`` family rather than an
``ImportError``.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Protocol

from service.errors import (
    AdminNotAllowlistedError,
    AppCheckRequiredError,
    SigningKeyError,
    UnauthorizedError,
)
from service.settings import Settings

__all__ = [
    "AdminPrincipal",
    "DevelopmentTokenVerifier",
    "FirebaseTokenVerifier",
    "StaticTokenVerifier",
    "TokenVerifier",
    "authenticate_admin",
    "bearer_token",
]


@dataclass(frozen=True, slots=True)
class AdminPrincipal:
    """The verified administrator behind one request."""

    uid: str
    email: str | None = None
    claims: Mapping[str, Any] | None = None


class TokenVerifier(Protocol):
    """Verifies Firebase ID tokens and (optionally) App Check tokens."""

    def verify_id_token(self, token: str) -> Mapping[str, Any]: ...

    def verify_app_check_token(self, token: str) -> Mapping[str, Any]: ...


class FirebaseTokenVerifier:
    """Thin adapter over ``firebase_admin`` (lazy import).

    Refuses to exist at all in production while the Firebase Auth emulator is
    configured: with ``FIREBASE_AUTH_EMULATOR_HOST`` set the SDK accepts
    unsigned emulator tokens, so that variable reaching a production deployment
    would silently disable authentication.  The check runs in ``__init__`` (no
    SDK import needed) so it also protects misconfigured local runs.
    """

    def __init__(
        self,
        project_id: str = "",
        *,
        env: str = "development",
        app_check_audience: str = "",
    ) -> None:
        if env == "production" and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST"):
            raise SigningKeyError(
                "FIREBASE_AUTH_EMULATOR_HOST must never be set in production: it "
                "makes Firebase accept unsigned emulator tokens"
            )
        self._project_id = project_id
        self._app_check_audience = app_check_audience.strip().removeprefix("projects/")
        self._app: Any = None

    def _firebase_app(self) -> Any:
        if self._app is None:
            try:
                import firebase_admin
                from firebase_admin import credentials
            except ImportError as exc:  # pragma: no cover - deployment dependency
                raise SigningKeyError(
                    "Firebase Admin support is not installed on this host "
                    "(pip install firebase-admin)"
                ) from exc
            try:
                self._app = firebase_admin.get_app()
            except ValueError:
                options = {"projectId": self._project_id} if self._project_id else None
                self._app = firebase_admin.initialize_app(
                    credentials.ApplicationDefault(), options
                )
        return self._app

    def verify_id_token(self, token: str) -> Mapping[str, Any]:
        try:
            from firebase_admin import auth
        except ImportError as exc:  # pragma: no cover - deployment dependency
            raise SigningKeyError(
                "Firebase Admin support is not installed on this host"
            ) from exc
        # `check_revoked=True`: a signed-out or revoked administrator session
        # stops working immediately, not when the token expires.
        claims = auth.verify_id_token(
            token, app=self._firebase_app(), check_revoked=True
        )
        self._assert_bound_to_project(claims)
        return claims

    def _assert_bound_to_project(self, claims: Mapping[str, Any]) -> None:
        """Only accept tokens minted for **this** Firebase project.

        ``verify_id_token`` already validates the audience against the app's
        project, but the project id is configuration here: pinning it again
        keeps a token from another project (or a verifier wired to a different
        default app) from being accepted after a configuration mistake.
        """
        if not self._project_id:
            return
        audience = claims.get("aud")
        if audience != self._project_id:
            raise UnauthorizedError(
                "the presented credentials are not valid for this project"
            )
        issuer = claims.get("iss")
        if issuer is not None and issuer != (
            f"https://securetoken.google.com/{self._project_id}"
        ):
            raise UnauthorizedError(
                "the presented credentials are not valid for this project"
            )

    def verify_app_check_token(self, token: str) -> Mapping[str, Any]:
        try:
            from firebase_admin import app_check
        except ImportError as exc:  # pragma: no cover - deployment dependency
            raise SigningKeyError(
                "Firebase App Check support is not installed on this host"
            ) from exc
        claims = app_check.verify_token(token, app=self._firebase_app())
        self._assert_app_check_project(claims)
        return claims

    def _assert_app_check_project(self, claims: Mapping[str, Any]) -> None:
        """Pin the App Check token to **this** Firebase project.

        App Check tokens carry ``aud = "projects/<project number>"``.  The Admin
        SDK already validates that against the app's project, but the number is
        configuration here, so it is compared again: a deployment wired to the
        wrong project (or a token minted elsewhere) fails closed instead of
        being accepted because both sides happened to agree.

        With no audience configured outside production the SDK check is the only
        one; production refuses that configuration when enforcement is enabled
        (see ``Settings.__post_init__``).
        """
        if not self._app_check_audience:
            return
        audience = claims.get("aud")
        if audience not in (
            self._app_check_audience,
            f"projects/{self._app_check_audience}",
        ):
            raise UnauthorizedError(
                "the App Check token is not valid for this project"
            )


class DevelopmentTokenVerifier:
    """Accept exactly one local token, ``dev:<uid>``, as that administrator.

    Exists so the dashboard can be developed against a locally running API
    without a Firebase project.  It is never wired when
    ``LICENSE_API_ENV=production`` (``Settings`` refuses the setting outright),
    it accepts a single fixed string, and the uid still has to pass the normal
    administrator allowlist — it cannot widen who is an administrator.
    """

    def __init__(self, uid: str, email: str | None = None) -> None:
        self._token = f"dev:{uid}"
        claims: dict[str, Any] = {"uid": uid, "auth_mode": "development"}
        if email:
            claims["email"] = email
        self._claims = claims

    def verify_id_token(self, token: str) -> Mapping[str, Any]:
        if token != self._token:
            raise UnauthorizedError("the presented credentials are not valid")
        return dict(self._claims)

    def verify_app_check_token(self, token: str) -> Mapping[str, Any]:
        raise UnauthorizedError("App Check is not available in development mode")


class StaticTokenVerifier:
    """Fixed token table — tests only (never wired in production)."""

    def __init__(
        self,
        id_tokens: Mapping[str, Mapping[str, Any]],
        app_check_tokens: Mapping[str, Mapping[str, Any]] | None = None,
    ) -> None:
        self._id_tokens = dict(id_tokens)
        self._app_check_tokens = dict(app_check_tokens or {})

    def verify_id_token(self, token: str) -> Mapping[str, Any]:
        claims = self._id_tokens.get(token)
        if claims is None:
            raise UnauthorizedError("the presented credentials are not valid")
        return claims

    def verify_app_check_token(self, token: str) -> Mapping[str, Any]:
        claims = self._app_check_tokens.get(token)
        if claims is None:
            raise UnauthorizedError("the presented App Check token is not valid")
        return claims


def bearer_token(authorization: str | None) -> str:
    """Extract the bearer token, or raise the generic 401."""
    if not authorization:
        raise UnauthorizedError("authentication is required")
    scheme, _, value = authorization.partition(" ")
    if scheme.lower() != "bearer" or not value.strip():
        raise UnauthorizedError("authentication is required")
    return value.strip()


def _is_allowlisted(principal: AdminPrincipal, settings: Settings) -> bool:
    if settings.allowlist_is_empty:
        # Fail closed: an unset allowlist authorizes nobody.
        return False
    if principal.uid in settings.admin_uids:
        return True
    if principal.email and principal.email.lower() in settings.admin_emails:
        return True
    return False


def authenticate_admin(
    *,
    authorization: str | None,
    app_check_header: str | None,
    verifier: TokenVerifier,
    settings: Settings,
) -> AdminPrincipal:
    """Run the three gates and return the verified administrator."""
    token = bearer_token(authorization)
    try:
        claims = verifier.verify_id_token(token)
    except UnauthorizedError:
        raise
    except Exception as exc:
        raise UnauthorizedError("the presented credentials are not valid") from exc

    uid = claims.get("uid") or claims.get("user_id") or claims.get("sub")
    if not isinstance(uid, str) or not uid:
        raise UnauthorizedError("the presented credentials are not valid")
    email = claims.get("email")
    principal = AdminPrincipal(
        uid=uid,
        email=email if isinstance(email, str) and email else None,
        claims=claims,
    )

    if settings.require_app_check:
        if not app_check_header:
            raise AppCheckRequiredError(
                "a verified Firebase App Check token is required"
            )
        try:
            verifier.verify_app_check_token(app_check_header)
        except Exception as exc:
            raise AppCheckRequiredError(
                "the App Check token is not valid"
            ) from exc

    if not _is_allowlisted(principal, settings):
        raise AdminNotAllowlistedError(
            "this account is not on the License Manager administrator allowlist"
        )
    return principal
