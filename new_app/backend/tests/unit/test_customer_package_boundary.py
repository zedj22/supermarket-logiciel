"""R4 §4 — the exact customer package boundary.

The manifest at ``new_app/backend/customer_package.json`` defines what a
customer receives: the ``app/`` backend package plus the Flutter
``lib/`` sources, and nothing else - no owner-only Generator, no
developer tests, no keystore, no issuance ledger, no dotenv file, and no
private key material of any kind.

The application never reads this file; it is a release-engineering
contract that this module enforces against the source tree.
"""

from __future__ import annotations

import json
from pathlib import Path

from setuptools import find_packages

from app.licensing.release_metadata import public_fingerprint
from app.licensing.verification_keys import load_verification_keys

BACKEND_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = BACKEND_ROOT.parent.parent
MANIFEST_PATH = BACKEND_ROOT / "customer_package.json"


def manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def package_roots() -> list[Path]:
    return [BACKEND_ROOT / entry for entry in manifest()["include_roots"]]


def shipped_files() -> list[Path]:
    files: list[Path] = []
    for root in package_roots():
        for path in root.rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts:
                files.append(path)
    return files


def label(path: Path) -> str:
    """A stable display path, also for files outside ``backend/``."""
    try:
        return str(path.relative_to(BACKEND_ROOT))
    except ValueError:
        return str(path)


def _is_excluded(relative: str, patterns: list[str]) -> bool:
    name = Path(relative).name
    for pattern in patterns:
        if pattern.endswith("/"):
            if relative.replace("\\", "/").startswith(pattern):
                return True
        elif name == pattern or Path(name).match(pattern):
            return True
    return False


# ── what must ship ──────────────────────────────────────────────────────────


def test_the_manifest_exists_where_the_boundary_is_declared() -> None:
    assert MANIFEST_PATH.is_file()
    document = manifest()

    assert document["format"] == "supermarket-pro/customer-package"
    assert document["version"] == 1
    assert set(document) >= {
        "format",
        "version",
        "include_roots",
        "include_files",
        "must_include",
        "must_exclude",
        "forbidden_filenames",
        "forbidden_extensions",
        "forbidden_content",
    }


def test_every_declared_must_include_path_exists() -> None:
    missing = [
        entry
        for entry in manifest()["must_include"]
        if not (BACKEND_ROOT / entry).exists()
    ]

    assert missing == []


def test_the_licensing_implementation_and_public_keys_are_shipped() -> None:
    must_include = manifest()["must_include"]

    for module in (
        "app/licensing/guard.py",
        "app/licensing/authorization.py",
        "app/licensing/verification_keys.py",
        "app/licensing/verification_keys.json",
        "app/licensing/release_metadata.py",
        "app/licensing/release_metadata.json",
        "app/api/v1/license.py",
    ):
        assert module in must_include, module


def test_the_flutter_licensing_ui_and_localization_are_shipped() -> None:
    must_include = set(manifest()["must_include"])
    flutter = BACKEND_ROOT / ".." / "lib"

    assert (flutter / "features" / "licensing").is_dir()
    assert (flutter / "core" / "strings.dart").is_file()
    shipped_dart = {entry for entry in must_include if entry.endswith(".dart")}
    assert shipped_dart, "the manifest must declare the Flutter licensing sources"
    for entry in shipped_dart:
        assert entry.startswith("../lib/"), entry


# ── what must not ship ──────────────────────────────────────────────────────


def test_the_manifest_declares_the_owner_only_and_dev_only_exclusions() -> None:
    excluded = manifest()["must_exclude"]

    assert "tools/" in excluded
    assert "tests/" in excluded
    assert "../test/" in excluded
    assert "signing_keystore.json" in excluded
    assert "issuance_log.jsonl" in excluded
    assert ".env" in excluded


def test_no_excluded_path_sits_inside_a_package_root() -> None:
    excluded = manifest()["must_exclude"]
    violations = [
        label(path) for path in shipped_files() if _is_excluded(label(path), excluded)
    ]

    assert violations == []


def test_the_owner_only_generator_is_not_a_shipped_package() -> None:
    document = manifest()

    assert document["include_roots"] == ["app", "../lib"]
    assert not any(
        root.startswith("tools") or root.startswith("tests")
        for root in document["include_roots"] + document["include_files"]
    )

    available = find_packages(where=str(BACKEND_ROOT))
    shipped = find_packages(where=str(BACKEND_ROOT), include=["app*"])
    assert "tools.license_generator" in available
    assert shipped
    assert all(package.split(".")[0] == "app" for package in shipped), (
        "only the app tree may ship"
    )


def test_no_package_root_carries_a_forbidden_filename_or_extension() -> None:
    document = manifest()
    bad_names = [
        label(path)
        for path in shipped_files()
        if path.name in document["forbidden_filenames"]
    ]
    bad_extensions = [
        label(path)
        for path in shipped_files()
        if path.suffix.lower() in document["forbidden_extensions"]
    ]

    assert bad_names == []
    assert bad_extensions == []


def test_no_shipped_file_contains_private_key_material() -> None:
    markers = manifest()["forbidden_content"]
    hits: list[tuple[str, str]] = []

    for path in shipped_files():
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for marker in markers:
            if marker in text:
                hits.append((label(path), marker))

    assert hits == []


def test_the_backend_never_imports_the_owner_only_generator() -> None:
    offenders: list[str] = []

    for path in (BACKEND_ROOT / "app").rglob("*.py"):
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith(("from tools", "import tools")):
                offenders.append(f"{path.name}: {stripped}")

    assert offenders == []


def test_the_flutter_package_root_carries_no_dev_tests() -> None:
    flutter_root = (BACKEND_ROOT / ".." / "lib").resolve()
    dev_tests = (REPO_ROOT / "new_app" / "test").resolve()

    assert flutter_root.is_dir()
    assert dev_tests.is_dir()
    assert not str(dev_tests).startswith(str(flutter_root))
    assert not any(
        path.is_relative_to(dev_tests) for path in shipped_files()
    ), "developer Flutter tests must never be inside the shipped lib/ root"


# ── the key material that does ship ─────────────────────────────────────────


def test_the_shipped_verification_keys_are_public_ed25519_only() -> None:
    shipped = load_verification_keys(
        BACKEND_ROOT / "app" / "licensing" / "verification_keys.json"
    )

    for key_id, public in shipped.items():
        assert isinstance(key_id, str) and key_id
        assert isinstance(public, bytes) and len(public) == 32
        # A 32-byte public key carries no private half by construction;
        # the fingerprint recorded for it must be recomputable.
        assert public_fingerprint(public).startswith("sha256:")


def test_the_shipped_release_record_matches_the_shipped_keys() -> None:
    from app.licensing.release_metadata import load_release_metadata

    shipped = load_verification_keys(
        BACKEND_ROOT / "app" / "licensing" / "verification_keys.json"
    )
    recorded = load_release_metadata(
        BACKEND_ROOT / "app" / "licensing" / "release_metadata.json"
    )

    assert set(recorded) == set(shipped)
    for key_id, public in shipped.items():
        assert recorded[key_id] == public_fingerprint(public)
