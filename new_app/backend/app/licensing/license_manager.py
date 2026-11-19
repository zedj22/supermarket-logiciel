"""LicenseManager — Lifetime license state, activation and status (L2-A).

Owns the **Lifetime** side of the licensing system on top of the Phase L0
primitives already in this package:

* `StateStore` — atomic, HMAC-verified, optionally DPAPI-sealed files.
  License state lives in ``<LICENSE_STATE_DIR>/license.state``, i.e. the
  **same directory as the trial and outside PostgreSQL**: no table, no
  migration, never part of a `pg_dump` or a backup archive.
* `load_verification_keys` — the packaged public Ed25519 keys
  (``app/licensing/verification_keys.json``).  Only public material is
  ever read here; private signing keys exist solely in the offline
  License Generator (Phase L2-D).
* `HardwareFingerprintService` — the current Main PC fingerprint.  The
  hash is always **computed on the server**; a client-supplied value is
  never trusted as the binding authority.
* `TrialManager` — used read-only for the installation id in an
  activation request.  ``ensure_started()`` is never called from here:
  starting/restarting the trial belongs to backend startup alone, so an
  activation can neither create, reset nor extend a trial.

Stored record (``license.state`` payload, JSON) — deliberately small::

    {"v": 1, "license_id": "...", "key_id": "...", "hw_hash": "...",
     "activated_at": "<UTC ISO-8601>",
     "payload_b64": "<base64 of the EXACT signed payload bytes>",
     "signature_b64": "<base64 of the raw Ed25519 signature>"}

The original payload bytes are stored verbatim so the signature can be
**re-verified on every read** — the StateStore HMAC proves the file was
not edited, and the Ed25519 signature proves the *content* was issued by
the owner's key.  Missing keys, an unreadable key file, a bad signature,
a tampered payload or a fingerprint that no longer matches all mean the
same thing: the license is **not valid** and is never reported as active.

No private key, no raw hardware identifier, no HMAC key and no full
activation code is ever stored or returned.
"""

from __future__ import annotations

import base64
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from app.core.config import settings
from app.core.exceptions import AppError
from app.licensing.activation_code import (
    ED25519_SIGNATURE_BYTES,
    LICENSE_KIND,
    build_request_code,
    build_request_payload,
    loads_strict,
    validate_payload,
    verify_activation_code,
)
from app.licensing.errors import (
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
    LicenseRequiredError,
    LicenseStatusUnavailableError,
)
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    HardwareIdentifierUnavailableError,
)
from app.licensing.state_store import StateStore, StateStoreError
from app.licensing.trial import TrialManager, TrialStatus
from app.licensing.verification_keys import (
    VerificationKeysError,
    load_verification_keys,
)

__all__ = [
    "LICENSE_STATE_NAME",
    "ActivationRequest",
    "FingerprintSource",
    "LicenseManager",
    "LicenseStatus",
]

UTC = timezone.utc

#: Envelope name inside ``LICENSE_STATE_DIR`` → ``license.state``.
LICENSE_STATE_NAME = "license"

#: Stored-record schema version.
_RECORD_VERSION = 1

#: The exact stored field set — anything else is unreadable state.
_RECORD_FIELDS = frozenset(
    {
        "v",
        "license_id",
        "key_id",
        "hw_hash",
        "activated_at",
        "payload_b64",
        "signature_b64",
    }
)


class FingerprintSource(Protocol):
    """The part of `HardwareFingerprintService` this manager relies on."""

    def fingerprint(self) -> str: ...

    def display_code(self) -> str: ...


@dataclass(frozen=True, slots=True)
class LicenseStatus:
    """A verified Lifetime license (times are UTC)."""

    license_id: str
    key_id: str
    license_type: str
    issued_at: datetime
    activated_at: datetime
    hw_hash: str
    features: tuple[str, ...]

    @property
    def mode(self) -> str:
        """``lifetime`` — distinct from ``trial``/``trial_expired``."""
        return "lifetime"


