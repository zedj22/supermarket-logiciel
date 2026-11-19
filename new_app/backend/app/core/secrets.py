"""Per-install secret provisioning for the production runtime (R2).

``APP_SECRET_KEY`` and ``JWT_SECRET_KEY`` must be unique per installation:
the repository placeholders (and the `.env.example` copy-paste values) can
forge sessions for *every* install that ships them.  The installer would
normally generate them; R2 ships the first-run mechanism itself.

Storage
-------
``<DATA_DIR>/config/secrets.env`` — a sibling of the installer-written
``<DATA_DIR>/config/.env``, inside the protected ProgramData tree::

    # Supermarket Pro - per-install secrets, generated on first start.
    APP_SECRET_KEY=<64 URL-safe chars>
    JWT_SECRET_KEY=<64 URL-safe chars>

The values are written with ``secrets.token_urlsafe(48)`` (384 bits of
CSPRNG output) and are pushed into ``os.environ`` so they outrank the
dotenv file, which is where a copied placeholder would otherwise live.

Guarantees
----------

* **Generated once** — the file is created with ``O_CREAT | O_EXCL``; an
  existing file is *never* rewritten, so restarts and upgrades cannot
  rotate a customer's secrets (and invalidate every active session).
* **Fail closed** — a file that exists but is unreadable, truncated,
  missing a key, malformed or holding a placeholder raises
  :class:`SecretsError` and is left byte-for-byte untouched.  The
  load-only path (:func:`load_production_secrets`) additionally raises
  :class:`SecretsMissingError` when the file is absent.
* **Installer-provided secrets win** — when ``.env`` already carries real
  values for both keys nothing is generated, so an installer that wrote
  its own secrets keeps them.
* **Never logged** — every error message names the *key* and the *path*,
  never a value; :mod:`app.core.logging` additionally scrubs the actual
  secret values out of every rendered log line.

This module deliberately imports nothing from :mod:`app.core.config`:
the launcher must provision secrets *before* ``Settings()`` is
instantiated, or the placeholder validator would fire first.
"""

from __future__ import annotations

import os
import re
import secrets as _random
from dataclasses import dataclass
from pathlib import Path

from app.core.constants import PLACEHOLDER_SECRET_VALUES

__all__ = [
    "DATABASE_ENV_FILE_NAME",
    "DATABASE_SECRET_KEYS",
    "PLACEHOLDER_SECRET_VALUES",
    "REQUIRED_SECRET_KEYS",
    "SECRETS_FILE_NAME",
    "DatabaseSecretsResult",
    "SecretsError",
    "SecretsMissingError",
    "SecretsProvisioningResult",
    "apply_secrets_to_environment",
    "database_env_file",
    "ensure_database_password",
    "ensure_production_secrets",
    "load_database_password",
    "load_production_secrets",
    "resolve_data_dir",
    "secrets_file_for",
]

#: File name inside ``<DATA_DIR>/config/``.
SECRETS_FILE_NAME = "secrets.env"

#: R3: the application *database role* password, generated once by the
#: provisioning pass.  Deliberately a SEPARATE file from ``secrets.env``:
#: R2's contract is that ``secrets.env`` is created once and never
#: rewritten, and appending a third key later would break it for every
#: installation that already has the file.  Same exclusivity rules apply.
DATABASE_ENV_FILE_NAME = "database.env"

#: Every key the per-install file must define.
REQUIRED_SECRET_KEYS: tuple[str, ...] = ("APP_SECRET_KEY", "JWT_SECRET_KEY")

#: Keys owned by ``database.env``.
DATABASE_SECRET_KEYS: tuple[str, ...] = ("DATABASE_PASSWORD",)

#: Shortest value we accept.  `token_urlsafe(48)` produces 64 characters;
#: 32 is the floor that also matches the Phase 17 "real looking secret"
#: contract used by the settings tests.
_MIN_SECRET_LENGTH = 32

#: URL-safe alphabet only: nothing that could break dotenv parsing or
#: smuggle a newline/quote into the generated file.
_SECRET_VALUE_RE = re.compile(r"^[A-Za-z0-9_\-]{32,512}$")

_ENV_LINE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")

