"""Installer credential policy (upgrade / reinstall / foreign server).

The installer must never ask for a password it already has, and must never
invent one.  Concretely:

* a PostgreSQL server installed BY this product (service
  ``postgresql-supermarketpro-18`` + ``C:\\Program Files\\SupermarketPro\\
  PostgreSQL\\18``) is never asked about: its password was generated on
  this PC and lives in ``config\\pg_admin.env``;
* an upgrade or a reinstall reads ``config\\pg_admin.env`` and NEVER shows
  the password page while the server still accepts that value;
* the page appears only when the server itself REJECTS the stored value
  (then it is explained once) or when the PostgreSQL belongs to somebody
  else and nothing usable is stored;
* a missing ``pg_admin.env`` next to surviving data stops the install with
  the recovery path instead of creating a second, empty database.

These tests pin the source contract of ``installer/setup.iss`` (Inno/Pascal
cannot be executed from pytest) and the few pure-Python pieces that can be
executed.  They never claim an installer was run.

French test machines are the reason every detection here uses a service
NAME, a directory, an exit code or a SQLSTATE — never localized text.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path

import pytest

BACKEND_ROOT = Path(__file__).resolve().parents[2]
PROJECT_ROOT = Path(__file__).resolve().parents[4]
SETUP_ISS = PROJECT_ROOT / "installer" / "setup.iss"
INSTALLER_PROVISION = PROJECT_ROOT / "installer" / "installer_provision.py"


def _iss() -> str:
    return SETUP_ISS.read_text(encoding="utf-8")


def _function_body(source: str, header: str) -> str:
    """Text of a Pascal function/procedure, from its header to its ``end;``."""
    lines = source.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.strip().lower().startswith(header.lower()):
            start = index
            break
    assert start is not None, f"{header!r} not found in setup.iss"
    for index in range(start, len(lines)):
        if lines[index].rstrip() == "end;":
            return "\n".join(lines[start:index + 1])
    raise AssertionError(f"{header!r} has no terminating 'end;'")


def _load_installer_provision():
    spec = importlib.util.spec_from_file_location(
        "installer_provision_creds", INSTALLER_PROVISION
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


# ─────────────────────────────────────────────────────────────────────────
# Our own server: never asked about
# ─────────────────────────────────────────────────────────────────────────


class TestOurOwnServer:
    def test_detection_uses_the_service_name_and_the_install_directory(self):
        body = _function_body(_iss(), "function OurPostgresServerPresent")
        assert "ServiceExists('{#PgServiceName}')" in body
        assert "DirExists(ExpandConstant('{#PgInstallDir}'))" in body

    def test_the_service_name_and_directory_are_our_own(self):
        source = _iss()
        assert '#define PgServiceName "postgresql-supermarketpro-18"' in source
        assert (
            '#define PgInstallDir "{autopf}\\SupermarketPro\\PostgreSQL\\18"'
            in source
        )

    def test_service_existence_is_an_exit_code_not_localized_text(self):
        body = _function_body(_iss(), "function ServiceExists")
        assert "sc query" in body
        assert "(Rc = 0)" in body
        # A localized state word (RUNNING / STOPPED / ÉCOUTE) must never be
        # parsed to decide whether the service exists.
        for word in ("RUNNING", "STOPPED", "SERVICE_NAME", "PAUSED"):
            assert word not in body

    def test_our_server_never_reaches_the_ask_branch(self):
        body = _function_body(_iss(), "function PasswordPageNeeded")
        guard = body.index("if OurPostgresServerPresent then")
        ask = body.rindex("PgPageNeeded := True;")
        assert guard < ask, (
            "the foreign-server branch must sit AFTER the our-server guard"
        )
        assert body[guard:ask].count("exit;") >= 1

    def test_a_missing_stored_file_is_refused_instead_of_prompted(self):
        """Our own server + no pg_admin.env: never a prompt, a clear stop."""
        body = _function_body(_iss(), "function PrepareToInstall")
        assert "OurPostgresServerPresent" in body
        assert "pg_admin.env" in body
        assert "will NOT create a new, empty database" in body
        assert "Recovery:" in body
        # The refusal must return a message (abort before any file is written).
        assert "Result :=" in body.split("if OurPostgresServerPresent")[1]
        assert "exit;" in body.split("if OurPostgresServerPresent")[1]


# ─────────────────────────────────────────────────────────────────────────
# Upgrade / reinstall: stored credentials are read, not asked for
# ─────────────────────────────────────────────────────────────────────────


class TestStoredCredentials:
    def test_the_stored_password_is_read_from_the_data_root(self):
        body = _function_body(_iss(), "function PasswordPageNeeded")
        assert "ReadKeyValue(DataRoot + '\\config\\pg_admin.env'" in body
        assert "'PG_ADMIN_PASSWORD'" in body

    def test_an_accepted_stored_password_skips_the_page_and_is_verified(self):
        body = _function_body(_iss(), "function PasswordPageNeeded")
        accepted = body.index("if VerifyPgAdminPassword(Stored, ErrorText, Checked)")
        block = body[accepted:]
        assert "PgAdminPassword := Stored;" in block
        assert "PgAdminVerified := True;" in block
        # The success path leaves the function before any page is requested.
        success = block.index("PgAdminVerified := True;")
        assert block.index("exit;") > success
        assert "PgPageNeeded := True" not in block[: block.index("exit;")]

    def test_a_rejected_stored_password_asks_exactly_once(self):
        body = _function_body(_iss(), "function PasswordPageNeeded")
        assert "PgStoredRejected := True;" in body
        rejected = body.index("PgStoredRejected := True;")
        assert "PgPageNeeded := True;" in body[rejected:]

    def test_the_rejection_message_explains_and_holds_the_page(self):
        body = _function_body(_iss(), "function NextButtonClick")
        assert "was rejected by the server" in body
        assert "Type the CURRENT superuser password" in body
        # The stale value is NOT discarded before a verified replacement:
        # provisioning overwrites it only after a successful pass.
        assert "DiscardStoredAdminPassword" not in _iss()
        assert "--save-admin-password" in _iss()

    def test_a_foreign_server_is_asked_for_its_own_password(self):
        body = _function_body(_iss(), "function PasswordPageNeeded")
        tail = body[body.index("if OurPostgresServerPresent then"):]
        assert "PgPageNeeded := True;" in tail, (
            "a server that is not ours must still be asked for its own "
            "superuser password"
        )

    def test_the_page_shown_is_the_verified_flow_only(self):
        body = _function_body(_iss(), "function ShouldSkipPage")
        assert "not PasswordPageNeeded" in body
        # No page for a fresh PC without PostgreSQL, ever.
        assert "PgAdminPage" in body


# ─────────────────────────────────────────────────────────────────────────
# Uninstall + reinstall
# ─────────────────────────────────────────────────────────────────────────


class TestUninstallReinstall:
    def test_uninstall_deletes_only_the_licence_state(self):
        body = _function_body(_iss(), "procedure CurUninstallStepChanged")
        assert "\\license" in body
        # The credentials and the data root survive (M5).
        for kept in ("pg_admin.env", "database.env", "secrets.env"):
            assert kept not in body
        assert "DelTree(DataRoot," not in body
        assert "DelTree(DataRoot, " not in body

    def test_reinstall_reuses_the_database_named_by_the_surviving_env(self):
        body = _function_body(_iss(), "procedure ResolveIdentity")
        assert "DatabaseNameFromEnv()" in body
        assert "IdentityReused := True;" in body

    def test_a_reinstall_is_not_a_fresh_install_and_is_backed_up_first(self):
        body = _function_body(_iss(), "function ProvisionArgs")
        fresh = [line for line in body.splitlines() if "--fresh-install" in line]
        assert fresh, "the fresh-install flag must still be passed"
        assert any("IdentityReused" in line for line in body.splitlines())
        assert any("UpgradeMode or IdentityReused" in line for line in body.splitlines())

    def test_the_database_name_comes_from_database_url(self):
        body = _function_body(_iss(), "function DatabaseNameFromEnv")
        assert "'DATABASE_URL'" in body
        assert "\\config\\.env" in body
        # Only a plain identifier is accepted from the file.
        assert "Pos(' ', Tail)" in body


# ─────────────────────────────────────────────────────────────────────────
# No password in logs, no default password anywhere
# ─────────────────────────────────────────────────────────────────────────


class TestNoPasswordLeak:
    def test_the_pascal_never_logs_the_password(self):
        offenders = [
            line
            for line in _iss().splitlines()
            if "PgAdminPassword" in line
            and any(marker in line for marker in ("Log(", "LogStep(", "MsgBox"))
        ]
        assert offenders == []

    def test_the_handoff_file_is_the_only_place_it_is_written(self):
        writes = [
            line.strip()
            for line in _iss().splitlines()
            if "SaveStringToFile" in line and "PgAdminPassword" in line
        ]
        assert writes == [
            "if not SaveStringToFile(PgAdminPasswordFile, PgAdminPassword, False) then"
        ]

    def test_the_python_driver_never_prints_the_password(self):
        text = INSTALLER_PROVISION.read_text(encoding="utf-8")
        for line in text.splitlines():
            if "print(" not in line:
                continue
            assert "admin_password" not in line, line
            assert "app_password" not in line, line
            assert "{password" not in line, line

    def test_no_default_password_is_hard_coded(self):
        sources = {
            "setup.iss": _iss(),
            "installer_provision.py": INSTALLER_PROVISION.read_text(encoding="utf-8"),
            "installer_selfcheck.py": (
                PROJECT_ROOT / "installer" / "installer_selfcheck.py"
            ).read_text(encoding="utf-8"),
        }
        for name, text in sources.items():
            # A literal credential in a file the customer receives.
            assert not re.search(r"PG_ADMIN_PASSWORD=[^\s<'\"{}]", text), name
            assert not re.search(r"DATABASE_PASSWORD=[^\s<'\"]", text), name
            # An assignment of a real (non-empty) literal would be a default.
            assert not re.search(
                r"^\s*(PgAdminPassword|admin_password)\s*:?=\s*'[^']", text, re.M
            ), name

    def test_both_credentials_are_randomly_generated(self):
        text = INSTALLER_PROVISION.read_text(encoding="utf-8")
        assert "token_urlsafe(18)" in text  # maintenance (postgres) password
        assert "ensure_database_password" in text  # app_user password


# ─────────────────────────────────────────────────────────────────────────
# File-level guarantees of the storage layer
# ─────────────────────────────────────────────────────────────────────────


def test_a_stored_password_is_never_overwritten_without_a_verified_value(tmp_path):
    """``overwrite=False`` keeps the old value (the wizard's stored path)."""
    module = _load_installer_provision()
    (tmp_path / "config").mkdir()
    module._persist_admin_password(tmp_path, "first@value")
    module._persist_admin_password(tmp_path, "second@value")  # must not replace
    assert module._load_admin_password(tmp_path) == "first@value"

    # A verified replacement is explicit, and round-trips byte for byte.
    module._persist_admin_password(tmp_path, "second@value", overwrite=True)
    assert module._load_admin_password(tmp_path) == "second@value"
    assert sorted(p.name for p in (tmp_path / "config").iterdir()) == ["pg_admin.env"]


@pytest.mark.parametrize("password", ["trailing@", "a@b:c/d", "sp ace@ pw"])
def test_the_stored_password_is_read_back_exactly(password, tmp_path):
    module = _load_installer_provision()
    (tmp_path / "config").mkdir()
    module._persist_admin_password(tmp_path, password)
    assert module._load_admin_password(tmp_path) == password
