"""Unit tests for R3 read-only PostgreSQL discovery (§2).

Everything here is hermetic: the registry, the filesystem scan and the
Windows service probes are stubbed, so no test depends on what is
installed on the machine running the suite.  The one test that does look
at the real machine is clearly marked and only asserts read-only
behaviour.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from app.core import postgres_discovery as disc

# ── canned probe output ─────────────────────────────────────────────────

SC_QUERY_OUTPUT = """\
SERVICE_NAME        : postgresql-x64-18
 TYPE               : 10  WIN32_OWN_PROCESS
 STATE              : 4  RUNNING
 WIN32_EXIT_CODE    : 0
 SERVICE_EXIT_CODE  : 0
 CHECKPOINT         : 0
 WAIT_HINT          : 0
 DISPLAY_NAME       : postgresql-x64-18 - PostgreSQL Server 18

SERVICE_NAME        : postgresql-x64-16
 TYPE               : 10  WIN32_OWN_PROCESS
 STATE              : 1  STOPPED
 WIN32_EXIT_CODE    : 1077
 SERVICE_EXIT_CODE  : 0
 CHECKPOINT         : 0
 WAIT_HINT          : 0
 DISPLAY_NAME       : postgresql-x64-16 - PostgreSQL Server 16

SERVICE_NAME        : Spooler
 TYPE               : 10  WIN32_OWN_PROCESS
 STATE              : 4  RUNNING
 DISPLAY_NAME       : Print Spooler
"""

SC_QC_OUTPUT = """\
[SC] QueryServiceConfig SUCCESS

SERVICE_NAME        : postgresql-x64-18
        TYPE               : 10  WIN32_OWN_PROCESS
        START_TYPE         : 2   AUTO_START
        ERROR_CONTROL      : 1   NORMAL
        BINARY_PATH_NAME   : "C:\\Program Files\\PostgreSQL\\18\\bin\\pg_ctl.exe" runservice -N "postgresql-x64-18" -D "C:\\Program Files\\PostgreSQL\\18\\data" -w
        LOAD_ORDER_GROUP   :
        TAG                : 0
        DISPLAY_NAME       : postgresql-x64-18 - PostgreSQL Server 18
        DEPENDENCIES       : RPCSS
        SERVICE_START_NAME : NT AUTHORITY\\NetworkService
