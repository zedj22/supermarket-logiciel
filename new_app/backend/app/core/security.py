"""Security module — PIN hashing and JWT token management.

PINs are hashed with Argon2id (NOT SHA-256, NOT MD5).
JWT tokens are signed with HS256 and contain minimal claims.

Security decisions documented:
- Argon2id chosen over bcrypt/scrypt for modern resistance to GPU attacks
- Time cost=3, memory=64MB, parallelism=4 — appropriate for local desktop/LAN
- Salt is randomly generated per hash (argon2 handles this internally)
- JWT claims are minimal: sub (user_id), sid (session_id), exp
- Token hash (SHA-256) stored in DB, not raw JWT
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone

import structlog
from jose import JWTError, jwt
from passlib.context import CryptContext

from app.core.config import settings
from app.core.constants import (
    ARGON2_HASH_LENGTH,
    ARGON2_MEMORY_COST,
    ARGON2_PARALLELISM,
    ARGON2_SALT_LENGTH,
    ARGON2_TIME_COST,
)

logger = structlog.get_logger(__name__)

# ---------------------------------------------------------------------------
# Argon2id PIN hashing
# ---------------------------------------------------------------------------

pwd_context = CryptContext(
    schemes=["argon2"],
    deprecated="auto",
    argon2__time_cost=ARGON2_TIME_COST,
    argon2__memory_cost=ARGON2_MEMORY_COST,
    argon2__parallelism=ARGON2_PARALLELISM,
    argon2__hash_len=ARGON2_HASH_LENGTH,
    argon2__salt_len=ARGON2_SALT_LENGTH,
)


def hash_pin(pin: str) -> str:
    """Hash a PIN using Argon2id.

    The hash includes the algorithm parameters and a random salt.
    Format: $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>
    """
    return pwd_context.hash(pin)


def verify_pin(pin: str, pin_hash: str) -> bool:
    """Verify a PIN against an Argon2id hash.

    Uses constant-time comparison internally.
    Returns False on any error (never raises).
    """
    try:
        return pwd_context.verify(pin, pin_hash)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# JWT token management
# ---------------------------------------------------------------------------


def create_access_token(
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    expires_delta: timedelta | None = None,
) -> str:
    """Create a signed JWT access token.

    Claims:
        sub: user UUID
        sid: session UUID
        exp: expiration time
        iat: issued at time
    """
    now = datetime.now(timezone.utc)
    expire = now + (expires_delta or timedelta(minutes=settings.JWT_ACCESS_TOKEN_EXPIRE_MINUTES))

    payload = {
        "sub": str(user_id),
        "sid": str(session_id),
        "exp": expire,
        "iat": now,
    }

    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)


def decode_access_token(token: str) -> dict | None:
    """Decode and verify a JWT access token.

    Returns the payload dict on success, None on any error.
    Never raises — handles all JWT errors internally.
    """
    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )
        return payload
    except JWTError as exc:
        logger.debug("jwt_decode_failed", error=str(exc))
        return None


def hash_token(token: str) -> str:
    """Create a SHA-256 fingerprint of a JWT token.

    Used to store a revocable reference in the database
    without storing the raw token.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
