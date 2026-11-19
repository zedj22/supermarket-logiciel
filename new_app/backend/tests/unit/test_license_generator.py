"""Phase L2-D - the offline License Generator.

The generator is the only component that ever holds an Ed25519 private
key, so these tests pin both correctness and containment:

* key generation is explicit (never silent), never replaces an existing
  key id, and refuses any directory inside a git work tree;
* ``SMPr1`` requests are read strictly - every malformed shape is
  refused with ``RequestFormatError`` before anything is signed;
* issued ``SMP1`` codes are byte-exact against the L2-A contract:
  exact payload field set, canonical bytes, unique license ids,
  second-precision UTC stamps, strict features - and always verified
  with the *backend's own verifier* before they are returned;
* tampering, wrong key ids and wrong hardware hashes fail with the
  pinned backend error codes;
* every export, ledger line and CLI stream is public-only: seed
  material never appears in any output, file or log;
* end-to-end: request built by the real LicenseManager -> generator
  issue -> exported key -> manager.activate -> Lifetime status;
* the ``tools`` package is excluded from the customer distribution.
"""

from __future__ import annotations

import base64
import io
import json
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from setuptools import find_packages

from app.core.exceptions import AppError
from app.licensing import activation_code as ac
from app.licensing.activation_code import (
    MAX_ACTIVATION_CODE_CHARS,
    PAYLOAD_FIELDS,
    REQUEST_PREFIX,
    build_request_code,
    build_request_payload,
    canonical_json,
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
from app.licensing.license_manager import LicenseManager
from app.licensing.state_store import StateStore
from app.licensing.trial import TrialManager
from app.licensing.verification_keys import _KEY_ID_RE, load_verification_keys
from tools.license_generator import cli, generator, keystore
from tools.license_generator.errors import (
    GeneratorError,
    IssueError,
    KeystoreError,
    RequestFormatError,
)

UTC = timezone.utc
T0 = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)

BACKEND_ROOT = Path(__file__).resolve().parents[2]

PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l2d-generator",
    system_volume_serial="SERIAL-L2D",
    hostname="owner-pc",
)

HW_HASH = "ab" * 32
INSTALL_ID = "L2D-INSTALL-0001"


def _payload(**overrides: object) -> dict:
    payload = build_request_payload(
        install_id=INSTALL_ID, hw_hash=HW_HASH, requested_at=T0
    )
    payload.update(overrides)
    return payload


def _raw_request(raw: bytes) -> str:
    segment = base64.b32encode(raw).decode("ascii").rstrip("=")
    return f"{REQUEST_PREFIX}.{segment}"


def _with_missing_field() -> dict:
    payload = _payload()
    payload.pop("hw_hash")
    return payload


VALID_REQUEST = build_request_code(_payload())
VALID_SEGMENT = VALID_REQUEST.split(".")[1]

MALFORMED_REQUESTS = [
    ("empty", "", "empty"),
    ("blank", "   ", "empty"),
    ("single-segment", "SMPr1", "two segments"),
    ("empty-payload-segment", "SMPr1.", "empty"),
    ("lowercase-base32", "SMPr1.abc", "Base32"),
    ("wrong-prefix", f"SMPr0.{VALID_SEGMENT}", "prefix"),
    ("three-segments", f"{VALID_REQUEST}.extra", "two segments"),
    ("too-long", "SMPr1." + "A" * 600, "longer than"),
    ("digit-one-in-base32", "SMPr1.ABC1", "Base32"),
    ("padded-segment", f"SMPr1.{VALID_SEGMENT}=", "Base32"),
    ("not-utf8", _raw_request(b"\xff\xfe{}"), "UTF-8"),
    ("not-an-object", _raw_request(b"[1,2]"), "object"),
    (
        "duplicate-field",
        _raw_request(
            b'{"v":1,"v":1,"install_id":"x","hw_hash":"y","requested_at":"z"}'
        ),
        "duplicate",
    ),
    (
        "non-finite-number",
        _raw_request(
            b'{"v":NaN,"install_id":"x","hw_hash":"y","requested_at":"z"}'
        ),
        "number",
    ),
    ("missing-field", build_request_code(_with_missing_field()), "fields are invalid"),
    ("extra-field", build_request_code(_payload(extra=1)), "fields are invalid"),
    ("version-two", build_request_code(_payload(v=2)), "version"),
    ("version-bool", build_request_code(_payload(v=True)), "version"),
    ("version-float", build_request_code(_payload(v=1.0)), "version"),
    ("install-id-number", build_request_code(_payload(install_id=7)), "install_id"),
    (
        "install-id-leading-dash",
        build_request_code(_payload(install_id="-abc")),
        "installation id",
    ),
    (
        "install-id-too-long",
        build_request_code(_payload(install_id="a" * 129)),
        "installation id",
    ),
    (
        "hw-hash-uppercase",
        build_request_code(_payload(hw_hash=HW_HASH.upper())),
        "lowercase hex",
    ),
    (
        "hw-hash-short",
        build_request_code(_payload(hw_hash="ab" * 31 + "a")),
        "lowercase hex",
    ),
    (
        "hw-hash-long",
        build_request_code(_payload(hw_hash=HW_HASH + "aa")),
        "lowercase hex",
    ),
    (
        "hw-hash-non-hex",
        build_request_code(_payload(hw_hash="z" * 64)),
        "lowercase hex",
    ),
    (
        "hw-hash-newline",
        build_request_code(_payload(hw_hash="ab" * 31 + "a\n")),
        "lowercase hex",
    ),
    (
        "timestamp-date-only",
        build_request_code(_payload(requested_at="2026-01-01")),
        "timestamp",
    ),
    (
        "timestamp-naive",
        build_request_code(_payload(requested_at="2026-01-01T00:00:00")),
        "timestamp",
    ),
    (
        "timestamp-garbage",
        build_request_code(_payload(requested_at="not-a-time")),
        "timestamp",
    ),
    (
        "timestamp-number",
        build_request_code(_payload(requested_at=1767225600)),
        "requested_at",
    ),
]


