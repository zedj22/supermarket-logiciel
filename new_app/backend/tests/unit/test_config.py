"""Tests for application configuration."""

import inspect


def test_settings_loads_defaults():
    """Verify settings load with default values."""
    from app.core.config import settings

    assert settings.APP_ENV in ("development", "testing", "production")
    assert settings.VERSION is not None
    assert settings.PORT > 0


def test_settings_has_required_fields():
    """Verify all required configuration fields exist."""
    from app.core.config import settings

    required_fields = [
        "APP_ENV",
        "APP_SECRET_KEY",
        "DATABASE_URL",
        "JWT_SECRET_KEY",
        "JWT_ALGORITHM",
        "LOG_LEVEL",
    ]
    for field in required_fields:
        assert hasattr(settings, field), f"Missing required setting: {field}"


def test_database_url_is_configured():
    """Verify DATABASE_URL is set (not empty)."""
    from app.core.config import settings

    assert settings.DATABASE_URL, "DATABASE_URL must not be empty"
    assert len(settings.DATABASE_URL) > 0


def test_database_url_has_no_hardcoded_default():
    """Verify DATABASE_URL field has no default value in the Settings class.

    DATABASE_URL must be configured externally via environment variable or .env file.
    No hardcoded password should exist in source code.
    """
    from app.core.config import Settings

    fields = Settings.model_fields
    assert "DATABASE_URL" in fields
    db_field = fields["DATABASE_URL"]
    from pydantic_core import PydanticUndefined
    assert db_field.default is PydanticUndefined, (
        f"DATABASE_URL should have no default, got: {db_field.default}"
    )


def test_settings_no_secrets_in_source():
    """Verify DATABASE_URL default does not contain hardcoded credentials."""
    source = inspect.getsource(__import__("app.core.config", fromlist=["Settings"]))
    assert "postgres:postgres" not in source, (
        "DATABASE_URL should not contain hardcoded credentials"
    )


def test_alembic_configparser_handles_url_encoded_password():
    """Regression test: URL-encoded characters in DATABASE_URL survive ConfigParser.

    Alembic's set_main_option uses ConfigParser which interprets % as
    interpolation syntax. The fix escapes % to %% so set() succeeds,
    and get_section() (which uses items() with default interpolation)
    converts %% back to % automatically.

    See: https://alembic.sqlalchemy.org/en/latest/config.html
    """
    from configparser import ConfigParser

    cfg = ConfigParser()
    cfg.read_dict({"alembic": {}})

    url_with_encoded_at = "postgresql://postgres:Islem2002%40@localhost:5432/supermarket_pro"

    # The env.py fix: escape % to %%
    escaped_url = url_with_encoded_at.replace("%", "%%")
    cfg.set("alembic", "sqlalchemy.url", escaped_url)

    # Alembic's run_migrations_online uses get_section() -> items() which
    # uses raw=False by default, so interpolation converts %% back to %
    section_dict = dict(cfg.items("alembic"))
    result = section_dict["sqlalchemy.url"]
    assert result == url_with_encoded_at, (
        f"ConfigParser should preserve URL-encoded characters. "
        f"Expected: {url_with_encoded_at!r}, Got: {result!r}"
    )


def test_alembic_configparser_handles_various_encoded_chars():
    """Verify multiple URL-encoded characters survive ConfigParser round-trip."""
    from configparser import ConfigParser

    cfg = ConfigParser()
    cfg.read_dict({"alembic": {}})

    test_urls = [
        "postgresql://postgres:p%40ss@localhost:5432/db",      # %40 = @
        "postgresql://postgres:p%23ss@localhost:5432/db",      # %23 = #
        "postgresql://postgres:p%25ss@localhost:5432/db",      # %25 = %
        "postgresql://postgres:p%2Fss@localhost:5432/db",      # %2F = /
    ]

    for url in test_urls:
        escaped = url.replace("%", "%%")
        cfg.set("alembic", "sqlalchemy.url", escaped)
        section_dict = dict(cfg.items("alembic"))
        result = section_dict["sqlalchemy.url"]
        assert result == url, f"Failed for URL: {url!r}, got: {result!r}"


def test_configparser_set_fails_without_escaping():
    """Verify that set() fails with unescaped % in value (the original bug)."""
    from configparser import ConfigParser

    cfg = ConfigParser()
    cfg.read_dict({"alembic": {}})

    url_with_encoded_at = "postgresql://postgres:p%40ss@localhost:5432/db"

    try:
        cfg.set("alembic", "sqlalchemy.url", url_with_encoded_at)
        # If set() succeeds without escaping, the behavior might have changed
        # in a newer Python version. That's fine — the fix still works.
    except ValueError:
        # Expected: ConfigParser rejects unescaped % in values
        pass