@dataclass(frozen=True, slots=True)
class ActivationRequest:
    """What the owner copies out of ``POST /license/activation-request``."""

    request_code: str
    fingerprint_display_code: str


@dataclass(frozen=True, slots=True)
class _StoredLicense:
    """Internal: a verified record plus the exact signed material."""

    status: LicenseStatus
    payload_bytes: bytes
    signature: bytes


def _stamp(moment: datetime) -> str:
    """Second-precision UTC ISO-8601 with ``+00:00`` (never ``Z``)."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    else:
        moment = moment.astimezone(UTC)
    return moment.replace(microsecond=0).isoformat()


def _parse_stamp(value: object, field: str) -> datetime:
    if not isinstance(value, str):
        raise LicenseInvalidError("the stored activation time is unreadable")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as exc:
        raise LicenseInvalidError("the stored activation time is unreadable") from exc
    if parsed.tzinfo is None:
        raise LicenseInvalidError("the stored activation time is unreadable")
    return parsed.astimezone(UTC)


def _b64decode_strict(value: object, *, message: str) -> bytes:
    if not isinstance(value, str):
        raise LicenseInvalidError(message)
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise LicenseInvalidError(message) from exc


class LicenseManager:
    """Read, activate and validate one installation's Lifetime license.

    Parameters
    ----------
    state_dir:
        Directory holding ``license.state`` (defaults to
        ``settings.LICENSE_STATE_DIR``).  Same directory as the trial —
        still deliberately outside PostgreSQL.
    store:
        Explicit `StateStore` (tests inject ``use_dpapi=False``).
    keys_path:
        Public verification-key file (defaults to
        ``settings.LICENSE_VERIFICATION_KEYS_FILE``).
    fingerprint:
        `HardwareFingerprintService` (or any matching object).  Tests
        inject `StaticHardwareInfoProvider`-backed instances so nothing
        depends on the developer's hardware.
    clock:
        Injectable "now" (defaults to the real UTC clock).
    trial:
        Read-only `TrialManager` used for the installation id.  Never
        starts or restarts a trial.
    """

    def __init__(
        self,
        state_dir: str | Path | None = None,
        *,
        store: StateStore | None = None,
        keys_path: str | Path | None = None,
        fingerprint: FingerprintSource | None = None,
        clock: Any = None,
        trial: TrialManager | None = None,
    ) -> None:
        if store is None:
            root = Path(state_dir if state_dir is not None else settings.LICENSE_STATE_DIR)
            if str(root) in ("", "."):
                raise ValueError("license state directory must be a real path")
            store = StateStore(root)
        self._store = store
        self._keys_path = Path(
            keys_path if keys_path is not None else settings.LICENSE_VERIFICATION_KEYS_FILE
        )
        self._fingerprint: FingerprintSource = (
            fingerprint if fingerprint is not None else HardwareFingerprintService()
        )
        if clock is not None:
            self._clock = clock
        else:
            self._clock = _utc_now
        self._trial = trial if trial is not None else TrialManager(state_dir=self._store.root)

    @classmethod
    def from_settings(cls, **kwargs: Any) -> LicenseManager:
        """Manager bound to the configured state dir and key file."""
        return cls(**kwargs)

    # ------------------------------------------------------------------
    # paths / time
    # ------------------------------------------------------------------
    @property
    def state_path(self) -> Path:
        """Absolute path of this installation's ``license.state``."""
        return self._store.path_for(LICENSE_STATE_NAME)

    @property
    def keys_path(self) -> Path:
        return self._keys_path

    def now(self) -> datetime:
        return _as_utc(self._clock()).replace(microsecond=0)

    # ------------------------------------------------------------------
    # status
    # ------------------------------------------------------------------
    def status(self) -> LicenseStatus | None:
        """Current verified license, ``None`` when none is installed.

        Re-verifies the Ed25519 signature and the hardware binding on
        **every** read — the StateStore HMAC alone is never taken as
        proof that the license is authentic.

        Raises ``license_invalid`` / ``license_invalid_key`` /
        ``license_bound_elsewhere`` when a record exists but cannot be
        trusted, and ``license_status_unavailable`` when the key file or
        the hardware fingerprint cannot be read.  A missing record is
        simply ``None``.
        """
        stored = self._read_valid()
        return None if stored is None else stored.status

    def _read_valid(self) -> _StoredLicense | None:
        """Read + fully re-verify the stored record (``None`` if absent)."""
        raw = self._store.read(LICENSE_STATE_NAME)
        if raw is None:
            return None
        keys = self._load_keys()
        hw_hash = self._fingerprint_hash()
        return self._reverify(raw, keys=keys, hw_hash=hw_hash)

    # ------------------------------------------------------------------
    # activation request
    # ------------------------------------------------------------------
    def build_activation_request(self) -> ActivationRequest:
        """Build the unsigned request code for the License Generator.

        Uses the existing Trial installation id (read-only) and the
        current server-side fingerprint.  Never starts a trial and never
        exposes a raw identifier — only the 64-hex digest inside the code
        and its grouped Base32 display form outside it.
        """
        trial = self._trial_status()
        if trial is None:
            raise LicenseRequiredError("no trial is installed on this backend")
        hw_hash = self._fingerprint_hash()
        payload = build_request_payload(
            install_id=trial.install_id,
            hw_hash=hw_hash,
            requested_at=self.now(),
        )
        return ActivationRequest(
            request_code=build_request_code(payload),
            fingerprint_display_code=self._fingerprint.display_code(),
        )

    def _trial_status(self) -> TrialStatus | None:
        """Read the trial without ever starting one (D5)."""
        try:
            return self._trial.status()
        except StateStoreError as exc:
            raise LicenseStatusUnavailableError(
                "the installation state cannot be read"
            ) from exc
        except OSError as exc:
            raise LicenseStatusUnavailableError(
                "the installation state cannot be read"
            ) from exc

    # ------------------------------------------------------------------
    # activation
    # ------------------------------------------------------------------
    def activate(self, code: str) -> LicenseStatus:
        """Validate, bind and persist a signed Lifetime activation code.

        Order matters and is part of the contract:

        1. the **current** fingerprint is computed on this machine;
        2. the code is parsed, schema-checked and signature-checked
           against a packaged public key;
        3. only then is anything written — so a failed attempt can never
           destroy an existing valid license.

        Behaviour when a license is already installed:

        * same ``license_id`` **and** identical signed bytes → no-op
          (idempotent, ``activated_at`` is preserved);
        * same ``license_id`` with re-issued content, or a different
          ``license_id`` → the fully verified new license replaces the
          old record (an owner-signed license for *this* hardware is
          authoritative; the record is written atomically).

        The trial file is never opened for writing: activation cannot
        reset, extend or move the trial start, and it works identically
        before and after trial expiry.
        """
        hw_hash = self._fingerprint_hash()
        keys = self._load_keys()
        presented = verify_activation_code(code, keys=keys, expected_hw_hash=hw_hash)

        current = self._read_valid_best_effort()
        if (
            current is not None
            and current.status.license_id == presented.license_id
            and current.payload_bytes == presented.payload_bytes
            and current.signature == presented.signature
        ):
            return current.status

        record = {
            "v": _RECORD_VERSION,
            "license_id": presented.license_id,
            "key_id": presented.key_id,
            "hw_hash": presented.hw_hash,
            "activated_at": _stamp(self.now()),
            "payload_b64": base64.b64encode(presented.payload_bytes).decode("ascii"),
            "signature_b64": base64.b64encode(presented.signature).decode("ascii"),
        }
        try:
            self._store.write(LICENSE_STATE_NAME, record)
        except StateStoreError as exc:
            raise LicenseStatusUnavailableError(
                "the license could not be stored"
            ) from exc

        stored = self._read_valid()
        if stored is None:
            # Unreachable in practice (we just wrote a valid record) and
            # deliberately fail-closed rather than report an unverified
            # license as active.
            raise LicenseInvalidError("the stored license could not be verified")
        return stored.status

    def _read_valid_best_effort(self) -> _StoredLicense | None:
        """Current license if it verifies, else ``None`` (never raises).

        An unreadable or invalid existing record is *replaced* by a fully
        verified activation rather than blocking recovery — while a
        *failed* activation never reaches a write at all.
        """
        try:
            return self._read_valid()
        except (AppError, StateStoreError, OSError):
            return None

    # ------------------------------------------------------------------
    # internals
    # ------------------------------------------------------------------
    def _load_keys(self) -> dict[str, bytes]:
        """Packaged public keys; an unusable file is never "no keys"."""
        try:
            return load_verification_keys(self._keys_path)
        except VerificationKeysError as exc:
            raise LicenseStatusUnavailableError(
                "the verification key file cannot be read"
            ) from exc
        except OSError as exc:
            raise LicenseStatusUnavailableError(
                "the verification key file cannot be read"
            ) from exc

    def _fingerprint_hash(self) -> str:
        """Current hardware digest, computed here — never accepted from a client."""
        try:
            return self._fingerprint.fingerprint()
        except HardwareIdentifierUnavailableError as exc:
            raise LicenseStatusUnavailableError(
                "the hardware fingerprint is unavailable"
            ) from exc

    def _reverify(
        self, record: object, *, keys: Mapping[str, bytes], hw_hash: str
    ) -> _StoredLicense:
        """Full re-validation of a stored record (fail-closed)."""
        if not isinstance(record, dict) or set(record) != _RECORD_FIELDS:
            raise LicenseInvalidError("the stored license is not in a recognized format")

        version = record["v"]
        if type(version) is not int or version != _RECORD_VERSION:
            raise LicenseInvalidError("the stored license is not in a recognized format")

        payload_bytes = _b64decode_strict(
            record["payload_b64"], message="the stored license payload is unreadable"
        )
        signature = _b64decode_strict(
            record["signature_b64"], message="the stored signature is unreadable"
        )
        document = loads_strict(payload_bytes, what="license")
        validate_payload(document)

        # The duplicated fields must agree with the signed payload: any
        # divergence means the record was edited (the payload's own
        # signature would still be valid, so this check is not redundant).
        for field in ("license_id", "key_id", "hw_hash"):
            if not isinstance(record[field], str) or document[field] != record[field]:
                raise LicenseInvalidError(
                    "the stored license does not match its signed payload"
                )

        self._verify_signature(document, signature, payload_bytes, keys=keys)

        if document["hw_hash"] != hw_hash:
            raise LicenseBoundElsewhereError(
                "the license is issued for different hardware"
            )

        activated_at = _parse_stamp(record["activated_at"], "activated_at")
        return _StoredLicense(
            status=LicenseStatus(
                license_id=document["license_id"],
                key_id=document["key_id"],
                license_type=LICENSE_KIND,
                issued_at=datetime.fromisoformat(document["issued_at"]).astimezone(UTC),
                activated_at=activated_at,
                hw_hash=document["hw_hash"],
                features=tuple(document["features"]),
            ),
            payload_bytes=payload_bytes,
            signature=signature,
        )

    @staticmethod
    def _verify_signature(
        document: Mapping[str, Any],
        signature: bytes,
        payload_bytes: bytes,
        *,
        keys: Mapping[str, bytes],
    ) -> None:
        """Ed25519 check over the exact stored payload bytes (fail-closed)."""
        if len(signature) != ED25519_SIGNATURE_BYTES:
            raise LicenseInvalidError("the stored signature is unreadable")
        public = keys.get(document["key_id"])
        if public is None:
            raise LicenseInvalidKeyError(
                "the license references an unknown verification key"
            )
        try:
            Ed25519PublicKey.from_public_bytes(public).verify(signature, payload_bytes)
        except (InvalidSignature, ValueError, TypeError) as exc:
            raise LicenseInvalidError("the stored license signature does not verify") from exc


def _as_utc(moment: datetime) -> datetime:
    if moment.tzinfo is None:
        return moment.replace(tzinfo=UTC)
    return moment.astimezone(UTC)


def _utc_now() -> datetime:
    return datetime.now(UTC)
