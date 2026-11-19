"""Passwords with reserved characters must survive every consumer.

Real report (2026-11-14): the superuser password ended with ``@`` and the
hand-built URL ``postgresql://postgres:<pw>@127.0.0.1:5432/postgres`` became
``…secret@@127.0.0.1…`` — psycopg2 read an empty host ("socket
@127.0.0.1/.s.PGSQL.5432"), and the installer reported *"password rejected"*
although ``psql`` had just verified it. These tests pin the fix:
URLs are built with ``URL.create``/percent-encoding, admin logins use
keyword arguments, SQL literals escape quotes/backslashes, and the file
handoff carries the exact bytes.
"""
from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

import pytest
from sqlalchemy.engine import make_url

from app.core import postgres_provisioning as pp
from app.core import secrets
from app.core.db_dump import DbParams

PROJECT_ROOT = Path(__file__).resolve().parents[4]

#: Every character class that used to break a URL, a cmd.exe line, a .bat
#: file or a SQL literal — plus a password that ENDS with '@' (the report).
PASSWORDS = [
    "trailing@",
    "p@ss:word/1%2#3?4&5!6'7\"8^9",
    "lead space and @",
    "espace finale@ ",
    "a:b/c@d%e#f?g&h!i^j'k\"l",
    "+slash\\back@slash",
]


def _load_installer_provision():
    spec = importlib.util.spec_from_file_location(
        "installer_provision_pw",
        PROJECT_ROOT / "installer" / "installer_provision.py",
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


# ─────────────────────────────────────────────────────────────────────────
# URL building / parsing
# ─────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("password", PASSWORDS)
def test_build_url_round_trips_every_password(password):
    url = pp.build_url(
        user="postgres", password=password, host="127.0.0.1", port=5432,
        dbname="postgres",
    )
    params = DbParams.from_url(url)
    assert params.password == password
    assert params.user == "postgres"
    assert params.host == "127.0.0.1"
    assert params.port == 5432
    assert params.dbname == "postgres"
    # SQLAlchemy (alembic, migrations, RBAC engine) must parse it too.
    assert make_url(url).password == password


@pytest.mark.parametrize("password", PASSWORDS)
def test_no_reserved_character_survives_unencoded(password):
    url = pp.build_url(user="app_user", password=password, dbname="supermarket_pro")
    userinfo = url.split("://", 1)[1].split("@127.0.0.1", 1)[0]
    # everything after the FIRST "@" is the encoded password; a raw second
    # "@" is exactly what broke host parsing.
    assert userinfo.count("@") <= 1


def test_maintenance_url_keeps_the_encoded_password():
    url = pp.build_url(user="postgres", password="trailing@", dbname="mydb")
    maintenance = pp.maintenance_url(url)
    assert DbParams.from_url(maintenance).password == "trailing@"
    assert DbParams.from_url(maintenance).dbname == "postgres"


def test_safe_repr_never_contains_the_password():
    url = pp.build_url(user="postgres", password="trailing@", dbname="mydb")
    assert "trailing@" not in DbParams.from_url(url).safe_repr()


# ─────────────────────────────────────────────────────────────────────────
# Admin login uses keyword arguments (no URL to misparse)
# ─────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("password", PASSWORDS)
def test_probe_admin_passes_keyword_arguments(monkeypatch, password):
    module = _load_installer_provision()
    calls: list[dict] = []

    class FakeCursor:
        def execute(self, sql):
            del sql

        def fetchone(self):
            return (1,)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    class FakeConn:
        def cursor(self):
            return FakeCursor()

        def close(self):
            return None

    def connect(**kwargs):
        calls.append(kwargs)
        return FakeConn()

    fake = types.ModuleType("psycopg2")
    fake.connect = connect  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "psycopg2", fake)

    module._probe_admin(
        host="127.0.0.1", port=5432, user="postgres", password=password
    )
    assert calls == [
        {
            "host": "127.0.0.1",
            "port": 5432,
            "user": "postgres",
            "password": password,
            "dbname": "postgres",
            "connect_timeout": 15,
        }
    ]


# ─────────────────────────────────────────────────────────────────────────
# Error classification (auth vs unreachable vs malformed URL)
# ─────────────────────────────────────────────────────────────────────────


def _params(password: str = "unit-pw-9182") -> DbParams:
    return DbParams(
        host="127.0.0.1", port=5432, dbname="postgres", user="postgres",
        password=password,
    )


class DriverError(Exception):
    def __init__(self, message, pgcode=None):
        super().__init__(message)
        self.pgcode = pgcode


def test_auth_failure_by_sqlstate_is_a_credentials_error():
    exc = DriverError(
        'FATAL:  password authentication failed for user "postgres"', "28P01"
    )
    classified = pp.classify_connection_error(exc, _params())
    assert isinstance(classified, pp.CredentialsError)
    assert "28P01" in str(classified)


def test_auth_failure_without_sqlstate_is_still_credentials():
    exc = DriverError('FATAL: password authentication failed for user "postgres"')
    assert isinstance(
        pp.classify_connection_error(exc, _params()), pp.CredentialsError
    )


def test_broken_url_is_not_reported_as_a_password_problem():
    """The exact sandbox/dev error: a URL that lost its host."""
    exc = DriverError(
        'connection to server on socket "@127.0.0.1/.s.PGSQL.5432" failed: '
        "Invalid argument (0x00002726/10022)"
    )
    classified = pp.classify_connection_error(exc, _params())
    assert isinstance(classified, pp.MalformedConnectionError)
    assert not isinstance(classified, pp.CredentialsError)
    assert "Invalid argument" in str(classified)


