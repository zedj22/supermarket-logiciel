"""Unit tests for R3 RBAC initialisation and audit (§5).

Every test gets its own in-memory SQLite database, so the catalog can be
inspected in an empty state, seeded, broken and re-audited without any
test influencing another — and without ever reaching PostgreSQL.
"""

from __future__ import annotations

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.core import rbac_bootstrap as rbac
from app.core.seed import ROLE_PERMISSIONS, seed_roles_and_permissions
from app.db.base import Base
from app.models.enums import PermissionScope
from app.models.user import Permission, Role, RolePermission, User


@pytest.fixture()
def db():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    session = Session(bind=engine)
    yield session
    session.rollback()
    session.close()
    engine.dispose()


def _counts(db: Session) -> dict[str, int]:
    return {
        "roles": len(db.execute(select(Role)).scalars().all()),
        "permissions": len(db.execute(select(Permission)).scalars().all()),
        "role_permissions": len(
            db.execute(select(RolePermission)).scalars().all()
        ),
        "users": len(db.execute(select(User)).scalars().all()),
    }


def _admin_user(db: Session, pin_hash: str = "original-pin-hash") -> User:
    user = User(full_name="Store Owner", pin_hash=pin_hash, is_active=True)
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


class TestAudit:
    def test_empty_database_reports_everything_missing(self, db):
        report = rbac.audit_rbac(db)
        assert report.ok is False
        assert report.missing_roles == rbac.REQUIRED_ROLES
        assert report.missing_permissions == rbac.REQUIRED_PERMISSIONS
        assert report.users_modified == 0

    def test_audit_is_read_only(self, db):
        seed_roles_and_permissions(db)
        before = _counts(db)

        first = rbac.audit_rbac(db)
        second = rbac.audit_rbac(db)

        assert _counts(db) == before
        assert first.ok and second.ok
        assert first.seeded == {} and second.seeded == {}

    def test_missing_grant_is_reported_for_the_right_role(self, db):
        seed_roles_and_permissions(db)
        cashier = db.execute(select(Role).where(Role.name == "cashier")).scalar_one()
        doomed = db.execute(
            select(RolePermission).where(RolePermission.role_id == cashier.id)
        ).scalars().first()
        db.delete(doomed)
        db.commit()

        report = rbac.audit_rbac(db)
        assert report.ok is False
        assert "cashier" in report.missing_role_permissions
        assert report.missing_roles == ()
        assert report.missing_permissions == ()
        assert doomed.permission.scope in report.missing_role_permissions["cashier"]

    def test_missing_role_is_reported_once_not_scope_by_scope(self, db):
        seed_roles_and_permissions(db)
        admin = db.execute(select(Role).where(Role.name == "admin")).scalar_one()
        db.delete(admin)  # cascades to its role_permissions
        db.commit()

        report = rbac.audit_rbac(db)
        assert report.ok is False
        assert report.missing_roles == ("admin",)
        # the role itself is the finding; every scope would just repeat it
        assert "admin" not in report.missing_role_permissions

    def test_missing_permission_scope_is_reported(self, db):
        seed_roles_and_permissions(db)
        scope = PermissionScope.POS_SALE.value
        permission = db.execute(
            select(Permission).where(Permission.scope == scope)
        ).scalar_one()
        db.delete(permission)
        db.commit()

        report = rbac.audit_rbac(db)
        assert report.ok is False
        assert scope in report.missing_permissions

    def test_summary_and_serialisation(self, db):
        report = rbac.audit_rbac(db)
        assert "missing roles" in report.summary
        payload = report.as_dict()
        assert payload["ok"] is False
        assert payload["users_modified"] == 0
        assert set(payload["missing_roles"]) == set(rbac.REQUIRED_ROLES)

        seed_roles_and_permissions(db)
        ok_report = rbac.audit_rbac(db)
        assert "RBAC complete" in ok_report.summary
        assert ok_report.as_dict()["ok"] is True


