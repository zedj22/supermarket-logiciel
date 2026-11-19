#!/usr/bin/env python3
"""Installer provisioning driver (R5).

Staged by ``installer/stage_payload.ps1`` into ``<app>\\backend\\`` and
Exec'd by ``setup.iss`` after the offline wheelhouse is installed.  It is
never imported by the application and never runs on the development
machine.

Orchestrates, in one idempotent pass:

  1. ``plan_provisioning()`` — reuse vs dedicated install (R3);
  2. optionally the gated dedicated PostgreSQL install
     (``install_dedicated``: execute + ``R3_ALLOW_POSTGRESQL_INSTALL=1``
     + SHA-256 verify + explicit runner — all four R3 gates);
  3. ``ensure_database_password()`` — ``database.env`` created once;
  4. an optional pre-migration ``pg_dump`` (M3 upgrade);
  5. ``provision_database()`` — create-if-absent, migrations, RBAC;
  6. a JSON report under ``<DATA_DIR>/logs/`` for the evidence log.

Contract 14 (R5 design §7): ``--rehearse-instance`` is the ONLY way an
explicit instance list ever reaches provisioning, and the production
installer never passes it — the shim lives here, in the rehearsal path.

Exit codes: 0 success, 1 provisioning failure (same convention as
``python -m app.core.postgres_provisioning``).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REHEARSE_ENV_NOTE = "rehearsal shim active (contract 14)"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="installer_provision.py")
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--db-name", required=True)
    parser.add_argument("--db-port", type=int, required=True)
    parser.add_argument("--app-user", default="app_user")
    parser.add_argument("--admin-user", default="postgres")
    parser.add_argument(
        "--admin-password-file",
        default="",
        help="file containing the maintenance (superuser) password",
    )
    parser.add_argument(
        "--backup-dir",
        default="",
        help="M3: pg_dump the target database here before migrating",
    )
    parser.add_argument(
        "--fresh-install",
        action="store_true",
        help=(
            "no previous install marker: refuse to touch a database that "
            "already exists on the reused server"
        ),
    )
    parser.add_argument(
        "--save-admin-password",
        action="store_true",
        help=(
            "AFTER a successful provisioning pass, store the supplied "
            "maintenance password in <data-dir>/config/pg_admin.env "
            "(overwriting a stale value); upgrades + M3 backups need it"
        ),
    )
    parser.add_argument(
        "--report-file",
        default="",
        help="defaults to <data-dir>/logs/provision_report.json",
    )
    # Dedicated install (production M1) — staged artefact + pin.
    parser.add_argument("--installer-path", default="")
    parser.add_argument("--installer-sha256", default="")
    parser.add_argument("--pg-install-dir", default="")
    parser.add_argument("--pg-data-dir", default="")
    # The wizard already reached the server with the maintenance password; the
    # plan must use THAT endpoint instead of re-running discovery (which can
    # disagree with a running server, e.g. because the service is merely
    # registered, localized state words, or a slow postmaster start).
    parser.add_argument(
        "--verified-server",
        action="store_true",
        help=(
            "the installer verified this server with the maintenance "
            "password; plan from it instead of rediscovering"
        ),
    )
    parser.add_argument("--admin-host", default="127.0.0.1")
    parser.add_argument(
        "--pg-bin-dir",
        default="",
        help="bin directory of the reused server (psql/pg_dump)",
    )
    # Contract 14: rehearsal-only explicit instance list.
    parser.add_argument(
        "--rehearse-instance",
        default="",
        metavar="HOST:PORT",
        help="REHEARSAL ONLY: explicit instance (never passed by production)",
    )
    parser.add_argument("--rehearse-major", type=int, default=18)
    parser.add_argument(
        "--rehearse-pg-bin",
        default="",
        help="portable server bin dir (psql/pg_dump) for the shim + backup",
    )
    return parser


def _read_password(path: str) -> str:
    """The password exactly as the wizard wrote it.

    Only a trailing line ending is removed: a password may legitimately
    start or end with a space, ``@``, ``%`` or any other character, and
    trimming it produced a credential that did not match the one the
    wizard had already verified with ``psql``.  ``utf-8-sig`` tolerates a
    BOM but never changes the value.
    """
    text = Path(path).read_text(encoding="utf-8-sig")
    if text.endswith("\r\n"):
        text = text[:-2]
    elif text.endswith("\n") or text.endswith("\r"):
        text = text[:-1]
    if not text:
        raise SystemExit(f"empty password file: {path}")
    return text


def _probe_admin(
    *, host: str, port: int, user: str, password: str, dbname: str = "postgres"
) -> None:
    """Verify the maintenance login with keyword arguments, never a URL.

    Keyword arguments cannot be broken by a password containing ``@``,
    ``:`` or ``/`` (a real superuser password ended in ``@`` and the URL
    form silently became an empty host).  Failures are classified so a
    refused login is reported differently from an unreachable server.
    """
    import psycopg2

    from app.core.db_dump import DbParams
    from app.core.postgres_provisioning import classify_connection_error

    params = DbParams(host=host, port=port, dbname=dbname, user=user,
                      password=password)
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            dbname=dbname,
            connect_timeout=15,
        )
    except Exception as exc:  # noqa: BLE001 - classified below
        raise classify_connection_error(exc, params) from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception as exc:  # noqa: BLE001
        raise classify_connection_error(exc, params) from exc
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass


def _persist_admin_password(
    data_dir: Path, password: str, *, overwrite: bool = False
) -> Path:
    """Store the maintenance password — only ever for a VERIFIED password.

    ``overwrite=True`` replaces an existing entry (an operator who corrected
    the password must be able to fix the stored value); the write goes to a
    temporary file first, so an interrupted run can never leave a half
    written credential behind.
    """
    target = data_dir / "config" / "pg_admin.env"
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and not overwrite:
        return target
    tmp = target.with_name("pg_admin.env.tmp")
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(
                "# Supermarket Pro - PostgreSQL maintenance (superuser) password\n"
                "# Written only after the credential was verified; used by\n"
                "# upgrades and pre-migration backups.\n"
                f"PG_ADMIN_PASSWORD={password}\n"
            )
        os.replace(tmp, target)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:  # pragma: no cover
                pass
    return target


def _load_admin_password(data_dir: Path) -> str | None:
    target = data_dir / "config" / "pg_admin.env"
    if not target.is_file():
        return None
    for line in target.read_text(encoding="utf-8").splitlines():
        if line.startswith("PG_ADMIN_PASSWORD="):
            # splitlines() already removed the line ending; nothing
            # else is trimmed: a trailing space or '@' is part of the
            # password and must reach the server unchanged.
            return line.split("=", 1)[1]
    return None


def _write_failure(data_dir: Path, message: str) -> Path | None:
    """Record the human-readable failure reason for the installer log.

    ``setup.iss`` cannot capture a child's stdout, so the real reason is
    written here (and in ``provision_report.json``) and read back into
    ``install_steps.log`` when the provision step fails.  Best effort: a
    logging problem must never change the exit code.
    """
    target = data_dir / "logs" / "provision_error.txt"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        clean = " ".join(str(message).split())
        target.write_text(f"{stamp} {clean}\n", encoding="utf-8")
        return target
    except OSError as exc:  # pragma: no cover - disk/permission problem
        print(f"warning: could not write {target}: {exc}", file=sys.stderr)
        return None


#: How long a freshly installed server may take to accept connections.
READY_TIMEOUT_SECONDS = 90.0


def _stamp(message: str) -> float:
    """Print a timestamped progress line (the wizard log shows these)."""
    now = time.monotonic()
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)
    return now


def _elapsed(started: float, what: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {what} took "
          f"{time.monotonic() - started:.1f} s", flush=True)


def _wait_for_server(
    *, host: str, port: int, user: str, password: str, timeout: float
) -> bool:
    """Poll until the server accepts a real login (or the timeout expires).

    Readiness is proven by ``SELECT 1`` on a real connection, which is the
    only check that matters afterwards: ``sc query`` can say RUNNING while
    the postmaster still refuses TCP, and a listening socket is not enough
    either (authentication and the default database must work too).
    """
    import psycopg2

    deadline = time.monotonic() + timeout
    attempt = 0
    while True:
        attempt += 1
        try:
            conn = psycopg2.connect(
                host=host,
                port=port,
                user=user,
                password=password,
                dbname="postgres",
                connect_timeout=5,
            )
            try:
                with conn.cursor() as cursor:
                    cursor.execute("SELECT 1")
                    cursor.fetchone()
            finally:
                conn.close()
            print(
                f"[{time.strftime('%H:%M:%S')}] PostgreSQL is ready on "
                f"{host}:{port} (attempt {attempt})",
                flush=True,
            )
            return True
        except Exception as exc:  # noqa: BLE001 - every failure means "not yet"
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(
                    f"[{time.strftime('%H:%M:%S')}] PostgreSQL never became "
                    f"ready on {host}:{port} after {attempt} attempt(s): {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                return False
            print(
                f"[{time.strftime('%H:%M:%S')}] waiting for PostgreSQL on "
                f"{host}:{port} (attempt {attempt}): {exc}",
                flush=True,
            )
            time.sleep(min(3.0, remaining))


def _known_instances(spec, *, port: int, user: str) -> list:
    """The instance this process just installed, described from its spec.

    Used instead of discovery after a dedicated install so the plan can only
    conclude "reuse" — the server we created is by definition there.
    """
    from app.core.postgres_discovery import PostgresInstance

    install_dir = Path(spec.resolved_install_dir())
    data_dir = Path(spec.resolved_data_dir())
    bin_dir = install_dir / "bin"
    return [
        PostgresInstance(
            major=spec.major,
            version_text=str(spec.major),
            install_dir=install_dir,
            bin_dir=bin_dir,
            data_dir=data_dir,
            service_name=spec.resolved_service_name(),
            service_state="RUNNING",
            port=port,
            superuser=user,
            psql=(bin_dir / "psql.exe") if (bin_dir / "psql.exe").is_file() else None,
            pg_dump=(bin_dir / "pg_dump.exe")
            if (bin_dir / "pg_dump.exe").is_file()
            else None,
            pg_ctl=(bin_dir / "pg_ctl.exe")
            if (bin_dir / "pg_ctl.exe").is_file()
            else None,
            sources=("installer-known",),
        )
    ]


def _verified_instances(
    *, host: str, port: int, user: str, password: str, bin_dir: str
) -> list | None:
    """Describe the server the WIZARD just reached, as a discovery instance.

    Discovery is deliberately bypassed here: the installer test-connected to
    ``host:port`` with the maintenance password, so that endpoint is the
    authority.  Asking the registry/service/netstat layer again can only
    introduce a race (a postmaster that is still starting, a localized
    netstat state word, a stale service registration).

    Returns ``None`` when the server cannot be reached with those
    credentials, so the caller can fail with a clear reason.
    """
    import psycopg2

    from app.core.postgres_discovery import PostgresInstance

    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            dbname="postgres",
            connect_timeout=10,
        )
    except Exception as exc:  # noqa: BLE001 - any driver error is "unreachable"
        print(
            f"the verified PostgreSQL endpoint {host}:{port} could not be "
            f"reached as {user}: {exc}",
            file=sys.stderr,
        )
        return None
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT current_setting('server_version')")
            version = str(cursor.fetchone()[0])
    except Exception as exc:  # noqa: BLE001
        print(f"could not read the server version: {exc}", file=sys.stderr)
        return None
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass

    head = version.split(".")[0]
    major = int(head) if head.isdigit() else None
    bin_path = Path(bin_dir) if bin_dir else None
    print(
        f"verified server: PostgreSQL {version} on {host}:{port} "
        f"(major {major})"
    )
    return [
        PostgresInstance(
            major=major,
            version_text=version,
            install_dir=bin_path.parent if bin_path else None,
            bin_dir=bin_path,
            service_name=None,
            service_state="RUNNING",
            port=port,
            superuser=user,
            psql=(bin_path / "psql.exe") if bin_path else None,
            pg_dump=(bin_path / "pg_dump.exe") if bin_path else None,
            pg_ctl=(bin_path / "pg_ctl.exe") if bin_path else None,
            sources=("installer-verified",),
        )
    ]


def _fail(data_dir: Path, message: str, code: int) -> int:
    """Report a failure the installer can read back AND return the code.

    Every failure path goes through here (or through ``_write_failure`` in
    ``main``'s exception handlers) so ``provision_error.txt`` always exists
    when the provision step exits non-zero — that file is what
    ``install_steps.log`` quotes as the reason.
    """
    print(f"FAILED: {message}", file=sys.stderr)
    _write_failure(data_dir, message)
    # The report must exist on failure too: without it the installed state
    # ("superuser saved, no database") cannot be diagnosed after the fact.
    _write_report(
        data_dir / "logs" / "provision_report.json",
        {
            "ok": False,
            "error": " ".join(str(message).split()),
            "stage": "installer-provisioning",
            "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        },
    )
    return code


def _write_report(path: Path, payload: dict) -> Path | None:
    """Best-effort JSON report write (never changes an exit code)."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return path
    except (OSError, TypeError, ValueError) as exc:  # pragma: no cover
        print(f"warning: could not write {path}: {exc}", file=sys.stderr)
        return None


def _run_backup(
    *,
    pg_dump: Path,
    host: str,
    port: int,
    user: str,
    password: str,
    dbname: str,
    backup_dir: str,
) -> str:
    out_dir = Path(backup_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / (
        "pre_migrate_" + time.strftime("%Y%m%d_%H%M%S") + ".sql"
    )
    env = {**os.environ, "PGPASSWORD": password}
    argv = [
        str(pg_dump),
        "--no-owner",
        "-h", host,
        "-p", str(port),
        "-U", user,
        "-d", dbname,
        "-f", str(out_file),
    ]
    proc = subprocess.run(
        argv, env=env, capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise SystemExit(
            f"pg_dump failed (rc={proc.returncode}): "
            f"{proc.stdout[-2000:]}{proc.stderr[-2000:]}"
        )
    if not out_file.is_file() or out_file.stat().st_size == 0:
        raise SystemExit(f"pg_dump produced no output: {out_file}")
    return str(out_file)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    data_dir = Path(args.data_dir)
    # Settings() is constructed on first import of app.core.* — pin the
    # environment BEFORE that happens, exactly like the launcher does.
    os.environ["DATA_DIR"] = str(data_dir)

    # Secrets first (same order as run_production.py): ensure_production_secrets
    # generates <DATA_DIR>/config/secrets.env once and publishes the values
    # through os.environ, so the placeholder validator in Settings() cannot
    # fire on the first app.core import.  app.core.secrets is import-safe
    # here (it deliberately never imports app.core.config).
    from app.core.secrets import SecretsError, ensure_production_secrets

    try:
        secrets_result = ensure_production_secrets(data_dir)
    except SecretsError as exc:
        print(f"secrets: {exc}", file=sys.stderr)
        return 1
    print(
        f"secrets: {secrets_result.source} "
        f"({'created' if secrets_result.created else 'existing'}) "
        f"-> {secrets_result.path}"
    )

    # ── instance shim (contract 14) ────────────────────────────────────
    instances = None
    shim = None
    if args.rehearse_instance:
        host, _, port_text = args.rehearse_instance.rpartition(":")
        host = host or "127.0.0.1"
        port = int(port_text)
        bin_dir = Path(args.rehearse_pg_bin) if args.rehearse_pg_bin else None
        from app.core.postgres_discovery import PostgresInstance

        shim = PostgresInstance(
            major=args.rehearse_major,
            version_text=f"{args.rehearse_major}.6",
            install_dir=bin_dir.parent if bin_dir else None,
            bin_dir=bin_dir,
            service_name="R5RehearsalPG",
            service_state="RUNNING",
            port=port,
            superuser=args.admin_user,
            psql=(bin_dir / "psql.exe") if bin_dir else None,
            pg_dump=(bin_dir / "pg_dump.exe") if bin_dir else None,
            pg_ctl=(bin_dir / "pg_ctl.exe") if bin_dir else None,
            sources=("rehearsal-shim",),
        )
        instances = [shim]
        print(f"note: {REHEARSE_ENV_NOTE} -> {shim.label}")

    from app.core.postgres_provisioning import (
        DedicatedInstanceSpec,
        ProvisioningError,
        install_dedicated,
        plan_provisioning,
        provision_database,
    )
    from app.core.secrets import ensure_database_password

    # ── 0. credentials (needed before the plan when the wizard verified) ──
    admin_password = None
    # Where the password came from decides what happens on rejection:
    #   wizard    — typed in the installer UI (the page already test-connected)
    #   stored    — read from config/pg_admin.env of a previous install
    #   generated — created with a dedicated instance (already persisted)
    admin_password_source = None
    if args.admin_password_file:
        admin_password = _read_password(args.admin_password_file)
        admin_password_source = "wizard"

    # ── 1. plan ───────────────────────────────────────────────────────
    # With `--verified-server` the plan is built from the endpoint the
    # installer already authenticated against, so a running PostgreSQL can
    # never be mistaken for a missing one.
    if args.verified_server:
        if admin_password is None:
            return _fail(
                data_dir,
                "the installer marked this server as verified but passed no "
                "maintenance password",
                4,
            )
        instances = _verified_instances(
            host=args.admin_host,
            port=args.db_port,
            user=args.admin_user,
            password=admin_password,
            bin_dir=args.pg_bin_dir,
        )
        if instances is None:
            return _fail(
                data_dir,
                f"the PostgreSQL server at {args.admin_host}:{args.db_port} "
                "was verified by the installer but is no longer reachable "
                "with those credentials; re-run the installer",
                4,
            )

    plan = plan_provisioning(port=args.db_port, instances=instances)
    print(f"plan: {plan.action} ({'; '.join(plan.reasons)})")

    # ── 2. dedicated install (production M1, gated by R3) ─────────────

    if plan.action == "install-dedicated":
        if not args.installer_path:
            return _fail(
                data_dir,
                "no reusable PostgreSQL server was found and no staged "
                "installer was supplied (--installer-path)",
                1,
            )
        if admin_password is None:
            admin_password = _load_admin_password(data_dir)
            if admin_password is not None:
                admin_password_source = "stored"
        if admin_password is None:
            import secrets as _secrets

            admin_password = _secrets.token_urlsafe(18)
            admin_password_source = "generated"
            # The new instance is created with this password, so it is real by
            # construction: persist it immediately (upgrades/backups need it).
            _persist_admin_password(data_dir, admin_password)
        spec = DedicatedInstanceSpec(
            installer_path=Path(args.installer_path),
            sha256=args.installer_sha256,
            data_dir=Path(args.pg_data_dir) if args.pg_data_dir else None,
            install_dir=Path(args.pg_install_dir) if args.pg_install_dir else None,
            port=args.db_port,
        )

        def _runner(argv_: list[str]) -> None:
            started = _stamp(
                "running the PostgreSQL installer (several minutes; its own "
                "log is %TEMP%\\install-postgresql.log)"
            )
            proc = subprocess.run(
                argv_, capture_output=True, text=True, check=False
            )
            _elapsed(started, "PostgreSQL installer")
            # Keep the installer's output: without it a slow or failed
            # install cannot be explained afterwards.
            log_path = data_dir / "logs" / "pg_install.log"
            try:
                log_path.parent.mkdir(parents=True, exist_ok=True)
                log_path.write_text(
                    f"rc={proc.returncode}\n"
                    f"--- stdout ---\n{proc.stdout}\n"
                    f"--- stderr ---\n{proc.stderr}\n",
                    encoding="utf-8",
                    errors="replace",
                )
            except OSError as exc:  # pragma: no cover
                print(f"warning: could not write {log_path}: {exc}", file=sys.stderr)
            # 3010 = Windows "success, reboot required".
            if proc.returncode not in (0, 3010):
                raise SystemExit(
                    f"dedicated installer failed (rc={proc.returncode}): "
                    f"{proc.stdout[-2000:]}{proc.stderr[-2000:]}"
                )

        result = install_dedicated(
            spec,
            password=admin_password,
            execute=True,
            runner=_runner,
            debug_trace=data_dir / "logs" / "pg_edb_install.log",
        )
        if not result.executed:
            return _fail(
                data_dir,
                f"dedicated PostgreSQL install refused: {result.reason}",
                1,
            )
        print(f"dedicated install: {result.reason}")
        _stamp("dedicated install finished")
        # Do NOT re-plan from discovery here.  The instance exists — we have
        # just created it, so its install dir, data dir, port, service name
        # and superuser password are known facts.  Re-discovering could only
        # add a race (service state while the postmaster starts, localized
        # `sc query` output, a not-yet-written registry key).
        if not _wait_for_server(
            host="127.0.0.1",
            port=args.db_port,
            user=args.admin_user,
            password=admin_password,
            timeout=READY_TIMEOUT_SECONDS,
        ):
            return _fail(
                data_dir,
                "the dedicated PostgreSQL install finished but the server "
                f"did not accept connections on 127.0.0.1:{args.db_port} "
                f"within {READY_TIMEOUT_SECONDS} s; service "
                f"{spec.resolved_service_name()!r} and its "
                "C:\\ProgramData\\SupermarketPro\\logs\\pg_install.log "
                "explain why (the instance is kept — a retry resumes)",
                1,
            )
        instances = _known_instances(
            spec, port=args.db_port, user=args.admin_user
        )
        plan = plan_provisioning(port=args.db_port, instances=instances)
        print(f"post-install plan: {plan.action}")

    # ── 3. credentials ────────────────────────────────────────────────
    if admin_password is None:
        admin_password = _load_admin_password(data_dir)
        if admin_password is not None:
            admin_password_source = "stored"

    db_secrets = ensure_database_password(data_dir)
    app_password = db_secrets.password

    from app.core.postgres_provisioning import (
        MalformedConnectionError,
        build_url,
    )

    admin_url = None
    if admin_password:
        # build_url percent-encodes the password (a trailing '@' used to
        # truncate the host and look like an authentication failure).
        admin_url = build_url(
            user=args.admin_user,
            password=admin_password,
            host="127.0.0.1",
            port=args.db_port,
            dbname="postgres",
        )
    app_url = build_url(
        user=args.app_user,
        password=app_password,
        host="127.0.0.1",
        port=args.db_port,
        dbname=args.db_name,
    )
    # Pin both for Settings() and every child process (alembic, pg_dump).
    os.environ["DATABASE_URL"] = app_url
    if admin_url:
        os.environ["PG_ADMIN_URL"] = admin_url

    # ── 3b. reuse / safety gates (R5 hardening) ──────────────────────
    # A reused server is somebody else's PostgreSQL: it needs a maintenance
    # connection to create our role and database, and it must never be
    # asked to adopt a database that this installation did not create.
    # The password is persisted at the very END, and only after provisioning
    # succeeded (see below): a wrong or unverified credential must never be
    # written to config/pg_admin.env, where nothing could ever correct it.

    if plan.action == "reuse":
        from app.core.postgres_provisioning import (
            database_exists,
            check_connectivity,
        )

        if admin_url is not None:
            # Verify the maintenance credential BEFORE touching anything.
            # A password that came from config/pg_admin.env and is rejected
            # here is stale: report it distinctly (exit 4) so the installer
            # asks for the current one instead of failing mid-migration.
            from app.core.postgres_provisioning import (
                CredentialsError,
                InstanceUnavailableError,
            )

            try:
                # Keyword arguments, not the URL: a password containing '@',
                # ':' or '/' must not be able to change the host we talk to.
                _probe_admin(
                    host="127.0.0.1",
                    port=args.db_port,
                    user=args.admin_user,
                    password=admin_password,
                )
                print(
                    f"admin login: OK ({args.admin_user}@127.0.0.1:"
                    f"{args.db_port}/postgres)"
                )
            except InstanceUnavailableError as exc:
                message = (
                    f"no PostgreSQL server is reachable on 127.0.0.1:"
                    f"{args.db_port} (the password was not even tested). "
                    f"Nothing was created or changed. Underlying error: {exc}"
                )
                print(f"FAILED: {message}", file=sys.stderr)
                _write_failure(data_dir, message)
                return 5
            except MalformedConnectionError as exc:
                message = (
                    "the installer built an unusable PostgreSQL connection "
                    f"string; this is a defect, not a password problem. {exc}"
                )
                print(f"FAILED: {message}", file=sys.stderr)
                _write_failure(data_dir, message)
                return 6
            except CredentialsError as exc:
                if admin_password_source == "stored":
                    message = (
                        "the PostgreSQL maintenance password stored in "
                        f"{data_dir / 'config' / 'pg_admin.env'} was "
                        "rejected by the server. Re-run the installer and "
                        "type the current superuser password; the stored "
                        "one is not reused after a rejection. "
                        f"Underlying error: {exc}"
                    )
                else:
                    message = (
                        "the PostgreSQL maintenance password supplied to "
                        "the installer was rejected by the server on "
                        f"127.0.0.1:{args.db_port}. Nothing was created or "
                        "changed and no password was stored. "
                        f"Underlying error: {exc}"
                    )
                print(f"FAILED: {message}", file=sys.stderr)
                _write_failure(data_dir, message)
                return 4

        if admin_url is None:
            # An upgrade (database + role already exist) can work with the
            # application credentials alone; a fresh install on a reused
            # server cannot.  Probe so the message is actionable instead of
            # a bare "password authentication failed for user app_user".
            try:
                check_connectivity(app_url)
            except ProvisioningError as exc:
                message = (
                    "an existing PostgreSQL server was detected on "
                    f"127.0.0.1:{args.db_port} ("
                    f"{plan.instance.label if plan.instance else 'unknown'}"
                    ") and no maintenance (superuser) password was "
                    "supplied. Enter the password of the '"
                    f"{args.admin_user}' user of that server in the "
                    "installer so it can create only its own role and "
                    "database; no other database is ever touched. "
                    f"Underlying error: {exc}"
                )
                print(f"FAILED: {message}", file=sys.stderr)
                _write_failure(data_dir, message)
                return 2
        elif args.fresh_install:
            try:
                occupied = database_exists(admin_url, args.db_name)
            except ProvisioningError as exc:
                print(
                    f"note: could not check whether {args.db_name} exists: "
                    f"{exc}",
                    file=sys.stderr,
                )
                occupied = False
            if occupied:
                message = (
                    f"database {args.db_name} already exists on "
                    f"127.0.0.1:{args.db_port} and was not created by this "
                    "installation. Refusing to migrate or modify it. "
                    "Re-run the installer with /DBNAME=<another_name> to "
                    "create this installation's own database next to it, "
                    "or remove that database yourself if it really is "
                    "yours to reuse — this installer never drops or "
                    "alters a database it did not create."
                )
                print(f"FAILED: {message}", file=sys.stderr)
                _write_failure(data_dir, message)
                return 3

    # ── 4. optional pre-migration backup (M3) ─────────────────────────
    backup_file = ""
    if args.backup_dir:
        source = shim or plan.instance
        if source is None or source.pg_dump is None:
            return _fail(
                data_dir,
                "--backup-dir was requested but no pg_dump is known for "
                "the selected PostgreSQL instance",
                1,
            )
        if admin_password is None:
            return _fail(
                data_dir,
                "--backup-dir was requested but no maintenance "
                "(superuser) password is available",
                1,
            )
        backup_file = _run_backup(
            pg_dump=Path(source.pg_dump),
            host="127.0.0.1",
            port=args.db_port,
            user=args.admin_user,
            password=admin_password,
            dbname=args.db_name,
            backup_dir=args.backup_dir,
        )
        print(f"backup: {backup_file}")

    # ── 5. provision (create-if-absent, migrate, RBAC) ────────────────
    report_path = Path(
        args.report_file
        or (data_dir / "logs" / "provision_report.json")
    )
    try:
        report = provision_database(
            app_url=app_url,
            admin_url=admin_url,
            dbname=args.db_name,
            owner=args.app_user,
            app_password=app_password,
            apply_migrations=True,
            initialize_rbac=True,
            instances=instances,
        )
        payload = report.as_dict()
        payload["backup_file"] = backup_file
        failed = not report.ok
    except ProvisioningError as exc:
        payload = {"ok": False, "error": str(exc)}
        if exc.report is not None:
            payload["report"] = exc.report.as_dict()
        failed = True

    if (
        not failed
        and args.save_admin_password
        and admin_password
        and admin_password_source in ("wizard", "stored")
    ):
        # Verified by the successful provisioning pass itself.
        try:
            saved = _persist_admin_password(
                data_dir, admin_password, overwrite=True
            )
            print(f"maintenance password stored (verified): {saved}")
        except OSError as exc:
            print(
                f"warning: could not store the maintenance password: {exc}",
                file=sys.stderr,
            )

    if failed:
        reason = payload.get("error")
        if not reason:
            steps = (payload.get("report") or {}).get("steps") or []
            failed_steps = [
                f"{s.get('name')}: {s.get('detail')}"
                for s in steps
                if s.get("status") == "failed"
            ]
            reason = "; ".join(failed_steps) or "provisioning reported failure"
        _write_failure(data_dir, reason)

    # Printing the JSON must survive a report that cannot be written: the
    # installer log is the only place an operator sees the real reason.
    print(json.dumps(payload, indent=2, default=str))
    try:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(
            json.dumps(payload, indent=2, default=str), encoding="utf-8"
        )
        print(f"report written: {report_path}")
    except OSError as exc:
        print(
            f"warning: could not write the report {report_path}: {exc}",
            file=sys.stderr,
        )
    return 1 if failed else 0


def _argv_data_dir() -> Path | None:
    argv = sys.argv[1:]
    for index, item in enumerate(argv):
        if item == "--data-dir" and index + 1 < len(argv):
            return Path(argv[index + 1])
        if item.startswith("--data-dir="):
            return Path(item.split("=", 1)[1])
    return None


def _entry() -> int:
    """Run :func:`main` and still leave a reason behind on a hard crash."""
    data_dir = _argv_data_dir()
    try:
        return main()
    except SystemExit as exc:
        # SystemExit comes from _read_password and the pg_dump/dedicated
        # installer helpers; those are real failures the operator must see.
        code = exc.code
        if data_dir is not None and code not in (0, None):
            _write_failure(
                data_dir, f"aborted (exit {code}): {exc}" if str(exc) else
                f"aborted (exit {code})",
            )
        raise
    except BaseException as exc:  # noqa: BLE001 - the installer needs a reason
        if data_dir is not None:
            _write_failure(
                data_dir, f"unexpected error: {exc.__class__.__name__}: {exc}"
            )
        print(f"FAILED: unexpected error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":

    raise SystemExit(_entry())