@dataclass
class Clock:
    moment: datetime = T0

    def __call__(self) -> datetime:
        return self.moment


def publics(key_dir: Path) -> dict[str, bytes]:
    return {kid: key.public for kid, key in keystore.load_keystore(key_dir).items()}


def issue(key_dir: Path, *, key_id: str = "k1", request: str | None = None, **kwargs):
    return generator.issue_license(
        request if request is not None else VALID_REQUEST,
        key_id=key_id,
        key_dir=key_dir,
        **kwargs,
    )


def decode_code(code: str) -> tuple[dict, bytes]:
    prefix, payload_b32, signature_b32 = code.split(".")
    assert prefix == "SMP1"
    payload = json.loads(
        base64.b32decode(payload_b32 + "=" * (-len(payload_b32) % 8))
    )
    signature = base64.b32decode(
        signature_b32 + "=" * (-len(signature_b32) % 8)
    )
    return payload, signature


def flip(segment: str) -> str:
    return ("A" if segment[0] != "A" else "B") + segment[1:]


@pytest.fixture()
def key_dir(tmp_path: Path) -> Path:
    return tmp_path / "owner_keys"


@pytest.fixture()
def k1(key_dir: Path) -> bytes:
    return keystore.generate_keypair(key_dir, "k1")


@pytest.fixture()
def state_dir(tmp_path: Path) -> Path:
    return tmp_path / "data" / "license"


@pytest.fixture()
def store(state_dir: Path) -> StateStore:
    return StateStore(state_dir, use_dpapi=False)


@pytest.fixture()
def clock() -> Clock:
    return Clock()


@pytest.fixture()
def trial(state_dir: Path, store: StateStore, clock: Clock) -> TrialManager:
    return TrialManager(state_dir=state_dir, store=store, clock=clock)


@pytest.fixture()
def manager(
    state_dir: Path, store: StateStore, clock: Clock, trial: TrialManager
) -> LicenseManager:
    return LicenseManager(
        state_dir=state_dir,
        store=store,
        fingerprint=HardwareFingerprintService(PROVIDER),
        clock=clock,
        trial=trial,
    )


