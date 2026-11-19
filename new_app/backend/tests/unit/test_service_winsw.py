"""R2: WinSW service definition and least-privilege ACL script.

The service is **not installed** by R2 (no installer phase yet), so these
tests pin the contract the installer will consume:

* absolute paths everywhere (the SCM may start the service from any CWD);
* automatic, delayed start with a controlled failure/restart policy and
  a graceful ``stoptimeout`` window;
* log redirection into ``<DATA_DIR>\\logs`` with size-based retention;
* a documented low-privilege service account and **no** credentials in
  the XML;
* the launcher it invokes is ``run_production.py`` (never
  ``uvicorn --reload``, never a development command);
* the ACL script grants Modify only on the data root and Read+Execute
  only on the installation tree.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET

import pytest

from app.core.config import BACKEND_ROOT

WINSW_DIR = BACKEND_ROOT / "winsw"
XML_PATH = WINSW_DIR / "SupermarketProBackend.xml"
ACL_PATH = WINSW_DIR / "grant_data_dir_acl.ps1"
README_PATH = WINSW_DIR / "README.md"

#: Accounts the service may run as — never LocalSystem.
ALLOWED_ACCOUNTS = {
    r"NT AUTHORITY\NetworkService",
    r"NT AUTHORITY\LocalService",
}

_ABSOLUTE = re.compile(r"^[A-Za-z]:\\")


@pytest.fixture(scope="module")
def service_xml() -> ET.Element:
    assert XML_PATH.is_file(), "winsw/SupermarketProBackend.xml is missing"
    return ET.parse(XML_PATH).getroot()


@pytest.fixture(scope="module")
def xml_text() -> str:
    return XML_PATH.read_text(encoding="utf-8")


def _text(root: ET.Element, tag: str) -> str:
    node = root.find(tag)
    assert node is not None and node.text, f"<{tag}> is missing"
    return node.text.strip()


# ---------------------------------------------------------------------------
# Identity and paths
# ---------------------------------------------------------------------------


def test_service_root_and_identity(service_xml):
    assert service_xml.tag == "service"
    service_id = _text(service_xml, "id")
    assert re.fullmatch(r"[A-Za-z0-9]+", service_id), (
        "WinSW ids should be alphanumeric"
    )
    assert _text(service_xml, "name")
    assert _text(service_xml, "description")


@pytest.mark.parametrize("tag", ["executable", "workingdirectory"])
def test_every_path_is_absolute(service_xml, tag):
    value = _text(service_xml, tag)
    assert _ABSOLUTE.match(value), f"<{tag}> must be absolute: {value}"


def test_arguments_reference_the_production_launcher(service_xml):
    arguments = _text(service_xml, "arguments")
    assert _ABSOLUTE.match(arguments.replace('"', "")), arguments
    assert "run_production.py" in arguments
    # The launcher must be started by the venv interpreter, never a
    # system python that could be missing dependencies.
    executable = _text(service_xml, "executable")
    assert executable.lower().endswith("python.exe")
    assert ".venv" in executable.replace("/", "\\")


def test_runtime_environment_is_declared(service_xml):
    env = {
        node.get("name"): node.get("value")
        for node in service_xml.findall("env")
    }
    assert env.get("APP_ENV") == "production"
    assert env.get("PYTHONDONTWRITEBYTECODE") == "1"
    data_dir = env.get("DATA_DIR")
    assert data_dir and _ABSOLUTE.match(data_dir)
    assert data_dir.lower().startswith("c:\\programdata\\")


def test_no_reload_and_single_worker_anywhere(xml_text):
    """The service must never start the development workflow."""
    assert "--reload" not in xml_text
    assert "reload=True" not in xml_text
    assert "uvicorn" not in xml_text.lower() or "run_production" in xml_text
    assert "--workers" not in xml_text


def test_no_credentials_are_stored_in_the_xml(service_xml, xml_text):
    assert service_xml.find("serviceaccount/password") is None
    assert service_xml.find("password") is None
    assert "--password" not in xml_text
    assert not re.search(r"<\s*password", xml_text, re.IGNORECASE)


# ---------------------------------------------------------------------------
# Start / stop / failure policy
# ---------------------------------------------------------------------------


def test_automatic_delayed_start(service_xml):
    assert _text(service_xml, "startmode").lower() == "automatic"
    assert _text(service_xml, "delayedAutoStart").lower() == "true"


def test_graceful_stop_window(service_xml):
    timeout = _text(service_xml, "stoptimeout")
    assert re.fullmatch(r"\d+\s*(sec|seconds|s|min|minutes|m)", timeout.lower())
    # WinSW must try a graceful stop before killing the process.
    assert service_xml.find("stopparentprocessfirst") is not None
    # Ctrl+C is the graceful stop signal; give the lifespan time to finish.
    assert int(re.match(r"\d+", timeout).group()) >= 10


def test_controlled_failure_restart_policy(service_xml):
    failures = service_xml.findall("onfailure")
    assert len(failures) >= 3, "expected a progressive restart policy"
    actions = {node.get("action") for node in failures}
    assert actions == {"restart"}
    seconds = [
        int(re.match(r"\d+", node.get("delay")).group())
        for node in failures
        if node.get("delay")
    ]
    assert len(seconds) == len(failures), "every failure must be delayed"
    assert seconds == sorted(seconds), seconds
    # Sandbox evidence: a config error (exit 3) restarted every second.
    # WinSW cannot branch on the exit code, so the delay must escalate and
    # the worst case is one attempt per minute.
    assert min(seconds) >= 10, seconds
    assert max(seconds) >= 60, seconds
    assert service_xml.find("resetfailure") is not None


def test_postgres_dependency_is_not_active_yet(service_xml, xml_text):
    """R2 does not install PostgreSQL: the dependency stays commented."""
    assert service_xml.find("depend") is None
    assert "<!--" in xml_text and "postgresql" in xml_text.lower()


# ---------------------------------------------------------------------------
# Logging + service account
# ---------------------------------------------------------------------------


def test_log_redirection_is_under_the_data_root(service_xml):
    logpath = _text(service_xml, "logpath")
    assert _ABSOLUTE.match(logpath)
    assert logpath.lower().startswith("c:\\programdata\\")
    assert logpath.lower().endswith("\\logs")

    log = service_xml.find("log")
    assert log is not None
    assert log.get("mode") in {"roll-by-size", "roll-by-size-time"}
    threshold = log.find("sizeThreshold")
    keep = log.find("keepFiles")
    assert threshold is not None and int(threshold.text) > 0
    assert keep is not None and int(keep.text) > 0


def test_low_privilege_service_account(service_xml):
    account = service_xml.find("serviceaccount")
    assert account is not None
    username = account.find("username")
    assert username is not None
    value = username.text.strip()
    assert value in ALLOWED_ACCOUNTS, value
    assert "system" not in value.lower()


def test_account_is_documented_in_the_readme():
    assert README_PATH.is_file(), "winsw/README.md is missing"
    readme = README_PATH.read_text(encoding="utf-8")
    assert "NetworkService" in readme
    assert "not installed" in readme.lower() or "does not install" in readme.lower()
    assert "backend.log" in readme


# ---------------------------------------------------------------------------
# ACL script
# ---------------------------------------------------------------------------


def test_acl_script_exists_and_refuses_program_files():
    assert ACL_PATH.is_file()
    source = ACL_PATH.read_text(encoding="utf-8")
    assert "Program Files" in source
    assert "Refusing to configure" in source


def test_acl_script_never_recurses_over_the_data_root():
    """Sandbox evidence (2026-11-14): `icacls <data root> … /T` followed by
    `/inheritance:r /T` stripped PostgreSQL's own ACLs from `postgres\data`,
    broke `postgresql.conf` access, and left `config\.env`, `secrets.env`
    and `database.env` with a DACL that granted nothing."""
    source = ACL_PATH.read_text(encoding="utf-8")
    code_lines = [
        line for line in source.splitlines()
        if "'/grant'" in line or "/inheritance:r" in line
    ]
    data_lines = [
        line for line in code_lines
        if "$resolvedData" in line or "$dir" in line or "$skipped" in line
    ]
    assert data_lines, "expected per-directory data-root grants"
    for line in data_lines:
        assert "'/T'" not in line, line
        assert "/inheritance:r" not in line, line
    assert "postgres" in source.lower()
    # The only recursive grant is read+execute on the installation tree.
    install_grants = [
        line for line in source.splitlines()
        if "$InstallDir" in line and "'/grant'" in line
    ]
    assert install_grants
    for line in install_grants:
        assert "RX" in line
        assert not re.search(r"\(OI\)\(CI\)M", line), line


def test_acl_script_grants_sids_only():
    """Locale safety: on French Windows a name form makes icacls exit 1332."""
    source = ACL_PATH.read_text(encoding="utf-8")
    grants = [line for line in source.splitlines() if "'/grant'" in line]
    assert grants, "expected explicit icacls grants"
    for line in grants:
        assert "BUILTIN" not in line, line
        assert "SID_" in line or "accountSid" in line, line
    assert any(
        "(OI)(CI)M" in line and "accountSid" in line for line in grants
    ), "the service account must get Modify on the data root"


def test_acl_script_is_not_executed_by_r2():
    """R2 ships the script; registering the service is installer work."""
    readme = README_PATH.read_text(encoding="utf-8")
    assert "grant_data_dir_acl.ps1" in readme
    root = ET.parse(XML_PATH).getroot()
    # The service definition never runs the ACL script itself (the script
    # may be *referenced* in a comment as operator documentation).
    for hook in ("onstart", "onstop", "prestart", "poststart", "executablepath"):
        assert root.find(hook) is None, hook
    assert root.find("serviceaccount").find("executablepath") is None
