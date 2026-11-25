"""Read-only live Firebase check for the KlickPOS License API.

Unlike ``preflight.py`` this script performs **no writes of any kind**: it is
safe to run against the real ``klickpos-license-manager`` project.  It answers:

* is Application Default Credentials discoverable by the standard Google
  provider, and which principal do they belong to;
* which project do they resolve to, and does it match the configured project;
* can the ADC identity *read* Firestore (through the real repository class);
* can the Admin SDK perform the user lookup that ``check_revoked=True`` uses;
* is the administrator allowlist configured.

Access tokens, credential files and secret values are never read aloud.  At
most a credential class name, a principal e-mail, a permission name and an
exception class name appear in the output.

Usage::

    cd new_app/license_manager
    LICENSE_API_FIREBASE_PROJECT_ID=klickpos-license-manager \
    LICENSE_API_ADMIN_UIDS=... LICENSE_API_ADMIN_EMAILS=... \
    ./.venv/Scripts/python.exe scripts/check_live_firebase.py

Targeting another project (Phase 8.3.2): the project, administrator uid and
e-mail are configuration now, not constants.  The **production values below are
the defaults**, so the command above still checks exactly what it used to:

    # staging, explicitly — refuse to fall back to production silently
    ./.venv/Scripts/python.exe scripts/check_live_firebase.py \
        --staging --project klickpos-license-free-8029b --uid <staging-uid>

    # same, through the environment instead of flags
    LICENSE_API_CHECK_PROJECT=klickpos-license-free-8029b \
    LICENSE_API_CHECK_UID=<staging-uid> \
    ./.venv/Scripts/python.exe scripts/check_live_firebase.py --staging

``--staging`` requires an explicit non-production project; a bare ``--project``
without it is also accepted for an ad-hoc target.  The project being checked is
printed before anything else happens.

Exit code 0 when no check FAILed.  ``SKIP`` means the check needs something
this host cannot provide (for example a live ID token), or that no target uid
was given.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

#: Production defaults — unchanged by Phase 8.3.2.
PRODUCTION_PROJECT = "klickpos-license-manager"
PRODUCTION_UID = "WeTMtT4ulPYqDJXfl7d9Lr4K9Zw1"
PRODUCTION_EMAIL = "islemzeblah31@gmail.com"

#: Backwards-compatible aliases for the names this script always exported.
EXPECTED_PROJECT = PRODUCTION_PROJECT
EXPECTED_UID = PRODUCTION_UID
EXPECTED_EMAIL = PRODUCTION_EMAIL

CHECK_PROJECT_ENV = "LICENSE_API_CHECK_PROJECT"
CHECK_UID_ENV = "LICENSE_API_CHECK_UID"
CHECK_EMAIL_ENV = "LICENSE_API_CHECK_EMAIL"

RESULTS: list[tuple[str, str, str]] = []


class TargetError(ValueError):
    """The requested target is incomplete or contradicts itself."""


@dataclass(frozen=True, slots=True)
class Target:
    """Which Firebase project (and administrator) this run is about."""

    project: str
    uid: str = ""
    email: str = ""
    mode: str = "production"


def resolve_target(
    argv: list[str] | None = None,
    environ: Mapping[str, str] | None = None,
) -> Target:
    """Resolve the checked project/administrator from flags and environment.

    Precedence is flag → environment → production default.  ``--staging`` is a
    promise that this run is *not* production, so it fails closed when no
    project is given rather than quietly checking production.
    """
    parser = argparse.ArgumentParser(
        prog="check_live_firebase.py",
        description=(
            "Read-only live Firebase check for the KlickPOS License API "
            "(defaults to the production project)."
        ),
    )
    parser.add_argument("--project", default="", help="Firebase/GCP project id to check")
    parser.add_argument("--uid", default="", help="expected administrator uid")
    parser.add_argument("--email", default="", help="expected administrator e-mail")
    parser.add_argument(
        "--staging",
        action="store_true",
        help="check a non-production project (requires --project or the environment)",
    )
    args = parser.parse_args(argv)
    env = os.environ if environ is None else environ

    project = (args.project or env.get(CHECK_PROJECT_ENV) or "").strip()
    uid = (args.uid or env.get(CHECK_UID_ENV) or "").strip()
    email = (args.email or env.get(CHECK_EMAIL_ENV) or "").strip()

    if args.staging:
        if not project:
            raise TargetError(
                "--staging requires an explicit --project (or "
                f"{CHECK_PROJECT_ENV}); refusing to fall back to production"
            )
        if project == PRODUCTION_PROJECT:
            raise TargetError(
                "--staging was requested but the project is the production project"
            )
        return Target(project=project, uid=uid, email=email, mode="staging")

    if project:
        return Target(project=project, uid=uid, email=email, mode="custom")
    return Target(
        project=PRODUCTION_PROJECT,
        uid=uid or PRODUCTION_UID,
        email=email or PRODUCTION_EMAIL,
        mode="production",
    )


def record(status: str, name: str, detail: str = "") -> None:
    RESULTS.append((status, name, detail))
    print(f"[{status:<4}] {name}{(' - ' + detail) if detail else ''}")


def check(name: str, func, *, required: bool = True) -> object | None:
    """Run one check; a non-string result is returned for the caller to inspect."""
    try:
        detail = func()
    except Exception as exc:  # noqa: BLE001 - classifying the failure is the point
        record("FAIL" if required else "WARN", name, _describe(exc))
        return None
    if isinstance(detail, str) or detail is None:
        record("PASS", name, detail or "")
    else:
        record("PASS", name)
    return detail


def _describe(exc: BaseException, limit: int = 320) -> str:
    """Exception class plus a short, whitespace-collapsed message.

    Google's 403 messages name the missing permission or API, which is exactly
    what the operator needs; they never contain credential material.
    """
    text = " ".join(str(exc).split())
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return f"{type(exc).__name__}: {text}" if text else type(exc).__name__


def main(
    argv: list[str] | None = None,
    environ: Mapping[str, str] | None = None,
) -> int:
    try:
        target = resolve_target(argv, environ)
    except TargetError as exc:
        print(f"error: {exc}")
        return 2

    from service.settings import load_settings

    print("== configuration ==")
    # Printed first, so a run can never be mistaken for one against another
    # project.  A project id is public configuration, not a secret.
    print(f"Checking Firebase project: {target.project} (mode={target.mode})")
    if target.uid or target.email:
        print(
            "Expected administrator: "
            f"uid={target.uid or '(not checked)'} "
            f"email={target.email or '(not checked)'}"
        )
    settings = load_settings()
    record("PASS", "settings load", f"env={settings.env}")
    record(
        "PASS" if settings.firebase_project_id == target.project else "FAIL",
        "LICENSE_API_FIREBASE_PROJECT_ID",
        settings.firebase_project_id or "missing",
    )
    record(
        "PASS" if settings.firestore_database or True else "FAIL",
        "Firestore database",
        settings.firestore_database or "(default)",
    )

    print("\n== Application Default Credentials ==")
    adc = Path(os.environ.get("APPDATA", "")) / "gcloud" / "application_default_credentials.json"
    record("PASS" if adc.is_file() else "FAIL",
           "ADC file at the standard gcloud location",
           "found" if adc.is_file() else "absent (run: gcloud auth application-default login)")
    record("SKIP" if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") else "PASS",
           "GOOGLE_APPLICATION_CREDENTIALS",
           "not set: the standard provider falls back to ADC"
           if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
           else "set (an explicit key takes precedence over ADC)")
    record("WARN" if os.environ.get("FIRESTORE_EMULATOR_HOST") else "PASS",
           "FIRESTORE_EMULATOR_HOST",
           "set: reads would go to the emulator" if os.environ.get("FIRESTORE_EMULATOR_HOST")
           else "not set (real project)")
    record("WARN" if os.environ.get("FIREBASE_AUTH_EMULATOR_HOST") else "PASS",
           "FIREBASE_AUTH_EMULATOR_HOST",
           "set: tokens would be unsigned emulator tokens"
           if os.environ.get("FIREBASE_AUTH_EMULATOR_HOST") else "not set (real project)")

    principal = check("google.auth.default() discovers ADC", _adc_identity)
    if principal:
        record("PASS" if principal.get("project") == target.project else "WARN",
               "ADC resolves to the expected project",
               principal.get("project") or
               "no project on the credential (a project must be passed explicitly)")
        record("PASS" if principal.get("quota_project") else "WARN",
               "quota project",
               principal.get("quota_project") or
               "none: quota is billed to the resource project, which needs "
               "serviceusage.services.use")

    print("\n== Firebase Admin (Authentication) ==")
    check("Admin SDK initialises with ADC", lambda: _admin_app(target.project))
    if target.uid:
        user = check(
            "Admin SDK user lookup (the check_revoked path)",
            lambda: _lookup_admin_user(target.project, target.uid),
        )
    else:
        user = None
        record(
            "SKIP",
            "Admin SDK user lookup (the check_revoked path)",
            "no administrator uid was given for this target",
        )
    if isinstance(user, dict):
        record("PASS" if user.get("uid") == target.uid else "FAIL",
               "dashboard administrator uid present in Firebase Auth",
               f"uid matches, providers={user.get('providers')}, disabled={user.get('disabled')}")
        if target.email:
            record("PASS" if user.get("email", "").lower() == target.email.lower() else "FAIL",
                   "dashboard administrator e-mail",
                   user.get("email") or "absent")
        else:
            record("SKIP", "dashboard administrator e-mail",
                   "no expected e-mail was given for this target")
    check("Admin SDK can list users (read-only)", lambda: _list_users(target.project),
          required=False)
    record("SKIP", "verify_id_token(check_revoked=True) end to end",
           "needs a live ID token; a token is never harvested or printed here")

    print("\n== Firestore (read-only, real project) ==")
    counts = check("repository.counts()", lambda: _repo_counts(settings, target.project))
    if isinstance(counts, dict):
        record("PASS", "counts read", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    for name, func in (
        ("repository.list_licenses(1)", lambda: _repo_list(settings, target.project, "licenses")),
        ("repository.list_devices(1)", lambda: _repo_list(settings, target.project, "devices")),
        ("repository.list_customers(1)", lambda: _repo_list(settings, target.project, "customers")),
        ("repository.list_audit_events(1)", lambda: _repo_list(settings, target.project, "audit")),
    ):
        check(name, func)

    print("\n== administrator allowlist ==")
    if settings.allowlist_is_empty:
        record("FAIL", "allowlist", "empty: every request is refused")
    else:
        if target.uid:
            record("PASS" if target.uid in settings.admin_uids else "FAIL",
                   "LICENSE_API_ADMIN_UIDS contains the dashboard administrator",
                   f"{len(settings.admin_uids)} uid(s) configured")
        else:
            record("SKIP", "LICENSE_API_ADMIN_UIDS contains the dashboard administrator",
                   "no expected uid was given for this target")
        if target.email:
            record("PASS" if target.email.lower() in settings.admin_emails else "FAIL",
                   "LICENSE_API_ADMIN_EMAILS contains the dashboard administrator",
                   f"{len(settings.admin_emails)} email(s) configured")
        else:
            record("SKIP", "LICENSE_API_ADMIN_EMAILS contains the dashboard administrator",
                   "no expected e-mail was given for this target")

    return _summary()


def _adc_identity() -> dict[str, str]:
    import google.auth
    from google.auth.transport.requests import Request

    credentials, project = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    # Force a real refresh: a lazy credential object proves nothing.  The token
    # itself is discarded immediately and never printed.
    credentials.refresh(Request())
    identity = {
        "class": type(credentials).__name__,
        "project": project or "",
        "quota_project": getattr(credentials, "quota_project_id", "") or "",
        "principal": getattr(credentials, "service_account_email", "") or "",
    }
    record("PASS", "credential refresh (access token obtained, not printed)",
           f"class={identity['class']}, principal={identity['principal'] or 'user ADC'}")
    return identity


def _admin_app(project: str):
    import firebase_admin
    from firebase_admin import credentials

    resolved = project or os.environ.get("LICENSE_API_FIREBASE_PROJECT_ID", "")
    try:
        return firebase_admin.get_app()
    except ValueError:
        return firebase_admin.initialize_app(
            credentials.ApplicationDefault(), {"projectId": resolved}
        )


def _lookup_admin_user(project: str, uid: str) -> dict[str, object]:
    from firebase_admin import auth

    user = auth.get_user(uid, app=_admin_app(project))
    return {
        "uid": user.uid,
        "email": user.email or "",
        "disabled": user.disabled,
        "providers": [p.provider_id for p in (user.provider_data or [])],
    }


def _list_users(project: str) -> str:
    from firebase_admin import auth

    page = auth.list_users(max_results=1, app=_admin_app(project))
    return f"{len(page.users)} user(s) in the first page"


def _repository(settings, project: str):
    from service.container import load_code_cipher
    from service.firestore_repository import FirestoreLicenseRepository

    return FirestoreLicenseRepository.connect(
        load_code_cipher(settings),
        project_id=settings.firebase_project_id or project,
        database=settings.firestore_database,
        env=settings.env,
    )


def _repo_counts(settings, project: str) -> dict[str, int]:
    return dict(_repository(settings, project).counts())


def _repo_list(settings, project: str, kind: str) -> str:
    repository = _repository(settings, project)
    rows = {
        "licenses": repository.list_licenses,
        "devices": repository.list_devices,
        "customers": repository.list_customers,
        "audit": repository.list_audit_events,
    }[kind](1)
    return f"{len(rows)} row(s) read"


def _summary() -> int:
    print("\n== summary ==")
    counts = {status: sum(1 for s, _, _ in RESULTS if s == status)
              for status in ("PASS", "WARN", "SKIP", "FAIL")}
    print(", ".join(f"{status}={count}" for status, count in counts.items()))
    failures = [name for status, name, _ in RESULTS if status == "FAIL"]
    if failures:
        print("failed checks: " + ", ".join(failures))
        return 1
    print("no failed checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
