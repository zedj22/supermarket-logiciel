"""Application configuration using Pydantic Settings."""

from __future__ import annotations

import warnings
from pathlib import Path
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

#: Repository-local backend root (`new_app/backend`).  Absolute so a
#: relative launch directory can never scatter runtime files around the
#: machine — same reasoning as `SERVER_ID_FILE` (§8.2).
BACKEND_ROOT = Path(__file__).resolve().parents[2]

#: Secrets shipped in the repository.  They are acceptable placeholders for
#: a development machine and fatal for a production one (§17.7).
PLACEHOLDER_SECRETS: dict[str, str] = {
    "APP_SECRET_KEY": "change-me-in-production",
    "JWT_SECRET_KEY": "jwt-change-me-in-production",
}


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
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
    RATE_WINDOW_SECONDS: int = 60
    AUTH_RATE_LIMIT_PER_MINUTE: int = 15
    API_RATE_LIMIT_PER_MINUTE: int = 1200

    # CORS
    CORS_ORIGINS: list[str] = ["http://localhost:3000", "http://localhost:8080"]

    # Logging
    LOG_LEVEL: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"

    # Server
    HOST: str = "127.0.0.1"
    PORT: int = 8000

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
    # file; SERVER_ID_FILE is the backend-local file that is created on
    # first start.  It is not a secret (it is echoed by /system/info).
    SERVER_ID: str = ""
    SERVER_ID_FILE: str = "data/server_id"

    # Phase 17 §17.2 — backup / restore.
    #
    # A backup is a plain `.sql` written by `pg_dump` plus a JSON sidecar
    # manifest; both live in BACKUP_DIR.  An empty BACKUP_DIR resolves to
    # `<backend>/backups`.  The tools are located through PG_DUMP_PATH /
    # PSQL_PATH first, then PATH, then the standard PostgreSQL install
    # directories — `pg_dump` is NOT on PATH on this machine.
    BACKUP_DIR: str = ""
    BACKUP_TIMEOUT_SECONDS: int = 300
    PG_DUMP_PATH: str = ""
    PSQL_PATH: str = ""

    # Phase 17 §17.7 — the repository placeholders sign every JWT, so
    # production must refuse to boot with them (development only warns:
    # this install runs APP_ENV=development with the shipped values).
    @model_validator(mode="after")
    def _reject_placeholder_secrets(self) -> Settings:
        insecure = [
            name
            for name, placeholder in PLACEHOLDER_SECRETS.items()
            if not getattr(self, name).strip() or getattr(self, name).strip() == placeholder
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
            f"{names} use the repository placeholder — anyone who knows them can "
            "forge sessions; generate unique secrets",
            UserWarning,
            stacklevel=2,
        )
        return self


settings = Settings()
