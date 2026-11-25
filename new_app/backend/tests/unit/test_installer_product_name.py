"""Product display name: Klick POS, with every upgrade-critical id intact.

The rename is a DISPLAY rename only.  The Inno ``AppId`` GUID, the install
and data directories, the default database name, the PostgreSQL service
name, the WinSW service id (``SupermarketProBackend``), the registry keys
and the ACL scripts must not move, or an install made with the previous
builder would be treated as a different product — no upgrade, a second
ProgramData tree, a second database.

These are source-contract tests over the shipped installer and runner
files; they do not execute Inno Setup or Flutter.
"""

from __future__ import annotations

from pathlib import Path

APP_DIR = Path(__file__).resolve().parents[3]
PROJECT_ROOT = Path(__file__).resolve().parents[4]
INSTALLER_DIR = PROJECT_ROOT / "installer"
SETUP_ISS = INSTALLER_DIR / "setup.iss"
SERVICE_XML = APP_DIR / "backend" / "winsw" / "SupermarketProBackend.xml"


def _iss() -> str:
    return SETUP_ISS.read_text(encoding="utf-8")


# ─────────────────────────────────────────────────────────────────────────
# The new display name
# ─────────────────────────────────────────────────────────────────────────


class TestDisplayName:
    def test_installer_identity_is_klick_pos(self):
        source = _iss()
        assert '#define MyAppName "Klick POS"' in source
        assert '#define MyAppPublisher "Klick POS"' in source
        # Apps & Features / uninstall entry and start-menu group follow
        # AppName; they must not name the old product.
        assert "UninstallDisplayName={#MyAppName}" in source
        assert 'DefaultGroupName={#MyAppName}' in source
        assert 'Name: "{autodesktop}\\{#MyAppName}"' in source
        assert 'Name: "{autoprograms}\\{#MyAppName}"' in source

    def test_the_output_file_is_klickpos_setup(self):
        source = _iss()
        assert '#define OutName "KlickPOS-Setup"' in source
        assert '#define OutName "KlickPOS-Setup-REHEARSAL"' in source
        assert "SupermarketPro-Setup" not in source

    def test_every_build_script_uses_the_new_file_name(self):
        for name in ("build_installer.ps1", "build_release.ps1", "rehearsal_harness.ps1"):
            text = (INSTALLER_DIR / name).read_text(encoding="utf-8")
            assert "KlickPOS-Setup" in text, name
            assert "SupermarketPro-Setup" not in text, name

    def test_the_winsw_display_name_changed_but_not_the_service_id(self):
        text = SERVICE_XML.read_text(encoding="utf-8")
        assert "<id>SupermarketProBackend</id>" in text
        assert "<name>Klick POS Backend</name>" in text
        assert "<description>Klick POS " in text

    def test_the_windows_runner_title_and_resources(self):
        main_cpp = (APP_DIR / "windows" / "runner" / "main.cpp").read_text(
            encoding="utf-8"
        )
        assert 'window.Create(L"Klick POS"' in main_cpp
        rc = (APP_DIR / "windows" / "runner" / "Runner.rc").read_text(
            encoding="utf-8"
        )
        assert 'VALUE "FileDescription", "Klick POS" "\\0"' in rc
        assert 'VALUE "ProductName", "Klick POS" "\\0"' in rc
        # The executable keeps its technical name (the installer, the
        # WinSW XML and the shortcuts all reference supermarket_pos.exe).
        assert 'VALUE "OriginalFilename", "supermarket_pos.exe" "\\0"' in rc
        assert 'VALUE "InternalName", "supermarket_pos" "\\0"' in rc

    def test_the_flutter_product_name_is_the_brand_in_every_locale(self):
        constants = (APP_DIR / "lib" / "core" / "constants.dart").read_text(
            encoding="utf-8"
        )
        assert "static const String appName = 'Klick POS';" in constants

        strings = (APP_DIR / "lib" / "core" / "strings.dart").read_text(
            encoding="utf-8"
        )
        occurrences = [
            line.strip()
            for line in strings.splitlines()
            if line.strip().startswith("'app_name':")
        ]
        assert occurrences, "app_name is missing from the string tables"
        for line in occurrences:
            assert "'app_name': 'Klick POS'," == line, line

    def test_the_default_store_name_on_receipts_is_the_product(self):
        config = (APP_DIR / "backend" / "app" / "core" / "config.py").read_text(
            encoding="utf-8"
        )
        assert 'STORE_NAME: str = "Klick POS"' in config
        models = (APP_DIR / "backend" / "app" / "models" / "settings.py").read_text(
            encoding="utf-8"
        )
        assert 'DEFAULT_STORE_NAME = "Klick POS"' in models
        assert "'STORE_NAME=Klick POS'" in _iss()


# ─────────────────────────────────────────────────────────────────────────
# Identifiers an upgrade depends on — frozen
# ─────────────────────────────────────────────────────────────────────────


class TestUpgradeStableIdentifiers:
    def test_the_production_app_id_guid_is_unchanged(self):
        source = _iss()
        # Indented because it lives in the production #else branch;
        # Inno escaping: "{{" is a literal "{".
        assert '"{{9E41A7C2-5B3F-4D18-B6E9-0C5A2F7D3301}"' in source
        assert "AppId={#AppIdGuid}" in source

    def test_install_and_data_directories_are_unchanged(self):
        source = _iss()
        assert '#define InstallDir "{autopf}\\Supermarket Pro"' in source
        assert '#define DataDir "{commonappdata}\\SupermarketPro"' in source
        assert '#define PgInstallDir "{autopf}\\SupermarketPro\\PostgreSQL\\18"' in source
        assert '#define PgDataDir "{commonappdata}\\SupermarketPro\\postgres\\data"' in source

    def test_the_database_name_and_postgresql_service_are_unchanged(self):
        source = _iss()
        assert "PendingDbName := 'supermarket_pro'" in source
        assert '#define PgServiceName "postgresql-supermarketpro-18"' in source

    def test_the_winsw_service_id_and_wrapper_are_unchanged(self):
        source = _iss()
        assert "SupermarketProBackend.exe" in source
        assert "render_service_xml.ps1" in source  # writes <app>\\SupermarketProBackend.xml
        verify = (INSTALLER_DIR / "verify_payload.ps1").read_text(encoding="utf-8")
        assert "'SupermarketProBackend.exe'," in verify
        assert "'backend/winsw/SupermarketProBackend.xml'," in verify
        acl = (APP_DIR / "backend" / "winsw" / "grant_data_dir_acl.ps1").read_text(
            encoding="utf-8"
        )
        assert "S-1-5-20" in acl and "icacls" in acl

    def test_the_firewall_rules_keep_their_names(self):
        """Renaming them would leave the previous install's rules behind."""
        source = _iss()
        assert 'name="Supermarket Pro HTTP"' in source
        assert 'name="Supermarket Pro Discovery"' in source
