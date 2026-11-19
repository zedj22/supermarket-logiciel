"""R4 §2 — release provisioning and the shipped release record.

The owner-side pass that turns a TEST key in a throwaway keystore into
``verification_keys.json`` plus ``release_metadata.json``.  Every key in
this file is generated into ``tmp_path``; a production key is never
generated, and the packaged files under ``app/licensing/`` are only ever
read.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.licensing.release_metadata import (
    RELEASE_METADATA_FORMAT,
    RELEASE_METADATA_VERSION,
    ReleaseMetadataError,
    fingerprints_from_keys,
    load_release_metadata,
    public_fingerprint,
    validate_release_metadata,
    write_release_metadata,
)
from app.licensing.verification_keys import load_verification_keys
from tools.license_generator import cli, keystore
from tools.license_generator.errors import KeystoreError
from tools.license_generator.release import provision_release

BACKEND_ROOT = Path(__file__).resolve().parents[2]

KEY_ID = "k1"
OTHER_ID = "k2"


def keygen(key_dir: Path, *key_ids: str) -> None:
    for key_id in key_ids:
        assert (
            cli.main(["keygen", "--key-dir", str(key_dir), "--key-id", key_id]) == 0
        ), f"keygen {key_id} failed"


def provision(key_dir: Path, keys_out: Path, metadata_out: Path, *key_ids: str, **kw):
    return provision_release(
        key_dir=key_dir,
        key_ids=list(key_ids),
        keys_out=keys_out,
        metadata_out=metadata_out,
        **kw,
    )


def public_of(key_dir: Path, key_id: str) -> bytes:
    return keystore.load_keystore(key_dir)[key_id].public


@pytest.fixture()
def work(tmp_path: Path) -> tuple[Path, Path, Path]:
    """A keystore plus the two files a release would ship."""
    key_dir = tmp_path / "keystore"
    keygen(key_dir, KEY_ID)
    return key_dir, tmp_path / "verification_keys.json", tmp_path / "release_metadata.json"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ── the happy path ──────────────────────────────────────────────────────────


def test_provision_release_publishes_public_material_only(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work

    result = provision(key_dir, keys_out, metadata_out, KEY_ID)

    assert result.key_ids == (KEY_ID,)
    assert result.dry_run is False

    shipped = load_verification_keys(keys_out)
    assert shipped == {KEY_ID: public_of(key_dir, KEY_ID)}

    recorded = load_release_metadata(metadata_out)
    assert recorded == {KEY_ID: public_fingerprint(shipped[KEY_ID])}
    assert recorded == fingerprints_from_keys(shipped)

    # No private half, in either shipped file.
    seed = keystore.load_keystore(key_dir)[KEY_ID].private_seed.hex()
    for path in (keys_out, metadata_out):
        text = read(path)
        assert seed not in text
        assert '"private"' not in text
        assert "private_seed" not in text


def test_the_release_record_carries_exactly_the_three_documented_fields(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)

    document = json.loads(read(metadata_out))

    assert set(document) == {"format", "version", "keys"}
    assert document["format"] == RELEASE_METADATA_FORMAT
    assert document["version"] == RELEASE_METADATA_VERSION


def test_provision_release_is_idempotent(work: tuple[Path, Path, Path]) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    before = (read(keys_out), read(metadata_out))

    again = provision(key_dir, keys_out, metadata_out, KEY_ID)

    assert (read(keys_out), read(metadata_out)) == before
    assert again.recorded == {KEY_ID: public_fingerprint(public_of(key_dir, KEY_ID))}


def test_a_second_key_is_added_while_the_first_is_preserved(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    keygen(key_dir, OTHER_ID)
    first = public_of(key_dir, KEY_ID)

    provision(key_dir, keys_out, metadata_out, OTHER_ID)

    shipped = load_verification_keys(keys_out)
    assert set(shipped) == {KEY_ID, OTHER_ID}
    assert shipped[KEY_ID] == first, "the first shipped key must not be rewritten"
    assert set(load_release_metadata(metadata_out)) == {KEY_ID, OTHER_ID}


def test_a_dry_run_checks_everything_and_writes_nothing(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    keygen(key_dir, OTHER_ID)
    before = (read(keys_out), read(metadata_out))

    result = provision(key_dir, keys_out, metadata_out, OTHER_ID, dry_run=True)

    assert result.dry_run is True
    assert result.recorded == {
        KEY_ID: public_fingerprint(public_of(key_dir, KEY_ID)),
        OTHER_ID: public_fingerprint(public_of(key_dir, OTHER_ID)),
    }
    assert (read(keys_out), read(metadata_out)) == before


def test_provision_release_never_creates_a_key(work: tuple[Path, Path, Path]) -> None:
    key_dir, keys_out, metadata_out = work

    with pytest.raises(KeystoreError, match="unknown key id"):
        provision(key_dir, keys_out, metadata_out, "k9")

    assert not keys_out.exists()
    assert not metadata_out.exists()
    assert set(keystore.load_keystore(key_dir)) == {KEY_ID}


# ── refusals leave both files untouched ─────────────────────────────────────


def test_an_unknown_key_id_leaves_an_existing_release_untouched(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    before = (read(keys_out), read(metadata_out))

    with pytest.raises(KeystoreError, match="unknown key id"):
        provision(key_dir, keys_out, metadata_out, "k9")

    assert (read(keys_out), read(metadata_out)) == before


def test_a_mismatched_recorded_fingerprint_is_refused(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    write_release_metadata(metadata_out, {KEY_ID: "sha256:" + "0" * 64})
    before = (read(keys_out), read(metadata_out))

    with pytest.raises(KeystoreError, match="DIFFERENT fingerprint"):
        provision(key_dir, keys_out, metadata_out, KEY_ID)

    assert (read(keys_out), read(metadata_out)) == before


def test_a_record_for_an_unshipped_key_is_refused(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    write_release_metadata(metadata_out, {"k9": "sha256:" + "0" * 64})
    before = (read(keys_out), read(metadata_out))

    with pytest.raises(KeystoreError, match="not present"):
        provision(key_dir, keys_out, metadata_out, KEY_ID)

    assert (read(keys_out), read(metadata_out)) == before


def test_a_corrupt_keys_file_is_refused_before_any_write(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    keys_out.write_text("{broken", encoding="utf-8")
    before = read(keys_out)

    with pytest.raises(KeystoreError, match="cannot be trusted"):
        provision(key_dir, keys_out, metadata_out, KEY_ID)

    assert read(keys_out) == before


def test_an_empty_or_duplicated_key_id_list_is_refused(
    work: tuple[Path, Path, Path],
) -> None:
    key_dir, keys_out, metadata_out = work

    with pytest.raises(KeystoreError, match="at least one"):
        provision(key_dir, keys_out, metadata_out)
    with pytest.raises(KeystoreError, match="duplicate"):
        provision(key_dir, keys_out, metadata_out, KEY_ID, KEY_ID)


# ── the release-record loader ───────────────────────────────────────────────


def test_a_missing_record_loads_as_no_release(tmp_path: Path) -> None:
    assert load_release_metadata(tmp_path / "absent.json") == {}


@pytest.mark.parametrize(
    "document",
    [
        "{broken",
        "[]",
        '"a string"',
        {"format": "other", "version": 1, "keys": {}},
        {"format": RELEASE_METADATA_FORMAT, "version": 99, "keys": {}},
        {"format": RELEASE_METADATA_FORMAT, "version": 1, "keys": {}, "extra": 1},
        {"format": RELEASE_METADATA_FORMAT, "version": 1},
        {"format": RELEASE_METADATA_FORMAT, "version": 1, "keys": []},
        {"format": RELEASE_METADATA_FORMAT, "version": 1, "keys": {"k1": "nope"}},
        {"format": RELEASE_METADATA_FORMAT, "version": 1, "keys": {"k1": "sha256:AB"}},
        {"format": RELEASE_METADATA_FORMAT, "version": 1, "keys": {"k 1": "sha256:" + "a" * 64}},
    ],
)
def test_a_malformed_record_is_refused_rather_than_read_as_empty(
    tmp_path: Path, document: object
) -> None:
    target = tmp_path / "release_metadata.json"
    target.write_text(document if isinstance(document, str) else json.dumps(document), encoding="utf-8")

    with pytest.raises(ReleaseMetadataError):
        load_release_metadata(target)


def test_a_duplicate_field_in_the_record_is_refused(tmp_path: Path) -> None:
    target = tmp_path / "release_metadata.json"
    fmt = json.dumps(RELEASE_METADATA_FORMAT)
    target.write_text(
        f'{{"format": {fmt}, "format": {fmt}, "version": 1, "keys": {{}}}}',
        encoding="utf-8",
    )

    with pytest.raises(ReleaseMetadataError, match="duplicate"):
        load_release_metadata(target)


def test_a_fingerprint_must_be_lowercase_sha256(tmp_path: Path) -> None:
    with pytest.raises(ReleaseMetadataError):
        write_release_metadata(tmp_path / "out.json", {"k1": "sha256:" + "A" * 64})
    with pytest.raises(ReleaseMetadataError):
        write_release_metadata(tmp_path / "out.json", {"k1": "md5:" + "a" * 32})
    with pytest.raises(ReleaseMetadataError):
        public_fingerprint(b"\x00" * 31)


def test_write_release_metadata_is_atomic_and_leaves_no_temp_file(
    tmp_path: Path,
) -> None:
    target = tmp_path / "nested" / "release_metadata.json"
    write_release_metadata(target, {"k1": "sha256:" + "a" * 64})

    assert sorted(p.name for p in target.parent.iterdir()) == ["release_metadata.json"]
    assert load_release_metadata(target) == {"k1": "sha256:" + "a" * 64}


# ── cross-checking a shipped pair ───────────────────────────────────────────


def _pair(tmp_path: Path, key_dir: Path) -> tuple[Path, Path]:
    keys_out = tmp_path / "verification_keys.json"
    metadata_out = tmp_path / "release_metadata.json"
    provision(key_dir, keys_out, metadata_out, KEY_ID)
    return keys_out, metadata_out


def test_validate_accepts_a_consistent_shipped_pair(
    tmp_path: Path, work: tuple[Path, Path, Path]
) -> None:
    key_dir, _, _ = work
    keys_out, metadata_out = _pair(tmp_path, key_dir)

    report = validate_release_metadata(keys_out, metadata_out)

    assert report.ok is True
    assert report.matched == (KEY_ID,)
    assert report.unrecorded == ()


def test_validate_refuses_a_shipped_key_that_was_never_recorded(
    tmp_path: Path, work: tuple[Path, Path, Path]
) -> None:
    key_dir, _, _ = work
    keys_out, metadata_out = _pair(tmp_path, key_dir)
    keystore.merge_verification_keys(
        keys_out, keystore.public_entry(OTHER_ID, b"\x01" * 32)
    )
    assert set(load_verification_keys(keys_out)) == {KEY_ID, OTHER_ID}
    assert set(load_release_metadata(metadata_out)) == {KEY_ID}

    with pytest.raises(ReleaseMetadataError, match="not recorded"):
        validate_release_metadata(keys_out, metadata_out)

    report = validate_release_metadata(keys_out, metadata_out, strict=False)
    assert report.ok is False
    assert report.unrecorded == (OTHER_ID,)


def test_validate_refuses_a_fingerprint_that_does_not_match(
    tmp_path: Path, work: tuple[Path, Path, Path]
) -> None:
    key_dir, _, _ = work
    keys_out, metadata_out = _pair(tmp_path, key_dir)
    write_release_metadata(metadata_out, {KEY_ID: "sha256:" + "0" * 64})

    with pytest.raises(ReleaseMetadataError, match="do not match"):
        validate_release_metadata(keys_out, metadata_out)


def test_validate_refuses_a_record_for_a_key_the_package_does_not_carry(
    tmp_path: Path, work: tuple[Path, Path, Path]
) -> None:
    key_dir, _, _ = work
    keys_out, metadata_out = _pair(tmp_path, key_dir)
    write_release_metadata(metadata_out, {"k9": "sha256:" + "a" * 64})

    with pytest.raises(ReleaseMetadataError, match="not present"):
        validate_release_metadata(keys_out, metadata_out)


# ── the files this repository actually ships ────────────────────────────────


def test_the_packaged_record_and_key_file_are_valid_public_pairs() -> None:
    keys_path = BACKEND_ROOT / "app" / "licensing" / "verification_keys.json"
    metadata_path = BACKEND_ROOT / "app" / "licensing" / "release_metadata.json"

    shipped = load_verification_keys(keys_path)
    recorded = load_release_metadata(metadata_path)

    assert set(shipped) == set(recorded), (
        "every shipped public key must be recorded in release_metadata.json"
    )
    for key_id, public in shipped.items():
        assert len(public) == 32
        assert recorded[key_id] == public_fingerprint(public)


def test_the_packaged_files_carry_no_private_material() -> None:
    for name in ("verification_keys.json", "release_metadata.json"):
        text = (BACKEND_ROOT / "app" / "licensing" / name).read_text(encoding="utf-8")
        assert '"private"' not in text
        assert "private_seed" not in text


# ── the CLI surface ─────────────────────────────────────────────────────────


def test_the_cli_exposes_the_provision_release_command(capsys) -> None:
    with pytest.raises(SystemExit) as excinfo:
        cli.main(["--help"])

    assert excinfo.value.code == 0
    assert "provision-release" in capsys.readouterr().out


def test_the_cli_provision_release_prints_the_release_record(
    tmp_path: Path, work: tuple[Path, Path, Path], capsys
) -> None:
    key_dir, keys_out, metadata_out = work

    rc = cli.main(
        [
            "provision-release",
            "--key-id",
            KEY_ID,
            "--keys-out",
            str(keys_out),
            "--metadata-out",
            str(metadata_out),
            "--key-dir",
            str(key_dir),
        ]
    )

    assert rc == 0
    captured = capsys.readouterr()
    document = json.loads(captured.out)
    assert set(document) == {"format", "keys", "version"}
    assert set(document["keys"]) == {KEY_ID}
    assert "public material only" in captured.err
    assert "Traceback" not in captured.err


def test_the_cli_provision_release_rejects_an_unknown_key_with_exit_two(
    tmp_path: Path, work: tuple[Path, Path, Path], capsys
) -> None:
    key_dir, keys_out, metadata_out = work

    rc = cli.main(
        [
            "provision-release",
            "--key-id",
            "k9",
            "--keys-out",
            str(keys_out),
            "--metadata-out",
            str(metadata_out),
            "--key-dir",
            str(key_dir),
        ]
    )

    assert rc == 2
    captured = capsys.readouterr()
    assert captured.err.startswith("error:")
    assert "unknown key id" in captured.err
    assert "Traceback" not in captured.err
    assert not keys_out.exists()
    assert not metadata_out.exists()
