"""Parameterised target for ``scripts/check_live_firebase.py`` (Phase 8.3.2).

The script used to hard-code production's project, uid and e-mail. It is now
configuration-driven, with the production values as the defaults, so the same
read-only check can be pointed at the Firebase Spark staging project without
editing source.

Only ``resolve_target`` is exercised: these tests never contact Firebase,
Firestore or Google, never create users and never write anything.
"""

from __future__ import annotations

import sys
from importlib import util
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"

_spec = util.spec_from_file_location(
    "check_live_firebase_under_test", SCRIPTS / "check_live_firebase.py"
)
assert _spec is not None and _spec.loader is not None
check = util.module_from_spec(_spec)
# Registered before execution: dataclasses resolves the defining module by name.
sys.modules[_spec.name] = check
_spec.loader.exec_module(check)

STAGING_PROJECT = "klickpos-license-free-8029b"


# --------------------------------------------------------------------------- #
# Production stays exactly as it was
# --------------------------------------------------------------------------- #


def test_the_default_target_is_the_production_project():
    target = check.resolve_target([], {})

    assert target.project == "klickpos-license-manager"
    assert target.uid == "WeTMtT4ulPYqDJXfl7d9Lr4K9Zw1"
    assert target.email == "islemzeblah31@gmail.com"
    assert target.mode == "production"


def test_the_production_defaults_are_unchanged_constants():
    assert check.PRODUCTION_PROJECT == "klickpos-license-manager"
    assert check.PRODUCTION_UID == "WeTMtT4ulPYqDJXfl7d9Lr4K9Zw1"
    assert check.PRODUCTION_EMAIL == "islemzeblah31@gmail.com"
    # The historical aliases still resolve to the same values.
    assert check.EXPECTED_PROJECT == check.PRODUCTION_PROJECT
    assert check.EXPECTED_UID == check.PRODUCTION_UID
    assert check.EXPECTED_EMAIL == check.PRODUCTION_EMAIL


def test_a_partial_override_keeps_the_other_production_defaults():
    target = check.resolve_target(["--uid", "another-uid"], {})

    assert target.project == "klickpos-license-manager"
    assert target.uid == "another-uid"
    assert target.email == "islemzeblah31@gmail.com"
    assert target.mode == "production"


# --------------------------------------------------------------------------- #
# Staging must be explicit
# --------------------------------------------------------------------------- #


def test_an_explicit_staging_target_uses_only_what_was_given():
    target = check.resolve_target(
        ["--staging", "--project", STAGING_PROJECT, "--uid", "staging-uid"], {}
    )

    assert target.project == STAGING_PROJECT
    assert target.uid == "staging-uid"
    # No production e-mail may be inherited by a staging run.
    assert target.email == ""
    assert target.mode == "staging"


def test_staging_target_can_come_from_the_environment():
    target = check.resolve_target(
        ["--staging"],
        {
            "LICENSE_API_CHECK_PROJECT": STAGING_PROJECT,
            "LICENSE_API_CHECK_UID": "staging-uid",
            "LICENSE_API_CHECK_EMAIL": "staging@example.com",
        },
    )

    assert target.project == STAGING_PROJECT
    assert target.uid == "staging-uid"
    assert target.email == "staging@example.com"
    assert target.mode == "staging"


def test_flags_win_over_the_environment():
    target = check.resolve_target(
        ["--staging", "--project", STAGING_PROJECT],
        {"LICENSE_API_CHECK_PROJECT": "some-other-project"},
    )
    assert target.project == STAGING_PROJECT


def test_staging_without_a_project_refuses_to_fall_back_to_production():
    with pytest.raises(check.TargetError):
        check.resolve_target(["--staging"], {})


def test_staging_cannot_be_pointed_at_the_production_project():
    with pytest.raises(check.TargetError):
        check.resolve_target(["--staging", "--project", "klickpos-license-manager"], {})


def test_a_bare_project_flag_creates_an_adhoc_target():
    target = check.resolve_target(["--project", STAGING_PROJECT], {})

    assert target.project == STAGING_PROJECT
    assert target.mode == "custom"
    assert target.uid == ""
    assert target.email == ""


def test_the_environment_can_name_another_project_without_staging_mode():
    target = check.resolve_target([], {"LICENSE_API_CHECK_PROJECT": STAGING_PROJECT})
    assert target.project == STAGING_PROJECT


def test_main_reports_a_staging_target_error_without_touching_firebase(capsys):
    exit_code = check.main(["--staging"], {})

    assert exit_code == 2
    output = capsys.readouterr().out
    assert "--staging" in output
    assert "refusing to fall back to production" in output
    # Nothing was checked: no PASS/FAIL summary is printed.
    assert "summary" not in output


def test_main_never_prints_a_token(capsys):
    # The staging path is refused before any credential is touched; the message
    # must not contain a token-shaped value or an environment dump.
    check.main(["--staging"], {})
    output = capsys.readouterr().out
    assert "ya29." not in output
    assert "Bearer " not in output
