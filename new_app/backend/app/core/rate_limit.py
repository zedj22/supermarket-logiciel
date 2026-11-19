"""Application-wide rate limiting (Phase 17 §17.7).

Roadmap Phase 3 lists "Rate limiting", but only the Phase 16 *pairing*
throttle shipped; D-08 deferred the app-wide control to this security
pass.  One sliding-window implementation is shared by:

* every route under ``/api/v1`` — a per-client-IP backstop
  (``API_RATE_LIMIT_PER_MINUTE``) that caps a runaway or hostile client;
* the PIN-entry endpoints (``/auth/login``, ``/auth/reauth``,
  ``/auth/setup``) at ``AUTH_RATE_LIMIT_PER_MINUTE`` so a wrong PIN cannot
  be sprayed faster than the per-account lockout (§4) allows.

State is process-local, exactly like Phase 16 pairing: a single uvicorn
worker, no new tables and no new dependency.
"""

from __future__ import annotations

import math
import threading
import time
from collections import deque

import structlog
from fastapi import Request

from app.core.config import settings
from app.core.exceptions import AppError

logger = structlog.get_logger(__name__)


class SlidingWindowLimiter:
    """Fixed-capacity sliding window keyed by an arbitrary string."""

    def __init__(self, limit: int, window_seconds: int = settings.RATE_WINDOW_SECONDS):
        self.limit = limit
        self.window_seconds = window_seconds
        self._lock = threading.Lock()
        self._hits: dict[str, deque[float]] = {}

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            bucket = self._hits.setdefault(key, deque())
            cutoff = now - self.window_seconds
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()
            if len(bucket) >= self.limit:
                return False
            bucket.append(now)
            # Opportunistic sweep so a busy server never leaks keys.
            if len(self._hits) > 4096:
                for k in list(self._hits):
                    if not self._hits[k] or self._hits[k][-1] <= cutoff:
                        self._hits.pop(k, None)
            return True

    def retry_after(self, key: str) -> int:
        """Seconds until ``key`` may retry again (at least 1)."""
        now = time.monotonic()
        with self._lock:
            bucket = self._hits.get(key)
            if not bucket:
                return self.window_seconds
            cutoff = now - self.window_seconds
            oldest = next((ts for ts in bucket if ts > cutoff), None)
        if oldest is None:
            return 1
        return max(1, math.ceil(oldest + self.window_seconds - now))

    def clear(self) -> None:
        """Forget every key (testing seam)."""
        with self._lock:
            self._hits.clear()


class RateLimitedError(AppError):
    code = "RATE_LIMITED"
    status_code = 429
    message_key = "errors.rateLimited"


#: Whole-API backstop, the stricter PIN-entry cap, and the Phase L2-A
#: Lifetime-activation cap (10 attempts/minute/client IP by default).
api_limiter = SlidingWindowLimiter(settings.API_RATE_LIMIT_PER_MINUTE)
auth_limiter = SlidingWindowLimiter(settings.AUTH_RATE_LIMIT_PER_MINUTE)
license_limiter = SlidingWindowLimiter(settings.LICENSE_ACTIVATION_RATE_LIMIT_PER_MINUTE)


def client_key(request: Request) -> str:
    """Stable per-caller key. Unknown peer still gets its own bucket."""
    client = request.client
    return client.host if client is not None and client.host else "unknown"


def enforce_rate_limit(
    request: Request,
    limiter: SlidingWindowLimiter,
    *,
    key: str | None = None,
    scope: str = "api",
) -> None:
    """Count one attempt and raise :class:`RateLimitedError` when over the cap."""
    effective_key = key or client_key(request)
    if limiter.allow(effective_key):
        return
    retry_seconds = limiter.retry_after(effective_key)
    logger.warning(
        "rate_limited",
        scope=scope,
        key=effective_key,
        retry_seconds=retry_seconds,
    )
    raise RateLimitedError(
        message="Too many requests — please wait a moment and retry",
        details={"scope": scope, "retry_seconds": retry_seconds},
    )


def api_rate_guard(request: Request) -> None:
    """Router-level backstop: every /api/v1 request counts against the client IP."""
    enforce_rate_limit(request, api_limiter, scope="api")


def reset_rate_limiters() -> None:
    """Testing seam: drop all sliding-window state between tests."""
    api_limiter.clear()
    auth_limiter.clear()
    license_limiter.clear()
