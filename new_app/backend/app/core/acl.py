"""Locale-proof Windows ACLs for the per-install configuration (R5).

Why this module exists
----------------------
On a French test machine the files the installer creates under
``<DATA_DIR>\\config`` ended up with a **protected DACL that granted
nothing**: ``icacls`` printed no ACE at all, inheritance was not applied,
and the NetworkService backend crash-looped with ``PermissionError`` on
``secrets.env`` / ``database.env``.  The old scheme relied on a recursive
``icacls <data root> /grant … /T`` followed by ``/inheritance:r /T``: a
single pass over everything, including the PostgreSQL data directory,
whose ACL must stay PostgreSQL's own.  Reproduced: after that exact
sequence ``icacls`` on a file inside the tree fails with "Access is
denied" and creating a new file there is denied too.

So the rules are applied **explicitly, per object, after creation**, and
verified.  Nothing here recurses (``/T`` is refused), nothing parses
localized text:

* principals are passed as ``*S-1-5-…`` SIDs (names are translated);
* verification reads SDDL through ``icacls /save``, which uses the
  locale-independent SDDL codes (``SY``, ``BA``, ``NS``) and reports
  ``PAI`` (protected) versus ``AI`` (inherited) explicitly;
* only exit codes decide success.

ACL contract
------------
``config\\.env``, ``config\\secrets.env``, ``config\\database.env``
    inheritance removed; NetworkService (S-1-5-20) **Read**,
    Administrators (S-1-5-32-544) **Full**, SYSTEM (S-1-5-18) **Full**.

``config\\pg_admin.env``
    inheritance removed; Administrators + SYSTEM Full only.  The backend
    never reads this file (``run_production.py`` opens ``.env``,
    ``database.env`` and ``secrets.env``; ``installer_provision.py`` owns
    ``pg_admin.env``), so granting the service account anything would only
    widen exposure of the superuser password.

``logs\\``
    inheritance **kept**; NetworkService Modify, Administrators and SYSTEM
    Full — an administrator must be able to read ``install_steps.log``,
    ``pg_install.log`` and ``provision_report.json`` after a failed
    install.

``config\\`` (the directory itself)
    inheritance kept with the same inheritable grants, so files created
    later (endpoint JSON, next-install secrets) are readable by the
    service and by administrators instead of inheriting nothing.

``postgres\\`` and ``data\\`` are never touched: the PostgreSQL data
directory must keep the ACLs ``initdb`` gave it, and a recursive grant
over it broke ``postgresql.conf`` access in a sandbox.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

#: Well-known SIDs — translated on localized Windows, so never use names.
SID_SYSTEM = "S-1-5-18"
SID_ADMINISTRATORS = "S-1-5-32-544"
SID_NETWORK_SERVICE = "S-1-5-20"

#: SDDL abbreviations used by ``icacls /save`` for those SIDs.
SDDL_CODES: dict[str, str] = {
    SID_SYSTEM: "SY",
    SID_ADMINISTRATORS: "BA",
    SID_NETWORK_SERVICE: "NS",
}

#: SDDL access masks that contain read access for a file/directory.
_READ_MASKS = {
    "FA", "FR", "FX", "F", "R",
    "0x1200a9", "0x120089", "0x1f01ff", "0x1301bf",
}
_FULL_MASKS = {"FA", "F", "0x1f01ff"}

#: Files that hold this installation's credentials.
CREDENTIAL_FILES: tuple[str, ...] = (".env", "secrets.env", "database.env")
ADMIN_ONLY_FILES: tuple[str, ...] = ("pg_admin.env",)

#: Sub-directories of DATA_DIR that must never be re-ACLed recursively.
UNTOUCHED_DIRS: tuple[str, ...] = ("postgres",)


@dataclass(frozen=True)
class AclSpec:
    """One object's intended DACL."""

    name: str
    #: ``(sid, rights)`` pairs; rights are icacls syntax (``R``, ``M``, ``F``).
    aces: tuple[tuple[str, str], ...]
    #: True → strip inherited ACEs (``/inheritance:r``); False → keep them.
    protected: bool
    #: Appended to every rights string, e.g. ``(OI)(CI)`` for directories.
    inherit_flags: str = ""
    #: Directory whose *direct* children get the same grants (never recursive).
    include_children: bool = False

    def grants(self) -> list[tuple[str, str]]:
        return [(sid, f"{self.inherit_flags}{rights}") for sid, rights in self.aces]