class TestKeystore:
    def test_keygen_returns_public_half_and_stores_both_halves(
        self, key_dir: Path
    ) -> None:
        public = keystore.generate_keypair(key_dir, "k1")
        assert len(public) == keystore.ED25519_SEED_BYTES
        stored = keystore.load_keystore(key_dir)
        assert set(stored) == {"k1"}
        entry = stored["k1"]
        assert entry.public == public
        assert len(entry.private_seed) == keystore.ED25519_SEED_BYTES
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
        )

        derived = Ed25519PrivateKey.from_private_bytes(
            entry.private_seed
        ).public_key()
        from cryptography.hazmat.primitives import serialization

        assert derived.public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        ) == public

    def test_keygen_refuses_existing_id_and_never_replaces_or_deletes(
        self, key_dir: Path
    ) -> None:
        first_public = keystore.generate_keypair(key_dir, "k1")
        path = key_dir / keystore.KEY_STORE_NAME
        before = path.read_bytes()
        with pytest.raises(KeystoreError, match="already exists"):
            keystore.generate_keypair(key_dir, "k1")
        assert path.read_bytes() == before
        keystore.generate_keypair(key_dir, "k2")
        assert set(keystore.load_keystore(key_dir)) == {"k1", "k2"}
        assert keystore.load_keystore(key_dir)["k1"].public == first_public

    @pytest.mark.parametrize(
        "key_id",
        ["", "-k1", "k 1", "k1!", "x" * 65, "k1\nx", "k.1", "ä"],
        ids=["empty", "leading-dash", "space", "bang", "too-long", "newline-mid",
             "dot", "non-ascii"],
    )
    def test_keygen_rejects_invalid_key_ids(self, tmp_path: Path, key_id: str) -> None:
        target = tmp_path / "case"
        with pytest.raises(KeystoreError, match="invalid key id"):
            keystore.generate_keypair(target, key_id)
        assert not (target / keystore.KEY_STORE_NAME).exists()

    @pytest.mark.parametrize("key_id", ["k1", "K1", "k_1-2", "1st"])
    def test_keygen_accepts_contract_valid_key_ids(
        self, tmp_path: Path, key_id: str
    ) -> None:
        target = tmp_path / f"case-{key_id}"
        public = keystore.generate_keypair(target, key_id)
        assert len(public) == 32
        assert set(keystore.load_keystore(target)) == {key_id}

    def test_key_id_pattern_is_pinned_to_the_backend(self) -> None:
        assert keystore._KEY_ID_RE.pattern == _KEY_ID_RE.pattern
        for candidate in ["k1", "1a", "K_1-2", "-k1", "k 1", "k1!", "x" * 65, ""]:
            assert bool(keystore._KEY_ID_RE.match(candidate)) == bool(
                _KEY_ID_RE.match(candidate)
            )

    def test_keystore_is_refused_inside_a_git_work_tree(self, tmp_path: Path) -> None:
        repo = tmp_path / "repo"
        (repo / ".git").mkdir(parents=True)
        for target in (repo / "keys", repo / "a" / "b", repo):
            with pytest.raises(KeystoreError, match="git work tree"):
                keystore.generate_keypair(target, "k1")
            with pytest.raises(KeystoreError, match="git work tree"):
                keystore.get_public_keys(target)
            with pytest.raises(KeystoreError, match="git work tree"):
                keystore.get_private_key(target, "k1")
        assert sorted(p.name for p in repo.iterdir()) == [".git"]

    @pytest.mark.parametrize(
        "kind,expected",
        [
            ("not-json", "not valid JSON"),
            ("top-level-list", "not a JSON object"),
            ("missing-wrapper", "not a recognized"),
            ("short-seed", "32-byte"),
            ("swapped-public", "inconsistent"),
            ("duplicate-field", "duplicate field"),
        ],
    )
    def test_load_keystore_rejects_garbage_and_tampering(
        self, key_dir: Path, kind: str, expected: str
    ) -> None:
        keystore.generate_keypair(key_dir, "k1")
        path = key_dir / keystore.KEY_STORE_NAME
        if kind == "not-json":
            path.write_text("{oops", encoding="utf-8")
        elif kind == "top-level-list":
            path.write_text("[]", encoding="utf-8")
        elif kind == "missing-wrapper":
            document = json.loads(path.read_text(encoding="utf-8"))
            path.write_text(json.dumps(document["keys"]), encoding="utf-8")
        elif kind == "short-seed":
            document = json.loads(path.read_text(encoding="utf-8"))
            document["keys"]["k1"]["private"] = base64.b64encode(b"123").decode()
            path.write_text(json.dumps(document), encoding="utf-8")
        elif kind == "swapped-public":
            document = json.loads(path.read_text(encoding="utf-8"))
            document["keys"]["k1"]["public"] = base64.b64encode(bytes(32)).decode()
            path.write_text(json.dumps(document), encoding="utf-8")
        else:
            raw = path.read_text(encoding="utf-8")
            path.write_text(
                raw.replace("{", '{"format": "x",', 1), encoding="utf-8"
            )
        with pytest.raises(KeystoreError, match=expected):
            keystore.load_keystore(key_dir)

    def test_missing_keystore_is_an_empty_store(self, key_dir: Path) -> None:
        assert keystore.load_keystore(key_dir) == {}

    def test_issue_never_generates_a_key_silently(self, key_dir: Path) -> None:
        with pytest.raises(KeystoreError, match="never generated implicitly"):
            issue(key_dir, key_id="k1")
        assert not (key_dir / keystore.KEY_STORE_NAME).exists()
        assert not (key_dir / generator.ISSUANCE_LOG_NAME).exists()

    def test_issue_with_unknown_key_id_leaves_keystore_untouched(
        self, key_dir: Path, k1: bytes
    ) -> None:
        path = key_dir / keystore.KEY_STORE_NAME
        before = path.read_bytes()
        with pytest.raises(KeystoreError, match="unknown key id"):
            issue(key_dir, key_id="k2")
        assert path.read_bytes() == before

    def test_rotation_adds_new_ids_and_keeps_old_ones_issuing(
        self, key_dir: Path
    ) -> None:
        first_public = keystore.generate_keypair(key_dir, "k1")
        keystore.generate_keypair(key_dir, "k2")
        store = keystore.load_keystore(key_dir)
        assert set(store) == {"k1", "k2"}
        assert store["k1"].public == first_public
        for key_id in ("k1", "k2"):
            issued = issue(key_dir, key_id=key_id)
            payload = verify_activation_code(
                issued.code, keys=publics(key_dir), expected_hw_hash=HW_HASH
            )
            assert payload.key_id == key_id

    def test_resolve_key_dir_precedence(self, monkeypatch, tmp_path: Path) -> None:
        monkeypatch.setenv(keystore.DEFAULT_ENV_VAR, str(tmp_path / "env"))
        assert keystore.resolve_key_dir(None) == tmp_path / "env"
        assert keystore.resolve_key_dir(tmp_path / "explicit") == tmp_path / "explicit"
        monkeypatch.delenv(keystore.DEFAULT_ENV_VAR)
        assert keystore.resolve_key_dir(None) == keystore.DEFAULT_HOME
        with pytest.raises(KeystoreError, match="empty"):
            keystore.resolve_key_dir("   ")


