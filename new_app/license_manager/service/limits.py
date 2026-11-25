"""Request-size and rate limits.

Two independent guards, both process-local (the service is stateless apart
from Firestore, so no shared cache is needed):

* **body cap** — a pure-ASGI middleware that counts bytes while the body is
  being read and answers ``413`` the moment the configured cap is exceeded,
  *before* any parsing happens (the same discipline the customer backend uses
  for ``/license/activate``);
* **per-administrator sliding windows** — one for reads, a tighter one for
  issuance, keyed by the verified Firebase uid (not by IP, which the caller
  does not control behind a proxy).
"""

from __future__ import annotations

import json
import threading
import time
from collections import deque
from collections.abc import Callable
from typing import Any

from service.errors import RateLimitedError

__all__ = ["BodyLimitMiddleware", "SlidingWindowLimiter"]


class SlidingWindowLimiter:
    """Fixed-capacity sliding window keyed by an arbitrary string."""

    def __init__(self, limit: int, window_seconds: int = 60) -> None:
        if limit < 1:
            raise ValueError("a rate limit must be at least 1 per window")
        self.limit = limit
        self.window_seconds = window_seconds
        self._lock = threading.Lock()
        self._hits: dict[str, deque[float]] = {}

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        cutoff = now - self.window_seconds
        with self._lock:
            bucket = self._hits.setdefault(key, deque())
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()
            if len(bucket) >= self.limit:
                return False
            bucket.append(now)
            if len(self._hits) > 4096:
                for candidate in list(self._hits):
                    entries = self._hits[candidate]
                    if not entries or entries[-1] <= cutoff:
                        self._hits.pop(candidate, None)
            return True

    def retry_after(self, key: str) -> int:
        with self._lock:
            bucket = self._hits.get(key)
            if not bucket:
                return 1
            elapsed = time.monotonic() - bucket[0]
        return max(1, int(self.window_seconds - elapsed) + 1)

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()


class BodyLimitMiddleware:
    """Reject an oversized request body before the application reads it.

    Pure ASGI so the body is buffered once (bounded by the cap) and replayed
    to the application — no double parsing, no framework-specific surprises.
    """

    def __init__(self, app: Callable, *, max_bytes: int) -> None:
        if max_bytes < 512:
            raise ValueError("the request body cap must be at least 512 bytes")
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: dict[str, Any], receive: Callable, send: Callable) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers") or []}
        declared = headers.get(b"content-length")
        if declared is not None:
            try:
                if int(declared) > self.max_bytes:
                    await self._reject(send)
                    return
            except ValueError:
                await self._reject(send, code="validation_error", status=422,
                                  message="Invalid Content-Length header")
                return

        chunks: list[bytes] = []
        total = 0
        while True:
            message = await receive()
            if message.get("type") == "http.disconnect":
                return
            if message.get("type") != "http.request":
                continue
            body = message.get("body", b"")
            total += len(body)
            if total > self.max_bytes:
                await self._reject(send)
                return
            chunks.append(body)
            if not message.get("more_body", False):
                break

        payload = b"".join(chunks)
        replayed = False

        async def replay() -> dict[str, Any]:
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": payload, "more_body": False}
            return {"type": "http.disconnect"}

        await self.app(scope, replay, send)

    async def _reject(
        self,
        send: Callable,
        *,
        code: str = "request_too_large",
        status: int = 413,
        message: str | None = None,
    ) -> None:
        body = json.dumps(
            {
                "error": {
                    "code": code,
                    "message": message
                    or f"the request body must not exceed {self.max_bytes} bytes",
                    "details": {"max_bytes": self.max_bytes},
                }
            }
        ).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                    (b"cache-control", b"no-store"),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})


def enforce(limiter: SlidingWindowLimiter, key: str) -> None:
    """Raise the controlled ``429`` when ``key`` is over its window."""
    if not limiter.allow(key):
        raise RateLimitedError(
            "too many requests; retry shortly",
            headers={"Retry-After": str(limiter.retry_after(key))},
        )