class TestInitialize:
    def test_initialize_creates_the_full_catalog(self, db):
        report = rbac.initialize_rbac(db)
        assert report.ok is True
        assert report.missing_roles == ()
        assert report.missing_permissions == ()
        assert report.missing_role_permissions == {}
        assert report.seeded["permissions"] == len(rbac.REQUIRED_PERMISSIONS)
        assert report.seeded["roles"] == len(rbac.REQUIRED_ROLES)
        assert report.seeded["role_permissions"] > 0

    def test_initialize_is_idempotent(self, db):
        first = rbac.initialize_rbac(db)
        second = rbac.initialize_rbac(db)
        assert first.seeded["permissions"] > 0
        assert second.seeded == {
            "permissions": 0,
            "roles": 0,
            "role_permissions": 0,
        }
        assert second.ok is True
        assert _counts(db)["roles"] == len(rbac.REQUIRED_ROLES)

    def test_initialize_repairs_a_partially_deleted_catalog(self, db):
        rbac.initialize_rbac(db)
        manager = db.execute(
            select(Role).where(Role.name == "manager")
        ).scalar_one()
        for role_permission in list(manager.role_permissions):
            db.delete(role_permission)
        db.commit()
        assert rbac.audit_rbac(db).ok is False

        repaired = rbac.initialize_rbac(db)
        assert repaired.ok is True
        assert repaired.seeded["role_permissions"] > 0

    def test_every_required_role_and_permission_exists_after_init(self, db):
        rbac.initialize_rbac(db)
        role_names = set(db.execute(select(Role.name)).scalars().all())
        scopes = set(db.execute(select(Permission.scope)).scalars().all())
        assert set(rbac.REQUIRED_ROLES) <= role_names
        assert set(rbac.REQUIRED_PERMISSIONS) <= scopes

    def test_role_grants_match_the_declared_mapping(self, db):
        rbac.initialize_rbac(db)
        for role_name, expected in ROLE_PERMISSIONS.items():
            role = db.execute(
                select(Role).where(Role.name == role_name)
            ).scalar_one()
            actual = {rp.permission.scope for rp in role.role_permissions}
            assert actual == {scope.value for scope in expected}, role_name


class TestAdministratorCredentialsAreUntouched:
    def test_initialize_never_writes_the_users_table(self, db):
        user = _admin_user(db, pin_hash="original-pin-hash")
        before = _counts(db)
        before_row = (
            user.id,
            user.full_name,
            user.pin_hash,
            user.is_active,
            user.failed_login_attempts,
            user.locked_until,
            user.created_at,
            user.updated_at,
        )

        rbac.initialize_rbac(db)

        db.expire_all()
        after_row = (
            user.id,
            user.full_name,
            user.pin_hash,
            user.is_active,
            user.failed_login_attempts,
            user.locked_until,
            user.created_at,
            user.updated_at,
        )
        assert after_row == before_row
        assert user.pin_hash == "original-pin-hash"
        assert _counts(db)["users"] == before["users"] == 1

    def test_repeated_initialisation_cannot_reset_a_pin(self, db):
        user = _admin_user(db, pin_hash="argon2id$salt$hash")
        for _ in range(3):
            rbac.initialize_rbac(db)
        db.expire_all()
        assert user.pin_hash == "argon2id$salt$hash"

    def test_audit_also_leaves_users_alone(self, db):
        user = _admin_user(db, pin_hash="keep-me")
        before = _counts(db)
        rbac.audit_rbac(db)
        rbac.audit_rbac(db)
        db.expire_all()
        assert user.pin_hash == "keep-me"
        assert _counts(db) == before

    def test_writable_tables_never_include_users(self):
        assert "users" not in rbac.WRITABLE_TABLES
        assert rbac.WRITABLE_TABLES == {
            "roles",
            "permissions",
            "role_permissions",
        }

    def test_module_source_never_targets_the_users_table(self):
        """The seed must not grow a `users` write by accident later."""
        import ast
        from pathlib import Path

        source = Path(rbac.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)

        docstrings: set[int] = set()
        for node in ast.walk(tree):
            if isinstance(
                node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
            ):
                body = node.body
                if (
                    body
                    and isinstance(body[0], ast.Expr)
                    and isinstance(body[0].value, ast.Constant)
                    and isinstance(body[0].value.value, str)
                ):
                    docstrings.add(id(body[0].value))

        strings = [
            node.value
            for node in ast.walk(tree)
            if isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and id(node) not in docstrings
        ]
        joined = "\n".join(strings)
        for forbidden in (
            "INSERT INTO users",
            "UPDATE users",
            "DELETE FROM users",
            "users.pin_hash",
            "pin_hash=",
        ):
            assert forbidden not in joined, forbidden


class TestCatalogConstants:
    def test_required_roles_come_from_the_seed_mapping(self):
        assert rbac.REQUIRED_ROLES == tuple(ROLE_PERMISSIONS)
        assert set(rbac.REQUIRED_ROLES) == {"admin", "manager", "cashier"}

    def test_required_permissions_cover_every_enum_value(self):
        assert rbac.REQUIRED_PERMISSIONS == tuple(
            scope.value for scope in PermissionScope
        )
        assert len(rbac.REQUIRED_PERMISSIONS) >= 30
        assert len(rbac.REQUIRED_PERMISSIONS) == len(
            set(rbac.REQUIRED_PERMISSIONS)
        )

    def test_admin_role_is_granted_every_permission(self):
        assert set(ROLE_PERMISSIONS["admin"]) == set(PermissionScope)
