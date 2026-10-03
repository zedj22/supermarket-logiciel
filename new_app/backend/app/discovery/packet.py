"""UDP discovery wire format (Phase 16 §4).

Deliberately tiny and deliberately unauthenticated: the discover/offer
exchange carries NO secrets (never a pairing code, token, PIN or JWT) —
only ``server_id``, the store name and the HTTP port, all of which are
already public on ``GET /api/v1/system/info`` (§4.3).

Framing
    <MAGIC bytes> + b"\\x00" + <UTF-8 JSON object>

Both directions are hard bounded: a discover request is at most 256 bytes
and an offer response at most 512 bytes. Anything larger, anything with
the wrong magic, a non-object JSON body, ``v != 1`` or a malformed nonce
is dropped silently — never answered, never logged at info level.

The magic string ``SUPERMARKET_PRO_DISCOVER_V1`` is a *magic* (a
"which app is this" marker), not a credential.

Application id
    Every datagram also carries ``"app": "supermarket_pro"``, which the
    Flutter client checks in ``_decode``
    (``lib/features/devices/discovery_service.dart``:
    ``decoded['app'] == discoveryAppId``) before it accepts *anything*.
    Magic + version alone are not enough there: without ``app`` the offer
    is silently dropped and the wizard reports "server not found" even
    though the responder answered correctly.  This is the cross-stack
    contract mismatch found in real 2-PC LAN testing — keep the field, and
    keep it equal to the Flutter constant.
"""

from __future__ import annotations

import json

MAGIC = b"SUPERMARKET_PRO_DISCOVER_V1"
PROTOCOL_VERSION = 1
# Must stay equal to `discoveryAppId` in Flutter's discovery_service.dart.
APP_ID = "supermarket_pro"
MAX_REQUEST_BYTES = 256
MAX_RESPONSE_BYTES = 512
NONCE_MIN = 8
NONCE_MAX = 64

TYPE_DISCOVER = "discover"
TYPE_OFFER = "offer"


def _frame(payload: dict) -> bytes:
    return MAGIC + b"\x00" + json.dumps(payload, separators=(",", ":")).encode("utf-8")


def _unframe(data: bytes, max_bytes: int) -> dict | None:
    """Return the payload dict, or None if anything at all looks wrong."""
    if not isinstance(data, (bytes, bytearray)):
        return None
    if len(data) > max_bytes:
        return None
    if not data.startswith(MAGIC + b"\x00"):
        return None
    body = bytes(data[len(MAGIC) + 1 :])
    if not body:
        return None
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def build_discover(nonce: str) -> bytes:
    """Client → server: ``{"v":1,"t":"discover","nonce":"..."}``."""
    return _frame({"v": PROTOCOL_VERSION, "t": TYPE_DISCOVER, "nonce": nonce})


def parse_discover(data: bytes) -> str | None:
    """Validate a discover request, returning its nonce or None."""
    payload = _unframe(data, MAX_REQUEST_BYTES)
    if payload is None:
        return None
    if payload.get("v") != PROTOCOL_VERSION:
        return None
    if payload.get("t") != TYPE_DISCOVER:
        return None
    nonce = payload.get("nonce")
    if not isinstance(nonce, str):
        return None
    if not (NONCE_MIN <= len(nonce) <= NONCE_MAX):
        return None
    return nonce


# An offer is metadata about one store; keeping the name short is what
# guarantees the whole datagram stays inside MAX_RESPONSE_BYTES even when
# the store name is Arabic (3 bytes/char in UTF-8).
OFFER_NAME_MAX_CHARS = 64


def build_offer(
    *,
    nonce: str,
    server_id: str,
    name: str,
    http_port: int,
    protocol: int = PROTOCOL_VERSION,
    tls: bool = False,
) -> bytes:
    """Server → client offer. Public metadata only (§4.3).

    ``app`` is a required field of the cross-stack contract: the Flutter
    client's ``_decode`` drops any datagram whose ``app`` is not
    ``supermarket_pro``, so omitting it made a perfectly good offer look
    like "server not found" on the second PC.
    """
    payload = {
        "v": PROTOCOL_VERSION,
        "app": APP_ID,
        "t": TYPE_OFFER,
        "nonce": nonce,
        "server_id": server_id,
        "name": name[:OFFER_NAME_MAX_CHARS],
        "http_port": int(http_port),
        "protocol": int(protocol),
        "tls": bool(tls),
    }
    return _frame(payload)


def parse_offer(data: bytes, *, expect_nonce: str | None = None) -> dict | None:
    """Client side: parse + validate an offer, or return None.

    Silently discards: oversized packets, wrong magic, wrong version, a
    non-object body and any offer whose nonce does not echo the one we
    sent (so a stale/misdirected offer cannot be accepted).
    """
    payload = _unframe(data, MAX_RESPONSE_BYTES)
    if payload is None:
        return None
    if payload.get("v") != PROTOCOL_VERSION:
        return None
    if payload.get("t") != TYPE_OFFER:
        return None
    for key in ("server_id", "name", "nonce"):
        value = payload.get(key)
        if not isinstance(value, str) or not value:
            return None
    port = payload.get("http_port")
    if not isinstance(port, int) or not (0 < port < 65536):
        return None
    if not isinstance(payload.get("protocol"), int):
        return None
    if expect_nonce is not None and payload.get("nonce") != expect_nonce:
        return None
    return payload
