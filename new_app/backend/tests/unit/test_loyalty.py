"""Phase A — loyalty foundation: settings service + schema constraints.

Covers:
- approved defaults on a database that has never been written to
- GET returns them without creating a row (read never writes)
- partial update persists, creates the singleton row, audits the change
- two sequential updates never create a second settings row
- server-side validation boundaries: negative rates, reward cap outside
  [0, 100] (0 parks redemption and IS valid)
- schema constraints (SQLite CHECK/UNIQUE mirrors of the PostgreSQL DDL):
  singleton id, non-negative account balances, one account per customer,
  unique ledger ``source_event_key``, known event types only, non-negative
  balance snapshots, negative deltas allowed, sale summary columns nullable
  with no legacy default and CHECK >= 0
"""

from __future__ import annotations

from decimal import Decimal

import pydantic
import pytest
from sqlalchemy import create_engine, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import ValidationError
from app.db.base import Base
from app.models.audit import AuditLog
from app.models.loyalty import (
    LOYALTY_SETTINGS_SINGLETON_ID,
    LEDGER_EVENT_TYPES,
    LoyaltyAccount,
    LoyaltyLedgerEntry,
    LoyaltySetting,
)
from app.models.party import Customer
from app.models.sale import Sale
from app.schemas.loyalty import LoyaltySettingsUpdateRequest
from app.services.loyalty import LoyaltySettingsService


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def db(engine):
    TestingSession = sessionmaker(bind=engine, autoflush=False)
    session = TestingSession()
    yield session
    session.close()


@pytest.fixture()
def service(db):
    return LoyaltySettingsService(db)


# ---------------------------------------------------------------------------
# Defaults / read path
# ---------------------------------------------------------------------------


def test_get_returns_approved_defaults(service, db):
    row = service.get()
    assert row.points_enabled is True
    assert row.points_rate == Decimal("0.01")
    assert row.cashback_enabled is False
    assert row.cashback_rate == Decimal("1.000")
    assert row.max_reward_discount_percent == Decimal("20.000")
    assert row.earn_on_debt_settlement is True


def test_read_never_writes(service, db):
    service.get()
    service.get()
    assert db.scalar(select(func.count()).select_from(LoyaltySetting)) == 0


def test_defaults_equal_model_constants(service):
    row = service.get()
    assert row.id == LOYALTY_SETTINGS_SINGLETON_ID
    assert row.points_rate == Decimal("0.01")  # one point per 100 DA


# ---------------------------------------------------------------------------
# Write path: partial update, singleton, audit
# ---------------------------------------------------------------------------


def test_update_persists_and_creates_singleton_row(service, db):
    row = service.update(LoyaltySettingsUpdateRequest(points_rate=Decimal("0.02")))
    assert row.points_rate == Decimal("0.02")
    # Untouched fields keep their defaults.
    assert row.cashback_enabled is False
    assert row.max_reward_discount_percent == Decimal("20.000")

    stored = db.get(LoyaltySetting, LOYALTY_SETTINGS_SINGLETON_ID)
    assert stored is not None
    assert stored.points_rate == Decimal("0.02")
    assert db.scalar(select(func.count()).select_from(LoyaltySetting)) == 1


def test_update_is_partial(service, db):
    service.update(LoyaltySettingsUpdateRequest(points_enabled=False))
    service.update(LoyaltySettingsUpdateRequest(cashback_enabled=True))
    row = service.get()
    assert row.points_enabled is False
    assert row.cashback_enabled is True
    assert row.points_rate == Decimal("0.01")


def test_two_updates_keep_single_row(service, db):
    service.update(LoyaltySettingsUpdateRequest(points_rate=Decimal("0.02")))
    service.update(LoyaltySettingsUpdateRequest(points_rate=Decimal("0.05")))
    assert db.scalar(select(func.count()).select_from(LoyaltySetting)) == 1
    assert service.get().points_rate == Decimal("0.05")


