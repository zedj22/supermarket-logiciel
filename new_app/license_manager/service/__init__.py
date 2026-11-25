"""KlickPOS License Manager — a private, administrator-only License API.

Reuses the customer application's licensing contract
(``new_app/backend/app/licensing``) unchanged: the same ``SMPr1`` request
format, the same canonical JSON, the same Ed25519 signing and the same
``SMP1`` activation code the KlickPOS desktop already verifies.
"""

from __future__ import annotations

from service.api import app, create_app

__all__ = ["app", "create_app"]