#: Mirrors `config.BACKEND_ROOT` (a relative process ``DATA_DIR`` anchors
#: to the backend root, never the CWD) — duplicated rather than imported
#: to keep this module free of any `app.core.config` import.
_BACKEND_ROOT = Path(__file__).resolve().parents[2]


class SecretsError(RuntimeError):
    """The per-install secret file exists but cannot be trusted.

    Fail closed: the caller must abort startup.  The file is never
    repaired, regenerated or overwritten in place.
    """


class SecretsMissingError(SecretsError):
    """No secret file exists and generation was not permitted."""


@dataclass(frozen=True)
class SecretsProvisioningResult:
    """Outcome of one provisioning pass (never contains log-forbidden data)."""

    path: Path
    data: dict[str, str]
    #: ``"generated"`` (first run), ``"file"`` (existing file) or
    #: ``"dotenv"`` (the installer already put real secrets in ``.env``).
    source: str
    created: bool


@dataclass(frozen=True)
class DatabaseSecretsResult:
    """Outcome of a ``database.env`` provisioning pass (R3)."""

    path: Path
    #: The database password when it was generated or loaded from file;
    #: empty when an externally supplied credential was used instead.
    password: str
    source: str  # "generated" | "file" | "external"
    created: bool


def resolve_data_dir(data_dir: str | Path | None = None) -> Path:
    """Absolute production data root (process ``DATA_DIR`` when omitted)."""
    raw = str(data_dir) if data_dir is not None else (os.environ.get("DATA_DIR") or "")
    raw = raw.strip()
    if not raw:
        raise SecretsError(
            "DATA_DIR is not set; production secrets need an explicit "
            "writable data root (e.g. C:\\ProgramData\\SupermarketPro)"
        )
    path = Path(raw)
    if not path.is_absolute():
        path = _BACKEND_ROOT / path
    return path


def secrets_file_for(data_dir: str | Path) -> Path:
    """Absolute path of the per-install secret file."""
    return Path(data_dir) / "config" / SECRETS_FILE_NAME


def apply_secrets_to_environment(values: dict[str, str]) -> None:
    """Publish ``values`` through ``os.environ`` (never overriding an
    explicitly exported variable — process environment still wins)."""
    for key in REQUIRED_SECRET_KEYS:
        value = values.get(key)
        if value:
            os.environ.setdefault(key, value)


def _validate_secret(name: str, value: str, source: Path) -> str:
    """Return a usable secret or raise.  Never echoes the value."""
    candidate = value.strip()
    if not candidate or candidate in PLACEHOLDER_SECRET_VALUES:
        raise SecretsError(
            f"{source}: {name} is empty or still a repository placeholder; "
            "refusing to start (delete the file only if you accept "
            "invalidating every active session)"
        )
    if len(candidate) < _MIN_SECRET_LENGTH or not _SECRET_VALUE_RE.match(candidate):
        raise SecretsError(
            f"{source}: {name} is malformed (expected {_MIN_SECRET_LENGTH}+ "
            "URL-safe characters); refusing to start"
        )
    return candidate


def _parse_env_text(text: str, source: Path) -> dict[str, str]:
    """Parse ``KEY=VALUE`` lines strictly; raise on any malformed input."""
    values: dict[str, str] = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = _ENV_LINE_RE.match(line)
        if match is None:
            raise SecretsError(f"{source}:{lineno}: malformed line")
        key, raw = match.group(1), match.group(2).strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
            raw = raw[1:-1]
        if key in values:
            raise SecretsError(f"{source}:{lineno}: duplicate key {key}")
        values[key] = raw
    return values


def parse_secrets_file(path: str | Path) -> dict[str, str]:
    """Read and strictly validate an existing secret file.

    Raises :class:`SecretsMissingError` when absent and
    :class:`SecretsError` for anything untrustworthy — truncated files,
    binary garbage, missing keys, placeholders, too-short values.
    """
    target = Path(path)
    try:
        text = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SecretsMissingError(f"missing per-install secret file: {target}") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise SecretsError(f"cannot read {target} ({exc.__class__.__name__})") from exc

    parsed = _parse_env_text(text, target)
    result: dict[str, str] = {}
    for key in REQUIRED_SECRET_KEYS:
        if key not in parsed:
            raise SecretsError(f"{target}: missing required key {key}")
        result[key] = _validate_secret(key, parsed[key], target)
    return result


