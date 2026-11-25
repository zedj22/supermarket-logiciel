"""Cloud Run service-to-service authentication (Dashboard → License API).

Two independent credentials travel on every proxied request, and neither can
stand in for the other:

1. **Cloud Run IAM identity token** — a Google-signed OIDC token minted by the
   Dashboard's *runtime service account* with the API's URL as its audience.
   Cloud Run itself refuses the request at the edge unless the caller holds
   ``roles/run.invoker``; this module verifies the same token again inside the
   process, so a deployment whose IAM binding was loosened by mistake is still
   closed.
2. **Firebase ID token** — the signed-in administrator. Verified by
   ``service.auth`` with revocation checking and the administrator allowlist.

The transport deliberately uses a **dedicated header**
(``X-Klickpos-Service-Authorization``) for the service token, because Cloud Run
consumes and strips ``Authorization`` / ``X-Serverless-Authorization`` at the
edge. ``Authorization`` therefore stays reserved for the Firebase token,
exactly as before this phase: the API's authentication and authorization
behaviour does not change.

A browser cannot usefully forge this header: held in a Cloud Run service
account, the token is minted only for that audience, carries the caller's
service-account email, and the API is not reachable without ``run.invoker``
in the first place. The check is defence in depth, not the only gate.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from service.errors import (
    ServiceIdentityNotAllowedError,
    ServiceIdentityRequiredError,
)

__all__ = ["SERVICE_IDENTITY_HEADER", "ServiceIdentityVerifier"]

#: Header the Dashboard server uses for the Cloud Run identity token.
#: Never ``Authorization``: that one carries the administrator's Firebase token.
SERVICE_IDENTITY_HEADER = "x-klickpos-service-authorization"


class ServiceIdentityVerifier:
    """Verify a Google-signed OIDC token minted for this API service.

    * the audience must equal the API's Cloud Run URL **exactly** — a token
      minted for any other service is useless here;
    * ``email_verified`` must be true;
    * when a caller allowlist is configured, the token's ``email`` must be in
      it (the Dashboard runtime service account).  An empty allowlist in
      production is refused by ``Settings``, so it cannot silently mean
      "anyone with a Google identity token".
    """

    def __init__(self, audience: str, allowed_emails: frozenset[str] | set[str] = frozenset()) -> None:
        self._audience = (audience or "").strip()
        self._allowed = frozenset(email.lower() for email in allowed_emails if email)
        if not self._audience:
            raise ValueError(
                "a Cloud Run audience is required to verify service identity"
            )

    @property
    def audience(self) -> str:
        return self._audience

    def check(self, header_value: str | None) -> Mapping[str, Any]:
        """Verify the header, or raise the controlled 401/403.

        Returns the verified claims so a caller could audit the service
        account; nothing is stored or logged.
        """
        token = _bearer(header_value)
        return self.verify(token)

    def verify(self, token: str) -> Mapping[str, Any]:
        if not token:
            raise ServiceIdentityRequiredError(
                "this endpoint is only reachable through the License Dashboard"
            )
        try:
            from google.auth.transport import requests as google_requests
            from google.oauth2 import id_token
        except ImportError as exc:  # pragma: no cover - deployment dependency
            raise ServiceIdentityRequiredError(
                "Cloud Run service identity verification is not installed on this host"
            ) from exc
        try:
            claims: Mapping[str, Any] = id_token.verify_oauth2_token(
                token, google_requests.Request(), audience=self._audience
            )
        except Exception as exc:
            # Signature, expiry, issuer and audience failures are one answer:
            # the caller is not the service this API trusts.  The provider's
            # message is never forwarded.
            raise ServiceIdentityRequiredError(
                "the calling service could not be verified"
            ) from exc

        if not claims.get("email_verified", False):
            raise ServiceIdentityRequiredError(
                "the calling service could not be verified"
            )
        email = str(claims.get("email") or "").lower()
        if not email:
            raise ServiceIdentityRequiredError(
                "the calling service could not be verified"
            )
        if self._allowed and email not in self._allowed:
            raise ServiceIdentityNotAllowedError(
                "this service account is not an allowed caller of the License API"
            )
        return claims


def _bearer(header_value: str | None) -> str:
    """Extract the token from ``Bearer <token>`` (scheme is case-insensitive)."""
    if not header_value:
        return ""
    scheme, _, value = header_value.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return value.strip()
