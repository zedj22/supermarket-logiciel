"""ACL contract + installer self-check (regression tests).

Sandbox evidence, 2026-11-14: `config\\.env`, `config\\secrets.env` and
`config\\database.env` were created with a DACL that granted nothing, so
NetworkService crash-looped on PermissionError while the installer reported
success; a recursive `/T` grant over the data root also broke PostgreSQL's
own ACLs.  These tests pin the replacement contract: per-object, by SID,
never recursive, and verified through locale-independent SDDL.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

from app.core import acl

BACKEND_ROOT = Path(__file__).resolve().parents[2]
PROJECT_ROOT = Path(__file__).resolve().parents[4]
SETUP_ISS = PROJECT_ROOT / "installer" / "setup.iss"
SELFCHECK_PATH = PROJECT_ROOT / "installer" / "installer_selfcheck.py"


def _load_selfcheck():
    spec = importlib.util.spec_from_file_location(
        "installer_selfcheck", SELFCHECK_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


# ─────────────────────────────────────────────────────────────────────────
# icacls command lines
# ─────────────────────────────────────────────────────────────────────────


class TestCommandLines:
    def test_credential_file_is_protected_and_service_readable(self, tmp_path):
        path = tmp_path / ".env"
        argv = acl.icacls_argv(path, acl.credential_file_spec(path))
        assert argv == [
            "icacls",
            str(path),
            "/inheritance:r",
            "/grant",
            "*S-1-5-20:R",
            "/grant",
            "*S-1-5-32-544:F",
            "/grant",
            "*S-1-5-18:F",
        ]

    def test_admin_file_excludes_the_service_account(self, tmp_path):
        path = tmp_path / "pg_admin.env"
        argv = acl.icacls_argv(path, acl.admin_file_spec(path))
        assert "/inheritance:r" in argv
        assert "*S-1-5-20:R" not in argv
        assert "*S-1-5-32-544:F" in argv
        assert "*S-1-5-18:F" in argv

    def test_logs_directory_keeps_inheritance_and_is_writable(self, tmp_path):
        path = tmp_path / "logs"
        argv = acl.icacls_argv(path, acl.logs_dir_spec(path))
        assert "/inheritance:r" not in argv
        assert "*S-1-5-20:(OI)(CI)M" in argv
        assert "*S-1-5-32-544:(OI)(CI)F" in argv
        assert "*S-1-5-18:(OI)(CI)F" in argv

    @pytest.mark.parametrize(
        "builder",
        [acl.credential_file_spec, acl.admin_file_spec, acl.logs_dir_spec],
    )
    def test_never_recursive(self, tmp_path, builder):
        path = tmp_path / "x"
        assert "/T" not in acl.icacls_argv(path, builder(path))


# ─────────────────────────────────────────────────────────────────────────
# Verification (SDDL, locale-free SID codes)
# ─────────────────────────────────────────────────────────────────────────

#: Real `icacls /save` output shape for a protected credential file.
CONFIG_SDDL = "D:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;NS)"
LOGS_SDDL = (
    "D:AI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;NS)"
)


class TestSddlCheck:
    def test_real_protected_sddl_passes(self, tmp_path):
        path = tmp_path / ".env"
        assert acl.check_sddl(CONFIG_SDDL, acl.credential_file_spec(path)) == []

    def test_inherited_sddl_fails_for_a_credential_file(self, tmp_path):
        path = tmp_path / ".env"
        problems = acl.check_sddl(LOGS_SDDL, acl.credential_file_spec(path))
        assert any("not protected" in p for p in problems)

    def test_missing_service_ace_is_reported(self, tmp_path):
        path = tmp_path / ".env"
        sddl = "D:PAI(A;;FA;;;SY)(A;;FA;;;BA)"
        problems = acl.check_sddl(sddl, acl.credential_file_spec(path))
        assert any("S-1-5-20" in p for p in problems)

    def test_missing_read_mask_is_reported(self, tmp_path):
        path = tmp_path / ".env"
        sddl = "D:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;WD;;;NS)"
        problems = acl.check_sddl(sddl, acl.credential_file_spec(path))
        assert any("no read access" in p for p in problems)

    def test_logs_directory_expects_inheritance(self, tmp_path):
        path = tmp_path / "logs"
        spec = acl.logs_dir_spec(path)
        assert acl.check_sddl(LOGS_SDDL, spec) == []
        assert any(
            "protected" in p for p in acl.check_sddl(CONFIG_SDDL, spec)
        )

    def test_admin_file_must_not_grant_the_service_account(self):
        def runner(argv):
            class Done:
                returncode = 0
                stdout = ""
                stderr = ""

            # write the SDDL where read_sddl expects it
            target = Path(argv[3])
            target.write_text(
                ".env\n" + CONFIG_SDDL + "\n", encoding="utf-16"
            )
            return Done()

        problems = acl.verify_admin_file_not_readable_by_service(
            Path("C:/x/pg_admin.env"), runner=runner
        )
        assert any("NetworkService" in p for p in problems)

    def test_unreadable_dacl_is_a_problem_not_a_silent_pass(self):
        class Denied:
            returncode = 1
            stdout = "Access is denied.\r\n"
            stderr = ""

        problems = acl.verify_spec(
            Path("C:/x/.env"), acl.credential_file_spec(Path("x")),
            runner=lambda argv: Denied(),
        )
        assert problems and "cannot read the DACL" in problems[0]


# ─────────────────────────────────────────────────────────────────────────
# self-check script
# ─────────────────────────────────────────────────────────────────────────


class TestSelfCheck:
    def test_health_connected_requires_the_database_field(self, monkeypatch):
        module = _load_selfcheck()

        class Response:
            status = 200

            def __init__(self, body):
                self._body = body.encode()

            def read(self):
                return self._body

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        monkeypatch.setattr(
            module.urllib.request,
            "urlopen",
            lambda url, timeout: Response(json.dumps({"database": "connected"})),
        )
        assert module.probe_health("http://x/health")[0] is True

        monkeypatch.setattr(
            module.urllib.request,
            "urlopen",
            lambda url, timeout: Response(json.dumps({"database": "disconnected"})),
        )
        ok, detail = module.probe_health("http://x/health")
        assert ok is False
        assert "disconnected" in detail

    def test_diagnostics_include_every_log_tail(self, tmp_path):
        module = _load_selfcheck()
        logs = tmp_path / "logs"
        logs.mkdir()
        (logs / "SupermarketProBackend.err.log").write_text(
            "FATAL: cannot read secrets.env\n", encoding="utf-8"
        )
        (logs / "backend.log").write_text("trial_state_ready\n", encoding="utf-8")

        target = module.write_diagnostics(tmp_path, "http://x/health", "HTTP 503")
        text = target.read_text(encoding="utf-8")
        assert "HTTP 503" in text
        assert "cannot read secrets.env" in text
        assert "trial_state_ready" in text
        assert target.name == "selfcheck.txt"

    def test_tail_is_bounded(self, tmp_path):
        module = _load_selfcheck()
        path = tmp_path / "backend.log"
        path.write_text("\n".join(f"line {i}" for i in range(500)))
        lines = module._tail(path, lines=5).splitlines()
        assert lines == [f"line {i}" for i in range(495, 500)]


# ─────────────────────────────────────────────────────────────────────────
# Installer wiring
# ─────────────────────────────────────────────────────────────────────────


class TestInstallerWiring:
    def test_acls_are_applied_after_provisioning_and_before_the_service(self):
        source = SETUP_ISS.read_text(encoding="utf-8")
        acl_call = source.index("HardenConfigAcls(VenvPy, BackendDir);")
        register = source.index("  ProductionServiceRegister;")
        assert acl_call < register, (
            "the ACL pass must be the last step that touches config, "
            "immediately before the service is registered"
        )
        assert "--phase pre-service" in source
        assert "--phase post-service" in source

    def test_a_failed_self_check_never_reports_success(self):
        source = SETUP_ISS.read_text(encoding="utf-8")
        assert "if not SelfCheckFailed then begin\n    CommitIdentity;" in source
        assert "CurPageChanged" in source
        assert "installation is NOT working yet" in source