class TestRequestParsing:
    def test_parses_a_backend_generated_request(self) -> None:
        request = generator.parse_request_code(VALID_REQUEST)
        assert request.install_id == INSTALL_ID
        assert request.hw_hash == HW_HASH
        assert request.requested_at == T0
        assert request.requested_at.tzinfo is not None
        decoded = json.loads(request.payload_bytes)
        assert decoded == {
            "v": 1,
            "install_id": INSTALL_ID,
            "hw_hash": HW_HASH,
            "requested_at": "2026-01-01T00:00:00+00:00",
        }
        assert list(decoded) == sorted(decoded)

    def test_parse_tolerates_surrounding_whitespace_only(self) -> None:
        padded = generator.parse_request_code(f"  {VALID_REQUEST}\n")
        plain = generator.parse_request_code(VALID_REQUEST)
        assert padded == plain

    @pytest.mark.parametrize(
        "value",
        [None, 42, b"SMPr1.x", ["SMPr1.x"], {"code": "x"}],
        ids=["none", "int", "bytes", "list", "dict"],
    )
    def test_parse_rejects_non_text(self, value: object) -> None:
        with pytest.raises(RequestFormatError, match="must be text"):
            generator.parse_request_code(value)

    @pytest.mark.parametrize(
        "name,code,expected", MALFORMED_REQUESTS, ids=[c[0] for c in MALFORMED_REQUESTS]
    )
    def test_parse_rejects_malformed_requests(
        self, name: str, code: str, expected: str
    ) -> None:
        with pytest.raises(RequestFormatError, match=expected):
            generator.parse_request_code(code)

    def test_parser_patterns_are_pinned_to_l2_a(self) -> None:
        assert generator._HW_HASH_RE.pattern == ac._HW_HASH_RE.pattern
        assert generator._FEATURE_RE.pattern == ac._FEATURE_RE.pattern
        assert generator._B32_RE.pattern == ac._B32_RE.pattern
        assert generator._LICENSE_ID_RE.pattern == ac._LICENSE_ID_RE.pattern