def _dotenv_provides_real_secrets(env_path: Path) -> bool:
    """True when the installer-written ``.env`` already holds real secrets."""
    try:
        text = env_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    try:
        parsed = _parse_env_text(text, env_path)
    except SecretsError:
        return False
    for key in REQUIRED_SECRET_KEYS:
        value = (parsed.get(key) or "").strip()
        if not value or value in PLACEHOLDER_SECRET_VALUES:
            return False
    return True


def _write_new_secrets_file(
    path: Path,
    values: dict[str, str],
    *,
    header: str = "",
    keys: tuple[str, ...] = REQUIRED_SECRET_KEYS,
) -> bool:
    """Create ``path`` exclusively; ``False`` when it already exists.

    Never overwrites: a concurrent first run (or a file created by an
    installer between our check and this call) simply loses the race and
    the caller loads the winner instead.
    """
    if not header:
        header = (
            "# Supermarket Pro - per-install secrets, generated on first start.\n"
            "# Do not edit, do not copy to another installation, never commit.\n"
            "# Deleting or corrupting this file invalidates every active session.\n"
        )
    body = "".join(f"{key}={values[key]}\n" for key in keys if key in values)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise SecretsError(
            f"cannot create {path.parent} ({exc.__class__.__name__}); "
            "check that DATA_DIR exists and the service account may write to it"
        ) from exc
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    except OSError as exc:
        raise SecretsError(f"cannot create {path} ({exc.__class__.__name__})") from exc
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(header + body)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as exc:
        try:
            path.unlink()
        except OSError:
            pass
        raise SecretsError(f"cannot write {path} ({exc.__class__.__name__})") from exc
    return True


def ensure_production_secrets(
    data_dir: str | Path | None = None, *, generate_if_missing: bool = True
) -> SecretsProvisioningResult:
    """Load (or, on first run, generate) this installation's secrets.

    Order:

    1. File present → parse and validate it (fail closed on anything
       malformed; the file is never touched).
    2. File absent and ``generate_if_missing`` is false → raise
       :class:`SecretsMissingError`.
    3. File absent and ``.env`` already defines both keys for real →
       nothing to do (installer-provided secrets win).
    4. Otherwise → generate both keys and create the file exclusively.

    Valid values are published into ``os.environ`` with ``setdefault`` so
    an explicitly exported variable still outranks them.
    """
    root = resolve_data_dir(data_dir)
    path = secrets_file_for(root)

    if path.exists():
        values = parse_secrets_file(path)
        apply_secrets_to_environment(values)
        return SecretsProvisioningResult(path, values, "file", created=False)

    if not generate_if_missing:
        raise SecretsMissingError(f"missing per-install secret file: {path}")

    if _dotenv_provides_real_secrets(root / "config" / ".env"):
        apply_secrets_to_environment({})
        return SecretsProvisioningResult(path, {}, "dotenv", created=False)

    generated = {key: _random.token_urlsafe(48) for key in REQUIRED_SECRET_KEYS}
    if _write_new_secrets_file(path, generated):
        apply_secrets_to_environment(generated)
        return SecretsProvisioningResult(path, generated, "generated", created=True)

    # Lost the first-run race: another process created the file first.
    values = parse_secrets_file(path)
    apply_secrets_to_environment(values)
    return SecretsProvisioningResult(path, values, "file", created=False)


def load_production_secrets(
    data_dir: str | Path | None = None,
) -> SecretsProvisioningResult:
    """Load-only variant: never creates anything, fails when absent."""
    return ensure_production_secrets(data_dir, generate_if_missing=False)


# ─────────────────────────────────────────────────────────────────────────
# R3 — application database role password (``database.env``)
# ─────────────────────────────────────────────────────────────────────────


def database_env_file(data_dir: str | Path) -> Path:
    """Absolute path of the database credential file."""
    return Path(data_dir) / "config" / DATABASE_ENV_FILE_NAME


