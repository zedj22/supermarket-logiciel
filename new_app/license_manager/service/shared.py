"""The **only** entry point into the existing KlickPOS licensing code.

Every other module in this service imports the licensing contract from here,
so the compatibility surface is one short, auditable list:

* the signed ``SMP1`` payload schema and its validator;
* canonical JSON serialisation;
* ``SMP1`` encoding and the customer-side verifier;
* the packaged public verification keys;
* the strict ``SMPr1`` request parser from the offline generator.

Nothing here is re-implemented, wrapped in different semantics, or duplicated:
the constants and regular expressions below are *the existing objects*, so a
future change to the contract automatically reaches this service.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping

from service.bootstrap import prepare_shared_import

prepare_shared_import()

# --- the licensing contract (unmodified customer code) --------------------- #
from app.licensing import activation_code as contract
from app.licensing.activation_code import (
    ACTIVATION_PREFIX,
    LICENSE_KIND,
    LICENSE_VERSION,
    MAX_ACTIVATION_CODE_CHARS,
    PAYLOAD_FIELDS,
    REQUEST_PREFIX,
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
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.verification_keys import (
    ED25519_PUBLIC_KEY_BYTES,
    VerificationKeysError,
    is_valid_key_id,
    load_verification_keys,
)
from tools.license_generator import generator as request_parser
from tools.license_generator.errors import (
    GeneratorError,
    RequestFormatError,
)

__all__ = [
    "ACTIVATION_PREFIX",
    "ED25519_PUBLIC_KEY_BYTES",
    "LICENSE_KIND",
    "LICENSE_VERSION",
    "MAX_ACTIVATION_CODE_CHARS",
    "PAYLOAD_FIELDS",
    "REQUEST_PREFIX",
    "GeneratorError",
    "HardwareFingerprintService",
    "LicenseBoundElsewhereError",
    "LicenseInvalidError",
    "LicenseInvalidKeyError",
    "RequestFormatError",
    "StaticHardwareInfoProvider",
    "VerificationKeysError",
    "canonical_json",
    "contract",
    "display_code_for",
    "encode_activation_code",
    "is_valid_hw_hash",
    "is_valid_key_id",
    "is_valid_license_id",
    "load_verification_keys",
    "normalise_features",
    "parse_request_code",
    "validate_payload",
    "verify_activation_code",
]

#: 64 lowercase hex characters — exactly the digest the customer signs.
_HW_HASH_RE = contract._HW_HASH_RE
#: The contract's own license-id pattern (``LIC-…`` values satisfy it).
_LICENSE_ID_RE = contract._LICENSE_ID_RE
#: The contract's own feature-grant pattern and cap.
_FEATURE_RE = contract._FEATURE_RE
_MAX_FEATURES = contract.MAX_FEATURES


def is_valid_hw_hash(value: object) -> bool:
    """True when ``value`` is the 64-hex hardware digest the contract signs."""
    return isinstance(value, str) and bool(_HW_HASH_RE.match(value))


def is_valid_license_id(value: object) -> bool:
    """True when ``value`` satisfies the contract's license-id pattern."""
    return isinstance(value, str) and bool(_LICENSE_ID_RE.match(value))


def normalise_features(features: Iterable[str] | None) -> tuple[str, ...]:
    """Validate feature grants with the contract's own pattern and cap.

    Raises ``ValueError`` with a human-readable reason (never a secret, never
    a code fragment).  Uses ``activation_code``'s regular expression object
    directly so this service can never accept a grant the customer's own
    ``validate_payload`` would reject.
    """
    if features is None:
        return ("pos",)
    if isinstance(features, str):
        raise ValueError(
            'features must be a list of names, not a single string '
            '(use ["pos"] rather than "pos")'
        )
    granted = tuple(features)
    if len(granted) > _MAX_FEATURES:
        raise ValueError(f"at most {_MAX_FEATURES} features may be granted")
    seen: set[str] = set()
    for feature in granted:
        if not isinstance(feature, str) or not _FEATURE_RE.match(feature):
            raise ValueError(
                "invalid feature grant: expected 1-32 characters of [a-z0-9_] "
                "starting with a lowercase letter"
            )
        if feature in seen:
            raise ValueError("a feature grant is repeated")
        seen.add(feature)
    return granted


def parse_request_code(code: str):
    """Strictly parse an ``SMPr1`` request with the existing generator parser.

    ``tools.license_generator.generator.parse_request_code`` is the reference
    implementation of that format (pinned to ``activation_code``'s patterns by
    ``tests/unit/test_license_generator.py``).  It raises
    ``RequestFormatError`` on the first violation and never echoes the input.
    """
    return request_parser.parse_request_code(code)


def display_code_for(hw_hash: str) -> str:
    """Grouped Base32 form of a hardware digest (13 groups of four).

    Read-only reproduction of ``HardwareFingerprintService.display_code`` for
    a digest we already hold: that method re-encodes *its own* fingerprint,
    and this service never runs on the customer's machine.  A test pins the
    two together for a fixed digest, so the two can never drift.
    """
    import base64

    raw = bytes.fromhex(hw_hash)
    stripped = base64.b32encode(raw).decode("ascii").rstrip("=")
    chunks = [stripped[index : index + 4] for index in range(0, len(stripped), 4)]
    return "-".join(chunks)


def load_customer_verification_keys(path: str) -> Mapping[str, bytes]:
    """Load the packaged public keys the customer's backend verifies against."""
    return load_verification_keys(path)
