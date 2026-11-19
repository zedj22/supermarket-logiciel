"""Application configuration using Pydantic Settings.

R1 (Windows production data paths): the backend separates the read-only
**installation tree** (``C:\\Program Files\\Supermarket Pro``) from the
writable **runtime data root** (``C:\\ProgramData\\SupermarketPro``) and
resolves every configuration file through a deterministic absolute path
— never the process current working directory.  See
``docs/R1_DATA_PATHS.md`` for the full directory layout.
"""

from __future__ import annotations

import os
import warnings
from pathlib import Path
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.constants import PLACEHOLDER_SECRET_VALUES, PLACEHOLDER_SECRETS

#: Repository-local backend root (`new_app/backend`).  Absolute so a
#: relative launch directory can never scatter runtime files around the
#: machine — same reasoning as `SERVER_ID_FILE` (§8.2).
BACKEND_ROOT = Path(__file__).resolve().parents[2]

#: Production writable subdirectories created under ``DATA_DIR`` (R1 §2).
#: Development never creates them eagerly — it keeps the historical
#: on-write behaviour of the pre-R1 layout.
DATA_SUBDIRS: tuple[str, ...] = ("config", "license", "data", "backups", "logs")


class DataDirectoryError(RuntimeError):
    """The configured production data directory cannot be created or used.

    Raised at startup (lifespan) when ``DATA_DIR`` points at a missing or
    inaccessible location — fail fast with an actionable message instead
    of scattering 500s on every licensing or backup write later.
    """


def resolve_env_file() -> str:
    """Absolute path of the ``.env`` file — never CWD-relative (audit B4).

    Resolution order:

    1. ``DATA_DIR`` in the **process environment** (set by the installer
       or service wrapper) → ``<DATA_DIR>/config/.env`` — the production
       layout, writable by the service account.
    2. Otherwise → ``<backend>/.env`` — the development layout, exactly
       where the file lives today.

    The process environment is consulted deliberately: a ``.env`` file
    cannot be used to locate itself.  A ``DATA_DIR`` entry *inside* a
    dotenv file still configures the data paths (step 2 finds the file),
    it just cannot relocate the file itself.
    """
    data_dir = (os.environ.get("DATA_DIR") or "").strip()
    if data_dir:
        root = Path(data_dir)
        if not root.is_absolute():
            # Deterministic (backend root), never the process CWD.
            root = BACKEND_ROOT / root
        return str(root / "config" / ".env")
    return str(BACKEND_ROOT / ".env")


def data_root(cfg: BaseSettings | None = None) -> Path:
    """Writable runtime data root.

    ``DATA_DIR`` (production) when configured, otherwise the backend root
    (development) — identical to the pre-R1 locations.
    """
    target = settings if cfg is None else cfg
    raw = (getattr(target, "DATA_DIR", "") or "").strip()
    if raw:
        return Path(raw)
    return BACKEND_ROOT


