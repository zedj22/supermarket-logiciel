"""R4 §3 — production licensing enforcement configuration.

Development keeps the historical default: ``LICENSE_ENFORCEMENT`` is
``off`` and the guard is a no-op until someone opts in.  Production must
never inherit that silence, so an *omitted* value under
``APP_ENV=production`` falls back to ``trial`` (never ``off``) while an
**explicit** value - including an explicit ``off`` - is honoured and
logged.

Everything here builds throwaway ``Settings`` objects; the process-wide
singleton in ``app.core.config`` is never mutated.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import get_args

import pytest
from pydantic import ValidationError

from app.core.config import Settings, settings
from app.main import _warn_if_production_enforcement_is_off

BACKEND_ROOT = Path(__file__).resolve().parents[2]

#: Unique secrets so a production ``Settings()`` is constructible at all:
#: R2 refuses the repository placeholders in production.
SECRETS = {
    "APP_SECRET_KEY": "r4-production-app-secret-00000000",
    "JWT_SECRET_KEY": "r4-production-jwt-secret-00000000",
}

MODES = ("off", "trial", "on")


def production(**kwargs: object) -> Settings:
    """A production ``Settings`` with no enforcement value supplied."""
    return Settings(APP_ENV="production", **SECRETS, **kwargs)  # type: ignore[arg-type]


def env_values(path: Path) -> dict[str, str]:
    """Active (non-comment, non-blank) ``KEY=VALUE`` lines of a template."""
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        name, _, value = stripped.partition("=")
        values[name] = value
    return values


# ── the production fallback ─────────────────────────────────────────────────


def test_an_omitted_value_in_production_falls_back_to_trial(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("LICENSE_ENFORCEMENT", raising=False)

    assert production().LICENSE_ENFORCEMENT == "trial"


def test_the_fallback_is_never_off(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("LICENSE_ENFORCEMENT", raising=False)

    assert production().LICENSE_ENFORCEMENT != "off"


@pytest.mark.parametrize("mode", MODES)
def test_an_explicit_mode_is_always_honoured(
    monkeypatch: pytest.MonkeyPatch, mode: str
) -> None:
    monkeypatch.delenv("LICENSE_ENFORCEMENT", raising=False)

    assert production(LICENSE_ENFORCEMENT=mode).LICENSE_ENFORCEMENT == mode


@pytest.mark.parametrize("mode", MODES)
def test_an_environment_value_is_treated_as_supplied(
    monkeypatch: pytest.MonkeyPatch, mode: str
) -> None:
    monkeypatch.setenv("LICENSE_ENFORCEMENT", mode)

    assert production().LICENSE_ENFORCEMENT == mode


def test_a_blank_value_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("LICENSE_ENFORCEMENT", raising=False)

    with pytest.raises(ValidationError):
        production(LICENSE_ENFORCEMENT="")


def test_an_unknown_mode_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("LICENSE_ENFORCEMENT", raising=False)

    with pytest.raises(ValidationError):
        production(LICENSE_ENFORCEMENT="sometimes")


# ── development is unchanged ────────────────────────────────────────────────


@pytest.mark.parametrize("app_env", ["development", "testing"])
def test_non_production_keeps_the_historical_default(
    monkeypatch: pytest.MonkeyPatch, app_env: str
) -> None:
    monkeypatch.delenv("LICENSE_ENFORCEMENT", raising=False)

    built = Settings(APP_ENV=app_env, **SECRETS)  # type: ignore[arg-type]

    assert built.LICENSE_ENFORCEMENT == "off"


def test_the_process_wide_settings_are_untouched() -> None:
    assert settings.APP_ENV == "testing"
    assert settings.LICENSE_ENFORCEMENT == "off"


def test_the_mode_vocabulary_is_exactly_off_trial_on() -> None:
    annotation = Settings.model_fields["LICENSE_ENFORCEMENT"].annotation

    assert set(get_args(annotation)) == set(MODES)


# ── the startup warning (R4 §3) ─────────────────────────────────────────────


def emitted_text(caplog: pytest.LogCaptureFixture, capsys) -> str:
    """Everything the helper logged, wherever structlog currently routes it.

    ``structlog`` writes to stdout until ``setup_logging()`` runs inside the
    application lifespan, and to stdlib logging afterwards - so both sinks
    are inspected rather than assuming one of them.
    """
    captured = capsys.readouterr()
    return caplog.text + captured.out + captured.err


def test_a_production_start_with_off_is_logged(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    monkeypatch.setattr(settings, "APP_ENV", "production")
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "off")

    with caplog.at_level(logging.WARNING):
        _warn_if_production_enforcement_is_off()

    text = emitted_text(caplog, capsys)
    assert "license_enforcement_disabled_in_production" in text
    assert "LICENSE_ENFORCEMENT=trial" in text


@pytest.mark.parametrize("mode", ["trial", "on"])
def test_a_production_start_with_enforcement_on_is_silent(
    monkeypatch: pytest.MonkeyPatch,
    mode: str,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    monkeypatch.setattr(settings, "APP_ENV", "production")
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", mode)

    with caplog.at_level(logging.WARNING):
        _warn_if_production_enforcement_is_off()

    assert "license_enforcement_disabled_in_production" not in emitted_text(
        caplog, capsys
    )


def test_development_never_warns_about_off(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    monkeypatch.setattr(settings, "APP_ENV", "development")
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "off")

    with caplog.at_level(logging.WARNING):
        _warn_if_production_enforcement_is_off()

    assert "license_enforcement_disabled_in_production" not in emitted_text(
        caplog, capsys
    )


def test_the_warning_helper_is_total_over_every_combination(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for app_env in ("production", "development", "testing"):
        for mode in MODES:
            monkeypatch.setattr(settings, "APP_ENV", app_env)
            monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", mode)
            _warn_if_production_enforcement_is_off()


# ── the installer template ──────────────────────────────────────────────────


def test_the_production_template_ships_trial_and_no_secret_values() -> None:
    values = env_values(BACKEND_ROOT / "production.env.example")

    assert values["APP_ENV"] == "production"
    assert values["LICENSE_ENFORCEMENT"] == "trial"
    # The R2 launcher generates both into <DATA_DIR>/config/secrets.env and
    # publishes them to the process environment; a copy-paste placeholder
    # here would be refused by _reject_placeholder_secrets.
    assert "APP_SECRET_KEY" not in values
    assert "JWT_SECRET_KEY" not in values
    # R3: the database password lives in database.env, never in this file.
    assert "PG_ADMIN_URL" not in values
    assert "database.env" in (BACKEND_ROOT / "production.env.example").read_text(
        encoding="utf-8"
    )


def test_the_template_documents_every_enforcement_mode() -> None:
    text = (BACKEND_ROOT / "production.env.example").read_text(encoding="utf-8")

    for mode in MODES:
        assert f" {mode}" in text
