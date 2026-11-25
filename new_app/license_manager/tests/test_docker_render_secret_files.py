"""Render Secret Files access for the combined image (production hardening R1).

Render mounts Secret Files under ``/etc/secrets`` with read access granted
through group 1000, and its own Docker documentation says a service whose user
is not in that group can hit ``Permission denied``. These tests pin the
Dockerfile contract that keeps that from happening, without weakening any
permission or changing the runtime identity:

* the runtime user stays UID 10001 with its own primary group;
* the image also joins GID 1000, creating that group only when absent;
* the container never runs as root.

The checks are static: no Docker daemon is required (and none is used).
"""

from __future__ import annotations

import re
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
DOCKERFILE = HERE / "Dockerfile.render"

#: The block that creates the runtime identity.
_USER_BLOCK_PATTERN = re.compile(
    r"RUN if ! getent group 1000 .*?"
    r"groupadd --system --gid 10001 license .*?"
    r"useradd --system --uid 10001 --gid license .*?"
    r"usermod -a -G 1000 license",
    re.S,
)


def _text() -> str:
    return DOCKERFILE.read_text(encoding="utf-8")


def test_the_runtime_user_stays_uid_10001_with_its_own_primary_group():
    text = _text()

    assert "useradd --system --uid 10001 --gid license --home-dir /app license" in text
    assert "groupadd --system --gid 10001 license" in text


def test_the_runtime_user_joins_gid_1000_for_render_secret_files():
    text = _text()

    assert "usermod -a -G 1000 license" in text
    # Membership is additive, never a change of the primary group.
    assert "--gid 1000 license" not in text


def test_gid_1000_is_created_only_when_the_base_image_lacks_it():
    text = _text()

    assert "getent group 1000" in text
    assert "groupadd --gid 1000 render-secrets" in text
    # The creation must be guarded: an unconditional groupadd fails the build on
    # a base image that already defines GID 1000.
    assert "groupadd --gid 1000 render-secrets 2>/dev/null" not in text
    assert re.search(r"if ! getent group 1000 >/dev/null; then groupadd", text)


def test_group_creation_precedes_the_membership_grant():
    block = _USER_BLOCK_PATTERN.search(_text())

    assert block is not None, "the runtime identity block is not shaped as expected"


def test_the_container_does_not_run_as_root():
    text = _text()

    assert "USER license" in text
    assert not re.search(r"^USER\s+root\s*$", text, re.M)