#: Secrets shipped in the repository.  They are acceptable placeholders for
#: a development machine and fatal for a production one (§17.7).  Defined in
#: `app.core.constants` (imported above) so the R2 secret-provisioning module
#: can share the list without importing this module — provisioning has to run
#: *before* `Settings()` below is instantiated.  Re-exported here for the
#: existing Phase 17 test contract.


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=resolve_env_file(),
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Application
    APP_ENV: Literal["development", "testing", "production"] = "development"
    APP_SECRET_KEY: str = "change-me-in-production"
    VERSION: str = "0.1.0"

    # Database
    DATABASE_URL: str

    # JWT (prepared for Phase 4)
    JWT_SECRET_KEY: str = "jwt-change-me-in-production"
    JWT_ALGORITHM: str = "HS256"
    JWT_ACCESS_TOKEN_EXPIRE_MINUTES: int = 480

    # Session / Lockout
    SESSION_LIFETIME_MINUTES: int = 480
    LOCKOUT_THRESHOLD: int = 5
    LOCKOUT_DURATION_MINUTES: int = 15

    # Phase 17 §17.7 — rate limiting (roadmap Phase 3 "Rate limiting"; before
    # this pass only the Phase 16 *pairing* throttle existed, D-08).
    #
    # RATE_WINDOW_SECONDS is the sliding window both limits are counted in.
    # AUTH_RATE_LIMIT_PER_MINUTE caps PIN attempts per client IP (login,
    # reauth, first-admin setup); the per-account lockout above still applies
    # on top of it. API_RATE_LIMIT_PER_MINUTE is the app-wide backstop for
    # every /api/v1 request from one client IP — generous enough that a busy
    # till never notices, small enough to stop a flood.
    #
    # LICENSE_ACTIVATION_RATE_LIMIT_PER_MINUTE is the dedicated cap on
    # POST /license/activate attempts per client IP (Phase L2-A): key
    # guessing must be far slower than the app-wide backstop allows.
    RATE_WINDOW_SECONDS: int = 60
    AUTH_RATE_LIMIT_PER_MINUTE: int = 15
    API_RATE_LIMIT_PER_MINUTE: int = 1200
    LICENSE_ACTIVATION_RATE_LIMIT_PER_MINUTE: int = 10

    # CORS
    CORS_ORIGINS: list[str] = ["http://localhost:3000", "http://localhost:8080"]

    # Logging
    LOG_LEVEL: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"

    # Server
    HOST: str = "127.0.0.1"
    PORT: int = 8000

    # ── R1 — Windows production data paths ────────────────────────────
    #
    # DATA_DIR is the writable runtime data root that separates customer
    # data from the read-only installation tree (audit B7):
    #
    #   production   DATA_DIR = C:\ProgramData\SupermarketPro
    #     config  → <DATA_DIR>\config\      (.env generated by installer)
    #     license → <DATA_DIR>\license\     (trial + Lifetime state)
    #     data    → <DATA_DIR>\data\        (server_id, application data)
    #     backups → <DATA_DIR>\backups\     (pg_dump output + manifests)
    #     logs    → <DATA_DIR>\logs\        (service stdout/stderr target)
    #
    # development   DATA_DIR empty (default) — every path keeps its
    # historical location next to the backend: <backend>\data\license,
    # <backend>\data\server_id, <backend>\backups, <backend>\.env.
    #
    # DATA_DIR must be set in the PROCESS environment to relocate the
    # .env file itself (see resolve_env_file); an entry inside the
    # dotenv file also configures the data paths above.  Never point
    # DATA_DIR inside Program Files — the backend must run without
    # write permission to the install tree.  Full layout + migration
    # procedure: docs/R1_DATA_PATHS.md.
    DATA_DIR: str = ""

    # Log directory — now OPERATIONAL (R2).  Empty resolves to
    # <DATA_DIR>\logs in production, <backend>\logs in development, and
    # when file logging is enabled (below) the rotating application log
    # is written straight into it.  The service wrapper additionally
    # redirects raw process stdout/stderr into the same directory.
    LOG_DIR: str = ""

    # ── R2 — production file logging ─────────────────────────────────
    #
    # LOG_FILE_ENABLED selects the rotating file sink under LOG_DIR:
    #   ""  (default) auto — ON when DATA_DIR is set (production),
    #                     OFF in development (stdout only, unchanged
    #                     from the pre-R2 behaviour).
    #   "1" / "true"  force the sink on (handy for development).
    #   "0" / "false" force it off even in production.
    # An empty value is legal so a copied .env.example never breaks.
    #
    # Rotation is size based: LOG_MAX_BYTES bytes per file, then
    # LOG_BACKUP_COUNT rotated files are retained (backend.log,
    # backend.log.1 … backend.log.N; the oldest is deleted first).
    # Total retained log volume ≈ LOG_MAX_BYTES * (LOG_BACKUP_COUNT + 1).
    LOG_FILE_ENABLED: str = ""
    LOG_FILE_NAME: str = "backend.log"
    LOG_MAX_BYTES: int = 5 * 1024 * 1024
    LOG_BACKUP_COUNT: int = 10

    # Store defaults (Phase 2+ will expand these)
    STORE_NAME: str = "Supermarket Pro"

    # Phase 16 — LAN / multi-PC.
    #
    # LAN_MODE turns on the router-level device guard (X-Device-ID +
    # X-Device-Token enforcement) for every /api/v1 route outside the
    # explicit allowlist.  It is OFF by default so single-PC behaviour
    # (and the whole pre-Phase-16 test suite) is bit-for-bit unchanged.
    #
    # DISCOVERY_ENABLED starts the UDP discovery responder in the app
    # lifespan.  DISCOVERY_PORT defaults to the SAME NUMBER as HTTP so a
    # store only ever has to remember/open one port number (owner Q13).
    # Both are plain numbers, never a secret.
    #
    # LAN-only: this phase never exposes the service to WAN/Internet
    # (owner Q5) and does not terminate TLS (owner Q8).
    LAN_MODE: bool = False
    DISCOVERY_ENABLED: bool = False
    DISCOVERY_PORT: int = 8000

    # Stable server identity (§8.2).  SERVER_ID overrides the persisted
    # file; SERVER_ID_FILE is the identity file that is created on first
    # start.  It is not a secret (it is echoed by /system/info).  R1:
    # always resolved to an ABSOLUTE path (never CWD-relative) —
    # `<backend>/data/server_id` in development, `<DATA_DIR>/data/server_id`
    # in production.
    SERVER_ID: str = ""
    SERVER_ID_FILE: str = "data/server_id"

    # Phase 17 §17.2 — backup / restore.
    #
    # A backup is a plain `.sql` written by `pg_dump` plus a JSON sidecar
    # manifest; both live in BACKUP_DIR.  An empty BACKUP_DIR resolves to
    # `<backend>/backups` (development) or `<DATA_DIR>/backups`
    # (production, R1); a relative value resolves against the same root.
    # The tools are located through PG_DUMP_PATH / PSQL_PATH first, then
    # PATH, then the standard PostgreSQL install directories — `pg_dump`
    # is NOT on PATH on this machine.
    BACKUP_DIR: str = ""
    BACKUP_TIMEOUT_SECONDS: int = 300
    PG_DUMP_PATH: str = ""
    PSQL_PATH: str = ""

    # ── R3 — PostgreSQL discovery / provisioning ─────────────────────
    #
    # Discovery (app/core/postgres_discovery.py) is strictly READ-ONLY and
    # never connects to a database.  It looks for an existing server in
    # this order, stopping at the first source that yields an instance:
    #
    #   1. the explicit overrides below (administrator / installer);
    #   2. HKLM\SOFTWARE\PostgreSQL\Installations\* registry keys;
    #   3. C:\Program Files\PostgreSQL\*\bin\psql.exe (and x86) on disk;
    #   4. Windows services whose name starts with "postgresql".
    #
    # Every override is optional and empty by default; a wrong override
    # fails closed (discovery reports nothing usable) rather than guessing.
    # PG_PORT is 0 = "let discovery read the port from the data dir's
    # postgresql.conf" (never a hardcoded 5432 assumption).
    PG_INSTALL_DIR: str = ""
    PG_BIN_DIR: str = ""
    PG_DATA_DIR: str = ""
    PG_SERVICE_NAME: str = ""
    PG_PORT: int = 0

    # Licensing — Phase L0 foundations + Phase L1 trial (v2 §11.2 / §12).
    #
    # LICENSE_ENFORCEMENT selects the router-level license-guard mode:
    #   "off"   (default) — the guard is a complete no-op: no request is
    #           altered, current behaviour is bit-for-bit unchanged. This
    #           is the only mode the shipped configuration enables.
    #   "trial" (Phase L1) — the Free Trial engine enforces the approved
    #           10-calendar-day trial: expired installs get 403
    #           trial_expired, a missing trial 403 license_required, an
    #           unverifiable trial 503 license_status_unavailable.
    #   "on"    (Phase L2-B) — the combined decision: a valid Lifetime
    #           license (re-verified on every request) or an active trial
    #           admits business routes; without one, expired/missing
    #           state is 403 trial_expired / license_required and
    #           unverifiable state 503 license_status_unavailable.
    # Never treat "cannot tell" as "licensed".
    #
    # LICENSE_STATE_DIR is the file-based license/trial state directory.
    # It is deliberately OUTSIDE PostgreSQL so a `pg_dump` backup or
    # restore can never carry licensing state (§7.5) and a restored
    # database cannot resurrect a consumed trial.  Empty resolves to
    # `<backend>/data/license` (development) or `<DATA_DIR>/license`
    # (production, R1); always absolute.
    #
    # TRIAL_DAYS is the trial length in calendar days (approved: 10 days
    # / 240 elapsed hours from the first backend start, §6.2).
    #
    # LICENSE_VERIFICATION_KEYS_FILE is the packaged PUBLIC Ed25519 key
    # file read by the Phase L2-A LicenseManager (§10.1).  It ships inside
    # the application — `app/licensing/verification_keys.json` — and is
    # NOT customer state: it never lives in LICENSE_STATE_DIR, is never
    # written at runtime and never carries private key material.  Empty
    # resolves to that packaged default; tests point it at a temporary
    # file.  See app/licensing/verification_keys.README.md.
    LICENSE_ENFORCEMENT: Literal["off", "trial", "on"] = "off"
    LICENSE_STATE_DIR: str = ""
    TRIAL_DAYS: int = 10
    LICENSE_VERIFICATION_KEYS_FILE: str = ""

    # NOTE (R1): these path validators run in definition order.
    # `_resolve_data_dir` first, so every later validator sees an
    # absolute DATA_DIR (or the empty development default).

    @model_validator(mode="after")
    def _resolve_data_dir(self) -> Settings:
        raw = (self.DATA_DIR or "").strip()
        if raw:
            root = Path(raw)
            if not root.is_absolute():
                # Deterministic base (backend root), never the process CWD.
                root = BACKEND_ROOT / root
            self.DATA_DIR = str(root)
        return self

    @model_validator(mode="after")
    def _resolve_license_state_dir(self) -> Settings:
        raw = (self.LICENSE_STATE_DIR or "").strip()
        if raw:
            path = Path(raw)
            if not path.is_absolute():
                root = Path(self.DATA_DIR) if self.DATA_DIR else BACKEND_ROOT
                path = root / path
            self.LICENSE_STATE_DIR = str(path)
        elif self.DATA_DIR:
            # Production: top-level `license/` in the data root.
            self.LICENSE_STATE_DIR = str(Path(self.DATA_DIR) / "license")
        else:
            # Development: unchanged pre-R1 location.
            self.LICENSE_STATE_DIR = str(BACKEND_ROOT / "data" / "license")
        if self.TRIAL_DAYS < 1:
            raise ValueError("TRIAL_DAYS must be at least 1 day")
        return self

    @model_validator(mode="after")
    def _resolve_server_id_file(self) -> Settings:
        raw = (self.SERVER_ID_FILE or "").strip() or "data/server_id"
        path = Path(raw)
        if not path.is_absolute():
            # R1 (audit B4/B7): relative values used to follow the CWD.
            root = Path(self.DATA_DIR) if self.DATA_DIR else BACKEND_ROOT
            path = root / path
        self.SERVER_ID_FILE = str(path)
        return self

    @model_validator(mode="after")
    def _resolve_log_dir(self) -> Settings:
        raw = (self.LOG_DIR or "").strip()
        if raw:
            path = Path(raw)
            if not path.is_absolute():
                root = Path(self.DATA_DIR) if self.DATA_DIR else BACKEND_ROOT
                path = root / path
            self.LOG_DIR = str(path)
        else:
            root = Path(self.DATA_DIR) if self.DATA_DIR else BACKEND_ROOT
            self.LOG_DIR = str(root / "logs")
        return self

    @model_validator(mode="after")
    def _validate_log_settings(self) -> Settings:
        """Normalise and sanity-check the R2 file-logging settings."""
        flag = (self.LOG_FILE_ENABLED or "").strip().lower()
        if flag and flag not in ("1", "0", "true", "false", "yes", "no", "on", "off"):
            raise ValueError(
                "LOG_FILE_ENABLED must be empty (auto), 1/0, true/false, "
                f"yes/no or on/off — got {self.LOG_FILE_ENABLED!r}"
            )
        self.LOG_FILE_ENABLED = flag
        name = (self.LOG_FILE_NAME or "").strip()
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            raise ValueError(
                "LOG_FILE_NAME must be a bare file name inside LOG_DIR — "
                f"got {self.LOG_FILE_NAME!r}"
            )
        self.LOG_FILE_NAME = name
        if self.LOG_MAX_BYTES < 1024:
            raise ValueError("LOG_MAX_BYTES must be at least 1024 bytes")
        if self.LOG_BACKUP_COUNT < 0:
            raise ValueError("LOG_BACKUP_COUNT must not be negative")
        return self

    @model_validator(mode="after")
    def _resolve_verification_keys_file(self) -> Settings:
        raw = (self.LICENSE_VERIFICATION_KEYS_FILE or "").strip()
        if not raw:
            self.LICENSE_VERIFICATION_KEYS_FILE = str(
                Path(__file__).resolve().parents[1]
                / "licensing"
                / "verification_keys.json"
            )
        return self

    # R4 — production enforcement default (docs/R4_PRODUCTION_LICENSING.md §3).
    #
    # Development keeps the historical default: LICENSE_ENFORCEMENT is
    # "off", the guard is a complete no-op, and nothing changes until a
    # developer opts in.  Production must not inherit that silence — a
    # customer's installer-written configuration that simply forgets the
    # key would otherwise ship with licensing disabled.  So when
    # APP_ENV=production and no value was supplied for the setting, the
    # mode falls back to "trial" (the Free Trial engine), never "off".
    #
    # An explicitly supplied value is always honoured, including an
    # explicit "off" — that stays a deliberate owner decision, and the
    # lifespan logs a warning whenever it is taken (R4 §3).  A blank or
    # unknown value never reaches this fallback: pydantic's Literal
    # rejects it at startup rather than silently disabling enforcement.
    #
    # `model_fields_set` is what distinguishes "supplied" from "default":
    # pydantic-settings records a field there only when the environment,
    # the dotenv file or the caller actually provided it (verified by
    # tests/unit/test_production_enforcement_config.py).
    @model_validator(mode="after")
    def _production_enforcement_default(self) -> Settings:
        if (
            self.APP_ENV == "production"
            and "LICENSE_ENFORCEMENT" not in self.model_fields_set
        ):
            self.LICENSE_ENFORCEMENT = "trial"
        return self

    # Phase 17 §17.7 — the repository placeholders sign every JWT, so
    # production must refuse to boot with them (development only warns:
    # this install runs APP_ENV=development with the shipped values).
    # R2: membership is checked against PLACEHOLDER_SECRET_VALUES, which
    # also contains the `.env.example` copy-paste strings — a production
    # start must reject those too.
    @model_validator(mode="after")
    def _reject_placeholder_secrets(self) -> Settings:
        insecure = [
            name
            for name in PLACEHOLDER_SECRETS
            if not getattr(self, name).strip()
            or getattr(self, name).strip() in PLACEHOLDER_SECRET_VALUES
        ]
        if not insecure:
            return self
        names = ", ".join(insecure)
        if self.APP_ENV == "production":
            raise ValueError(
                f"{names} still hold the repository placeholder; generate a "
                "unique secret before running with APP_ENV=production"
            )
        warnings.warn(
            f"{names} use the repository placeholder - anyone who knows them can "
            "forge sessions; generate unique secrets",
            UserWarning,
            stacklevel=2,
        )
        return self