def test_update_writes_one_audit_row(service, db):
    service.update(
        LoyaltySettingsUpdateRequest(points_rate=Decimal("0.02")),
        actor_id=None,
    )
    rows = list(
        db.scalars(
            select(AuditLog).where(AuditLog.entity_type == "loyalty_settings")
        ).all()
    )
    assert len(rows) == 1
    assert rows[0].action == "update"


def test_empty_update_rejected(service):
    with pytest.raises(pydantic.ValidationError) as excinfo:
        LoyaltySettingsUpdateRequest()
    assert "at least one" in str(excinfo.value).lower()


# ---------------------------------------------------------------------------
# Server-side validation boundaries
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "field,value",
    [
        ("points_rate", Decimal("-0.01")),
        ("cashback_rate", Decimal("-1")),
        ("max_reward_discount_percent", Decimal("-1")),
        ("max_reward_discount_percent", Decimal("100.001")),
    ],
)
def test_out_of_bound_numeric_settings_rejected(service, db, field, value):
    """The schema rejects them outright; nothing reaches the database."""
    with pytest.raises((pydantic.ValidationError, ValidationError)):
        request = LoyaltySettingsUpdateRequest(**{field: value})
        service.update(request)
    assert db.scalar(select(func.count()).select_from(LoyaltySetting)) == 0


@pytest.mark.parametrize(
    "field,value",
    [
        ("points_rate", Decimal("-0.01")),
        ("cashback_rate", Decimal("-1")),
        ("max_reward_discount_percent", Decimal("-1")),
        ("max_reward_discount_percent", Decimal("100.001")),
    ],
)
def test_domain_guard_alone_refuses_out_of_bounds(field, value):
    """Defense in depth: a caller that bypasses the pydantic schema still
    cannot persist an out-of-bounds rule."""
    with pytest.raises(ValidationError):
        LoyaltySettingsService._validate({field: value})


@pytest.mark.parametrize(
    "field,value",
    [
        ("points_rate", Decimal("0")),  # zero rate = earn disabled, allowed
        ("cashback_rate", Decimal("0")),
        ("max_reward_discount_percent", Decimal("0")),  # parks redemption
        ("max_reward_discount_percent", Decimal("100")),
        ("max_reward_discount_percent", Decimal("0.001")),
    ],
)
def test_boundary_values_accepted(service, db, field, value):
    row = service.update(LoyaltySettingsUpdateRequest(**{field: value}))
    assert getattr(row, field) == value


# ---------------------------------------------------------------------------
# Schema constraints: accounts
# ---------------------------------------------------------------------------


def _customer(db) -> Customer:
    customer = Customer(name="Loyalty Unit Customer")
    db.add(customer)
    db.flush()
    return customer


def test_account_rejects_negative_points_balance(db):
    account = LoyaltyAccount(customer_id=_customer(db).id, points_balance=-1)
    db.add(account)
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_account_rejects_negative_cashback_balance(db):
    account = LoyaltyAccount(
        customer_id=_customer(db).id, cashback_balance=Decimal("-0.001")
    )
    db.add(account)
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_account_defaults_are_zero(db):
    account = LoyaltyAccount(customer_id=_customer(db).id)
    db.add(account)
    db.flush()
    assert account.points_balance == 0
    assert account.cashback_balance == 0


def test_one_account_per_customer(db):
    customer = _customer(db)
    db.add(LoyaltyAccount(customer_id=customer.id))
    db.flush()
    db.add(LoyaltyAccount(customer_id=customer.id))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


# ---------------------------------------------------------------------------
# Schema constraints: ledger
# ---------------------------------------------------------------------------


def _account(db) -> LoyaltyAccount:
    account = LoyaltyAccount(customer_id=_customer(db).id)
    db.add(account)
    db.flush()
    return account


