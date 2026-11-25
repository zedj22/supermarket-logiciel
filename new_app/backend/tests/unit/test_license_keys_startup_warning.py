"""The startup honesty check for the packaged public verification keys.

A customer package whose ``verification_keys.json`` is missing, empty or
malformed can never accept an activation code: every lookup fails closed
with ``license_invalid_key``, which the app renders as a licence problem
even though the licence is fine and the *build* is the problem.  The
lifespan therefore reports that state once at startup (Phase L2 fix) —
these tests pin that it reports it, that it never blocks startup, and
that a properly provisioned build stays silent.
"""

from __future__ import annotations

import base64
import logging

import pytest

from app.core.config import settings
from app.main import _warn_if_license_keys_unusable

#: A structurally valid 32-byte public key — never used for signing here.
_PUBLIC = base64.b64encode(bytes(range(32))).decode("ascii")


def _emitted(caplog: pytest.LogCaptureFixture, capsys) -> str:
    """Everything the helper logged, whichever sink structlog used."""
    captured = capsys.readouterr()
    return caplog.text + captured.out + captured.err


def _point_at(monkeypatch: pytest.MonkeyPatch, path) -> None:
    monkeypatch.setattr(settings, "LICENSE_VERIFICATION_KEYS_FILE", str(path))


def test_an_empty_key_file_is_reported_at_startup(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    """The shipped-``{}`` release: activation can never succeed."""
    keys = tmp_path / "verification_keys.json"
    keys.write_text("{}", encoding="utf-8")
    _point_at(monkeypatch, keys)

    with caplog.at_level(logging.WARNING):
        _warn_if_license_keys_unusable()

    text = _emitted(caplog, capsys)
    assert "license_verification_keys_empty" in text
    assert "license_invalid_key" in text


def test_a_missing_key_file_is_reported_at_startup(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    _point_at(monkeypatch, tmp_path / "absent.json")

    with caplog.at_level(logging.WARNING):
        _warn_if_license_keys_unusable()

    assert "license_verification_keys_empty" in _emitted(caplog, capsys)


def test_an_unreadable_key_file_is_reported_without_raising(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    """A corrupted file must not abort startup — only say why it is broken."""
    keys = tmp_path / "verification_keys.json"
    keys.write_text("{not json", encoding="utf-8")
    _point_at(monkeypatch, keys)

    with caplog.at_level(logging.WARNING):
        _warn_if_license_keys_unusable()

    text = _emitted(caplog, capsys)
    assert "license_verification_keys_unusable" in text
    assert "not valid" not in text  # never echoes the file's content


def test_a_provisioned_build_stays_silent(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
    caplog: pytest.LogCaptureFixture,
    capsys,
) -> None:
    keys = tmp_path / "verification_keys.json"
    keys.write_text(f'{{"test-2026": "{_PUBLIC}"}}', encoding="utf-8")
    _point_at(monkeypatch, keys)

    with caplog.at_level(logging.WARNING):
        _warn_if_license_keys_unusable()

    text = _emitted(caplog, capsys)
    assert "license_verification_keys" not in text


def test_the_repository_key_file_is_a_provisioned_release() -> None:
    """Guard the D: project itself: it must stay activation-capable."""
    from app.licensing.verification_keys import load_verification_keys

    keys = load_verification_keys(settings.LICENSE_VERIFICATION_KEYS_FILE)
    assert keys, "the project's verification_keys.json ships no public key"