@dataclass
class AclReport:
    applied: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems


# ─────────────────────────────────────────────────────────────────────────
# Specifications
# ─────────────────────────────────────────────────────────────────────────


def credential_file_spec(path: Path) -> AclSpec:
    """``.env`` / ``secrets.env`` / ``database.env``: service reads, admins own."""
    return AclSpec(
        name=str(path),
        aces=(
            (SID_NETWORK_SERVICE, "R"),
            (SID_ADMINISTRATORS, "F"),
            (SID_SYSTEM, "F"),
        ),
        protected=True,
    )


def admin_file_spec(path: Path) -> AclSpec:
    """``pg_admin.env``: administrators and SYSTEM only."""
    return AclSpec(
        name=str(path),
        aces=((SID_ADMINISTRATORS, "F"), (SID_SYSTEM, "F")),
        protected=True,
    )


def logs_dir_spec(path: Path) -> AclSpec:
    """``logs\\``: inheritance kept so administrators can always read it."""
    return AclSpec(
        name=str(path),
        aces=(
            (SID_NETWORK_SERVICE, "M"),
            (SID_ADMINISTRATORS, "F"),
            (SID_SYSTEM, "F"),
        ),
        protected=False,
        inherit_flags="(OI)(CI)",
        include_children=True,
    )


def config_dir_spec(path: Path) -> AclSpec:
    """``config\\`` itself: inheritable grants so later files are readable."""
    return AclSpec(
        name=str(path),
        aces=(
            (SID_NETWORK_SERVICE, "R"),
            (SID_ADMINISTRATORS, "F"),
            (SID_SYSTEM, "F"),
        ),
        protected=False,
        inherit_flags="(OI)(CI)",
    )


# ─────────────────────────────────────────────────────────────────────────
# Command lines (pure — asserted by the unit tests)
# ─────────────────────────────────────────────────────────────────────────


def icacls_argv(path: Path | str, spec: AclSpec) -> list[str]:
    """The exact ``icacls`` arguments for one object.  Never recursive."""
    argv: list[str] = ["icacls", str(path)]
    if spec.protected:
        argv.append("/inheritance:r")
    for sid, rights in spec.grants():
        argv.extend(["/grant", f"*{sid}:{rights}"])
    assert "/T" not in argv, "recursive ACL changes are forbidden"
    return argv


def save_argv(path: Path | str, sddl_file: Path) -> list[str]:
    """``icacls <path> /save <file>`` — SDDL with locale-free SID codes."""
    return ["icacls", str(path), "/save", str(sddl_file), "/C"]


# ─────────────────────────────────────────────────────────────────────────
# Apply / verify
# ─────────────────────────────────────────────────────────────────────────


def _run(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv, capture_output=True, text=True, check=False, encoding="utf-8",
        errors="replace",
    )


def apply_spec(path: Path | str, spec: AclSpec, *, runner=_run) -> None:
    """Apply one spec; a non-zero icacls exit is an error (no silent skip)."""
    target = Path(path)
    if not target.exists():
        raise FileNotFoundError(f"cannot apply ACLs to missing {target}")
    completed = runner(icacls_argv(target, spec))
    if completed.returncode != 0:
        raise AclError(
            f"icacls failed for {target} (exit {completed.returncode}): "
            f"{(completed.stdout or '') + (completed.stderr or '')}".strip()
        )
    if spec.include_children and target.is_dir():
        for child in sorted(target.iterdir()):
            if child.is_file():
                child_spec = AclSpec(
                    name=str(child),
                    aces=spec.aces,
                    protected=spec.protected,
                )
                completed = runner(icacls_argv(child, child_spec))
                if completed.returncode != 0:
                    raise AclError(
                        f"icacls failed for {child} "
                        f"(exit {completed.returncode})"
                    )


