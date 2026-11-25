"""JSON logging is opt-in and never changes a local run's output."""

from __future__ import annotations

import json

import structlog

from service.cloud_logging import configure_logging, logging_enabled


def test_logging_is_off_unless_enabled(monkeypatch):
    monkeypatch.delenv("LICENSE_API_LOG_JSON", raising=False)
    assert logging_enabled({}) is False
    assert configure_logging({}) is False


def test_json_logging_emits_one_object_per_event(capsys):
    try:
        assert configure_logging({"LICENSE_API_LOG_JSON": "1"}) is True
        structlog.get_logger("test").info("license_api_event", reason="ValueError")
        line = capsys.readouterr().out.strip().splitlines()[-1]
        payload = json.loads(line)
    finally:
        structlog.reset_defaults()

    assert payload["event"] == "license_api_event"
    assert payload["reason"] == "ValueError"
    assert payload["level"] == "info"
    assert "timestamp" in payload
