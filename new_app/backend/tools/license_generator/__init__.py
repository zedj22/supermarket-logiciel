"""Offline Lifetime License Generator (Phase L2-D).

Owner-machine only.  This package holds the private Ed25519 keystore and
the CLI that reads ``SMPr1`` requests and signs ``SMP1`` Lifetime codes
against the exact L2-A canonical contract.  It never ships to customers
(``pyproject.toml`` packages only ``app*``), never writes into the
customer application or the backend state, and never exports anything
but public halves.

Entry point: ``python -m tools.license_generator --help``.
Operations: ``docs/LICENSE_GENERATOR_OPERATIONS.md``.
"""

from __future__ import annotations
