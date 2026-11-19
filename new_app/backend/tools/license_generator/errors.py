"""Controlled failure family for the offline License Generator (Phase L2-D).

Every expected failure the CLI can hit derives from `GeneratorError`, so
``main()`` can turn it into a one-line ``error: ...`` on stderr with a
non-zero exit code and **no traceback**.  Messages are operator-facing
and, by construction, never interpolate keystore contents - a message can
name a key id or a path, never key material.
"""

from __future__ import annotations


class GeneratorError(Exception):
    """Base class for every expected License Generator failure."""


class KeystoreError(GeneratorError):
    """The private-key store cannot be used as asked.

    Raised for: a key directory inside a git work tree, an existing key
    id being reused (never replaced), unknown key ids on signing, and a
    keystore file that is missing, malformed or self-inconsistent.
    """


class RequestFormatError(GeneratorError):
    """The pasted ``SMPr1....`` activation request is not strictly valid.

    The request is unsigned, so there is nothing to verify - only the
    strict format gate.  Every rejection message says what is wrong
    without echoing the pasted code back.
    """


class IssueError(GeneratorError):
    """A license could not be issued exactly as asked.

    Raised for invalid feature grants, rejected license ids and the
    (never-expected) case where the L2-A contract validator or the
    backend self-verification refuses a payload this tool built - the
    code is withheld whenever this happens.
    """
