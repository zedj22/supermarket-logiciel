"""Fetching secret *values* at runtime.

Three backends exist, selected explicitly by ``LICENSE_API_SECRET_SOURCE``:

* ``secretmanager`` (default) — Google Cloud Secret Manager, the Cloud Run
  deployment path.  Unchanged by Phase 8.3.2.
* ``file`` — read-only files mounted by the hosting platform (Render secret
  files), for hosts that have no Secret Manager.  See ``FileSecretFetcher``.
* ``environment`` — development only; refused when ``LICENSE_API_ENV`` is
  ``production``.

Two consumers exist: the Ed25519 signing seed (``signing.py``) and the
activation-code encryption key (``crypto.py``).  Nothing fetched here is
written to disk, logged or included in an error message — only *why* a fetch
failed (an exception class name) is ever logged.

``StaticSecretFetcher`` exists for tests and for a developer's machine; no
production path can fall back to it, and neither can the file source fall back
to environment values.
"""

from __future__ import annotations

import os
import stat
from collections.abc import Mapping
from pathlib import Path
from typing import Protocol

from service.errors import SigningKeyError

__all__ = [
    "EnvironmentSecretFetcher",
    "FileSecretFetcher",
    "SecretFetcher",
    "SecretManagerFetcher",
    "StaticSecretFetcher",
]

#: A secret is a small text document (a JSON signing record or a base64 key).
#: The cap keeps a mistaken mount (a log file, a disk image) from being read.
_MAX_SECRET_BYTES = 64 * 1024


class SecretFetcher(Protocol):
    """Read one secret version as UTF-8 text."""

    def fetch(self, name: str, version: str = "latest") -> str: ...


class SecretManagerFetcher:
    """Google Cloud Secret Manager, imported lazily.

    The SDK is a deployment dependency, not an import-time one, so the service
    (and its whole test suite) runs on a machine without ``google-cloud-*``
    installed.  A missing SDK becomes the controlled
    ``signing_unavailable`` error rather than an ``ImportError`` traceback.
    """

    def __init__(self, project_id: str) -> None:
        if not project_id:
            raise SigningKeyError(
                "a Firebase/GCP project id is required to read secrets"
            )
        self._project_id = project_id
        try:
            from google.cloud import secretmanager
        except ImportError as exc:  # pragma: no cover - deployment dependency
            raise SigningKeyError(
                "Secret Manager support is not installed on this host "
                "(pip install google-cloud-secret-manager)"
            ) from exc
        self._client = secretmanager.SecretManagerServiceClient()

    def fetch(self, name: str, version: str = "latest") -> str:
        if not name:
            raise SigningKeyError("no secret name was configured")
        resource = (
            f"projects/{self._project_id}/secrets/{name}/versions/{version or 'latest'}"
        )
        try:
            response = self._client.access_secret_version(name=resource)
        except Exception as exc:
            raise SigningKeyError(
                "the signing material could not be read from Secret Manager"
            ) from exc
        return response.payload.data.decode("utf-8")