def ensure_data_dirs(cfg: Settings | None = None) -> list[Path]:
    """Create the production data layout; development is a no-op (R1).

    With ``DATA_DIR`` configured, every subdirectory of ``DATA_SUBDIRS``
    is created (missing parents included).  A directory that cannot be
    created — missing parent that is really a file, no write permission,
    full disk — raises :class:`DataDirectoryError` so the lifespan fails
    fast with an actionable message instead of 500-ing on every licensing
    or backup write later.

    Without ``DATA_DIR`` nothing is touched: development keeps the
    historical lazy, on-write behaviour (StateStore / server identity /
    BackupService already create their own directories).
    """
    target = settings if cfg is None else cfg
    raw = (getattr(target, "DATA_DIR", "") or "").strip()
    if not raw:
        return []
    root = Path(raw)
    created: list[Path] = []
    for name in DATA_SUBDIRS:
        directory = root / name
        try:
            existed = directory.is_dir()
            directory.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise DataDirectoryError(
                f"production data directory {directory} cannot be created "
                f"({exc}); check that DATA_DIR={root} exists and the "
                "service account has write permission to it"
            ) from exc
        if not existed:
            created.append(directory)
    return created


def legacy_data_locations(
    cfg: Settings | None = None, *, backend_root: Path | None = None
) -> list[Path]:
    """Writable locations inside the install tree that predate R1.

    With ``DATA_DIR`` configured, report — but never move, copy or delete
    — any data still sitting in the historical in-tree locations
    (``<backend>/data/license``, ``<backend>/data/server_id``,
    ``<backend>/backups``).  The caller logs each hit so the operator
    migrates manually (docs/R1_DATA_PATHS.md §Migration).  Development
    (no ``DATA_DIR``) returns nothing: those locations *are* the live
    data there.
    """
    target = settings if cfg is None else cfg
    raw = (getattr(target, "DATA_DIR", "") or "").strip()
    if not raw:
        return []
    root = backend_root if backend_root is not None else BACKEND_ROOT
    found: list[Path] = []
    for candidate in (root / "data" / "license", root / "data" / "server_id", root / "backups"):
        try:
            if candidate.is_file():
                found.append(candidate)
            elif candidate.is_dir() and any(candidate.iterdir()):
                found.append(candidate)
        except OSError:
            # An unreadable legacy location is not ours to judge here;
            # this is only a migration hint, never a gate.
            continue
    return found


settings = Settings()
