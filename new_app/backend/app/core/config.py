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


settings = Settings()
