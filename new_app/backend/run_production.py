"""Production launcher for the Supermarket Pro backend (R2).

Starts ``app.main:app`` through Uvicorn with the configured production
host and port, from *any* current working directory, without an
activated developer virtual environment and without ``--reload``.

Usage::

    python run_production.py            # prepare + serve
    python run_production.py --check    # prepare + print resolved config, exit

What it does, in order:

1. requires ``DATA_DIR`` in the process environment (the installer /
   service wrapper sets it) and anchors a relative value to the backend
   root — never the CWD;
2. requires the production ``<DATA_DIR>/config/.env`` to exist;
3. sets ``APP_ENV=production``, ``PYTHONDONTWRITEBYTECODE=1`` and
   ``chdir``s to the backend root explicitly;
4. provisions / loads the per-install secrets **before**
   ``app.core.config`` is imported, so ``Settings()`` never evaluates
   the placeholder validator with placeholder values;
5. reads ``<DATA_DIR>/config/database.env`` (R3) and publishes the
   assembled ``DATABASE_URL`` for the application role into the process
   environment — also **before** ``Settings()`` is imported, so
   pydantic-settings' env-over-dotenv precedence picks it up (R4 §5
   handoff).  An already-exported ``DATABASE_URL`` wins untouched and
   ``PG_ADMIN_URL`` is never read here;
6. re-checks the secrets are not repository placeholders (fail closed);
7. installs Ctrl+C / Ctrl+Break handlers so the stop signal WinSW sends
   ends in a clean exit code (see :func:`install_signal_handlers`);
8. serves with ``reload=False``, ``workers=1`` and the uvicorn logging
   config disabled so the application's own logging (stdout + rotating
   file sink) is the single source of truth.

Development is untouched: keep using ``python -m uvicorn app.main:app
--reload`` from ``new_app/backend`` exactly as before.

Exit codes::

    0  clean start/stop (or successful --check)
    1  the server failed after configuration was accepted
    2  usage error / DATA_DIR missing
    3  secret provisioning refused (missing when load-only, corrupted
       secrets.env or database.env)
    4  configuration invalid (missing .env, unusable settings, placeholder)
    5  the configured HTTP port is already in use (P5: a typed, actionable
       failure instead of a generic uvicorn bind traceback — WinSW's
       restart policy and the installer log can tell them apart)
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

from dotenv import dotenv_values

#: This file lives at the backend root; absolute import root for `app.*`.
BACKEND_ROOT = Path(__file__).resolve().parent

EXIT_OK = 0
EXIT_SERVE_FAILED = 1
EXIT_USAGE = 2
EXIT_SECRETS_FAILED = 3
EXIT_CONFIG_INVALID = 4
#: P5 — the configured HTTP port cannot be bound.  A distinct code lets
#: WinSW's failure log, the installer step log and an operator tell
#: "another program owns 8000" apart from "the application crashed".
EXIT_PORT_IN_USE = 5

APP_TARGET = "app.main:app"

#: Descriptor file name shared with the Flutter client
#: (``lib/features/devices/device_identity.dart``).
ENDPOINT_FILE_NAME = "supermarket_endpoint.json"

#: Locale-proof ``BUILTIN\Users`` SID for ``icacls /grant *…`` — English
#: group names do not resolve on non-English Windows (verified: name
#: lookup fails with exit 1332 on French Windows).
_USERS_SID = "*S-1-5-32-545"


def resolve_data_dir() -> Path | None:
    """Absolute production data root, or ``None`` with a fatal message."""
    raw = (os.environ.get("DATA_DIR") or "").strip()
    if not raw:
        print(
            "FATAL: DATA_DIR is not set. The production launcher needs an "
            "explicit writable data root, e.g. "
            "set DATA_DIR=C:\\ProgramData\\SupermarketPro",
            file=sys.stderr,
        )
        return None
    path = Path(raw)
    if not path.is_absolute():
        # Same rule as app.core.config: relative anchors to the backend
        # root, never to the process CWD.
        path = BACKEND_ROOT / path
    return path


def build_uvicorn_kwargs(cfg: Any) -> dict[str, Any]:
    """The exact keyword arguments handed to ``uvicorn.run``.

    Single worker is a hard invariant (rate limits and pairing state are
    process-local) and ``reload`` is never used in production.
    """
    return {
        "app": APP_TARGET,
        "host": cfg.HOST,
        "port": int(cfg.PORT),
        "reload": False,
        "workers": 1,
        "log_config": None,
        "access_log": True,
    }


def _probe_port(host: str, port: int) -> OSError | None:
    """Return the bind error for ``host:port``, or ``None`` when it is free.

    P5: a pre-flight bind is the only way to turn a port conflict into an
    actionable message before uvicorn prints a socket traceback.  Wildcard
    addresses are probed as ``""`` (every interface, which is what uvicorn
    binds on Windows for ``0.0.0.0``).  The socket is always closed, so the
    port is released immediately; the remaining race with another process is
    inherent, and the real bind still fails with the same exit code below.
    """
    import socket

    probe_host = "" if host in ("", "0.0.0.0", "::") else host
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((probe_host, int(port)))
        return None
    except OSError as exc:  # EADDRINUSE / WSAEADDRINUSE (10048)
        return exc
    finally:
        try:
            sock.close()
        except OSError:  # pragma: no cover - close never fails in practice
            pass


def install_signal_handlers() -> None:
    """Make Ctrl+C / Ctrl+Break end in a clean exit code.

    uvicorn installs its own handlers while serving and, on the way out,
    restores the *previous* ones before re-raising the captured signal.
    The Windows default for ``SIGBREAK`` terminates the process with a
    non-zero status even after a perfectly graceful shutdown — which the
    service wrapper would report as a failure and restart.  Raising
    ``KeyboardInterrupt`` instead lets :func:`main` return ``EXIT_OK``.
    """
    def _to_keyboard_interrupt(_signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    candidates = [signal.SIGINT]
    sigbreak = getattr(signal, "SIGBREAK", None)
    if sigbreak is not None:
        candidates.append(sigbreak)
    for sig in candidates:
        try:
            signal.signal(sig, _to_keyboard_interrupt)
        except (OSError, ValueError, RuntimeError):  # pragma: no cover
            pass


def build_runtime_report(
    cfg: Any,
    secrets_result: Any,
    uvicorn_kwargs: dict,
    log_file_enabled: bool,
    database_url_source: str,
    database_env_path: Path,
) -> dict:
    """Resolved production runtime description (never contains secrets)."""
    log_dir = Path(cfg.LOG_DIR)
    return {
        "app": APP_TARGET,
        "app_env": cfg.APP_ENV,
        "host": cfg.HOST,
        "port": int(cfg.PORT),
        "reload": uvicorn_kwargs["reload"],
        "workers": uvicorn_kwargs["workers"],
        "working_directory": str(Path.cwd()),
        "backend_root": str(BACKEND_ROOT),
        "data_dir": cfg.DATA_DIR,
        "log_dir": str(log_dir),
        "log_file": str(log_dir / cfg.LOG_FILE_NAME),
        "log_file_enabled": log_file_enabled,
        "env_file": cfg.model_config.get("env_file"),
        "secrets_file": str(secrets_result.path),
        "secrets_source": secrets_result.source,
        # R4 §5 handoff: where the effective DATABASE_URL came from.
        # The URL itself is deliberately absent — it embeds the password.
        "database_url_source": database_url_source,
        "database_env_file": str(database_env_path),
        "uvicorn": dict(uvicorn_kwargs),
    }


def _prepare_environment(data_dir: Path) -> None:
    """Environment + CWD that must be in place before any app import."""
    os.environ["DATA_DIR"] = str(data_dir)
    # Never write __pycache__ into a read-only Program Files tree.
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    # This launcher *is* the production entry point: always production.
    os.environ["APP_ENV"] = "production"
    os.chdir(BACKEND_ROOT)


def _account_name() -> str:
    """The Windows account this process runs as (for permission errors)."""
    domain = os.environ.get("USERDOMAIN", "")
    user = os.environ.get("USERNAME", "")
    if not user:
        try:
            import getpass

            user = getpass.getuser()
        except Exception:  # noqa: BLE001 - diagnostics only
            user = "<unknown>"
    return f"{domain}\\{user}" if domain and user else user


def _unreadable_hint(path: Path, exc: BaseException) -> str:
    """Permission failure with the account and file the operator needs.

    The sandbox crash-loop only said "cannot read …secrets.env
    (PermissionError)"; nothing named the account, so the ACL problem could
    not be diagnosed from the service log alone.
    """
    sid = "*S-1-5-20"
    return (
        f"cannot read {path} ({exc.__class__.__name__}) as account "
        f"{_account_name()}: the DACL on that file does not grant this "
        "account read access. Repair with: "
        f'icacls "{path}" /grant {sid}:R   '
        "(the installer applies this automatically; see "
        "installer_selfcheck.py --phase pre-service and the ACL section of "
        "BUILD_RELEASE_REPORT.md)"
    )


def _harden_config_acls(data_dir: Path) -> None:
    """Best-effort explicit DACLs for this install's config files.

    The installer applies them before the service starts; repeating the
    pass here covers files this process creates (first-run secrets) and
    reports anything still wrong.  Never fatal: without WRITE_DAC the
    installer's ACLs stand and the service keeps running.
    """
    if os.name != "nt":
        return
    try:
        from app.core import acl

        report = acl.harden_data_dir(data_dir)
    except Exception as exc:  # noqa: BLE001 - diagnostics must never stop us
        print(f"warning: could not apply config ACLs: {exc}", file=sys.stderr)
        return
    for problem in report.problems:
        print(f"warning: config ACL: {problem}", file=sys.stderr)


def _database_url_with_password(base_url: str, password: str) -> str | None:
    """Rebuild ``base_url`` with ``password`` as its credential.

    Returns ``None`` for anything that is not a PostgreSQL URL with a
    userinfo component (a test's SQLite URL, an empty value, a URL with
    no user) — the caller then publishes nothing and leaves the
    ``.env`` value alone.  The password is percent-encoded so a
    ``@``/``:``/``#`` in it cannot corrupt the URL.
    """
    raw = (base_url or "").strip().strip("\"'")
    if not raw:
        return None
    parts = urlsplit(raw)
    if parts.scheme.lower() not in {"postgres", "postgresql"}:
        return None
    userinfo, sep, hostport = parts.netloc.rpartition("@")
    if not sep or not hostport:
        return None
    user = userinfo.partition(":")[0]
    if not user:
        return None
    netloc = f"{user}:{quote(password, safe='')}@{hostport}"
    return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def _publish_database_url(env_file: Path, password: str | None) -> str:
    """Publish ``DATABASE_URL`` for the application role (R4 §5 handoff).

    The password written by R3's provisioning pass to
    ``<DATA_DIR>/config/database.env`` is substituted into the
    installer's ``DATABASE_URL`` and pushed into ``os.environ`` *before*
    ``app.core.config`` is imported, so ``Settings()`` resolves it
    through pydantic-settings' normal env-over-dotenv precedence.

    Returns where the effective value came from — one of
    ``process_env`` (already exported; left untouched), ``database_env``
    (assembled and published), ``dotenv`` (no ``database.env`` yet, the
    ``.env`` value stands) or ``unusable`` (a ``database.env`` exists
    but the ``.env`` URL cannot be rebuilt).  The URL itself is never
    returned or logged: it embeds the password.
    """
    if (os.environ.get("DATABASE_URL") or "").strip():
        return "process_env"
    if password is None:
        return "dotenv"
    base = (dotenv_values(env_file).get("DATABASE_URL") or "").strip()
    url = _database_url_with_password(base, password)
    if url is None:
        return "unusable"
    os.environ["DATABASE_URL"] = url
    return "database_env"


def _fatal(message: str, code: int) -> int:
    print(f"FATAL: {message}", file=sys.stderr)
    return code


def _grant_users_read(path: Path) -> bool:
    """Best-effort: grant ``BUILTIN\\Users`` read on ``path`` by SID.

    The install-time ACL script strips inherited ACEs from the data root
    so ordinary users cannot read ``config\\secrets.env``; the endpoint
    descriptor is the one file under ``<DATA_DIR>/config/`` the desktop
    app (running as a standard user) must still be able to read.  The
    grant uses the locale-proof SID form and is applied to the *temp*
    file before the atomic rename, so the descriptor is readable the
    moment it becomes visible.  Returns True when icacls confirmed the
    grant; callers treat False as a warning, never as fatal.
    """
    try:
        proc = subprocess.run(
            ["icacls", str(path), "/grant", f"{_USERS_SID}:R"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _publish_local_endpoint(cfg: Any) -> dict[str, list[str]]:
    """Best-effort: tell the desktop app where this backend listens.

    Writes ``supermarket_endpoint.json`` to every location the Flutter
    app probes, in the app's own probe order:

    * ``<DATA_DIR>/config/`` — the R1 production location.  The service
      account owns this tree (``winsw/grant_data_dir_acl.ps1``); after
      that script strips inherited ACEs, ordinary users lose read
      access, so each write is followed by an explicit locale-proof
      ``BUILTIN\\Users:R`` grant on the file itself (the descriptor is
      the only non-secret file in ``config/``).
    * ``<backend>/../app/`` — the rehearsal/dev sibling layout, kept
      for installs where the app folder is writable.

    Both writes are atomic (unique temp file + ``os.replace``).  The
    URL always uses a loopback host the local app can reach, even when
    the server binds a wildcard/LAN address; the port comes from the
    configured settings and is never hardcoded.  Every failure is
    swallowed and reported in the result: production defaults to port
    8000 anyway, and a non-writable install tree (Program Files under
    the NetworkService service account) must never stop the server.

    Returns ``{"written": [...], "failed": [...], "warnings": [...]}``
    with absolute file paths for logging.
    """
    result: dict[str, list[str]] = {"written": [], "failed": [], "warnings": []}
    try:
        host = str(getattr(cfg, "HOST", "") or "").strip()
        if host in ("", "0.0.0.0", "::"):
            host = "127.0.0.1"
        port = int(cfg.PORT)
        payload = {
            "base_url": f"http://{host}:{port}",
            "host": host,
            "port": port,
        }
        blob = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    except (TypeError, ValueError) as exc:
        result["failed"].append(f"payload: {exc}")
        return result

    # (target, needs the BUILTIN\Users read grant)
    targets: list[tuple[Path, bool]] = []
    data_dir = str(getattr(cfg, "DATA_DIR", "") or "").strip()
    if data_dir:
        targets.append((Path(data_dir) / "config" / ENDPOINT_FILE_NAME, True))
    app_dir = BACKEND_ROOT.parent / "app"
    if app_dir.is_dir():
        targets.append((app_dir / ENDPOINT_FILE_NAME, False))

    for target, needs_grant in targets:
        tmp = target.with_name(f".{target.name}.{uuid.uuid4().hex}.tmp")
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_bytes(blob)
            if needs_grant and not _grant_users_read(tmp):
                result["warnings"].append(f"users-read grant failed: {target}")
            os.replace(tmp, target)
            result["written"].append(str(target))
        except OSError:
            try:
                tmp.unlink()
            except OSError:
                pass
            result["failed"].append(str(target))
    return result


def main(argv: list[str] | None = None) -> int:
    """Prepare the production runtime and (unless ``--check``) serve."""
    parser = argparse.ArgumentParser(
        prog="run_production.py",
        description="Production launcher for the Supermarket Pro backend (R2).",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="run the full startup preparation, print the resolved "
        "configuration as JSON and exit without serving",
    )
    args = parser.parse_args(argv)

    data_dir = resolve_data_dir()
    if data_dir is None:
        return EXIT_USAGE

    env_file = data_dir / "config" / ".env"
    try:
        env_file.read_text(encoding="utf-8")
    except FileNotFoundError:
        return _fatal(
            f"missing production configuration file {env_file}; create it "
            "(installer-generated DATABASE_URL and settings) before starting",
            EXIT_CONFIG_INVALID,
        )
    except PermissionError as exc:
        return _fatal(_unreadable_hint(env_file, exc), EXIT_CONFIG_INVALID)
    except OSError as exc:
        return _fatal(
            f"cannot read {env_file} ({exc.__class__.__name__}) as account "
            f"{_account_name()}: {exc}",
            EXIT_CONFIG_INVALID,
        )

    _prepare_environment(data_dir)

    # Secrets first: app.core.config instantiates Settings() at import
    # time and its placeholder validator would otherwise fire before we
    # had a chance to provision unique per-install values.
    try:
        from app.core.secrets import (
            SecretsError,
            database_env_file,
            ensure_production_secrets,
            load_database_password,
        )

        secrets_result = ensure_production_secrets(data_dir)
        # R4 §5 handoff: the application-role password from database.env
        # (None when the file does not exist yet; SecretsError when it is
        # unusable — fail closed, the file is left untouched).
        database_password = load_database_password(data_dir)
    except SecretsError as exc:
        cause = exc.__cause__ or exc.__context__
        message = str(exc)
        if isinstance(cause, PermissionError):
            # Name the account and the file: "PermissionError" alone sent a
            # technician hunting a healthy service.
            target = getattr(cause, "filename", None) or (
                data_dir / "config" / "secrets.env"
            )
            message = f"{message}\n{_unreadable_hint(Path(target), cause)}"
        return _fatal(message, EXIT_SECRETS_FAILED)

    # ... published before the settings import below, exactly like the
    # application secrets, so env-over-dotenv precedence applies.
    database_url_source = _publish_database_url(env_file, database_password)
    database_env_path = database_env_file(data_dir)

    try:
        from app.core.config import (
            PLACEHOLDER_SECRET_VALUES,
            STAGING_VERIFICATION_KEYS_FILE_NAME,
            settings,
        )
    except Exception as exc:  # noqa: BLE001 - any settings failure is fatal
        return _fatal(
            f"configuration could not be loaded ({exc.__class__.__name__}): {exc}",
            EXIT_CONFIG_INVALID,
        )

    # C-2 (Phase 0-A): the production launcher pins the production trust
    # profile explicitly.  `Settings` already refuses `APP_ENV=production` with
    # the staging profile (or with a staging keys-file override); these two
    # checks repeat the rule here so the launcher states its intent in one
    # place and fails with an actionable message (exit 4) rather than a generic
    # validation error.  The staging workflow never goes through this file: it
    # starts uvicorn directly with `APP_ENV=development`.
    if settings.LICENSE_TRUST_PROFILE != "production":
        return _fatal(
            "LICENSE_TRUST_PROFILE must be 'production' for the production "
            f"launcher (got {settings.LICENSE_TRUST_PROFILE!r}); the staging "
            "trust profile is only for the isolated staging workflow",
            EXIT_CONFIG_INVALID,
        )
    if Path(settings.LICENSE_VERIFICATION_KEYS_FILE).name == (
        STAGING_VERIFICATION_KEYS_FILE_NAME
    ):
        return _fatal(
            "LICENSE_VERIFICATION_KEYS_FILE must not point at the staging "
            "registry in production; use the packaged "
            "app/licensing/verification_keys.json",
            EXIT_CONFIG_INVALID,
        )

    # Belt and braces: never serve with a placeholder, whatever APP_ENV
    # ended up being.
    insecure = [
        name
        for name in ("APP_SECRET_KEY", "JWT_SECRET_KEY")
        if not getattr(settings, name).strip()
        or getattr(settings, name).strip() in PLACEHOLDER_SECRET_VALUES
    ]
    if insecure:
        return _fatal(
            f"{', '.join(insecure)} still hold the repository placeholder; "
            f"refusing to start (check {secrets_result.path})",
            EXIT_CONFIG_INVALID,
        )

    from app.core.logging import file_logging_enabled, setup_logging

    uvicorn_kwargs = build_uvicorn_kwargs(settings)
    log_file_enabled = file_logging_enabled(settings)
    report = build_runtime_report(
        settings,
        secrets_result,
        uvicorn_kwargs,
        log_file_enabled,
        database_url_source,
        database_env_path,
    )

    if args.check:
        # A dry run never changes ACLs; the serving path below does.
        print(json.dumps(report, indent=2, sort_keys=True))
        return EXIT_OK

    # Serving: make sure the files this process needs carry an explicit
    # DACL (the installer applied them before starting the service).
    _harden_config_acls(data_dir)

    setup_logging(settings.LOG_LEVEL)
    import structlog

    logger = structlog.get_logger("run_production")

    endpoint_result = _publish_local_endpoint(settings)
    for path in endpoint_result["written"]:
        logger.info("local_endpoint_published", path=path)
    for note in endpoint_result["warnings"]:
        logger.warning("local_endpoint_publish_warning", note=note)
    for path in endpoint_result["failed"]:
        logger.warning("local_endpoint_publish_failed", path=path)

    logger.info(
        "production_start",
        app=report["app"],
        host=report["host"],
        port=report["port"],
        data_dir=report["data_dir"],
        log_file=report["log_file"],
        env_file=report["env_file"],
        secrets_source=report["secrets_source"],
        database_url_source=report["database_url_source"],
        workers=report["workers"],
        reload=report["reload"],
    )

    install_signal_handlers()

    # P5 — refuse to start on a busy port with a typed failure.
    conflict = _probe_port(settings.HOST, int(settings.PORT))
    if conflict is not None and (
        getattr(conflict, "errno", None) not in (48, 98, 10048)
    ):
        # The address itself is unusable (not assigned to this machine,
        # reserved, ...). That is a configuration failure, not a conflict:
        # keep the historical exit code and say what is wrong.
        logger.critical(
            "bind_failed",
            host=settings.HOST,
            port=int(settings.PORT),
            error=getattr(conflict, "strerror", None) or str(conflict),
            errno=getattr(conflict, "errno", None),
            hint="HOST must be 127.0.0.1, 0.0.0.0 or an address of this machine",
        )
        print(
            f"FATAL: cannot bind {settings.HOST}:{settings.PORT} "
            f"({getattr(conflict, 'strerror', None) or conflict}).",
            file=sys.stderr,
        )
        return EXIT_SERVE_FAILED
    if conflict is not None:
        logger.critical(
            "port_in_use",
            host=settings.HOST,
            port=int(settings.PORT),
            error=getattr(conflict, "strerror", None) or str(conflict),
            errno=getattr(conflict, "errno", None),
            hint=(
                "another process is listening on this port; stop it, or set "
                "PORT in <DATA_DIR>/config/.env to a free port (the desktop "
                "app reads the published supermarket_endpoint.json)"
            ),
        )
        print(
            f"FATAL: port {settings.PORT} on {settings.HOST} is already in use "
            f"({getattr(conflict, 'strerror', None) or conflict}). "
            "Stop the process using it or change PORT in the .env file.",
            file=sys.stderr,
        )
        return EXIT_PORT_IN_USE

    try:
        import uvicorn

        uvicorn.run(**uvicorn_kwargs)
    except KeyboardInterrupt:
        logger.info("production_stopped", reason="signal")
        return EXIT_OK
    except SystemExit as exc:  # uvicorn exits non-zero on bind failure
        code = exc.code
        return EXIT_OK if code in (0, None) else EXIT_SERVE_FAILED
    except OSError as exc:
        # A bind that lost the race against another process: same typed
        # outcome as the pre-flight check above.
        if getattr(exc, "errno", None) in (48, 98, 10048):
            logger.critical(
                "port_in_use",
                host=settings.HOST,
                port=int(settings.PORT),
                error=str(exc),
            )
            return EXIT_PORT_IN_USE
        logger.critical(
            "production_start_failed",
            error=str(exc),
            error_type=exc.__class__.__name__,
        )
        return EXIT_SERVE_FAILED
    except Exception as exc:  # noqa: BLE001 - report and fail closed
        logger.critical(
            "production_start_failed",
            error=str(exc),
            error_type=exc.__class__.__name__,
        )
        return EXIT_SERVE_FAILED

    logger.info("production_stopped", reason="server_exit")
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Ctrl+C during the preparation phase (before uvicorn installs
        # its own handlers) must still be a clean stop, never a traceback
        # with a non-zero exit code the service wrapper would restart on.
        sys.exit(EXIT_OK)
