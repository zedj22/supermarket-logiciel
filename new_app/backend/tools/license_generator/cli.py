"""Command-line interface for the offline License Generator (Phase L2-D).

Six commands over one private keystore:

* ``keygen --key-id ID``   - create a keypair under an explicit id
  (stdout: the one-key public entry for verification_keys.json);
* ``list-keys``            - inventory of key ids (never private halves);
* ``export-key --key-id ID`` - publish an id's public half, by default
  merged into a verification_keys.json **preserving every existing id**;
* ``provision-release --key-id ID --keys-out F --metadata-out F`` -
  R4 release pass: publish one or more public ids **and** record their
  fingerprints in release metadata, validating both files before and
  after any write;
* ``issue --key-id ID``    - strictly read an ``SMPr1`` request and print
  a signed ``SMP1`` Lifetime code (stdout = the code, summary on stderr);
* ``verify CODE --hw-hash`` - check any code with the backend verifier.

Exit codes: ``0`` success, ``1`` a rejected code/hash (``error: <code>: ...``),
``2`` an operator or input error (``error: ...``).  No command ever prints,
logs or writes private key material; the generator is meant to run on an
offline owner machine (`python -m tools.license_generator ...`).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from app.core.exceptions import AppError
from app.licensing.activation_code import verify_activation_code
from app.licensing.verification_keys import VerificationKeysError, load_verification_keys
from tools.license_generator import generator, keystore
from tools.license_generator.errors import GeneratorError
from tools.license_generator.release import provision_release

__all__ = ["main"]

_HW_HASH_NOTE = "64 lowercase hex characters (SHA-256)"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m tools.license_generator",
        description=(
            "Offline Lifetime license generator (Phase L2-D). Runs only on "
            "the owner machine; private keys never leave the keystore."
        ),
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--key-dir",
        metavar="DIR",
        help=(
            "keystore directory (default: $"
            f"{keystore.DEFAULT_ENV_VAR} or {keystore.DEFAULT_HOME})"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    keygen = sub.add_parser(
        "keygen",
        parents=[common],
        help="generate a keypair under an explicit new key id",
        description=(
            "Generate an Ed25519 keypair under an explicit key id. Existing "
            "ids are never replaced; stdout is the PUBLIC entry only."
        ),
    )
    keygen.add_argument("--key-id", required=True, metavar="ID", help="new explicit key id")
    keygen.add_argument("--label", default="", metavar="TEXT", help="free-text label")
    keygen.set_defaults(func=_cmd_keygen)

    listing = sub.add_parser(
        "list-keys",
        parents=[common],
        help="list key ids and public halves (never private material)",
    )
    listing.set_defaults(func=_cmd_list)

    export = sub.add_parser(
        "export-key",
        parents=[common],
        help="export one key id's PUBLIC half for customer provisioning",
        description=(
            "Print the one-key public entry; with --out it is merged into "
            "that verification_keys.json preserving every existing key id."
        ),
    )
    export.add_argument("--key-id", required=True, metavar="ID", help="existing key id")
    export.add_argument(
        "--out",
        metavar="FILE",
        help="merge the entry into this verification_keys.json (atomic, additive)",
    )
    export.set_defaults(func=_cmd_export)

    release = sub.add_parser(
        "provision-release",
        parents=[common],
        help="publish public keys into a release and record their fingerprints",
        description=(
            "R4 release pass: merge the listed EXISTING key ids into "
            "verification_keys.json (every other id preserved) and record every "
            "shipped key id's sha256 fingerprint in release metadata. Refuses "
            "unknown ids, conflicting public keys and inconsistent records. "
            "Never generates a key and never touches private material."
        ),
    )
    release.add_argument(
        "--key-id",
        action="append",
        dest="key_ids",
        required=True,
        metavar="ID",
        help="existing key id to publish (repeat for several)",
    )
    release.add_argument(
        "--keys-out",
        required=True,
        metavar="FILE",
        help="verification_keys.json to update (atomic, additive)",
    )
    release.add_argument(
        "--metadata-out",
        required=True,
        metavar="FILE",
        help="release metadata file to write (public fingerprints only)",
    )
    release.add_argument(
        "--dry-run",
        action="store_true",
        help="run every check and report, but write nothing",
    )
    release.set_defaults(func=_cmd_provision_release)

    issue = sub.add_parser(
        "issue",
        parents=[common],
        help="sign a Lifetime activation code from an SMPr1 request",
        description=(
            "Strictly read an SMPr1 request and print a signed SMP1 Lifetime "
            "code. stdout is the code ONLY; the summary goes to stderr."
        ),
    )
    issue.add_argument("--key-id", required=True, metavar="ID", help="existing key id to sign with")
    source = issue.add_mutually_exclusive_group()
    source.add_argument("--request", metavar="CODE", help="the SMPr1 request code")
    source.add_argument(
        "--request-file",
        metavar="FILE",
        help="read the SMPr1 request from a file ('-' for stdin)",
    )
    issue.add_argument(
        "--features",
        default="pos",
        metavar="CSV",
        help="comma-separated feature grants (default: pos)",
    )
    issue.add_argument(
        "--license-id",
        metavar="ID",
        help="custom license id (default: a fresh unique LIC-... value)",
    )
    issue.set_defaults(func=_cmd_issue)

    verify = sub.add_parser(
        "verify",
        help="verify an SMP1 code with the backend verifier (offline check)",
    )
    verify.add_argument("code", metavar="SMP1-CODE", help="the activation code to check")
    verify.add_argument(
        "--hw-hash",
        required=True,
        metavar="HASH",
        help=f"expected hardware hash: {_HW_HASH_NOTE}",
    )
    verify.add_argument(
        "--keys-file",
        metavar="FILE",
        help="verification_keys.json to verify against (default: keystore publics)",
    )
    verify.add_argument(
        "--key-dir",
        metavar="DIR",
        help=(
            "keystore directory for default public keys (default: $"
            f"{keystore.DEFAULT_ENV_VAR} or {keystore.DEFAULT_HOME})"
        ),
    )
    verify.set_defaults(func=_cmd_verify)
    return parser


def _cmd_keygen(args: argparse.Namespace) -> int:
    key_dir = keystore.resolve_key_dir(args.key_dir)
    public = keystore.generate_keypair(key_dir, args.key_id, label=args.label)
    print(json.dumps(keystore.public_entry(args.key_id, public), sort_keys=True))
    print(
        f"created key id {args.key_id!r} in {key_dir} "
        "(public half printed above; the private half stays in the keystore)",
        file=sys.stderr,
    )
    return 0


def _cmd_list(args: argparse.Namespace) -> int:
    key_dir = keystore.resolve_key_dir(args.key_dir)
    store = keystore.load_keystore(key_dir)
    if not store:
        print(
            f"no keys in {key_dir} - create one explicitly with "
            "`keygen --key-id ...` (keys are never generated implicitly)",
            file=sys.stderr,
        )
        return 0
    for key_id, key in sorted(store.items()):
        print(
            f"{key_id}\t{key.created_at}\tpublic={keystore._b64encode(key.public)}"
            + (f"\tlabel={key.label}" if key.label else "")
        )
    return 0


def _cmd_export(args: argparse.Namespace) -> int:
    key_dir = keystore.resolve_key_dir(args.key_dir)
    store = keystore.load_keystore(key_dir)
    if args.key_id not in store:
        known = ", ".join(sorted(store)) or "none"
        raise GeneratorError(
            f"unknown key id {args.key_id!r} (existing key ids: {known}) - "
            "export requires an existing key from `keygen`"
        )
    entry = keystore.public_entry(args.key_id, store[args.key_id].public)
    if args.out:
        keystore.merge_verification_keys(Path(args.out), entry)
        print(
            f"merged public key {args.key_id!r} into {args.out} "
            "(existing key ids preserved)",
            file=sys.stderr,
        )
    print(json.dumps(entry, sort_keys=True))
    return 0


def _cmd_provision_release(args: argparse.Namespace) -> int:
    result = provision_release(
        key_dir=keystore.resolve_key_dir(args.key_dir),
        key_ids=args.key_ids,
        keys_out=args.keys_out,
        metadata_out=args.metadata_out,
        dry_run=args.dry_run,
    )
    # stdout is the release record: key ids and public fingerprints only.
    print(
        json.dumps(
            {
                "format": "supermarket-pro/release-keys",
                "version": 1,
                "keys": result.recorded,
            },
            indent=2,
            sort_keys=True,
        )
    )
    verb = "would publish" if result.dry_run else "published"
    print(
        f"{verb} key id(s) {', '.join(result.key_ids)} into {result.keys_out} "
        f"and recorded {len(result.recorded)} key id(s) in {result.metadata_out} "
        "- public material only; the private halves stay in the keystore",
        file=sys.stderr,
    )
    return 0


def _read_request(args: argparse.Namespace) -> str:
    if args.request is not None:
        return args.request
    if args.request_file is not None:
        if args.request_file == "-":
            return sys.stdin.read()
        try:
            return Path(args.request_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise GeneratorError(f"cannot read the request file: {exc}") from exc
    if sys.stdin.isatty():
        raise GeneratorError(
            "paste the SMPr1 request on stdin, or pass --request / --request-file"
        )
    return sys.stdin.read()


def _cmd_issue(args: argparse.Namespace) -> int:
    key_dir = keystore.resolve_key_dir(args.key_dir)
    raw = _read_request(args)
    features = tuple(part.strip() for part in args.features.split(",") if part.strip())
    issued = generator.issue_license(
        raw,
        key_id=args.key_id,
        key_dir=key_dir,
        features=features,
        license_id=args.license_id,
    )
    print(issued.code)
    print(
        f"issued license_id={issued.license_id} key_id={issued.key_id} "
        f"issued_at={issued.issued_at} features={','.join(issued.features)} "
        "- recorded in the issuance log (no secrets)",
        file=sys.stderr,
    )
    return 0


def _cmd_verify(args: argparse.Namespace) -> int:
    hw_hash = args.hw_hash.strip()
    if not generator._HW_HASH_RE.match(hw_hash):
        raise GeneratorError(f"invalid --hw-hash: expected {_HW_HASH_NOTE}")
    if args.keys_file:
        try:
            keys = load_verification_keys(Path(args.keys_file))
        except VerificationKeysError as exc:
            raise GeneratorError(f"cannot use {args.keys_file}: {exc}") from exc
    else:
        key_dir = keystore.resolve_key_dir(args.key_dir)
        keys = keystore.get_public_keys(key_dir)
    payload = verify_activation_code(args.code, keys=keys, expected_hw_hash=hw_hash)
    print(
        f"verified license_id={payload.license_id} key_id={payload.key_id} "
        f"kind={payload.kind} issued_at={payload.issued_at} "
        f"features={','.join(payload.features)}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point: one error line per failure, no traceback, no secrets."""
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except GeneratorError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except AppError as exc:
        print(f"error: {exc.code}: {exc}", file=sys.stderr)
        return 1