def test_refused_connection_is_unreachable_not_credentials():
    exc = DriverError(
        'could not connect to server: Connection refused\n'
        "\tIs the server running on host \"127.0.0.1\" and accepting TCP/IP "
        "connections on port 5432?"
    )
    assert isinstance(
        pp.classify_connection_error(exc, _params()), pp.InstanceUnavailableError
    )


def test_timeout_is_unreachable():
    exc = DriverError("connection to server timed out: timeout expired")
    assert isinstance(
        pp.classify_connection_error(exc, _params()), pp.InstanceUnavailableError
    )


def test_unknown_error_keeps_the_raw_text():
    exc = DriverError("some brand new driver failure")
    classified = pp.classify_connection_error(exc, _params(password="s3cret-pw"))
    assert "some brand new driver failure" in str(classified)
    assert "s3cret-pw" not in str(classified)


# ─────────────────────────────────────────────────────────────────────────
# SQL: CREATE/ALTER ROLE and CREATE DATABASE quoting
# ─────────────────────────────────────────────────────────────────────────


class FakeCursor:
    def __init__(self, statements, rows):
        self.statements = statements
        self.rows = list(rows)

    def execute(self, sql, params=None):
        self.statements.append((sql, params))

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeConn:
    def __init__(self, statements, rows):
        self.autocommit = False
        self._cursor = FakeCursor(statements, rows)

    def cursor(self):
        return self._cursor

    def close(self):
        return None


@pytest.mark.parametrize(
    "password", ["p@ss:word/1%2#3?4&5!6'7\"8^9", "trailing@", "+slash\\back@slash"]
)
def test_ensure_role_quotes_the_password_as_an_escape_literal(password):
    statements: list = []
    url = pp.build_url(user="postgres", password="admin@", dbname="postgres")
    created = pp.ensure_role(
        url, "app_user", password, connect=lambda _url: FakeConn(statements, [None])
    )
    assert created is True
    sql = statements[-1][0]
    assert sql.startswith("CREATE ROLE \"app_user\" LOGIN PASSWORD E'")
    # quotes and backslashes are escaped, never left raw
    assert "''" not in sql.replace("''", "")  # no empty literal trick
    assert "'" not in sql.split("E'", 1)[1][: -1].replace("\\'", "")


@pytest.mark.parametrize("password", ["trailing@", "a'b\"c@d"])
def test_ensure_role_password_quotes_the_password(password):
    statements: list = []
    url = pp.build_url(user="postgres", password="admin@", dbname="postgres")
    changed = pp.ensure_role_password(
        url, "app_user", password,
        connect=lambda _url: FakeConn(statements, [(1,)]),
    )
    assert changed is True
    sql = statements[-1][0]
    assert sql.startswith('ALTER ROLE "app_user" WITH LOGIN PASSWORD E\'')
    assert "app_user" in sql and "DROP" not in sql


def test_create_database_uses_a_validated_identifier_only():
    statements: list = []
    url = pp.build_url(user="postgres", password="admin@", dbname="postgres")
    created = pp.create_database(
        url, "supermarket_pro_install", "app_user",
        connect=lambda _url: FakeConn(statements, [None]),
    )
    assert created is True
    sql = statements[-1][0]
    assert 'CREATE DATABASE "supermarket_pro_install"' in sql
    assert 'OWNER "app_user"' in sql
    assert "admin@" not in sql


# ─────────────────────────────────────────────────────────────────────────
# database.env, DATABASE_URL and pg_admin.env round trips
# ─────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("password", ["trailing@", "a@c:d/e%f#g&h!i^j+k"])
def test_database_env_round_trip_then_url(password, tmp_path):
    result = secrets.ensure_database_password(tmp_path, external=password)
    assert result.password == password
    assert secrets.load_database_password(tmp_path) == password

    # run_production publishes this URL for Settings()/alembic.
    from run_production import _database_url_with_password

    url = _database_url_with_password(
        "postgresql://app_user@127.0.0.1:5432/supermarket_pro_install", password
    )
    assert url is not None
    assert DbParams.from_url(url).password == password
    assert make_url(url).password == password


def test_database_env_rejects_surrounding_whitespace_instead_of_trimming(
    tmp_path,
):
    with pytest.raises(secrets.SecretsError):
        secrets.ensure_database_password(tmp_path, external=" pass word ")


@pytest.mark.parametrize("password", PASSWORDS)
def test_admin_password_file_round_trip(password, tmp_path):
    """pg_admin.env is written and read byte-for-byte (no trimming)."""
    module = _load_installer_provision()
    (tmp_path / "config").mkdir()
    module._persist_admin_password(tmp_path, password)
    assert module._load_admin_password(tmp_path) == password


@pytest.mark.parametrize("password", PASSWORDS)
def test_wizard_handoff_file_carries_the_exact_bytes(password, tmp_path):
    """What setup.iss writes with SaveStringToFile (no newline) is read back."""
    module = _load_installer_provision()
    handoff = tmp_path / "pg_admin_password.txt"
    handoff.write_bytes(password.encode("utf-8"))
    assert module._read_password(str(handoff)) == password

    with_newline = tmp_path / "with_newline.txt"
    with_newline.write_bytes(password.encode("utf-8") + b"\r\n")
    assert module._read_password(str(with_newline)) == password
