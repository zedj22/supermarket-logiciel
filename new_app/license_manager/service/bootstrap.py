"""Import wiring between this service and the existing KlickPOS licensing code.

The KlickPOS License Manager is **additive**: it owns no licensing format of
its own.  Everything cryptographic comes from the customer application's own
modules, imported unmodified:

* ``app/licensing/activation_code.py`` — canonical JSON, ``SMPr1`` request
  parsing helpers, ``SMP1`` encoding, payload validation and the verifier.
* ``app/licensing/verification_keys.py`` — the packaged public Ed25519 keys
  (the *same* file the customer's backend verifies against).
* ``app/licensing/fingerprint.py`` — the hardware fingerprint construction
  (read-only, used for the human-readable display code format).
* ``tools/license_generator/generator.py`` — the existing strict ``SMPr1``
  parser, reused verbatim for incoming requests.

Two things have to be true before those imports work:

1. ``new_app/backend`` must be on ``sys.path`` (that is where ``app`` and
   ``tools`` live).  ``ensure_backend_on_path`` does exactly that.
2. The shared ``app`` package executes ``app/licensing/__init__.py`` on first
   import, which pulls in the backend's whole licensing surface — including
   ``app.core.config.Settings``, which declares ``DATABASE_URL`` as a required
   field.  This service never opens a database, so a placeholder is supplied
   **only when the variable is absent** (``setdefault``): it satisfies that
   import and is never read, never logged and never used to connect.  A real
   value already present in the environment always wins.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

__all__ = [
    "BACKEND_ROOT",
    "ensure_backend_on_path",
    "prepare_shared_import",
]

#: ``new_app/license_manager/service/bootstrap.py`` → ``new_app``
NEW_APP_ROOT = Path(__file__).resolve().parents[2]
#: The customer application's backend, which owns the licensing contract.
BACKEND_ROOT = NEW_APP_ROOT / "backend"

#: Placeholder database URL: satisfies ``Settings`` at import time only.
_UNUSED_DATABASE_URL = (
    "postgresql+psycopg://license-manager:unused@127.0.0.1:1/unused"
)


def ensure_backend_on_path() -> Path:
    """Put ``new_app/backend`` first on ``sys.path`` (idempotent)."""
    if not (BACKEND_ROOT / "app" / "licensing").is_dir():
        raise RuntimeError(
            f"the KlickPOS backend was not found at {BACKEND_ROOT}; the License "
            "Manager cannot reuse the licensing contract without it"
        )
    target = str(BACKEND_ROOT)
    if target in sys.path:
        sys.path.remove(target)
    sys.path.insert(0, target)
    return BACKEND_ROOT


def prepare_shared_import() -> None:
    """Make the shared ``app``/``tools`` packages importable."""
    ensure_backend_on_path()
    os.environ.setdefault("DATABASE_URL", _UNUSED_DATABASE_URL)