class FileSecretFetcher:
    """Secret **files** mounted read-only by the host (Render secret files).

    Layout: one regular file per secret, directly inside ``LICENSE_API_SECRET_DIR``,
    named exactly like the configured secret name::

        /etc/secrets/LICENSE_API_SIGNING_SECRET      (JSON: key_id + seed_b64)
        /etc/secrets/LICENSE_API_CODE_ENC_SECRET     (base64 of 32 bytes)

    Rules this class exists to enforce:

    * the directory is resolved **once**, at construction, so a later symlink
      swap cannot move the root;
    * a name is a *file name*, never a path: separators, drive letters, ``.``,
      ``..`` and leading dots are refused before anything is opened;
    * the file must resolve inside that directory, must not itself be a
      symlink, and must be a regular file — ``O_NOFOLLOW`` where the platform
      supports it closes the gap between the check and the open;
    * contents are returned as UTF-8 text with trailing newlines removed (the
      shape ``load_signing_key`` and ``ActivationCodeCipher.from_base64``
      expect); empty, unreadable, oversized and non-UTF-8 files fail closed;
    * no message contains a path, a name from the directory listing or any
      byte of the secret, and nothing is ever written, cached to disk or logged.

    ``version`` is a Secret Manager concept and is accepted but ignored: file
    names carry the secret *name* only, so a deployment can keep its pinned
    version variables while switching sources.
    """

    def __init__(self, directory: str | Path) -> None:
        raw = str(directory or "").strip()
        if not raw:
            raise SigningKeyError(
                "LICENSE_API_SECRET_DIR is required when "
                "LICENSE_API_SECRET_SOURCE=file"
            )
        try:
            root = Path(raw).expanduser().resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise SigningKeyError(
                "the configured secret directory does not exist"
            ) from exc
        if not root.is_dir():
            raise SigningKeyError("the configured secret directory is not a directory")
        self._root = root

    @property
    def directory(self) -> Path:
        """The resolved directory (for diagnostics; never contains a secret)."""
        return self._root

    def path_for(self, name: str) -> Path:
        """Resolve one secret file name inside the directory, or fail closed."""
        candidate = (name or "").strip()
        if not candidate:
            raise SigningKeyError("no secret name was configured")
        if any(separator in candidate for separator in ("/", "\\", os.sep, os.altsep or "/")):
            raise SigningKeyError("a secret name may not contain a path separator")
        if candidate in (".", "..") or candidate.startswith("."):
            raise SigningKeyError("a secret name may not be a relative path element")
        if ":" in candidate or Path(candidate).is_absolute():
            raise SigningKeyError("a secret name may not be an absolute path")

        path = self._root / candidate
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError as exc:
            raise SigningKeyError(
                "the configured secret file is missing"
            ) from exc
        except (OSError, RuntimeError) as exc:
            raise SigningKeyError(
                "the configured secret file could not be resolved"
            ) from exc

        # A symlink here would let a mount trick the service into reading a
        # file outside the directory, so it is refused even when it points
        # *inside* it: the mount layout is expected to be plain files.
        if path.is_symlink() or resolved.parent != self._root:
            raise SigningKeyError(
                "the configured secret file is not a regular file in the secret directory"
            )
        try:
            if not stat.S_ISREG(resolved.stat().st_mode):
                raise SigningKeyError(
                    "the configured secret file is not a regular file in the secret directory"
                )
        except OSError as exc:
            raise SigningKeyError(
                "the configured secret file could not be inspected"
            ) from exc
        return resolved

    def fetch(self, name: str, version: str = "latest") -> str:
        """Read one secret file as UTF-8 text (``version`` is ignored)."""
        path = self.path_for(name)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
        try:
            descriptor = os.open(os.fspath(path), flags)
        except OSError as exc:
            raise SigningKeyError(
                "the configured secret file is not readable"
            ) from exc
        try:
            with os.fdopen(descriptor, "rb") as handle:
                payload = handle.read(_MAX_SECRET_BYTES + 1)
        except OSError as exc:
            raise SigningKeyError(
                "the configured secret file is not readable"
            ) from exc
        if len(payload) > _MAX_SECRET_BYTES:
            raise SigningKeyError("the configured secret file is unexpectedly large")
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SigningKeyError(
                "the configured secret file is not valid UTF-8 text"
            ) from exc
        # A mounted file commonly ends with one newline (`echo`/editor); the
        # parsers expect the document itself, so only trailing line endings go.
        text = text.rstrip("\r\n")
        if not text.strip():
            raise SigningKeyError("the configured secret file is empty")
        return text


class StaticSecretFetcher:
    """Fixed values — tests and the operator's own local runs only."""

    def __init__(self, values: Mapping[str, str]) -> None:
        self._values = dict(values)

    def fetch(self, name: str, version: str = "latest") -> str:
        try:
            return self._values[name]
        except KeyError as exc:
            raise SigningKeyError("the configured secret is not available") from exc


class EnvironmentSecretFetcher:
    """Development convenience: the secret value in an environment variable.

    Refused outside development so a misconfigured deployment can never take
    this path (``settings.Settings`` already rejects the development variables
    in production; this is the second, independent guard).
    """

    def __init__(self, environ: Mapping[str, str], *, env: str) -> None:
        if env == "production":
            raise SigningKeyError(
                "environment-provided secrets are not available in production"
            )
        self._environ = environ

    def fetch(self, name: str, version: str = "latest") -> str:
        value = self._environ.get(name, "")
        if not value:
            raise SigningKeyError("the configured development secret is not set")
        return value
