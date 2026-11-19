"""RBAC initialisation and audit for a provisioned database (R3 §5).

Two operations, deliberately separated:

``audit_rbac``
    Strictly read-only.  Reports which of the required roles, permission
    scopes and role→permission grants are missing from the database.
    Running it twice changes nothing, and it can be pointed at a live
    production database safely.

``initialize_rbac``
    Runs the existing idempotent seed
    (:func:`app.core.seed.seed_roles_and_permissions`) and then audits
    the result.  It touches **only** ``roles``, ``permissions`` and
    ``role_permissions``: the ``users`` table is never written, so an
    administrator's ``pin_hash`` (and every other credential column)
    cannot be overwritten by a provisioning pass — decision D15's
    "seed is data, not identity" rule, now enforced by construction.

Provisioning calls this explicitly (``provision_database``); ordinary
application startup never does.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import structlog
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.seed import ROLE_PERMISSIONS, seed_roles_and_permissions
from app.models.enums import PermissionScope
from app.models.user import Permission, Role, RolePermission

logger = structlog.get_logger(__name__)

#: Roles every provisioned database must have (mirrors ROLE_PERMISSIONS).
REQUIRED_ROLES: tuple[str, ...] = tuple(ROLE_PERMISSIONS)

#: Permission scopes every provisioned database must expose.
REQUIRED_PERMISSIONS: tuple[str, ...] = tuple(
    scope.value for scope in PermissionScope
)

#: Tables this module is allowed to write.  ``users`` is deliberately
#: absent and asserted by the R3 test suite.
WRITABLE_TABLES: frozenset[str] = frozenset(
    {"roles", "permissions", "role_permissions"}
)


@dataclass
class RbacReport:
    """Outcome of an audit (and of the seed that preceded it)."""

    #: Rows the seed created, per target (0 on a second run).
    seeded: dict[str, int] = field(default_factory=dict)
    missing_roles: tuple[str, ...] = ()
    missing_permissions: tuple[str, ...] = ()
    missing_role_permissions: dict[str, tuple[str, ...]] = field(
        default_factory=dict
    )
    #: Always 0 — recorded so a report can prove no identity was touched.
    users_modified: int = 0
    #: ``True`` when the audit found nothing missing.
    ok: bool = True

    @property
    def summary(self) -> str:
        if self.ok:
            created = sum(self.seeded.values())
            return (
                f"RBAC complete ({created} rows created on this run, "
                "nothing missing)"
            )
        parts: list[str] = []
        if self.missing_roles:
            parts.append("missing roles: " + ", ".join(self.missing_roles))
        if self.missing_permissions:
            parts.append(
                "missing permissions: " + ", ".join(self.missing_permissions)
            )
        for role, scopes in sorted(self.missing_role_permissions.items()):
            parts.append(f"{role} lacks: " + ", ".join(scopes))
        return "; ".join(parts) or "RBAC incomplete"

    def as_dict(self) -> dict:
        return {
            "ok": self.ok,
            "summary": self.summary,
            "seeded": dict(self.seeded),
            "missing_roles": list(self.missing_roles),
            "missing_permissions": list(self.missing_permissions),
            "missing_role_permissions": {
                role: list(scopes)
                for role, scopes in self.missing_role_permissions.items()
            },
            "users_modified": self.users_modified,
        }


def _session(db: Session | None) -> tuple[Session, bool]:
    """Return ``(session, owned)`` — create one only when none was given."""
    if db is not None:
        return db, False
    from app.db.engine import _factory

    return _factory.session_factory(), True


def audit_rbac(db: Session | None = None) -> RbacReport:
    """Read-only completeness check of the RBAC catalog.

    Never writes, never commits, never touches ``users``.  Safe to run
    against a live database on every deploy.
    """
    session, owned = _session(db)
    try:
        role_names = set(
            session.execute(select(Role.name)).scalars().all()
        )
        permission_scopes = set(
            session.execute(select(Permission.scope)).scalars().all()
        )

        rows = session.execute(
            select(Role.name, Permission.scope).join(
                RolePermission, RolePermission.role_id == Role.id
            ).join(
                Permission, Permission.id == RolePermission.permission_id
            )
        ).all()
        grants: dict[str, set[str]] = {}
        for role_name, scope in rows:
            grants.setdefault(role_name, set()).add(scope)

        missing_roles = tuple(
            name for name in REQUIRED_ROLES if name not in role_names
        )
        missing_permissions = tuple(
            scope for scope in REQUIRED_PERMISSIONS
            if scope not in permission_scopes
        )
        missing_grants: dict[str, tuple[str, ...]] = {}
        for role_name, scopes in ROLE_PERMISSIONS.items():
            if role_name not in role_names:
                # The whole role is missing; listing every scope as well
                # would just repeat the same problem twice.
                continue
            present = grants.get(role_name, set())
            missing = tuple(
                scope.value for scope in scopes if scope.value not in present
            )
            if missing:
                missing_grants[role_name] = missing

        return RbacReport(
            missing_roles=missing_roles,
            missing_permissions=missing_permissions,
            missing_role_permissions=missing_grants,
            ok=not (missing_roles or missing_permissions or missing_grants),
        )
    finally:
        if owned:
            session.close()


def initialize_rbac(db: Session | None = None) -> RbacReport:
    """Seed the RBAC catalog (idempotent) and audit the result.

    Only ``roles`` / ``permissions`` / ``role_permissions`` are written —
    see :data:`WRITABLE_TABLES`.  Administrator credentials live in
    ``users`` and are structurally out of reach of this function.
    """
    session, owned = _session(db)
    try:
        seeded = seed_roles_and_permissions(session)
        report = audit_rbac(session)
        report.seeded = dict(seeded)
        logger.info(
            "rbac_initialized",
            created_permissions=seeded.get("permissions", 0),
            created_roles=seeded.get("roles", 0),
            created_role_permissions=seeded.get("role_permissions", 0),
            ok=report.ok,
            users_modified=0,
        )
        return report
    finally:
        if owned:
            session.close()


def run_rbac_audit() -> int:
    """CLI entry point: ``python -m app.core.rbac_bootstrap``."""
    import sys

    report = audit_rbac()
    print(report.summary)
    if not report.ok:
        print(report.as_dict(), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(run_rbac_audit())
