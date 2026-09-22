"""Phase 4 auth tests — security, auth service, auth API.

Covers:
- Argon2id hashing
- JWT creation/verification
- Session creation/revocation
- Setup-first-admin flow
- Login/lockout
- User CRUD
- Auth API endpoints
- Authorization dependencies
"""

from __future__ import annotations

import time
import uuid
from datetime import timedelta
from unittest.mock import patch

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings
from app.core.constants import (
    ARGON2_HASH_LENGTH,
    ARGON2_MEMORY_COST,
    ARGON2_PARALLELISM,
    ARGON2_SALT_LENGTH,
    ARGON2_TIME_COST,
    PIN_MAX_LENGTH,
    PIN_MIN_LENGTH,
)
from app.core.config import settings
from app.core.security import (
    create_access_token,
    decode_access_token,
    hash_pin,
    hash_token,
    verify_pin,
)
from app.db.base import BaseModel
from app.models.audit import AuditLog
from app.models.enums import AuditAction, PermissionScope, UserRoleEnum
from app.models.user import AuthSession, Permission, Role, User, UserRole, RolePermission
from app.schemas.auth import (
    LoginRequest,
    LoginResponse,
    PINChangeRequest,
    SetupRequest,
    UserCreateRequest,
    UserListResponse,
    UserResponse,
    UserUpdateRequest,
    VerifyResponse,
    CurrentUserResponse,
)
from app.services.auth import AuthService


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def engine():
    """SQLite in-memory engine for unit tests."""
    eng = create_engine("sqlite:///:memory:", echo=False)
    BaseModel.metadata.create_all(eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def db(engine):
    """Session per test, rolled back after."""
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()


# ---------------------------------------------------------------------------
# Security: Argon2id
# ---------------------------------------------------------------------------

class TestArgon2id:
    def test_hash_pin_returns_string(self):
        h = hash_pin("1234")
        assert isinstance(h, str)

    def test_hash_pin_verifies(self):
        h = hash_pin("5678")
        assert verify_pin("5678", h)
        assert not verify_pin("5679", h)

    def test_different_hashes_for_same_pin(self):
        h1 = hash_pin("1234")
        h2 = hash_pin("1234")
        assert h1 != h2

    def test_verify_pin_empty_pin_fails(self):
        assert not verify_pin("", "$argon2id$v=19$m=65536,t=3,p=4$test$salt$hash")

    def test_hash_config_constants(self):
        assert ARGON2_TIME_COST == 3
        assert ARGON2_MEMORY_COST == 65536
        assert ARGON2_PARALLELISM == 4
        assert ARGON2_HASH_LENGTH == 32
        assert ARGON2_SALT_LENGTH == 16


# ---------------------------------------------------------------------------
# Security: JWT
# ---------------------------------------------------------------------------

class TestJWT:
    def test_create_and_decode_token(self):
        user_id = uuid.uuid4()
        session_id = uuid.uuid4()
        token = create_access_token(user_id=user_id, session_id=session_id)
        assert isinstance(token, str)
        decoded = decode_access_token(token)
        assert decoded is not None
        assert decoded["sub"] == str(user_id)
        assert decoded["sid"] == str(session_id)
        assert "exp" in decoded
        assert "iat" in decoded

    def test_decode_expired_token(self):
        user_id = uuid.uuid4()
        session_id = uuid.uuid4()
        token = create_access_token(
            user_id=user_id,
            session_id=session_id,
            expires_delta=timedelta(seconds=-1),
        )
        decoded = decode_access_token(token)
        assert decoded is None

    def test_decode_invalid_token(self):
        decoded = decode_access_token("not.a.valid.token")
        assert decoded is None

    def test_hash_token_returns_hex_string(self):
        h = hash_token("some-token-value")
        assert isinstance(h, str)
        assert len(h) == 64  # SHA-256 hex digest

    def test_hash_token_deterministic(self):
        assert hash_token("abc") == hash_token("abc")
        assert hash_token("abc") != hash_token("def")


# ---------------------------------------------------------------------------
# Security: Pin constraints
# ---------------------------------------------------------------------------

class TestPinConstraints:
    def test_min_pin_length(self):
        assert PIN_MIN_LENGTH == 4

    def test_max_pin_length(self):
        assert PIN_MAX_LENGTH == 6


# ---------------------------------------------------------------------------
# Auth Service: Setup
# ---------------------------------------------------------------------------

class TestSetupFirstAdmin:
    def test_setup_creates_admin(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        assert user.full_name == "Admin"
        assert user.is_active
        assert user.pin_hash != ""

    def test_setup_creates_admin_role(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        role_names = [r.name for r in user.roles]
        assert "admin" in role_names

    def test_setup_fails_pin_mismatch(self, db: Session):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.setup_first_admin(
                name="Admin",
                pin="1234",
                pin_confirm="5678",
            )

    def test_setup_fails_pin_too_short(self, db: Session):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.setup_first_admin(
                name="Admin",
                pin="12",
                pin_confirm="12",
            )

    def test_setup_fails_admin_exists(self, db: Session):
        service = AuthService(db)
        service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        with pytest.raises(Exception):
            service.setup_first_admin(
                name="Admin2",
                pin="5678",
                pin_confirm="5678",
            )

    def test_is_setup_needed(self, db: Session):
        service = AuthService(db)
        assert service.is_setup_needed()
        service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        assert not service.is_setup_needed()


# ---------------------------------------------------------------------------
# Auth Service: Login
# ---------------------------------------------------------------------------

class TestLogin:
    @pytest.fixture()
    def admin_user(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        return user

    def test_login_returns_token(self, db: Session, admin_user):
        service = AuthService(db)
        token, user = service.login(
            user_id=admin_user.id,
            pin="1234",
            device_name="Test Device",
        )
        assert isinstance(token, str)
        assert user.id == admin_user.id

    def test_login_creates_session(self, db: Session, admin_user):
        service = AuthService(db)
        token, user = service.login(
            user_id=admin_user.id,
            pin="1234",
            device_name="Test Device",
        )
        sessions = db.scalars(
            select(AuthSession).where(AuthSession.user_id == admin_user.id)
        ).all()
        assert len(sessions) == 1
        assert sessions[0].device_name == "Test Device"

    def test_login_wrong_pin_fails(self, db: Session, admin_user):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.login(
                user_id=admin_user.id,
                pin="9999",
                device_name="Test Device",
            )

    def test_login_locks_account_after_threshold(self, db: Session, admin_user):
        service = AuthService(db)
        for _ in range(settings.LOCKOUT_THRESHOLD):
            with pytest.raises(Exception):
                service.login(
                    user_id=admin_user.id,
                    pin="9999",
                    device_name="Test Device",
                )
        # Now correct pin should also fail
        with pytest.raises(Exception):
            service.login(
                user_id=admin_user.id,
                pin="1234",
                device_name="Test Device",
            )

    def test_login_resets_attempts_on_success(self, db: Session, admin_user):
        service = AuthService(db)
        # Fail twice
        for _ in range(2):
            with pytest.raises(Exception):
                service.login(
                    user_id=admin_user.id,
                    pin="9999",
                    device_name="Test Device",
                )
        # Succeed
        token, user = service.login(
            user_id=admin_user.id,
            pin="1234",
            device_name="Test Device",
        )
        assert isinstance(token, str)
        # Check counter reset
        db.refresh(admin_user)
        assert admin_user.failed_login_attempts == 0


# ---------------------------------------------------------------------------
# Auth Service: Login audit user_id attribution
# ---------------------------------------------------------------------------

class TestLoginAuditUserId:
    """Regression: login audit rows must record the authenticated user's id."""

    @pytest.fixture()
    def admin_user(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        return user

    def test_successful_login_audit_has_user_id(self, db: Session, admin_user):
        service = AuthService(db)
        service.login(
            user_id=admin_user.id,
            pin="1234",
            device_name="Test Device",
        )

        audit = db.execute(
            select(AuditLog).where(
                AuditLog.action == AuditAction.LOGIN.value,
                AuditLog.details == f"User {admin_user.full_name} logged in",
            )
        ).scalar_one()

        assert audit.user_id == admin_user.id
        # Audit must never store credentials or tokens
        assert "1234" not in (audit.details or "")

    def test_failed_login_audit_has_user_id(self, db: Session, admin_user):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.login(
                user_id=admin_user.id,
                pin="9999",
                device_name="Test Device",
            )
        db.flush()

        audit = db.execute(
            select(AuditLog).where(
                AuditLog.action == AuditAction.LOGIN.value,
                AuditLog.details == f"Failed login for {admin_user.full_name}",
            )
        ).scalar_one()

        assert audit.user_id == admin_user.id
        assert "9999" not in (audit.details or "")

    def test_login_audit_does_not_store_token_or_pin_hash(
        self, db: Session, admin_user
    ):
        service = AuthService(db)
        token, _ = service.login(
            user_id=admin_user.id,
            pin="1234",
            device_name="Test Device",
        )

        audits = db.execute(
            select(AuditLog).where(AuditLog.action == AuditAction.LOGIN.value)
        ).scalars().all()
        assert audits
        for audit in audits:
            blob = " ".join(
                str(v) for v in (
                    audit.details,
                    audit.before_state,
                    audit.after_state,
                    audit.entity_type,
                )
                if v is not None
            )
            assert "1234" not in blob
            assert token not in blob
            assert admin_user.pin_hash not in blob


# ---------------------------------------------------------------------------
# Auth Service: Verify Token
# ---------------------------------------------------------------------------

class TestVerifyToken:
    @pytest.fixture()
    def admin_session(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        token, _ = service.login(
            user_id=user.id,
            pin="1234",
            device_name="Test Device",
        )
        return token, user

    def test_verify_valid_token(self, db: Session, admin_session):
        service = AuthService(db)
        token, user = admin_session
        verified_user, session = service.verify_token(token)
        assert verified_user.id == user.id

    def test_verify_invalid_token(self, db: Session, admin_session):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.verify_token("invalid.token.here")


# ---------------------------------------------------------------------------
# Auth Service: Logout
# ---------------------------------------------------------------------------

class TestLogout:
    @pytest.fixture()
    def admin_session(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        token, _ = service.login(
            user_id=user.id,
            pin="1234",
            device_name="Test Device",
        )
        return token, user

    def test_logout_revokes_session(self, db: Session, admin_session):
        service = AuthService(db)
        token, user = admin_session
        service.logout(token)
        with pytest.raises(Exception):
            service.verify_token(token)


# ---------------------------------------------------------------------------
# Auth Service: Reauth
# ---------------------------------------------------------------------------

class TestReauth:
    @pytest.fixture()
    def admin_user(self, db: Session):
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        return user

    def test_reauth_valid_pin(self, db: Session, admin_user):
        service = AuthService(db)
        service.reauth(user_id=admin_user.id, pin="1234")

    def test_reauth_invalid_pin(self, db: Session, admin_user):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.reauth(user_id=admin_user.id, pin="9999")


# ---------------------------------------------------------------------------
# Auth Service: User CRUD
# ---------------------------------------------------------------------------

class TestUserCRUD:
    @pytest.fixture()
    def admin_user(self, db: Session):
        from app.core.seed import seed_roles_and_permissions
        seed_roles_and_permissions(db)
        service = AuthService(db)
        user = service.setup_first_admin(
            name="Admin",
            pin="1234",
            pin_confirm="1234",
        )
        return user

    def test_create_user(self, db: Session, admin_user):
        service = AuthService(db)
        new_user = service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        assert new_user.full_name == "Cashier 1"
        assert new_user.is_active
        role_names = [r.name for r in new_user.roles]
        assert "cashier" in role_names

    def test_create_user_duplicate_name_fails(self, db: Session, admin_user):
        service = AuthService(db)
        service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        with pytest.raises(Exception):
            service.create_user(
                name="Cashier 1",
                pin="9012",
                role_names=["cashier"],
            )

    def test_create_user_weak_pin_fails(self, db: Session, admin_user):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.create_user(
                name="Cashier 2",
                pin="12",
                role_names=["cashier"],
            )

    def test_update_user_name(self, db: Session, admin_user):
        service = AuthService(db)
        new_user = service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        updated = service.update_user(
            user_id=new_user.id,
            name="Cashier Updated",
        )
        assert updated.full_name == "Cashier Updated"

    def test_update_user_deactivate(self, db: Session, admin_user):
        service = AuthService(db)
        new_user = service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        updated = service.update_user(
            user_id=new_user.id,
            is_active=False,
        )
        assert not updated.is_active

    def test_delete_user(self, db: Session, admin_user):
        service = AuthService(db)
        new_user = service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        service.delete_user(new_user.id)
        assert db.get(User, new_user.id) is None

    def test_delete_last_admin_fails(self, db: Session, admin_user):
        service = AuthService(db)
        with pytest.raises(Exception):
            service.delete_user(admin_user.id)

    def test_change_pin(self, db: Session, admin_user):
        service = AuthService(db)
        new_user = service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        invalidated = service.change_pin(
            user_id=new_user.id,
            new_pin="9012",
            new_pin_confirm="9012",
        )
        assert isinstance(invalidated, int)

    def test_change_pin_mismatch_fails(self, db: Session, admin_user):
        service = AuthService(db)
        new_user = service.create_user(
            name="Cashier 1",
            pin="5678",
            role_names=["cashier"],
        )
        with pytest.raises(Exception):
            service.change_pin(
                user_id=new_user.id,
                new_pin="9012",
                new_pin_confirm="3456",
            )


# ---------------------------------------------------------------------------
# Schemas: Validation
# ---------------------------------------------------------------------------

class TestSchemas:
    def test_user_list_response(self):
        resp = UserListResponse(
            items=[],
            total=0,
            page=1,
            page_size=10,
            pages=0,
        )
        assert resp.total == 0

    def test_verify_response_valid(self):
        resp = VerifyResponse(valid=True)
        assert resp.valid

    def test_verify_response_invalid(self):
        resp = VerifyResponse(valid=False)
        assert not resp.valid

    def test_current_user_response(self):
        resp = CurrentUserResponse(
            id=uuid.uuid4(),
            full_name="Admin",
            is_active=True,
            roles=[],
            permissions=[PermissionScope.POS_SALE],
        )
        assert resp.permissions == [PermissionScope.POS_SALE]


# ---------------------------------------------------------------------------
# Seed: Role/Permission
# ---------------------------------------------------------------------------

class TestSeed:
    def test_seed_creates_permissions(self, db: Session):
        from app.core.seed import seed_roles_and_permissions

        result = seed_roles_and_permissions(db)
        assert result["permissions"] == 27
        assert result["roles"] == 3
        assert result["role_permissions"] > 0

    def test_seed_is_idempotent(self, db: Session):
        from app.core.seed import seed_roles_and_permissions

        result1 = seed_roles_and_permissions(db)
        result2 = seed_roles_and_permissions(db)
        assert result2["permissions"] == 0
        assert result2["roles"] == 0

    def test_admin_role_has_all_permissions(self, db: Session):
        from app.core.seed import seed_roles_and_permissions

        seed_roles_and_permissions(db)
        admin_role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        perm_count = len(admin_role.role_permissions)
        assert perm_count == 27


# ---------------------------------------------------------------------------
# Lockout configuration
# ---------------------------------------------------------------------------

class TestLockoutConfig:
    def test_lockout_threshold(self):
        assert settings.LOCKOUT_THRESHOLD == 5

    def test_lockout_duration(self):
        assert settings.LOCKOUT_DURATION_MINUTES == 15
