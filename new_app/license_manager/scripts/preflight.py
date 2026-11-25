"""Readiness check for the KlickPOS License API (no secrets are ever printed).

Usage::

    cd new_app/license_manager
    ./.venv/Scripts/python.exe scripts/preflight.py            # real project
    FIRESTORE_EMULATOR_HOST=127.0.0.1:8081 \\
    FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \\
    ./.venv/Scripts/python.exe scripts/preflight.py            # emulators

The Firestore probe is **read-only by default**, so this script is safe to run
against the real project.  ``--write-probe`` adds one round-trip write to
``_preflight/probe`` for emulators and scratch projects; never use it against
production data.

It answers, in order: is the configuration complete, are the Google SDKs
installed, is Application Default Credentials available, can Firestore be
reached, is the signing key present, and is that key id published in the
customer's packaged verification keys.

Every line is PASS / FAIL / SKIP / WARN. Values of secrets, tokens and key
material are never read aloud — at most a secret *name*, a public key id or an
exception class name appears in the output. Exit code: 0 when no check FAILed.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

RESULTS: list[tuple[str, str, str]] = []


def record(status: str, name: str, detail: str = "") -> None:
    RESULTS.append((status, name, detail))
    print(f"[{status:<4}] {name}{(' - ' + detail) if detail else ''}")


def check(name: str, func, *, required: bool = True) -> None:
    """Run one check: exception class only, never the exception message."""
    try:
        detail = func()
    except Exception as exc:  # noqa: BLE001 - the point is to classify it
        record("FAIL" if required else "WARN", name, type(exc).__name__)
        return
    record("PASS", name, detail or "")


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    allow_write = "--write-probe" in args

    from service.settings import load_settings

    print("== configuration ==")
    try:
        settings = load_settings()
    except Exception as exc:  # noqa: BLE001
        record("FAIL", "settings load", f"{type(exc).__name__}: {exc}")
        return _summary()

    record("PASS", "settings load", f"env={settings.env}")
    if settings.is_production:
        for name in ("LICENSE_API_FIREBASE_PROJECT_ID", "LICENSE_API_SIGNING_SECRET",
                     "LICENSE_API_CODE_ENC_SECRET"):
            value = {
                "LICENSE_API_FIREBASE_PROJECT_ID": settings.firebase_project_id,
                "LICENSE_API_SIGNING_SECRET": settings.signing_secret_name,
                "LICENSE_API_CODE_ENC_SECRET": settings.code_encryption_secret_name,
            }[name]
            record("PASS" if value else "FAIL", name, "set" if value else "missing")
    else:
        for name, present in (
            ("LICENSE_API_DEV_SIGNING_SEED_B64", bool(settings.dev_signing_seed_b64)),
            ("LICENSE_API_DEV_CODE_ENC_KEY_B64", bool(settings.dev_code_encryption_key_b64)),
        ):
            record("PASS" if present else "WARN", name, "set" if present else "not set")

    if settings.allowlist_is_empty:
        record("FAIL", "administrator allowlist",
               "empty: every request will be refused (set LICENSE_API_ADMIN_UIDS "
               "or LICENSE_API_ADMIN_EMAILS)")
    else:
        record("PASS", "administrator allowlist",
               f"{len(settings.admin_uids)} uid(s), {len(settings.admin_emails)} email(s)")
    record("PASS" if settings.require_app_check else "WARN", "App Check enforcement",
           "required" if settings.require_app_check else "not required")
    # Cloud Run service-to-service authentication (Phase 6).
    record(
        "PASS" if settings.require_cloud_run_invoker else "WARN",
        "Cloud Run invoker verification",
        (
            f"required, audience={settings.cloud_run_audience or 'MISSING'}, "
            f"{len(settings.cloud_run_invoker_emails)} caller service account(s)"
            if settings.require_cloud_run_invoker
            else "not required (correct for a local run, wrong on Cloud Run)"
        ),
    )

    print("\n== Google Cloud SDKs ==")
    for module in ("firebase_admin", "google.cloud.firestore", "google.cloud.secretmanager"):
        check(f"import {module}", lambda m=module: _import(m))

    print("\n== credentials ==")
    explicit = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
    if explicit:
        record("PASS" if Path(explicit).is_file() else "FAIL",
               "GOOGLE_APPLICATION_CREDENTIALS", "file present" if Path(explicit).is_file()
               else "set but the file does not exist")
    else:
        record("SKIP", "GOOGLE_APPLICATION_CREDENTIALS", "not set")
    adc = Path(os.environ.get("APPDATA", "")) / "gcloud" / "application_default_credentials.json"
    record("PASS" if adc.is_file() else "FAIL", "Application Default Credentials",
           "found" if adc.is_file() else "absent (run: gcloud auth application-default login)")
    check("Firebase Admin initialises", lambda: _firebase_app(settings), required=False)

    print("\n== Firestore ==")
    if os.environ.get("FIRESTORE_EMULATOR_HOST"):
        record("WARN", "FIRESTORE_EMULATOR_HOST",
               "set: this run talks to an emulator, not your project")
    else:
        record("SKIP", "FIRESTORE_EMULATOR_HOST", "not set (real project)")
    check("Firestore round trip", lambda: _firestore_probe(settings, allow_write=allow_write))

    print("\n== signing material ==")
    check("signing key loads", lambda: _signing_key(settings))
    check("activation-code key loads", lambda: _code_cipher(settings))
    check("signing key id is published in the customer keys", lambda: _published(settings),
          required=False)

    print("\n== verification keys ==")
    record("PASS" if settings.verification_keys_path.is_file() else "FAIL",
           "verification_keys.json",
           str(settings.verification_keys_path) if settings.verification_keys_path.is_file()
           else "missing (set LICENSE_API_VERIFICATION_KEYS_FILE)")
    check("verification keys parse", lambda: _key_ids(settings))

    return _summary()


def _import(module: str) -> str:
    import importlib

    importlib.import_module(module)
    return "installed"


def _firebase_app(settings) -> str:
    """Initialise the Admin SDK **and force credential resolution**.

    ``initialize_app`` alone proves nothing: the credentials object is lazy, so
    the real test is obtaining an access token. The token is discarded, never
    printed.
    """
    import firebase_admin
    from firebase_admin import credentials

    try:
        app = firebase_admin.get_app()
    except ValueError:
        options = {"projectId": settings.firebase_project_id} if settings.firebase_project_id else None
        app = firebase_admin.initialize_app(credentials.ApplicationDefault(), options)
    credential = app.credential
    if credential is not None:
        credential.get_access_token()  # raises DefaultCredentialsError without ADC
    return f"project={getattr(app, 'project_id', settings.firebase_project_id) or 'unknown'}"


def _firestore_probe(settings, *, allow_write: bool = False) -> str:
    """Reach Firestore without touching existing data.

    Read-only by default (a list over an empty collection still proves the
    credentials and the ``datastore.entities.list`` permission). The optional
    write stays confined to the ``_preflight`` collection so it can never
    collide with licenses, devices, customers or the audit log.
    """
    from google.cloud import firestore

    kwargs = {}
    if settings.firebase_project_id:
        kwargs["project"] = settings.firebase_project_id
    if settings.firestore_database:
        kwargs["database"] = settings.firestore_database
    client = firestore.Client(**kwargs)
    if not allow_write:
        list(client.collection("licenses").limit(1).stream())
        return "read-only ok (--write-probe for a write round trip)"
    client.collection("_preflight").document("probe").set({"at": "preflight"})
    data = client.collection("_preflight").document("probe").get().to_dict() or {}
    if data.get("at") != "preflight":
        raise RuntimeError("probe document did not read back")
    return "write+read ok"


def _signing_key(settings) -> str:
    from service.container import load_issuer_factory

    issuer = load_issuer_factory(settings)()
    return f"key_id={issuer.key_id} published={issuer.is_published()}"


def _code_cipher(settings) -> str:
    from service.container import load_code_cipher

    cipher = load_code_cipher(settings)
    sealed = cipher.seal(license_id="preflight", code="SMP1.PREFLIGHT.PROBE")
    if cipher.open(license_id="preflight", envelope=sealed) != "SMP1.PREFLIGHT.PROBE":
        raise RuntimeError("seal/open round trip failed")
    return "seal/open ok"


def _published(settings) -> str:
    from service import shared
    from service.container import load_issuer_factory

    issuer = load_issuer_factory(settings)()
    keys = shared.load_customer_verification_keys(str(settings.verification_keys_path))
    if not issuer.is_published():
        raise RuntimeError(
            f"key id {issuer.key_id!r} is absent from the packaged verification keys"
        )
    return f"published among {sorted(keys)}"


def _key_ids(settings) -> str:
    from service import shared

    keys = shared.load_customer_verification_keys(str(settings.verification_keys_path))
    return f"key ids: {sorted(keys) or 'none'}"


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