class TestIssuance:
    def test_issue_returns_a_backend_verifiable_lifetime_code(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir, features=("pos", "inventory"))
        assert issued.code.startswith("SMP1.")
        assert issued.code.count(".") == 2
        assert len(issued.code) <= MAX_ACTIVATION_CODE_CHARS
        payload = verify_activation_code(
            issued.code, keys=publics(key_dir), expected_hw_hash=HW_HASH
        )
        assert payload.license_id == issued.license_id
        assert payload.key_id == "k1"
        assert payload.kind == "lifetime"
        assert payload.hw_hash == HW_HASH
        assert payload.features == ("pos", "inventory")
        assert payload.issued_at.tzinfo is not None
        assert len(payload.signature) == 64

    def test_payload_field_set_is_exactly_the_l2_a_contract(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir)
        document, signature = decode_code(issued.code)
        assert set(document) == set(PAYLOAD_FIELDS)
        assert document["v"] == 1 and type(document["v"]) is int
        assert document["kind"] == "lifetime"
        assert document["key_id"] == "k1"
        assert document["license_id"] == issued.license_id
        assert document["hw_hash"] == HW_HASH
        assert isinstance(document["features"], list)
        ac.validate_payload(document)

    def test_payload_bytes_are_canonical(self, key_dir: Path, k1: bytes) -> None:
        issued = issue(key_dir)
        payload = verify_activation_code(
            issued.code, keys=publics(key_dir), expected_hw_hash=HW_HASH
        )
        assert payload.payload_bytes == canonical_json(json.loads(payload.payload_bytes))
        assert payload.payload_bytes == canonical_json(decode_code(issued.code)[0])

    def test_license_ids_are_unique_and_contract_valid(self, key_dir: Path, k1: bytes) -> None:
        issued_ids = [issue(key_dir).license_id for _ in range(40)]
        assert len(set(issued_ids)) == 40
        for license_id in issued_ids:
            assert ac._LICENSE_ID_RE.match(license_id), license_id

    def test_custom_license_id_is_used(self, key_dir: Path, k1: bytes) -> None:
        issued = issue(key_dir, license_id="LIC-CUSTOM-0001")
        assert issued.license_id == "LIC-CUSTOM-0001"
        payload = verify_activation_code(
            issued.code, keys=publics(key_dir), expected_hw_hash=HW_HASH
        )
        assert payload.license_id == "LIC-CUSTOM-0001"

    def test_invalid_custom_license_id_is_refused_without_a_ledger_entry(
        self, key_dir: Path, k1: bytes
    ) -> None:
        with pytest.raises(IssueError, match="license id"):
            issue(key_dir, license_id="short")
        assert not (key_dir / generator.ISSUANCE_LOG_NAME).exists()

    @pytest.mark.parametrize(
        "features",
        [
            ("POS",),
            ("bad token",),
            ("x" * 33,),
            ("pos", "pos"),
            (7,),
            "pos",
            tuple(f"feat{i}" for i in range(33)),
        ],
        ids=[
            "uppercase", "space", "too-long", "duplicate", "non-string",
            "bare-string", "too-many",
        ],
    )
    def test_issue_refuses_invalid_feature_grants(
        self, key_dir: Path, k1: bytes, features
    ) -> None:
        with pytest.raises(IssueError):
            issue(key_dir, features=features)
        assert not (key_dir / generator.ISSUANCE_LOG_NAME).exists()

    def test_empty_features_are_allowed(self, key_dir: Path, k1: bytes) -> None:
        issued = issue(key_dir, features=())
        payload = verify_activation_code(
            issued.code, keys=publics(key_dir), expected_hw_hash=HW_HASH
        )
        assert payload.features == ()

    def test_issued_at_is_second_precision_utc_offset(
        self, key_dir: Path, k1: bytes
    ) -> None:
        moment = datetime(2026, 3, 1, 12, 0, 0, 123456, tzinfo=UTC)
        issued = issue(key_dir, issued_at=moment)
        document, _ = decode_code(issued.code)
        assert document["issued_at"] == "2026-03-01T12:00:00+00:00"
        assert issued.issued_at == document["issued_at"]

    def test_stamp_is_pinned_to_the_backend_stamp(self) -> None:
        moments = [
            T0,
            datetime(2026, 6, 30, 23, 59, 59, 999999, tzinfo=UTC),
            datetime(2026, 6, 30, 8, 30, 0, tzinfo=timezone(timedelta(hours=2))),
            datetime(2026, 6, 30, 8, 30, 0),
        ]
        for moment in moments:
            assert generator._stamp(moment) == ac._stamp(moment)

    def test_issuance_ledger_records_without_secrets(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir, features=("pos", "inventory"))
        log = key_dir / generator.ISSUANCE_LOG_NAME
        raw = log.read_text(encoding="utf-8")
        lines = raw.splitlines()
        assert len(lines) == 1
        entry = json.loads(lines[0])
        assert set(entry) == {
            "recorded_at",
            "license_id",
            "key_id",
            "install_id",
            "issued_at",
            "features",
        }
        assert entry["license_id"] == issued.license_id
        assert entry["key_id"] == "k1"
        assert entry["install_id"] == INSTALL_ID
        assert entry["features"] == ["pos", "inventory"]
        assert "hw_hash" not in raw
        assert HW_HASH not in raw
        seed = base64.b64encode(
            keystore.load_keystore(key_dir)["k1"].private_seed
        ).decode()
        assert seed not in raw


class TestSigningAndBinding:
    def test_tampered_payload_segment_is_rejected(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir)
        prefix, payload_segment, signature_segment = issued.code.split(".")
        tampered = f"{prefix}.{flip(payload_segment)}.{signature_segment}"
        with pytest.raises(LicenseInvalidError):
            verify_activation_code(
                tampered, keys=publics(key_dir), expected_hw_hash=HW_HASH
            )

    def test_tampered_signature_segment_is_rejected(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir)
        prefix, payload_segment, signature_segment = issued.code.split(".")
        tampered = f"{prefix}.{payload_segment}.{flip(signature_segment)}"
        with pytest.raises(LicenseInvalidError):
            verify_activation_code(
                tampered, keys=publics(key_dir), expected_hw_hash=HW_HASH
            )

    def test_signature_is_checked_against_the_referenced_key_id(
        self, key_dir: Path
    ) -> None:
        keystore.generate_keypair(key_dir, "k1")
        keystore.generate_keypair(key_dir, "k2")
        issued = issue(key_dir, key_id="k1")
        store = keystore.load_keystore(key_dir)
        mismatched = {"k1": store["k2"].public}
        with pytest.raises(LicenseInvalidError):
            verify_activation_code(
                issued.code, keys=mismatched, expected_hw_hash=HW_HASH
            )
        with pytest.raises(LicenseInvalidKeyError) as excinfo:
            verify_activation_code(
                issued.code,
                keys={"k2": store["k2"].public},
                expected_hw_hash=HW_HASH,
            )
        assert excinfo.value.code == "license_invalid_key"
        with pytest.raises(LicenseInvalidKeyError):
            verify_activation_code(issued.code, keys={}, expected_hw_hash=HW_HASH)

    def test_code_for_other_hardware_is_bound_elsewhere(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir)
        with pytest.raises(LicenseBoundElsewhereError) as excinfo:
            verify_activation_code(
                issued.code, keys=publics(key_dir), expected_hw_hash="cd" * 32
            )
        assert excinfo.value.code == "license_bound_elsewhere"

    def test_verify_with_a_malformed_expected_hash_fails_closed(
        self, key_dir: Path, k1: bytes
    ) -> None:
        issued = issue(key_dir)
        with pytest.raises(LicenseBoundElsewhereError):
            verify_activation_code(
                issued.code, keys=publics(key_dir), expected_hw_hash="NOT-A-HASH"
            )


