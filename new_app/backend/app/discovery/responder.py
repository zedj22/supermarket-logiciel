"""UDP discovery responder (Phase 16 §4).

A single daemon thread that answers ``discover`` datagrams with an
``offer``. Standard library only — ``socket`` + ``threading``. No asyncio,
no third-party dependency, no multicast/broadcast scanning.

Lifecycle
    started from the FastAPI lifespan when ``DISCOVERY_ENABLED=1``,
    stopped again on shutdown. With the flag off (the default) nothing is
    ever bound, so single-PC installs behave exactly as before Phase 16.

Safety properties
    * binds exactly ONE UDP port (``DISCOVERY_PORT``, default 8000 = the
      HTTP port so a store only opens one number);
    * never scans the subnet, never sends an unsolicited packet;
    * answers only well formed, in-budget ``discover`` packets;
    * rate limited to 10 discover requests per second per source IP;
    * replies with public metadata only (no pairing code, no token, no
      PIN, no JWT) — §4.3;
    * a bind failure (port already in use) logs a warning and leaves the
      API running; discovery is a convenience, not a dependency.
"""

from __future__ import annotations

import socket
import threading
import time

import structlog

from app.core.config import settings
from app.core.server_identity import get_server_id
from app.discovery.packet import build_offer, parse_discover

logger = structlog.get_logger(__name__)

RATE_LIMIT_PER_SECOND = 10


class _RateLimiter:
    """10 discover requests per second, per source IP."""

    def __init__(self, limit: int = RATE_LIMIT_PER_SECOND):
        self.limit = limit
        self._lock = threading.Lock()
        self._hits: dict[str, list[float]] = {}

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            bucket = self._hits.setdefault(key, [])
            cutoff = now - 1.0
            bucket[:] = [t for t in bucket if t > cutoff]
            if len(bucket) >= self.limit:
                return False
            bucket.append(now)
            if len(self._hits) > 1024:
                for k in list(self._hits):
                    if not self._hits[k]:
                        self._hits.pop(k, None)
            return True


class DiscoveryResponder:
    """Owns the UDP socket and its worker thread."""

    def __init__(self, *, port: int | None = None, host: str = ""):
        self.port = settings.DISCOVERY_PORT if port is None else port
        self.host = host
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._limiter = _RateLimiter()

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    @property
    def bound_port(self) -> int | None:
        """The actual UDP port after bind (useful with ``port=0``)."""
        sock = self._sock
        if sock is None:
            return None
        try:
            return int(sock.getsockname()[1])
        except OSError as exc:  # pragma: no cover - socket already closed
            logger.debug("discovery_port_query_failed", error=str(exc))
            return None

    def start(self) -> bool:
        """Bind and start serving. Returns False when binding failed."""
        if self.running:
            return True
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((self.host, self.port))
            sock.settimeout(0.5)
        except OSError as exc:
            logger.warning(
                "discovery_bind_failed",
                port=self.port,
                error=str(exc),
                hint="set DISCOVERY_ENABLED=0 or free the UDP port",
            )
            return False

        self._sock = sock
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._serve,
            name="smp-discovery",
            daemon=True,
        )
        self._thread.start()
        logger.info(
            "discovery_started",
            port=self.port,
            server_id=get_server_id(),
            protocol=1,
        )
        return True

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None:
            thread.join(timeout=2.0)
        self._thread = None
        sock = self._sock
        self._sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError as exc:  # pragma: no cover - best effort shutdown
                # Best effort, but never silent (§17.7): a socket that will
                # not close means the port may stay occupied after stop().
                logger.warning("discovery_socket_close_failed", error=str(exc))
        logger.info("discovery_stopped")

    # ------------------------------------------------------------------

    def _serve(self) -> None:
        sock = self._sock
        if sock is None:  # pragma: no cover - defensive
            return
        while not self._stop.is_set():
            try:
                data, addr = sock.recvfrom(2048)
            except TimeoutError:
                continue
            except OSError as exc:
                if self._stop.is_set():  # pragma: no cover - normal shutdown
                    break
                logger.warning("discovery_recv_failed", error=str(exc))
                break
            try:
                self._handle(data, addr, sock)
            except Exception as exc:  # pragma: no cover - never kill the loop
                logger.warning("discovery_handle_failed", error=str(exc))

    def _handle(
        self, data: bytes, addr: tuple[str, int], sock: socket.socket
    ) -> None:
        nonce = parse_discover(data)
        if nonce is None:
            # Wrong magic / too big / bad JSON / bad version: silent drop.
            logger.debug("discovery_dropped", reason="invalid_packet", peer=addr[0])
            return
        if not self._limiter.allow(addr[0]):
            logger.debug("discovery_rate_limited", peer=addr[0])
            return
        reply = build_offer(
            nonce=nonce,
            server_id=get_server_id(),
            name=settings.STORE_NAME,
            http_port=settings.PORT,
        )
        try:
            sock.sendto(reply, addr)
        except OSError as exc:  # pragma: no cover - unreachable peer
            logger.debug("discovery_reply_failed", peer=addr[0], error=str(exc))


# ---------------------------------------------------------------------------
# Lifespan helpers
# ---------------------------------------------------------------------------

_responder: DiscoveryResponder | None = None


def start_discovery() -> bool:
    """Start the responder when DISCOVERY_ENABLED is on. Idempotent."""
    global _responder
    if not settings.DISCOVERY_ENABLED:
        return False
    if _responder is None:
        _responder = DiscoveryResponder()
    return _responder.start()


def stop_discovery() -> None:
    global _responder
    if _responder is not None:
        _responder.stop()


def current_responder() -> DiscoveryResponder | None:
    return _responder
