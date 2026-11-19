"""Owner-side tooling that is deliberately outside the customer package.

Packaging boundary (Phase L2-D): ``tool.setuptools.packages.find`` in
``pyproject.toml`` includes only ``app*``, so nothing under ``tools/`` is
ever built into the backend distribution, installed on a customer machine
as part of the application, or imported by ``app`` at runtime.
"""

from __future__ import annotations