class TestEndToEnd:
    def test_request_issue_export_activate_lifetime(
        self,
        state_dir: Path,
        store: StateStore,
        clock: Clock,
        trial: TrialManager,
        manager: LicenseManager,
        key_dir: Path,
    ) -> None:
        trial.ensure_started()
        request = manager.build_activation_request().request_code
        assert generator.parse_request_code(request).install_id == (
            trial.ensure_started().install_id
        )

        public = keystore.generate_keypair(key_dir, "k1")
        keys_file = state_dir.parent / "verification_keys.json"
        keystore.merge_verification_keys(
            keys_file, keystore.public_entry("k1", public)
        )
        loaded = load_verification_keys(keys_file)
        assert set(loaded) == {"k1"} and loaded["k1"] == public

        granted = ("pos", "inventory")
        issued = generator.issue_license(
            request, key_id="k1", key_dir=key_dir, features=granted
        )

        bound = LicenseManager(
            state_dir=state_dir,
            store=store,
            keys_path=keys_file,
            fingerprint=HardwareFingerprintService(PROVIDER),
            clock=clock,
            trial=trial,
        )
        status = bound.activate(issued.code)
        assert status.mode == "lifetime"
        assert status.license_id == issued.license_id
        assert status.key_id == "k1"
        assert status.features == granted
        assert status.hw_hash == HardwareFingerprintService(PROVIDER).fingerprint()
        assert bound.status().license_id == issued.license_id
        assert bound.activate(issued.code).license_id == issued.license_id

    def test_merge_preserves_existing_ids_and_refuses_conflicts(
        self, tmp_path: Path, key_dir: Path, k1: bytes
    ) -> None:
        target = tmp_path / "verification_keys.json"
        other_public = bytes(range(32))
        target.write_text(
            json.dumps({"k9": base64.b64encode(other_public).decode()}),
            encoding="utf-8",
        )
        entry = keystore.public_entry("k1", k1)
        keystore.merge_verification_keys(target, entry)
        loaded = load_verification_keys(target)
        assert set(loaded) == {"k1", "k9"}
        assert loaded["k9"] == other_public
        assert loaded["k1"] == k1

        keystore.merge_verification_keys(target, entry)
        assert set(load_verification_keys(target)) == {"k1", "k9"}

        other_dir = tmp_path / "other_keys"
        other_k1 = keystore.generate_keypair(other_dir, "k1")
        before = target.read_bytes()
        with pytest.raises(KeystoreError, match="DIFFERENT"):
            keystore.merge_verification_keys(
                target, keystore.public_entry("k1", other_k1)
            )
        assert target.read_bytes() == before

        seed = base64.b64encode(keystore.load_keystore(key_dir)["k1"].private_seed).decode()
        assert seed not in target.read_text(encoding="utf-8")


