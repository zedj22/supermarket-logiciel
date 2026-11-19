"""Read-only PostgreSQL discovery on Windows (R3 §2).

R3 has to answer one question before anything else: *is there already a
PostgreSQL server on this machine, and may we reuse it?*  This module
answers it **without ever connecting to a database and without ever
modifying anything** — no service is started, no file is written, no
registry key is touched, and the only subprocesses launched are the
three read-only probes ``sc query``, ``sc qc`` and ``psql --version``.

Discovery sources, in priority order (§2):

1. explicit overrides from settings (``PG_INSTALL_DIR`` / ``PG_BIN_DIR`` /
   ``PG_DATA_DIR`` / ``PG_SERVICE_NAME`` / ``PG_PORT``) — the
   administrator or the installer knows better than we do;
2. ``HKLM\\SOFTWARE\\PostgreSQL\\Installations\\*`` registry keys (the
   EDB installer writes one per install: base dir, data dir, service id,
   superuser, version);
3. the filesystem — ``<root>\\<ver>\\bin\\psql.exe`` under
   ``C:\\Program Files\\PostgreSQL`` and its ``Program Files (x86)``
   counterpart (a server can exist with its registry key deleted);
4. Windows services whose name starts with ``postgresql`` (a server can
   exist with neither registry key nor the usual install layout).

Each source contributes *facts* about one instance; facts are merged by
install directory / service name so the same server is never reported
twice.

Version policy (§2 "do not guess") is evidence based:

* ``MIN_SUPPORTED_MAJOR = 13`` — migrations ``0002``/``0015`` call
  ``gen_random_uuid()`` which is core from PostgreSQL 13 (before that it
  needs the ``pgcrypto`` extension), and ``0023`` relies on ``pg_trgm``
  being a *trusted* extension, which is PostgreSQL 13+ behaviour.
* ``VERIFIED_MAX_MAJOR = 18`` — the version this repository's migration
  suite actually runs against on this machine.
* A major newer than the verified one is reported as
  ``accepted but unverified``: it is *not* rejected (that would be an
  equally unfounded guess) and it is *not* silently trusted — the caller
  must opt in explicitly with ``allow_unverified=True``.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass, replace
from pathlib import Path

import structlog

from app.core.config import settings

logger = structlog.get_logger(__name__)

#: PostgreSQL major versions we refuse to reuse (see module docstring).
MIN_SUPPORTED_MAJOR = 13

#: Highest major this repository's migrations have been run against.
VERIFIED_MAX_MAJOR = 18

#: IANA default; only used when neither ``postgresql.conf`` nor the
#: settings override can tell us the truth.
DEFAULT_PORT = 5432

#: Well-known install roots (shared with :mod:`app.core.db_dump`).
PG_INSTALL_ROOTS: tuple[Path, ...] = (
    Path(r"C:\Program Files\PostgreSQL"),
    Path(r"C:\Program Files (x86)\PostgreSQL"),
)

#: Registry locations of the EDB installer's per-install keys.
REGISTRY_INSTALL_ROOTS: tuple[str, ...] = (
    r"SOFTWARE\PostgreSQL\Installations",
    r"SOFTWARE\WOW6432Node\PostgreSQL\Installations",
)

#: Only these subcommands are ever executed by discovery.  A test asserts
#: every command this module runs is in this list — discovery must never
#: become a way to run arbitrary (let alone mutating) SQL.
READ_ONLY_SC_COMMANDS: frozenset[str] = frozenset({"query", "qc"})

_TIMEOUT_SECONDS = 15


# ─────────────────────────────────────────────────────────────────────────
# Model
# ─────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class PostgresInstance:
    """Everything discovery could learn about one server, without asking it."""

    major: int | None = None
    version_text: str | None = None
    install_dir: Path | None = None
    bin_dir: Path | None = None
    data_dir: Path | None = None
    service_name: str | None = None
    service_state: str | None = None
    port: int | None = None
    superuser: str | None = None
    service_account: str | None = None
    psql: Path | None = None
    pg_dump: Path | None = None
    pg_ctl: Path | None = None
    #: Which sources contributed (``override`` / ``registry`` /
    #: ``filesystem`` / ``service``), for the operator's report.
    sources: tuple[str, ...] = ()

    @property
    def key(self) -> str:
        """Stable identity used to merge facts about the same server."""
        if self.install_dir is not None:
            return f"install:{str(self.install_dir).lower()}"
        if self.service_name:
            return f"service:{self.service_name.lower()}"
        if self.data_dir is not None:
            return f"data:{str(self.data_dir).lower()}"
        return f"unknown:{id(self)}"

    @property
    def is_running(self) -> bool:
        return (self.service_state or "").upper() == "RUNNING"

    @property
    def has_tools(self) -> bool:
        """True when the client binaries we need for backup are present."""
        return self.psql is not None and self.pg_dump is not None

    @property
    def label(self) -> str:
        version = self.version_text or (
            f"{self.major}.x" if self.major is not None else "unknown version"
        )
        where = self.install_dir or self.data_dir or self.service_name
        return f"PostgreSQL {version} ({where})"


@dataclass(frozen=True)
class Compatibility:
    """Whether an instance may be reused — and how well we know that."""

    accepted: bool
    verified: bool
    reason: str

    @property
    def usable(self) -> bool:
        return self.accepted


def check_compatibility(instance: PostgresInstance) -> Compatibility:
    """Apply the evidence-based version policy (never a guess)."""
    major = instance.major
    if major is None:
        return Compatibility(
            accepted=False,
            verified=False,
            reason=(
                "the server version could not be determined from the "
                "registry, the install directory or psql --version; "
                "refusing to guess"
            ),
        )
    if major < MIN_SUPPORTED_MAJOR:
        return Compatibility(
            accepted=False,
            verified=False,
            reason=(
                f"PostgreSQL {major} is older than the minimum supported "
                f"major {MIN_SUPPORTED_MAJOR}: migrations 0002/0015 need "
                "gen_random_uuid() (core since 13) and 0023 needs pg_trgm "
                "to be a trusted extension (13+)"
            ),
        )
    if major > VERIFIED_MAX_MAJOR:
        return Compatibility(
            accepted=True,
            verified=False,
            reason=(
                f"PostgreSQL {major} is newer than the verified maximum "
                f"{VERIFIED_MAX_MAJOR}; the migration suite has not been "
                "run against it — pass allow_unverified=True to reuse it"
            ),
        )
    return Compatibility(
        accepted=True,
        verified=True,
        reason=(
            f"PostgreSQL {major} is within the supported range "
            f"{MIN_SUPPORTED_MAJOR}-{VERIFIED_MAX_MAJOR}"
        ),
    )


# ─────────────────────────────────────────────────────────────────────────
# Probes (the only subprocesses discovery may run)
# ─────────────────────────────────────────────────────────────────────────


def _run_command(argv: list[str]) -> str:
    """Run a read-only probe and return its stdout (``""`` on failure)."""
    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.debug(
            "pg_discovery_probe_failed",
            probe=Path(argv[0]).name,
            error=str(exc),
        )
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout or ""


def _service_overview() -> dict[str, str]:
    """``{service name: STATE}`` for every postgres service (one probe)."""
    output = _run_command(["sc.exe", "query", "state=", "all"])
    return {
        name: state
        for name, state in parse_sc_query_states(output).items()
    }


#: ``sc query`` prints the state as ``<number> <word>``.  The NUMBER is
#: locale-independent; the word is localized (RUNNING / EN COURS /
#: ABHÖREN …), and reading it was how a perfectly healthy service ended up
#: reported as "not running".  Service state codes are a fixed Windows
#: contract.
SERVICE_STATE_BY_CODE: dict[str, str] = {
    "1": "STOPPED",
    "2": "START_PENDING",
    "3": "STOP_PENDING",
    "4": "RUNNING",
    "5": "CONTINUE_PENDING",
    "6": "PAUSE_PENDING",
    "7": "PAUSED",
}

#: Any ``FIELD : <state code>`` line inside a service block.
_STATE_CODE_LINE = re.compile(r"^\s*\S+\s*:\s*([1-7])(?:\s|$)")


def parse_sc_query_states(output: str) -> dict[str, str]:
    """``{name: state}`` out of ``sc query`` output (pure, locale-proof).

    Only ``SERVICE_NAME`` is matched textually (that field name is the same
    on every Windows language); the state is taken from its numeric code.
    A textual fallback keeps the previous behaviour for synthetic inputs.
    """
    states: dict[str, str] = {}
    current: str | None = None
    for line in output.splitlines():
        name_match = re.match(
            r"^\s*SERVICE_NAME\s*:\s*(.+?)\s*$", line, re.IGNORECASE
        )
        if name_match:
            candidate = name_match.group(1)
            current = candidate if "postgres" in candidate.lower() else None
            if current is not None:
                states.setdefault(current, "")
            continue
        if current is None or states.get(current):
            continue
        code_match = _STATE_CODE_LINE.match(line)
        if code_match:
            states[current] = SERVICE_STATE_BY_CODE[code_match.group(1)]
            continue
        word_match = re.search(r"\b(RUNNING|STOPPED|PAUSED)\b", line.upper())
        if word_match:
            states[current] = word_match.group(1)
    return states


def parse_sc_single_state(output: str) -> str:
    """STATE of ``sc query <one service>`` (pure, locale-proof).

    ``sc`` localizes its field NAMES as well as the state word on some
    Windows languages (``NOM_SERVICE`` / ``ÉTAT``), so for a single known
    service the state is taken from the numeric code alone.  Service state
    codes 1-7 never collide with the other numeric fields of that output
    (``TYPE : 10``, ``..._EXIT_CODE : 0``, ``CHECKPOINT : 0x0``).
    """
    for line in output.splitlines():
        code_match = _STATE_CODE_LINE.match(line)
        if code_match:
            return SERVICE_STATE_BY_CODE[code_match.group(1)]
    return ""


def parse_sc_query(output: str) -> list[str]:
    """Service names out of ``sc query state= all`` output (pure)."""
    return list(parse_sc_query_states(output))


def parse_sc_qc(output: str) -> dict[str, str]:
    """Facts out of ``sc qc <name>`` output (pure).

    Handles both key spellings (``BINARY_PATH_NAME`` on current Windows,
    ``PATH_NAME`` on older ones) and pulls the data directory out of the
    ``-D`` argument of ``pg_ctl``.  ``sc qc`` does not report the running
    state on every Windows build, so state is never taken from here.
    """
    facts: dict[str, str] = {}
    for match in re.finditer(
        r"^\s*([A-Za-z_0-9]+)\s*:\s*(.*?)\s*$", output, re.MULTILINE
    ):
        key, value = match.group(1).upper(), match.group(2)
        if key in ("BINARY_PATH_NAME", "PATH_NAME") and value:
            facts.setdefault("binary_path", value)
        elif key == "SERVICE_START_NAME" and value:
            facts.setdefault("service_account", value)
        elif key == "DISPLAY_NAME" and value:
            facts.setdefault("display_name", value)

    binary = facts.get("binary_path", "")
    executable = _first_token(binary)
    if executable:
        facts["executable"] = executable
        facts.setdefault("bin_dir", str(Path(executable).parent))
    data_dir = _flag_value(binary, "-D")
    if data_dir:
        facts["data_dir"] = data_dir
    return facts


def _first_token(command_line: str) -> str:
    """Executable out of a possibly quoted Windows command line."""
    stripped = command_line.strip()
    if not stripped:
        return ""
    if stripped.startswith('"'):
        end = stripped.find('"', 1)
        return stripped[1:end] if end > 0 else ""
    return stripped.split()[0]


def _flag_value(command_line: str, flag: str) -> str:
    """Value of ``-D "..."`` (or ``-D path``) in a command line."""
    pattern = re.compile(
        re.escape(flag) + r'\s+(?:"([^"]+)"|(\S+))', re.IGNORECASE
    )
    match = pattern.search(command_line)
    if match is None:
        return ""
    return match.group(1) or match.group(2) or ""


def parse_version_text(text: str) -> int | None:
    """Major version out of ``psql (PostgreSQL) 18.6`` / ``18.6-4`` (pure)."""
    if not text:
        return None
    match = re.search(r"(\d+)\.(\d+)", text) or re.search(r"\b(\d+)\b", text)
    if match is None:
        return None
    return int(match.group(1))


def _probe_version(bin_dir: Path) -> tuple[str | None, int | None]:
    """``psql --version`` → (raw text, major).  Empty on any failure."""
    psql = bin_dir / "psql.exe"
    if not psql.is_file():
        return None, None
    output = _run_command([str(psql), "--version"]).strip()
    if not output:
        return None, None
    return output, parse_version_text(output)


def _port_from_conf(data_dir: Path | None) -> int | None:
    """Read ``port = N`` from ``postgresql.conf`` (never guess it)."""
    if data_dir is None:
        return None
    conf = data_dir / "postgresql.conf"
    try:
        text = conf.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        stripped = line.split("#", 1)[0].strip()
        match = re.match(r"^port\s*=\s*(\d+)\s*$", stripped, re.IGNORECASE)
        if match:
            return int(match.group(1))
    return None


# ─────────────────────────────────────────────────────────────────────────
# Sources
# ─────────────────────────────────────────────────────────────────────────


def _override_facts() -> dict[str, str]:
    """Explicit settings as one synthetic source (highest priority)."""
    facts: dict[str, str] = {}
    install = (settings.PG_INSTALL_DIR or "").strip()
    bin_dir = (settings.PG_BIN_DIR or "").strip()
    data_dir = (settings.PG_DATA_DIR or "").strip()
    service = (settings.PG_SERVICE_NAME or "").strip()
    if install:
        facts["install_dir"] = install
    if bin_dir:
        facts["bin_dir"] = bin_dir
    if data_dir:
        facts["data_dir"] = data_dir
    if service:
        facts["service_name"] = service
    if settings.PG_PORT:
        facts["port"] = str(int(settings.PG_PORT))
    if not facts:
        return {}
    facts["_source"] = "override"
    return facts


def _registry_facts() -> list[dict[str, str]]:
    """One fact dict per ``HKLM\\...\\PostgreSQL\\Installations\\*`` key."""
    if sys.platform != "win32":  # pragma: no cover - non-Windows dev box
        return []
    try:
        import winreg
    except ImportError:  # pragma: no cover - non-Windows
        return []

    entries: list[dict[str, str]] = []
    for root in REGISTRY_INSTALL_ROOTS:
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, root) as handle:
                index = 0
                while True:
                    try:
                        subkey_name = winreg.EnumKey(handle, index)
                    except OSError:
                        break
                    index += 1
                    entries.append(_read_registry_key(winreg, root, subkey_name))
        except OSError:
            continue
    return entries


def _read_registry_key(winreg, root: str, subkey: str) -> dict[str, str]:
    """Values of one installation key, mapped onto our fact names."""
    facts: dict[str, str] = {"_source": "registry"}
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, f"{root}\\{subkey}") as key:
            for value_name, fact_name in (
                ("Base Directory", "install_dir"),
                ("Data Directory", "data_dir"),
                ("Service ID", "service_name"),
                ("Service Account", "service_account"),
                ("Super User", "superuser"),
                ("Version", "version_text"),
            ):
                try:
                    value = winreg.QueryValueEx(key, value_name)[0]
                except OSError:
                    continue
                if isinstance(value, str) and value.strip():
                    facts[fact_name] = value.strip()
    except OSError:
        return facts
    return facts


def _filesystem_facts() -> list[dict[str, str]]:
    """One fact dict per ``<root>\\<ver>\\bin\\psql.exe`` found on disk."""
    entries: list[dict[str, str]] = []
    for root in PG_INSTALL_ROOTS:
        if not root.is_dir():
            continue
        try:
            candidates = sorted(root.glob("*/bin/psql.exe"), reverse=True)
        except OSError as exc:  # pragma: no cover - unreadable install dir
            logger.debug("pg_discovery_glob_failed", root=str(root), error=str(exc))
            continue
        for psql in candidates:
            bin_dir = psql.parent
            install_dir = bin_dir.parent
            facts: dict[str, str] = {
                "_source": "filesystem",
                "install_dir": str(install_dir),
                "bin_dir": str(bin_dir),
                "psql": str(psql),
                "pg_dump": str(bin_dir / "pg_dump.exe"),
                "pg_ctl": str(bin_dir / "pg_ctl.exe"),
            }
            version_text, major = _probe_version(bin_dir)
            if version_text:
                facts["version_text"] = version_text
            if major is not None:
                facts["major"] = str(major)
            elif install_dir.name.isdigit():
                facts["major"] = install_dir.name
            entries.append(facts)
    return entries


def _service_facts() -> list[dict[str, str]]:
    """One fact dict per Windows service whose name mentions postgres.

    Two read-only probes per service: ``sc query state= all`` (once, for
    the running state) and ``sc qc <name>`` (binary path, data dir,
    service account).
    """
    overview = _service_overview()
    entries: list[dict[str, str]] = []
    for name in overview:
        output = _run_command(["sc.exe", "qc", name])
        if not output:
            continue
        parsed = parse_sc_qc(output)
        facts: dict[str, str] = {
            "_source": "service",
            "service_name": name,
        }
        state = overview.get(name, "")
        if not state:
            # The bulk listing did not report a state for this service (a
            # localized build, or a service created while the listing ran).
            # Ask for that single service before concluding anything.
            single = _run_command(["sc.exe", "query", name])
            state = parse_sc_query_states(single).get(
                name, ""
            ) or parse_sc_single_state(single)
        if state:
            facts["state"] = state
        for key in ("service_account", "data_dir", "bin_dir", "display_name"):
            if parsed.get(key):
                facts[key] = parsed[key]
        bin_dir_value = parsed.get("bin_dir", "")
        if bin_dir_value:
            bin_dir = Path(bin_dir_value)
            facts["install_dir"] = str(bin_dir.parent)
            for tool in ("psql", "pg_dump", "pg_ctl"):
                candidate = bin_dir / f"{tool}.exe"
                if candidate.is_file():
                    facts[tool] = str(candidate)
            version_text, major = _probe_version(bin_dir)
            if version_text:
                facts["version_text"] = version_text
            if major is not None:
                facts["major"] = str(major)
        entries.append(facts)
    return entries


# ─────────────────────────────────────────────────────────────────────────
# Merge + selection
# ─────────────────────────────────────────────────────────────────────────


def _identity_keys(facts: dict[str, object]) -> set[str]:
    """Every name that identifies the server these facts describe."""
    keys: set[str] = set()
    for name in ("install_dir", "service_name", "data_dir", "bin_dir"):
        value = facts.get(name)
        if value:
            keys.add(f"{name}:{str(value).lower()}")
    return keys


def _merge_fact_batches(
    batches: list[list[dict[str, str]]],
) -> list[dict[str, object]]:
    """Fold fact dicts that describe the same server into one group.

    Two dicts belong together when they share an identity key (install
    directory, service name, data directory or bin directory), so a
    server reported by the registry *and* by the service manager ends up
    as a single instance.  Batches are processed in priority order and
    the first writer of a field wins, which is why the settings override
    runs first.
    """
    groups: list[dict[str, object]] = []
    for batch in batches:
        for facts in batch:
            if not facts:
                continue
            keys = _identity_keys(facts)
            matches = [
                group for group in groups if _identity_keys(group) & keys
            ] if keys else []
            if not matches:
                target: dict[str, object] = {"_sources": set()}
                groups.append(target)
            else:
                target = matches[0]
                for extra in matches[1:]:
                    for name, value in extra.items():
                        if name == "_sources":
                            target["_sources"].update(value)  # type: ignore[union-attr]
                        elif value:
                            target.setdefault(name, value)
                    groups.remove(extra)
            for name, value in facts.items():
                if name == "_source":
                    target["_sources"].add(value)  # type: ignore[union-attr]
                elif value:
                    target.setdefault(name, value)
    return groups


def _coerce(facts: dict[str, object]) -> PostgresInstance:
    """Turn merged facts into a typed instance (nothing is invented)."""
    major_text = facts.get("major")
    major = int(major_text) if isinstance(major_text, str) and major_text.isdigit() else None
    if major is None:
        major = parse_version_text(str(facts.get("version_text") or ""))
    port_text = facts.get("port")
    port = int(port_text) if isinstance(port_text, str) and port_text.isdigit() else None
    if port is None:
        port = _port_from_conf(_as_path(_text(facts, "data_dir")))

    sources = tuple(
        source
        for source in ("override", "registry", "filesystem", "service")
        if source in facts.get("_sources", set())  # type: ignore[operator]
    )
    return PostgresInstance(
        major=major,
        version_text=_text(facts, "version_text"),
        install_dir=_as_path(_text(facts, "install_dir")),
        bin_dir=_as_path(_text(facts, "bin_dir")),
        data_dir=_as_path(_text(facts, "data_dir")),
        service_name=_text(facts, "service_name"),
        service_state=_text(facts, "state"),
        port=port,
        superuser=_text(facts, "superuser"),
        service_account=_text(facts, "service_account"),
        psql=_as_path(_text(facts, "psql")),
        pg_dump=_as_path(_text(facts, "pg_dump")),
        pg_ctl=_as_path(_text(facts, "pg_ctl")),
        sources=sources,
    )


def _text(facts: dict[str, object], name: str) -> str | None:
    value = facts.get(name)
    return value if isinstance(value, str) and value else None


def _as_path(value: str | None) -> Path | None:
    return Path(value) if value else None


def discover_instances(
    *,
    include_overrides: bool = True,
    include_registry: bool = True,
    include_filesystem: bool = True,
    include_services: bool = True,
) -> list[PostgresInstance]:
    """Find every PostgreSQL server this machine appears to have.

    Strictly read-only: no connection, no service control, no writes.
    Sources are all consulted (they complement each other — a server may
    have a registry key but no service, or a service but no registry key)
    and their facts are merged per install directory / service name.
    """
    batches: list[list[dict[str, str]]] = []
    if include_overrides:
        override = _override_facts()
        batches.append([override] if override else [])
    if include_registry:
        batches.append(_registry_facts())
    if include_filesystem:
        batches.append(_filesystem_facts())
    if include_services:
        batches.append(_service_facts())

    instances = [_coerce(group) for group in _merge_fact_batches(batches)]

    # A port override with no identity of its own ("the server we mean is
    # on this port") applies to the instances we found; it never invents
    # an instance on its own.
    override_port = int(settings.PG_PORT or 0)
    if override_port:
        instances = [
            replace(item, port=override_port)
            if _override_matches(item) or len(instances) == 1
            else item
            for item in instances
        ]

    instances = _drop_empty(instances)
    instances.sort(
        key=lambda item: (
            item.major if item.major is not None else -1,
            str(item.install_dir or ""),
        ),
        reverse=True,
    )
    logger.debug(
        "pg_discovery_complete",
        count=len(instances),
        instances=[
            {
                "label": item.label,
                "state": item.service_state,
                "port": item.port,
                "sources": list(item.sources),
            }
            for item in instances
        ],
    )
    return instances


def _override_matches(instance: PostgresInstance) -> bool:
    """True when ``instance`` is the one the settings override names."""
    install = (settings.PG_INSTALL_DIR or "").strip()
    service = (settings.PG_SERVICE_NAME or "").strip()
    data_dir = (settings.PG_DATA_DIR or "").strip()
    if install and instance.install_dir is not None:
        return str(instance.install_dir).lower() == install.lower()
    if service and instance.service_name:
        return instance.service_name.lower() == service.lower()
    if data_dir and instance.data_dir is not None:
        return str(instance.data_dir).lower() == data_dir.lower()
    return False


def _drop_empty(instances: list[PostgresInstance]) -> list[PostgresInstance]:
    """Discard groups that carry no evidence of an actual server."""
    return [
        item
        for item in instances
        if item.install_dir is not None
        or item.data_dir is not None
        or item.service_name
        or item.major is not None
    ]


def select_instance(
    instances: list[PostgresInstance],
    *,
    require_running: bool = True,
    allow_unverified: bool = False,
) -> PostgresInstance | None:
    """Pick the instance to reuse.

    Preference order: running over stopped, verified over unverified,
    higher major over lower.  ``None`` when nothing qualifies — the
    caller then has to provision instead of reusing (§3).
    """
    best: PostgresInstance | None = None
    best_score: tuple[int, int, int] | None = None
    for instance in instances:
        compat = check_compatibility(instance)
        if not compat.accepted:
            continue
        if compat.verified is False and not allow_unverified:
            continue
        if require_running and not instance.is_running:
            continue
        score = (
            1 if instance.is_running else 0,
            1 if compat.verified else 0,
            instance.major if instance.major is not None else -1,
        )
        if best_score is None or score > best_score:
            best, best_score = instance, score
    return best


def with_port(instance: PostgresInstance, port: int) -> PostgresInstance:
    """Copy of ``instance`` reporting ``port`` (used by the planner)."""
    return replace(instance, port=port)