def _parse_database_file(path: Path) -> dict[str, str]:
    """Read and strictly validate an existing ``database.env``."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SecretsMissingError(f"missing database secret file: {path}") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise SecretsError(f"cannot read {path} ({exc.__class__.__name__})") from exc

    parsed = _parse_env_text(text, path)
    result: dict[str, str] = {}
    for key in DATABASE_SECRET_KEYS:
        if key not in parsed:
            raise SecretsError(f"{path}: missing required key {key}")
        # database.env accepts both the generated (URL-safe, 43 chars)
        # and the installer-supplied form validated on write; see
        # `_validate_external_password`.
        result[key] = _validate_external_password(parsed[key], path)
    return result


def _validate_external_password(value: str, source: Path) -> str:
    """Lengthier check for an operator-supplied password.

    Unlike the generated ones an external password is not ours to choose,
    so the URL-safe alphabet is not enforced — but it must be non-empty
    and must not be able to break the ``KEY=VALUE`` file format.
    """
    # Never silently trim: a password is a byte string the server must
    # accept exactly as stored, so leading/trailing whitespace is rejected
    # explicitly instead of being "cleaned" away.
    if not value or not value.strip():
        raise SecretsError(f"{source}: DATABASE_PASSWORD is empty")
    if value != value.strip():
        raise SecretsError(
            f"{source}: DATABASE_PASSWORD must not start or end with "
            "whitespace (it is used verbatim)"
        )
    candidate = value
    if candidate in PLACEHOLDER_SECRET_VALUES:
        raise SecretsError(
            f"{source}: DATABASE_PASSWORD is still a repository placeholder"
        )
    if len(candidate) < 8 or any(ch in candidate for ch in "\r\n\"'"):
        raise SecretsError(
            f"{source}: DATABASE_PASSWORD must be at least 8 characters and "
            "must not contain quotes or line breaks"
        )
    return candidate


def ensure_database_password(
    data_dir: str | Path | None = None,
    *,
    external: str | None = None,
    generate_if_missing: bool = True,
) -> DatabaseSecretsResult:
    """Load (or, on first provisioning run, generate) the role password.

    Same guarantees as :func:`ensure_production_secrets`: created once
    with ``O_CREAT | O_EXCL``, an existing file is never rewritten, a
    malformed one fails closed and is left untouched, and the value is
    never logged.  ``secrets.env`` is not modified in any way.

    ``external`` is a password the installer already placed in
    ``DATABASE_URL``; it is persisted so later provisioning runs see the
    same credential instead of minting a second one.
    """
    root = resolve_data_dir(data_dir)
    path = database_env_file(root)

    if path.exists():
        values = _parse_database_file(path)
        return DatabaseSecretsResult(
            path, values["DATABASE_PASSWORD"], "file", created=False
        )

    if external:
        password = _validate_external_password(external, path)
        values = {"DATABASE_PASSWORD": password}
        created = _write_new_secrets_file(
            path,
            values,
            header=(
                "# Supermarket Pro - application database role password (R3).\n"
                "# Generated once by the provisioning pass; never rewritten.\n"
                "# Referenced by DATABASE_URL; do not commit, do not copy.\n"
            ),
            keys=DATABASE_SECRET_KEYS,
        )
        if not created:
            values = _parse_database_file(path)
            return DatabaseSecretsResult(
                path, values["DATABASE_PASSWORD"], "file", created=False
            )
        return DatabaseSecretsResult(path, password, "external", created=True)

    if not generate_if_missing:
        raise SecretsMissingError(f"missing database secret file: {path}")

    password = _random.token_urlsafe(32)
    values = {"DATABASE_PASSWORD": password}
    if _write_new_secrets_file(
        path,
        values,
        header=(
            "# Supermarket Pro - application database role password (R3).\n"
            "# Generated once by the provisioning pass; never rewritten.\n"
            "# Referenced by DATABASE_URL; do not commit, do not copy.\n"
        ),
        keys=DATABASE_SECRET_KEYS,
    ):
        return DatabaseSecretsResult(path, password, "generated", created=True)

    # Lost the first-run race: another process created the file first.
    values = _parse_database_file(path)
    return DatabaseSecretsResult(path, values["DATABASE_PASSWORD"], "file", created=False)


def load_database_password(
    data_dir: str | Path | None = None,
) -> str | None:
    """Read-only accessor; ``None`` when no file exists yet."""
    root = resolve_data_dir(data_dir)
    path = database_env_file(root)
    if not path.exists():
        return None
    return _parse_database_file(path)["DATABASE_PASSWORD"]