class TestCommandLine:
    def test_keygen_prints_only_the_public_entry(
        self, tmp_path: Path, capsys
    ) -> None:
        key_dir = tmp_path / "cli_keys"
        rc = cli.main(
            ["keygen", "--key-dir", str(key_dir), "--key-id", "k1", "--label", "cli"]
        )
        captured = capsys.readouterr()
        assert rc == 0
        entry = json.loads(captured.out)
        assert set(entry) == {"k1"}
        assert len(base64.b64decode(entry["k1"], validate=True)) == 32
        seed = base64.b64encode(
            keystore.load_keystore(key_dir)["k1"].private_seed
        ).decode()
        assert seed not in captured.out
        assert seed not in captured.err
        assert "created key id 'k1'" in captured.err

    def test_list_keys_shows_ids_without_private_material(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        keystore.generate_keypair(key_dir, "k2")
        rc = cli.main(["list-keys", "--key-dir", str(key_dir)])
        captured = capsys.readouterr()
        assert rc == 0
        assert "k1" in captured.out and "k2" in captured.out
        store = keystore.load_keystore(key_dir)
        for key in store.values():
            seed = base64.b64encode(key.private_seed).decode()
            assert seed not in captured.out
            assert seed not in captured.err

    def test_keygen_inside_a_git_work_tree_exits_2(
        self, tmp_path: Path, capsys
    ) -> None:
        repo = tmp_path / "repo"
        (repo / ".git").mkdir(parents=True)
        rc = cli.main(
            ["keygen", "--key-dir", str(repo / "keys"), "--key-id", "k1"]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert captured.err.startswith("error:")
        assert "git work tree" in captured.err
        assert "Traceback" not in captured.err
        assert not (repo / "keys").exists()

    def test_issue_stdout_is_only_the_code(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        rc = cli.main(
            [
                "issue",
                "--key-dir",
                str(key_dir),
                "--key-id",
                "k1",
                "--request",
                VALID_REQUEST,
                "--features",
                "pos,inventory",
            ]
        )
        captured = capsys.readouterr()
        assert rc == 0
        code = captured.out.strip()
        document, _ = decode_code(code)
        assert set(document) == set(PAYLOAD_FIELDS)
        assert document["features"] == ["pos", "inventory"]
        assert "issued license_id=" in captured.err
        seed = base64.b64encode(
            keystore.load_keystore(key_dir)["k1"].private_seed
        ).decode()
        assert seed not in captured.out + captured.err
        assert HW_HASH not in captured.err

    def test_issue_reads_the_request_from_stdin(
        self, key_dir: Path, k1: bytes, capsys, monkeypatch
    ) -> None:
        monkeypatch.setattr(sys, "stdin", io.StringIO(VALID_REQUEST))
        rc = cli.main(["issue", "--key-dir", str(key_dir), "--key-id", "k1"])
        captured = capsys.readouterr()
        assert rc == 0
        assert captured.out.strip().startswith("SMP1.")

    def test_issue_reads_the_request_from_a_file(
        self, key_dir: Path, k1: bytes, tmp_path: Path, capsys
    ) -> None:
        request_file = tmp_path / "request.txt"
        request_file.write_text(VALID_REQUEST, encoding="utf-8")
        rc = cli.main(
            [
                "issue",
                "--key-dir",
                str(key_dir),
                "--key-id",
                "k1",
                "--request-file",
                str(request_file),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 0
        assert captured.out.strip().startswith("SMP1.")

    def test_issue_with_unknown_key_exits_2_without_a_traceback(
        self, tmp_path: Path, capsys
    ) -> None:
        rc = cli.main(
            [
                "issue",
                "--key-dir",
                str(tmp_path / "empty"),
                "--key-id",
                "ghost",
                "--request",
                VALID_REQUEST,
            ]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert captured.err.startswith("error:")
        assert "Traceback" not in captured.err
        assert "keygen" in captured.err
        assert not (tmp_path / "empty").exists()

    def test_issue_with_a_malformed_request_exits_2(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        rc = cli.main(
            [
                "issue",
                "--key-dir",
                str(key_dir),
                "--key-id",
                "k1",
                "--request",
                "garbage",
            ]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert "error:" in captured.err
        assert "Traceback" not in captured.err

    def test_export_merges_into_an_existing_keys_file(
        self, tmp_path: Path, key_dir: Path, k1: bytes, capsys
    ) -> None:
        target = tmp_path / "verification_keys.json"
        target.write_text(
            json.dumps({"k9": base64.b64encode(bytes(range(32))).decode()}),
            encoding="utf-8",
        )
        rc = cli.main(
            [
                "export-key",
                "--key-dir",
                str(key_dir),
                "--key-id",
                "k1",
                "--out",
                str(target),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 0
        assert set(load_verification_keys(target)) == {"k1", "k9"}
        seed = base64.b64encode(
            keystore.load_keystore(key_dir)["k1"].private_seed
        ).decode()
        assert seed not in target.read_text(encoding="utf-8")
        assert "existing key ids preserved" in captured.err
        assert set(json.loads(captured.out)) == {"k1"}

    def test_export_refuses_a_conflicting_public_key(
        self, tmp_path: Path, capsys
    ) -> None:
        first_dir = tmp_path / "first"
        second_dir = tmp_path / "second"
        keystore.generate_keypair(first_dir, "k1")
        keystore.generate_keypair(second_dir, "k1")
        target = tmp_path / "verification_keys.json"
        assert (
            cli.main(
                [
                    "export-key",
                    "--key-dir",
                    str(first_dir),
                    "--key-id",
                    "k1",
                    "--out",
                    str(target),
                ]
            )
            == 0
        )
        capsys.readouterr()
        before = target.read_bytes()
        rc = cli.main(
            [
                "export-key",
                "--key-dir",
                str(second_dir),
                "--key-id",
                "k1",
                "--out",
                str(target),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert "DIFFERENT" in captured.err
        assert target.read_bytes() == before

    def test_export_of_an_unknown_key_exits_2(
        self, key_dir: Path, capsys
    ) -> None:
        rc = cli.main(
            ["export-key", "--key-dir", str(key_dir), "--key-id", "ghost"]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert "unknown key id" in captured.err

    def test_verify_succeeds_with_keystore_public_keys(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        rc = cli.main(
            [
                "verify",
                issued.code,
                "--hw-hash",
                HW_HASH,
                "--key-dir",
                str(key_dir),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 0
        assert captured.out.startswith(f"verified license_id={issued.license_id}")

    def test_verify_succeeds_with_a_keys_file(
        self, tmp_path: Path, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        target = tmp_path / "verification_keys.json"
        keystore.merge_verification_keys(target, keystore.public_entry("k1", k1))
        rc = cli.main(
            [
                "verify",
                issued.code,
                "--hw-hash",
                HW_HASH,
                "--keys-file",
                str(target),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 0
        assert issued.license_id in captured.out

    def test_verify_for_other_hardware_exits_1(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        rc = cli.main(
            [
                "verify",
                issued.code,
                "--hw-hash",
                "cd" * 32,
                "--key-dir",
                str(key_dir),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 1
        assert "license_bound_elsewhere" in captured.err

    def test_verify_of_a_tampered_code_exits_1(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        prefix, payload_segment, signature_segment = issued.code.split(".")
        tampered = f"{prefix}.{payload_segment}.{flip(signature_segment)}"
        rc = cli.main(
            [
                "verify",
                tampered,
                "--hw-hash",
                HW_HASH,
                "--key-dir",
                str(key_dir),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 1
        assert "license_invalid" in captured.err

    def test_verify_with_an_unknown_key_exits_1(
        self, tmp_path: Path, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        target = tmp_path / "verification_keys.json"
        target.write_text(
            json.dumps({"k9": base64.b64encode(bytes(range(32))).decode()}),
            encoding="utf-8",
        )
        rc = cli.main(
            [
                "verify",
                issued.code,
                "--hw-hash",
                HW_HASH,
                "--keys-file",
                str(target),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 1
        assert "license_invalid_key" in captured.err

    def test_verify_with_a_corrupt_keys_file_exits_2(
        self, tmp_path: Path, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        target = tmp_path / "verification_keys.json"
        target.write_text("{broken", encoding="utf-8")
        rc = cli.main(
            [
                "verify",
                issued.code,
                "--hw-hash",
                HW_HASH,
                "--keys-file",
                str(target),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert captured.err.startswith("error:")
        assert "Traceback" not in captured.err

    def test_verify_rejects_a_malformed_hw_hash_argument(
        self, key_dir: Path, k1: bytes, capsys
    ) -> None:
        issued = issue(key_dir)
        rc = cli.main(
            [
                "verify",
                issued.code,
                "--hw-hash",
                "nope",
                "--key-dir",
                str(key_dir),
            ]
        )
        captured = capsys.readouterr()
        assert rc == 2
        assert "hw-hash" in captured.err

    def test_module_entry_point_runs_in_a_subprocess(self, tmp_path: Path) -> None:
        key_dir = tmp_path / "sub_keys"
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "tools.license_generator",
                "keygen",
                "--key-dir",
                str(key_dir),
                "--key-id",
                "k1",
            ],
            cwd=str(BACKEND_ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=60,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        entry = json.loads(result.stdout)
        assert set(entry) == {"k1"}
        seed = base64.b64encode(
            keystore.load_keystore(key_dir)["k1"].private_seed
        ).decode()
        assert seed not in result.stdout
        assert seed not in result.stderr
        assert "Traceback" not in result.stderr

        help_result = subprocess.run(
            [sys.executable, "-m", "tools.license_generator", "--help"],
            cwd=str(BACKEND_ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=60,
            check=False,
        )
        assert help_result.returncode == 0
        assert "keygen" in help_result.stdout


class TestPackagingBoundary:
    def test_generator_is_excluded_from_the_customer_distribution(self) -> None:
        text = (BACKEND_ROOT / "pyproject.toml").read_text(encoding="utf-8")
        assert 'include = ["app*"]' in text
        available = find_packages(where=str(BACKEND_ROOT))
        assert "tools.license_generator" in available
        shipped = find_packages(where=str(BACKEND_ROOT), include=["app*"])
        assert shipped
        assert not any(
            package.split(".")[0] == "tools" for package in shipped
        ), "the generator must never be part of the shipped backend package"


def test_generator_errors_stay_in_the_controlled_family() -> None:
    assert issubclass(KeystoreError, GeneratorError)
    assert issubclass(RequestFormatError, GeneratorError)
    assert issubclass(IssueError, GeneratorError)
    assert not issubclass(GeneratorError, AppError)