class AclError(RuntimeError):
    """An ACL could not be applied (never swallowed)."""


def read_sddl(path: Path | str, *, runner=_run) -> str:
    """The object's SDDL string, via ``icacls /save`` (UTF-16, SID codes)."""
    target = Path(path)
    with tempfile.TemporaryDirectory(prefix="sp-acl-") as tmp:
        sddl_file = Path(tmp) / "dacl.txt"
        completed = runner(save_argv(target, sddl_file))
        if completed.returncode != 0 or not sddl_file.is_file():
            raise AclError(
                f"cannot read the DACL of {target} (icacls /save exit "
                f"{completed.returncode}); the object grants nothing to the "
                "current account"
            )
        # `icacls /save` writes UTF-16LE **without** a BOM.
        data = sddl_file.read_bytes()
        raw = ""
        for encoding in ("utf-16", "utf-16-le", "utf-8"):
            try:
                raw = data.decode(encoding)
                break
            except UnicodeError:
                continue
        else:  # pragma: no cover - defensive
            raw = data.decode("utf-8", errors="replace")
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("D:"):
            return line
    raise AclError(f"no DACL line in icacls /save output for {target}")


def check_sddl(sddl: str, spec: AclSpec) -> list[str]:
    """Problems with ``sddl`` against ``spec`` (pure, no localized text)."""
    problems: list[str] = []
    if spec.protected and not sddl.startswith("D:PAI") and not sddl.startswith(
        "D:PA"
    ):
        problems.append(f"DACL is not protected (expected D:PAI, got {sddl[:8]})")
    if not spec.protected:
        if sddl.startswith("D:PAI"):
            problems.append("DACL is protected but inheritance was expected")
        elif not sddl.startswith("D:AI"):
            problems.append(
                f"DACL has no auto-inherited flag (expected D:AI, got {sddl[:8]})"
            )
    for sid, _rights in spec.aces:
        code = SDDL_CODES.get(sid, sid)
        if f";;{code})" not in sddl and f";;{code}(" not in sddl:
            problems.append(f"no ACE for {sid} ({code})")
            continue
        masks = [
            ace.split(";")[2]
            for ace in sddl.split("(")[1:]
            if f";;{code})" in ace or f";;{code}(" in ace
        ]
        if not any(
            mask.upper() in {m.upper() for m in _READ_MASKS}
            for mask in masks
        ):
            problems.append(f"ACE for {sid} ({code}) grants no read access")
        if _rights == "F" and not any(
            mask.upper() in {m.upper() for m in _FULL_MASKS}
            for mask in masks
        ):
            problems.append(f"ACE for {sid} ({code}) is not Full control")
    return problems


def verify_spec(path: Path | str, spec: AclSpec, *, runner=_run) -> list[str]:
    """Read the DACL and compare it with the spec."""
    try:
        sddl = read_sddl(path, runner=runner)
    except AclError as exc:
        return [str(exc)]
    return check_sddl(sddl, spec)