def test_ledger_rejects_duplicate_source_event_key(db):
    account = _account(db)
    entry = LoyaltyLedgerEntry(
        account_id=account.id,
        event_type="sale_earn",
        points_delta=10,
        balance_after_points=10,
        source_event_key="sale-earn:dup",
    )
    db.add(entry)
    db.flush()
    db.add(
        LoyaltyLedgerEntry(
            account_id=account.id,
            event_type="sale_earn",
            points_delta=10,
            balance_after_points=20,
            source_event_key="sale-earn:dup",
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_ledger_rejects_unknown_event_type(db):
    account = _account(db)
    db.add(
        LoyaltyLedgerEntry(
            account_id=account.id,
            event_type="sale_earn_typo",
            points_delta=10,
            balance_after_points=10,
            source_event_key="typo:1",
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_ledger_accepts_every_documented_event_type(db):
    account = _account(db)
    for index, event in enumerate(LEDGER_EVENT_TYPES):
        db.add(
            LoyaltyLedgerEntry(
                account_id=account.id,
                event_type=event,
                points_delta=1,
                balance_after_points=index + 1,
                source_event_key=f"{event}:row-{index}",
            )
        )
    db.flush()
    count = db.scalar(
        select(func.count()).select_from(LoyaltyLedgerEntry)
    )
    assert count == len(LEDGER_EVENT_TYPES)


def test_ledger_rejects_negative_balance_snapshot(db):
    account = _account(db)
    db.add(
        LoyaltyLedgerEntry(
            account_id=account.id,
            event_type="adjustment",
            points_delta=-5,
            balance_after_points=-5,
            source_event_key="adjustment:bad",
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_ledger_accepts_negative_deltas_with_non_negative_snapshot(db):
    """Redeem / clawback entries carry negative deltas; the snapshot of the
    resulting balance must still be >= 0."""
    account = _account(db)
    db.add(
        LoyaltyLedgerEntry(
            account_id=account.id,
            event_type="redeem",
            points_delta=-5,
            balance_after_points=5,
            cashback_delta=Decimal("-1.500"),
            balance_after_cashback=Decimal("0.500"),
            source_event_key="redeem:1",
        )
    )
    db.flush()
    entry = db.scalar(
        select(LoyaltyLedgerEntry).where(
            LoyaltyLedgerEntry.source_event_key == "redeem:1"
        )
    )
    assert entry.points_delta == -5


# ---------------------------------------------------------------------------
# Schema constraints: sale summary columns
# ---------------------------------------------------------------------------


def test_legacy_sale_row_keeps_null_loyalty_summary(db):
    sale = Sale(invoice_number="LOYALTY-NULL-1", subtotal=100, total=100)
    db.add(sale)
    db.flush()
    assert sale.loyalty_points_earned is None
    assert sale.loyalty_cashback_earned is None
    assert sale.loyalty_points_redeemed is None
    assert sale.loyalty_redeemed_value is None
    assert sale.amount_due is None


def test_sale_accepts_written_loyalty_summary(db):
    sale = Sale(
        invoice_number="LOYALTY-SUM-1",
        subtotal=100,
        total=100,
        loyalty_points_earned=1,
        amount_due=Decimal("99.000"),
    )
    db.add(sale)
    db.flush()
    assert sale.loyalty_points_earned == 1


def test_sale_rejects_negative_loyalty_summary(db):
    db.add(
        Sale(
            invoice_number="LOYALTY-NEG-1",
            subtotal=100,
            total=100,
            loyalty_points_earned=-1,
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_sale_rejects_negative_amount_due(db):
    db.add(
        Sale(
            invoice_number="LOYALTY-NEG-2",
            subtotal=100,
            total=100,
            amount_due=Decimal("-0.001"),
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


# ---------------------------------------------------------------------------
# Model-level guards: singleton CHECK
# ---------------------------------------------------------------------------


def test_settings_row_id_must_be_one(db):
    db.add(
        LoyaltySetting(
            id=2,
            points_enabled=True,
            points_rate=Decimal("0.01"),
            cashback_enabled=False,
            cashback_rate=Decimal("1.000"),
            max_reward_discount_percent=Decimal("20.000"),
            earn_on_debt_settlement=True,
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()