"""

def assert_read_only_probe(argv: list[str]) -> None:
    """Fail unless ``argv`` is one of the three documented read-only probes.

    Checked token by token (not on a joined string) so that no extra
    argument — a service to stop, a flag to reconfigure — can slip past.
    """
    assert argv, "empty command"
    if argv[0] == "sc.exe":
        assert argv[1] in {"query", "qc"}, argv
        # `sc query state= all` / `sc qc <service name>` — nothing else.
        for token in argv[2:]:
            assert token in {"state=", "all"} or re.fullmatch(
                r"[A-Za-z0-9_.\-]+", token
            ), argv
        return
    if argv[0].endswith("psql.exe"):
        assert argv[1:] == ["--version"], argv
        return
    raise AssertionError(f"unexpected discovery probe: {argv!r}")


@pytest.fixture()
def isolated(monkeypatch):
    """Discovery that cannot reach the real registry / disk / services."""
    monkeypatch.setattr(disc, "_registry_facts", lambda: [])
    monkeypatch.setattr(disc, "_filesystem_facts", lambda: [])
    monkeypatch.setattr(disc, "_service_facts", lambda: [])
    for name in (
        "PG_INSTALL_DIR",
        "PG_BIN_DIR",
        "PG_DATA_DIR",
        "PG_SERVICE_NAME",
    ):
        monkeypatch.setattr(disc.settings, name, "")
    monkeypatch.setattr(disc.settings, "PG_PORT", 0)
    return monkeypatch


# ── pure parsers ────────────────────────────────────────────────────────


class TestParsers:
    def test_sc_query_states_lists_only_postgres_services(self):
        states = disc.parse_sc_query_states(SC_QUERY_OUTPUT)
        assert states == {
            "postgresql-x64-18": "RUNNING",
            "postgresql-x64-16": "STOPPED",
        }
        assert "Spooler" not in states

    def test_sc_query_names_helper_matches_states(self):
        assert disc.parse_sc_query(SC_QUERY_OUTPUT) == [
            "postgresql-x64-18",
            "postgresql-x64-16",
        ]

    def test_sc_qc_extracts_binary_data_dir_and_account(self):
        facts = disc.parse_sc_qc(SC_QC_OUTPUT)
        # `sc qc` does not report state on every build, so it is never
        # taken from here (state comes from `sc query state= all`).
        assert "state" not in facts
        assert facts["service_account"] == r"NT AUTHORITY\NetworkService"
        assert facts["data_dir"] == r"C:\Program Files\PostgreSQL\18\data"
        assert facts["bin_dir"] == r"C:\Program Files\PostgreSQL\18\bin"
        assert facts["executable"].endswith("pg_ctl.exe")

    def test_sc_qc_accepts_the_older_path_name_key(self):
        output = (
            "SERVICE_NAME : postgresql-x64-14\n"
            "  PATH_NAME  : \"C:\\PG14\\bin\\pg_ctl.exe\" runservice "
            "-D \"C:\\PG14\\data\"\n"
        )
        facts = disc.parse_sc_qc(output)
        assert facts["bin_dir"] == r"C:\PG14\bin"
        assert facts["data_dir"] == r"C:\PG14\data"

    @pytest.mark.parametrize(
        ("text", "expected"),
        [
            ("psql (PostgreSQL) 18.6", 18),
            ("psql (PostgreSQL) 17.2", 17),
            ("18.6-4", 18),
            ("16", 16),
            ("", None),
            ("not a version", None),
        ],
    )
    def test_parse_version_text(self, text, expected):
        assert disc.parse_version_text(text) == expected

    def test_port_is_read_from_postgresql_conf_never_guessed(self, tmp_path):
        conf = tmp_path / "postgresql.conf"
        conf.write_text(
            "# port = 5432 would be the default\n"
            "listen_addresses = '*'\n"
            "port = 5433    # customer changed it\n",
            encoding="utf-8",
        )
        assert disc._port_from_conf(tmp_path) == 5433

    def test_port_is_none_when_conf_is_absent(self, tmp_path):
        assert disc._port_from_conf(tmp_path) is None
        assert disc._port_from_conf(None) is None

    def test_first_token_handles_quoted_paths(self):
        assert disc._first_token('"C:\\a b\\c.exe" -x') == "C:\\a b\\c.exe"
        assert disc._first_token("C:\\a\\c.exe -x") == "C:\\a\\c.exe"
        assert disc._first_token("") == ""


# ── version policy ──────────────────────────────────────────────────────


class TestVersionPolicy:
    @pytest.mark.parametrize("major", [9, 11, 12])
    def test_below_minimum_is_refused(self, major):
        compat = disc.check_compatibility(disc.PostgresInstance(major=major))
        assert compat.accepted is False
        assert compat.verified is False
        assert "13" in compat.reason

    @pytest.mark.parametrize("major", [13, 14, 15, 16, 17, 18])
    def test_within_range_is_accepted_and_verified(self, major):
        compat = disc.check_compatibility(disc.PostgresInstance(major=major))
        assert compat.accepted is True
        assert compat.verified is True

    def test_newer_than_verified_is_accepted_but_not_trusted(self):
        compat = disc.check_compatibility(disc.PostgresInstance(major=19))
        assert compat.accepted is True
        assert compat.verified is False
        assert "allow_unverified" in compat.reason

    def test_unknown_version_is_never_guessed(self):
        compat = disc.check_compatibility(disc.PostgresInstance(major=None))
        assert compat.accepted is False
        assert "could not be determined" in compat.reason

    def test_constants_are_evidence_based(self):
        # migrations 0002/0015 need gen_random_uuid() (core since PG13),
        # 0023 needs trusted pg_trgm (PG13+), the suite runs on PG18.
        assert disc.MIN_SUPPORTED_MAJOR == 13
        assert disc.VERIFIED_MAX_MAJOR == 18


# ── selection ───────────────────────────────────────────────────────────


def _instance(**kwargs) -> disc.PostgresInstance:
    defaults = dict(
        major=18,
        version_text="18.6",
        install_dir=Path(r"C:\Program Files\PostgreSQL\18"),
        service_name="postgresql-x64-18",
        service_state="RUNNING",
        port=5432,
    )
    defaults.update(kwargs)
    return disc.PostgresInstance(**defaults)


class TestSelection:
    def test_prefers_running_over_stopped(self):
        stopped = _instance(
            major=18, service_state="STOPPED", service_name="pg18"
        )
        running = _instance(
            major=16, service_state="RUNNING", service_name="pg16",
            install_dir=Path(r"C:\Program Files\PostgreSQL\16"),
        )
        assert disc.select_instance([stopped, running]) is running

    def test_prefers_verified_over_unverified(self):
        newer = _instance(major=19, service_name="pg19")
        older = _instance(
            major=18,
            service_name="pg18",
            install_dir=Path(r"C:\Program Files\PostgreSQL\18"),
        )
        # Without the opt-in the unverified major is not even a candidate.
        assert disc.select_instance([newer, older]) is older
        # With the opt-in a *verified* server still wins over a newer
        # unverified one: "allow unverified" widens the pool, it does not
        # downgrade the preference.
        assert (
            disc.select_instance([newer, older], allow_unverified=True)
            is older
        )
        # …and when nothing verified exists it becomes selectable.
        assert (
            disc.select_instance([newer], allow_unverified=True) is newer
        )
        assert disc.select_instance([newer]) is None

    def test_refuses_everything_when_the_service_is_stopped(self):
        stopped = _instance(service_state="STOPPED")
        assert disc.select_instance([stopped]) is None

    def test_refuses_incompatible_versions(self):
        ancient = _instance(major=12)
        assert disc.select_instance([ancient]) is None

    def test_returns_none_for_an_empty_list(self):
        assert disc.select_instance([]) is None


# ── sources ─────────────────────────────────────────────────────────────


class TestSources:
    def test_filesystem_scan_finds_every_installed_version(self, tmp_path):
        """No single hardcoded version path (§2: detect, don't assume)."""
        for major in ("16", "17", "18"):
            bin_dir = tmp_path / major / "bin"
            bin_dir.mkdir(parents=True)
            (bin_dir / "psql.exe").write_bytes(b"not a real binary")
            (bin_dir / "pg_dump.exe").write_bytes(b"not a real binary")

        monkeypatch = pytest.MonkeyPatch()
        try:
            monkeypatch.setattr(disc, "PG_INSTALL_ROOTS", (tmp_path,))
            monkeypatch.setattr(disc, "_probe_version", lambda _b: (None, None))
            entries = disc._filesystem_facts()
        finally:
            monkeypatch.undo()

        majors = sorted(int(e["major"]) for e in entries)
        assert majors == [16, 17, 18]
        assert all(Path(e["psql"]).name == "psql.exe" for e in entries)

    def test_registry_facts_are_mapped_onto_instance_fields(self, monkeypatch):
        monkeypatch.setattr(
            disc,
            "_registry_facts",
            lambda: [
                {
                    "_source": "registry",
                    "install_dir": r"C:\Program Files\PostgreSQL\17",
                    "data_dir": r"C:\Program Files\PostgreSQL\17\data",
                    "service_name": "postgresql-x64-17",
                    "service_account": "NT AUTHORITY\\NetworkService",
                    "superuser": "postgres",
                    "version_text": "17.4-1",
                }
            ],
        )
        monkeypatch.setattr(disc, "_filesystem_facts", lambda: [])
        monkeypatch.setattr(disc, "_service_facts", lambda: [])

        instances = disc.discover_instances()
        assert len(instances) == 1
        found = instances[0]
        assert found.major == 17
        assert found.service_name == "postgresql-x64-17"
        assert found.superuser == "postgres"
        assert found.sources == ("registry",)

    def test_service_facts_come_from_the_service_manager(self, monkeypatch):
        monkeypatch.setattr(disc, "_registry_facts", lambda: [])
        monkeypatch.setattr(disc, "_filesystem_facts", lambda: [])
        monkeypatch.setattr(
            disc,
            "_service_facts",
            lambda: [
                {
                    "_source": "service",
                    "service_name": "postgresql-supermarketpro-16",
                    "state": "RUNNING",
                    "install_dir": r"D:\pg\16",
                    "bin_dir": r"D:\pg\16\bin",
                    "data_dir": r"D:\pgdata\16",
                    "major": "16",
                }
            ],
        )
        monkeypatch.setattr(disc.settings, "PG_PORT", 0)

        instances = disc.discover_instances()
        assert len(instances) == 1
        found = instances[0]
        assert found.is_running is True
        assert found.sources == ("service",)
        assert found.major == 16

    def test_the_same_server_reported_twice_is_one_instance(self, monkeypatch):
        install = r"C:\Program Files\PostgreSQL\18"
        monkeypatch.setattr(
            disc,
            "_registry_facts",
            lambda: [
                {
                    "_source": "registry",
                    "install_dir": install,
                    "service_name": "postgresql-x64-18",
                    "version_text": "18.6-4",
                }
            ],
        )
        monkeypatch.setattr(
            disc,
            "_filesystem_facts",
            lambda: [
                {
                    "_source": "filesystem",
                    "install_dir": install,
                    "bin_dir": install + r"\bin",
                    "psql": install + r"\bin\psql.exe",
                    "major": "18",
                }
            ],
        )
        monkeypatch.setattr(
            disc,
            "_service_facts",
            lambda: [
                {
                    "_source": "service",
                    "service_name": "postgresql-x64-18",
                    "install_dir": install,
                    "state": "RUNNING",
                }
            ],
        )

        instances = disc.discover_instances()
        assert len(instances) == 1
        assert set(instances[0].sources) == {
            "registry",
            "filesystem",
            "service",
        }

    def test_explicit_override_wins_over_discovered_values(self, monkeypatch):
        install = r"C:\Program Files\PostgreSQL\17"
        monkeypatch.setattr(disc.settings, "PG_INSTALL_DIR", install)
        monkeypatch.setattr(disc.settings, "PG_PORT", 5499)
        monkeypatch.setattr(
            disc,
            "_registry_facts",
            lambda: [
                {
                    "_source": "registry",
                    "install_dir": install,
                    "version_text": "17.4-1",
                }
            ],
        )
        monkeypatch.setattr(disc, "_filesystem_facts", lambda: [])
        monkeypatch.setattr(disc, "_service_facts", lambda: [])

        instances = disc.discover_instances()
        assert len(instances) == 1
        found = instances[0]
        assert found.port == 5499  # the setting, not a discovered value
        assert found.major == 17  # still learned from the registry
        assert found.sources == ("override", "registry")

    def test_port_override_alone_never_invents_an_instance(self, isolated):
        monkeypatch = isolated
        monkeypatch.setattr(disc.settings, "PG_PORT", 5433)
        assert disc.discover_instances() == []


# ── read-only guarantees ────────────────────────────────────────────────


class TestReadOnlyGuarantees:
    def test_discovery_runs_only_the_documented_read_only_probes(
        self, monkeypatch, tmp_path
    ):
        """The single chokepoint for subprocesses is on a tight leash."""
        install_dir = tmp_path / "18"
        bin_dir = install_dir / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "psql.exe").write_bytes(b"not a real binary")
        (bin_dir / "pg_dump.exe").write_bytes(b"not a real binary")

        qc_output = (
            "SERVICE_NAME        : postgresql-x64-18\n"
            "  BINARY_PATH_NAME   : \""
            + str(bin_dir / "pg_ctl.exe")
            + "\" runservice -D \""
            + str(install_dir / "data")
            + "\"\n"
            "  SERVICE_START_NAME : NT AUTHORITY\\NetworkService\n"
            "  DISPLAY_NAME       : PostgreSQL Server 18\n"
        )

        launched: list[list[str]] = []

        def fake_run(argv):
            launched.append(list(argv))
            joined = " ".join(argv)
            if joined.startswith("sc.exe query"):
                return SC_QUERY_OUTPUT
            if joined.startswith("sc.exe qc"):
                return qc_output
            if joined.endswith("--version"):
                return "psql (PostgreSQL) 18.6"
            return ""

        monkeypatch.setattr(disc, "_run_command", fake_run)
        monkeypatch.setattr(disc, "_registry_facts", lambda: [])
        monkeypatch.setattr(disc, "PG_INSTALL_ROOTS", (tmp_path,))
        monkeypatch.setattr(disc.settings, "PG_PORT", 0)

        # Registry is stubbed out, filesystem + services run for real
        # (against the fake probe and the temporary install tree).
        disc.discover_instances()

        assert launched, "discovery should have probed something"
        commands = {" ".join(argv) for argv in launched}
        assert any(c.startswith("sc.exe query") for c in commands)
        assert any(c.startswith("sc.exe qc") for c in commands)
        assert any(c.endswith("--version") for c in commands)
        for argv in launched:
            assert_read_only_probe(argv)

    def test_module_source_never_touches_the_database(self):
        """No driver import, no engine, no DDL anywhere in the module."""
        source = Path(disc.__file__).read_text(encoding="utf-8")
        assert "psycopg2" not in source
        assert "create_engine" not in source
        assert "Session" not in source
        for forbidden in (
            "DROP DATABASE",
            "DROP SCHEMA",
            "DROP TABLE",
            "TRUNCATE",
            "DELETE FROM",
            "INSERT INTO",
            "CREATE DATABASE",
        ):
            assert forbidden not in source.upper()

    def test_module_does_not_hardcode_one_install_path(self):
        source = Path(disc.__file__).read_text(encoding="utf-8")
        # Both Program Files roots must be probed, and the version has to
        # come from the discovered directory / psql, never a constant.
        assert r"C:\Program Files\PostgreSQL" in source
        assert r"C:\Program Files (x86)\PostgreSQL" in source
        assert r"PostgreSQL\18" not in source
        assert r"PostgreSQL\17" not in source

    def test_settings_overrides_exist_and_default_to_empty(self):
        from app.core.config import Settings

        fields = Settings.model_fields
        for name in (
            "PG_INSTALL_DIR",
            "PG_BIN_DIR",
            "PG_DATA_DIR",
            "PG_SERVICE_NAME",
        ):
            assert name in fields
            assert fields[name].default == ""
        assert fields["PG_PORT"].default == 0


