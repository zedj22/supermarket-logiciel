"""Application configuration using Pydantic Settings."""

from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


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


settings = Settings()
