"""Phase L2-A — Lifetime activation code parsing, verification, rejection.

Test keypairs are generated **in-process** (`Ed25519PrivateKey.generate`)
and never shipped, never written to disk and never shared with any
production key: the packaged `verification_keys.json` stays `{}`.

The matrix below is the adversarial half of §7: every malformed,
forged, tampered or foreign-hardware code must fail closed with one of
the existing controlled licensing codes, and must never echo the code,
the payload or a cryptographic exception back to the caller.
"""

from __future__ import annotations

import base64
import json
from datetime import datetime, timezone
from typing import Any

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from app.licensing.activation_code import (
    ACTIVATION_PREFIX,
    MAX_ACTIVATION_CODE_CHARS,
    build_request_code,
    build_request_payload,
    canonical_json,
    encode_activation_code,
    validate_payload,
    verify_activation_code,
)
from app.licensing.errors import (
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
)

UTC = timezone.utc

HW = "a" * 64
OTHER_HW = "f" * 64


def _raw_public(private: Ed25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


@pytest.fixture(scope="module")
def private() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()


@pytest.fixture(scope="module")
def keys(private: Ed25519PrivateKey) -> dict[str, bytes]:
    return {"k1": _raw_public(private)}


def payload(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "v": 1,
        "key_id": "k1",
        "license_id": "LIC-2026-0001",
        "kind": "lifetime",
        "issued_at": "2026-01-01T00:00:00+00:00",
        "hw_hash": HW,
        "features": ["pos", "inventory"],
    }
    body.update(overrides)
    return body


def code_of(body: dict[str, Any], private: Ed25519PrivateKey) -> str:
    return encode_activation_code(body, private.sign(canonical_json(body)))


def code_from_raw(payload_raw: bytes, signature: bytes) -> str:
    return (
        f"{ACTIVATION_PREFIX}."
        f"{base64.b32encode(payload_raw).decode().rstrip('=')}."
        f"{base64.b32encode(signature).decode().rstrip('=')}"
    )


def verify(code: str, keys: dict[str, bytes], hw: str = HW) -> Any:
    return verify_activation_code(code, keys=keys, expected_hw_hash=hw)


# ── the happy path ──────────────────────────────────────────────────────────


def test_valid_code_verifies_and_exposes_the_exact_payload(keys, private):
    body = payload()
    result = verify(code_of(body, private), keys)

    assert result.license_id == "LIC-2026-0001"
    assert result.key_id == "k1"
    assert result.kind == "lifetime"
    assert result.features == ("pos", "inventory")
    assert result.issued_at == datetime(2026, 1, 1, tzinfo=UTC)
    assert result.hw_hash == HW
    assert result.payload_bytes == canonical_json(body)
    assert len(result.signature) == 64


def test_encoding_is_deterministic_and_canonical(keys, private):
    body = payload()
    first, second = code_of(body, private), code_of(body, private)
    assert first == second
    assert first.startswith(f"{ACTIVATION_PREFIX}.")
    assert first.count(".") == 2
    assert len(first) <= MAX_ACTIVATION_CODE_CHARS
    # Sorted keys, compact separators — the bytes the signature covers.
    assert result_bytes_starts_with_sorted(body)


def result_bytes_starts_with_sorted(body: dict[str, Any]) -> bool:
    return canonical_json(body).startswith(b'{"features":')


# ── structure ───────────────────────────────────────────────────────────────


def test_wrong_prefix_is_rejected(keys, private):
    code = code_of(payload(), private)
    with pytest.raises(LicenseInvalidError):
        verify(code.replace(ACTIVATION_PREFIX, "SMPr1", 1), keys)


def test_too_few_segments_is_rejected(keys, private):
    code = code_of(payload(), private)
    with pytest.raises(LicenseInvalidError):
        verify(code.rsplit(".", 1)[0], keys)


def test_too_many_segments_is_rejected(keys, private):
    code = code_of(payload(), private)
    with pytest.raises(LicenseInvalidError):
        verify(code + ".extra", keys)


def test_empty_segments_are_rejected(keys, private):
    with pytest.raises(LicenseInvalidError):
        verify(f"{ACTIVATION_PREFIX}..{'A' * 52}", keys)
    with pytest.raises(LicenseInvalidError):
        verify(f"{ACTIVATION_PREFIX}.{'A' * 52}.", keys)


def test_oversized_code_is_rejected_before_decoding(keys, private):
    code = code_of(payload(), private) + "A" * MAX_ACTIVATION_CODE_CHARS
    assert len(code) > MAX_ACTIVATION_CODE_CHARS
    with pytest.raises(LicenseInvalidError):
        verify(code, keys)


@pytest.mark.parametrize("bad", ["", "   ", ".", ACTIVATION_PREFIX])
def test_blank_codes_are_rejected(keys, bad):
    with pytest.raises(LicenseInvalidError):
        verify(bad, keys)


def test_non_string_code_is_rejected(keys):
    with pytest.raises(LicenseInvalidError):
        verify(None, keys)  # type: ignore[arg-type]


def test_request_code_is_not_a_license(keys):
    request = build_request_code(
        build_request_payload(install_id="x", hw_hash=HW, requested_at=datetime.now(UTC))
    )
    with pytest.raises(LicenseInvalidError):
        verify(request, keys)


def test_invalid_base32_is_rejected(keys, private):
    code = code_of(payload(), private)
    prefix, payload_part, signature_part = code.split(".")
    broken = f"{prefix}.{payload_part[:-1]}1.{signature_part}"
    with pytest.raises(LicenseInvalidError):
        verify(broken, keys)


def test_lowercase_base32_is_rejected(keys, private):
    code = code_of(payload(), private)
    prefix, payload_part, signature_part = code.split(".")
    with pytest.raises(LicenseInvalidError):
        verify(f"{prefix}.{payload_part.lower()}.{signature_part}", keys)


# ── payload content ─────────────────────────────────────────────────────────


def test_invalid_json_payload_is_rejected(keys, private):
    code = code_from_raw(b"this is not json", private.sign(b"this is not json"))
    with pytest.raises(LicenseInvalidError):
        verify(code, keys)


def test_non_object_json_payload_is_rejected(keys, private):
    raw = b'["v", 1]'
    code = code_from_raw(raw, private.sign(raw))
    with pytest.raises(LicenseInvalidError):
        verify(code, keys)


def test_duplicate_json_keys_are_rejected(keys, private):
    raw = (
        b'{"v":1,"v":1,"key_id":"k1","license_id":"LIC-2026-0001",'
        b'"kind":"lifetime","issued_at":"2026-01-01T00:00:00+00:00",'
        b'"hw_hash":"' + HW.encode() + b'","features":[]}'
    )
    code = code_from_raw(raw, private.sign(raw))
    with pytest.raises(LicenseInvalidError):
        verify(code, keys)


def test_nan_in_payload_is_rejected(keys, private):
    raw = b'{"v":1,"key_id":NaN}'
    code = code_from_raw(raw, private.sign(raw))
    with pytest.raises(LicenseInvalidError):
        verify(code, keys)


def test_missing_field_is_rejected(keys, private):
    body = payload()
    body.pop("hw_hash")
    with pytest.raises(LicenseInvalidError):
        verify(code_of(body, private), keys)


def test_unknown_field_is_rejected(keys, private):
    with pytest.raises(LicenseInvalidError):
        verify(code_of(payload(customer="someone"), private), keys)


def test_unsupported_version_is_rejected(keys, private):
    with pytest.raises(LicenseInvalidError):
        verify(code_of(payload(v=2), private), keys)


def test_boolean_version_is_rejected(keys, private):
    with pytest.raises(LicenseInvalidError):
        verify(code_of(payload(v=True), private), keys)


def test_unsupported_license_kind_is_rejected(keys, private):
    with pytest.raises(LicenseInvalidError) as exc:
        verify(code_of(payload(kind="subscription"), private), keys)
    assert "subscription" in str(exc.value)


def test_invalid_timestamp_is_rejected(keys, private):
    for bad in ("2026-01-01", "not-a-time", 1767225600):
        with pytest.raises(LicenseInvalidError):
            verify(code_of(payload(issued_at=bad), private), keys)


def test_naive_timestamp_is_rejected(keys, private):
    with pytest.raises(LicenseInvalidError):
        verify(code_of(payload(issued_at="2026-01-01T00:00:00"), private), keys)


def test_invalid_hardware_hash_is_rejected(keys, private):
    for bad in ("A" * 64, HW[:-1], HW + "0", "z" * 64, ""):
        with pytest.raises(LicenseInvalidError):
            verify(code_of(payload(hw_hash=bad), private), keys)


def test_invalid_license_id_is_rejected(keys, private):
    for bad in ("", "short", "with space!"):
        with pytest.raises(LicenseInvalidError):
            verify(code_of(payload(license_id=bad), private), keys)


def test_length_bounds_are_fully_anchored():
    """``match`` alone only anchors at the start: over-long values and
    trailing-newline smuggling must not slip through the schema."""
    validate_payload(payload(license_id="x" * 64))
    for bad in ("x" * 65, "y" * 7, "x" * 64 + "\n"):
        with pytest.raises(LicenseInvalidError):
            validate_payload(payload(license_id=bad))

    validate_payload(payload(hw_hash=HW))
    for bad in (HW + "0", HW[:-1], HW + "\n"):
        with pytest.raises(LicenseInvalidError):
            validate_payload(payload(hw_hash=bad))

    validate_payload(payload(features=["f" * 32]))
    for bad in (["f" * 33], ["f" * 32 + "\n"]):
        with pytest.raises(LicenseInvalidError):
            validate_payload(payload(features=bad))


@pytest.mark.parametrize(
    "features",
    [
        "pos",  # not a list
        ["POS"],  # wrong case
        ["pos", "pos"],  # duplicate
        [1],  # not a string
        [""],  # empty token
        ["pos" + "x" * 40],  # too long
        [f"f{i}" for i in range(33)],  # too many
    ],
)
def test_invalid_feature_lists_are_rejected(keys, private, features):
    with pytest.raises(LicenseInvalidError):
        verify(code_of(payload(features=features), private), keys)


# ── keys and signatures ─────────────────────────────────────────────────────


def test_unknown_key_id_is_rejected(keys, private):
    with pytest.raises(LicenseInvalidKeyError) as exc:
        verify(code_of(payload(key_id="k9"), private), keys)
    assert exc.value.code == "license_invalid_key"


def test_no_shipped_keys_never_verifies(keys, private):
    with pytest.raises(LicenseInvalidKeyError):
        verify(code_of(payload(), private), {})


def test_tampered_signature_is_rejected(keys, private):
    body = payload()
    good = private.sign(canonical_json(body))
    bad = bytes([good[0] ^ 0x01]) + good[1:]
    with pytest.raises(LicenseInvalidError):
        verify(code_from_raw(canonical_json(body), bad), keys)


def test_signature_over_a_different_payload_is_rejected(keys, private):
    body = payload()
    signature = private.sign(canonical_json(body))
    other = canonical_json(payload(license_id="LIC-2026-0002"))
    with pytest.raises(LicenseInvalidError):
        verify(code_from_raw(other, signature), keys)


def test_wrong_length_signature_is_rejected(keys, private):
    body = payload()
    with pytest.raises(LicenseInvalidError):
        verify(code_from_raw(canonical_json(body), b"\x00" * 56), keys)


def test_signature_is_checked_over_the_exact_bytes_not_a_reserialization(
    keys, private
):
    """Whitespace-shifted bytes carry the same JSON but must not verify."""
    body = payload()
    compact = canonical_json(body)
    spaced = json.dumps(body, indent=2, sort_keys=False).encode("utf-8")
    assert json.loads(spaced) == json.loads(compact)
    with pytest.raises(LicenseInvalidError):
        verify(code_from_raw(spaced, private.sign(compact)), keys)


def test_untrusted_key_material_shape_never_verifies(private):
    body = payload()
    short_key = b"\x01" * 16  # not a 32-byte Ed25519 key
    code = code_of(body, private)
    with pytest.raises(LicenseInvalidError):
        verify(code, {"k1": short_key})


# ── hardware binding ────────────────────────────────────────────────────────


def test_hardware_mismatch_is_rejected_as_bound_elsewhere(keys, private):
    with pytest.raises(LicenseBoundElsewhereError) as exc:
        verify(code_of(payload(), private), keys, hw=OTHER_HW)
    assert exc.value.code == "license_bound_elsewhere"


def test_valid_code_for_this_machine_is_accepted(keys, private):
    assert verify(code_of(payload(hw_hash=OTHER_HW), private), keys, hw=OTHER_HW)


# ── what the errors may say ─────────────────────────────────────────────────


def test_errors_never_echo_the_code_payload_or_crypto_detail(keys, private):
    code = code_of(payload(), private)
    tampered = code[:-2] + ("A" if code[-2] != "A" else "B") + code[-1:]

    for bad in (tampered, code.replace(ACTIVATION_PREFIX, "SMPr1", 1), code + "A" * 600):
        with pytest.raises(LicenseInvalidError) as exc:
            verify(bad, keys)
        message = str(exc.value)
        assert code not in message
        assert code.split(".")[1][:20] not in message
        assert "InvalidSignature" not in message
        assert "ed25519" not in message.lower()


def test_hardware_mismatch_error_does_not_leak_the_expected_hash(keys, private):
    with pytest.raises(LicenseBoundElsewhereError) as exc:
        verify(code_of(payload(), private), keys, hw=OTHER_HW)
    assert HW not in str(exc.value)
    assert OTHER_HW not in str(exc.value)