class TestDedicatedInstanceIsSeenAsRunning:
    """Regression: our dedicated instance is `postgresql-supermarketpro-18`.

    The install reported a Running EDB service as "not running" because the
    state word was read instead of its Windows state code.  These cases pin
    the locale-proof reading.
    """

    DEDICATED = (
        "SERVICE_NAME: postgresql-supermarketpro-18\r\n"
        "DISPLAY_NAME: postgresql-supermarketpro-18 - PostgreSQL Server 18\r\n"
        "        TYPE               : 10  WIN32_OWN_PROCESS\r\n"
        "        STATE              : 4  RUNNING\r\n"
        "                                (STOPPABLE, NOT_PAUSABLE, "
        "ACCEPTS_SHUTDOWN)\r\n"
        "        WIN32_EXIT_CODE    : 0  (0x0)\r\n"
        "        CHECKPOINT         : 0x0\r\n"
    )

    def test_custom_service_name_is_running(self):
        assert disc.parse_sc_query_states(self.DEDICATED) == {
            "postgresql-supermarketpro-18": "RUNNING"
        }

    def test_instance_from_that_state_is_running(self):
        instance = disc.PostgresInstance(
            major=18,
            service_name="postgresql-supermarketpro-18",
            service_state=disc.parse_sc_query_states(self.DEDICATED)[
                "postgresql-supermarketpro-18"
            ],
        )
        assert instance.is_running is True

    def test_single_service_localized_output_still_reports_running(self):
        localized = (
            "NOM_SERVICE: postgresql-supermarketpro-18\r\n"
            "        TYPE               : 10  WIN32_OWN_PROCESS\r\n"
            "        ÉTAT               : 4  EN COURS D'EXÉCUTION\r\n"
        )
        assert disc.parse_sc_single_state(localized) == "RUNNING"

    def test_stopped_instance_is_still_reported_as_stopped(self):
        stopped = self.DEDICATED.replace(": 4  RUNNING", ": 1  STOPPED")
        assert (
            disc.parse_sc_query_states(stopped)[
                "postgresql-supermarketpro-18"
            ]
            == "STOPPED"
        )