def harden_data_dir(data_dir: Path | str, *, runner=_run) -> AclReport:
    """Apply the whole contract for an existing ``<DATA_DIR>``."""
    root = Path(data_dir)
    report = AclReport()
    config = root / "config"
    logs = root / "logs"

    targets: list[tuple[Path, AclSpec]] = []
    if config.is_dir():
        # The directory itself keeps its inherited DACL (the data-root
        # grants are inheritable); replacing it made the directory
        # unusable for the account that owns the installation.
        for name in CREDENTIAL_FILES:
            path = config / name
            if path.is_file():
                targets.append((path, credential_file_spec(path)))
        for name in ADMIN_ONLY_FILES:
            path = config / name
            if path.is_file():
                targets.append((path, admin_file_spec(path)))
    if logs.is_dir():
        targets.append((logs, logs_dir_spec(logs)))

    for path, spec in targets:
        if root / UNTOUCHED_DIRS[0] in path.parents:  # pragma: no cover - guard
            report.problems.append(f"refusing to change ACLs under {path}")
            continue
        try:
            apply_spec(path, spec, runner=runner)
            report.applied.append(str(path))
        except (AclError, FileNotFoundError) as exc:
            report.problems.append(str(exc))
    return report


def verify_data_dir(data_dir: Path | str, *, runner=_run) -> AclReport:
    """Verify the whole contract without changing anything."""
    root = Path(data_dir)
    report = AclReport()
    config = root / "config"
    logs = root / "logs"

    checks: list[tuple[Path, AclSpec]] = []
    if config.is_dir():
        for name in CREDENTIAL_FILES:
            path = config / name
            if path.is_file():
                checks.append((path, credential_file_spec(path)))
            else:
                report.problems.append(f"missing credential file {path}")
        for name in ADMIN_ONLY_FILES:
            path = config / name
            if path.is_file():
                checks.append((path, admin_file_spec(path)))
    else:
        report.problems.append(f"missing config directory {config}")
    if logs.is_dir():
        checks.append((logs, logs_dir_spec(logs)))
    else:
        report.problems.append(f"missing log directory {logs}")

    for path, spec in checks:
        for problem in verify_spec(path, spec, runner=runner):
            report.problems.append(f"{path}: {problem}")
        if not any(p.startswith(str(path)) for p in report.problems):
            report.applied.append(str(path))
    return report


#: Readability of ``pg_admin.env`` for the service account is a *negative*
#: requirement: NetworkService must NOT have an ACE there.
def verify_admin_file_not_readable_by_service(
    path: Path | str, *, runner=_run
) -> list[str]:
    try:
        sddl = read_sddl(path, runner=runner)
    except AclError as exc:
        return [str(exc)]
    if f";;{SDDL_CODES[SID_NETWORK_SERVICE]})" in sddl or (
        f";;{SDDL_CODES[SID_NETWORK_SERVICE]}(" in sddl
    ):
        return [
            f"{path}: NetworkService {SID_NETWORK_SERVICE} has an ACE on the "
            "superuser password file; grant Administrators and SYSTEM only"
        ]
    return []


# ─────────────────────────────────────────────────────────────────────────
# CLI (used by the installer self-check)
# ─────────────────────────────────────────────────────────────────────────


def _format_report(title: str, report: AclReport) -> str:
    lines = [f"=== {title} ==="]
    for item in report.applied:
        lines.append(f"  OK   {item}")
    for problem in report.problems:
        lines.append(f"  FAIL {problem}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m app.core.acl",
        description="Apply or verify the installer's ACL contract.",
    )
    parser.add_argument("--data-dir", required=True)
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="do not change anything, only report problems",
    )
    args = parser.parse_args(argv)

    if os.name != "nt":  # pragma: no cover - installer is Windows only
        print("ACLs are Windows-only; nothing to do", file=sys.stderr)
        return 0

    data_dir = Path(args.data_dir)
    if not args.verify_only:
        applied = harden_data_dir(data_dir)
        print(_format_report("ACL apply", applied))
        if applied.problems:
            return 1
        admin = data_dir / "config" / "pg_admin.env"
        if admin.is_file():
            problems = verify_admin_file_not_readable_by_service(admin)
            if problems:
                print("\n".join(problems), file=sys.stderr)
                return 1
    verified = verify_data_dir(data_dir)
    print(_format_report("ACL verify", verified))
    return 0 if verified.ok else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
