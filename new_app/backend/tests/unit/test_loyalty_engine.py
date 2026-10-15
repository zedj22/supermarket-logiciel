"""Phase B — transactional loyalty engine.

Covers:
- formula helpers: floor-only points, cashback quantization, reward
  milestones (100 points = 1 reward), percent validation, discount math
- lazy account creation for an existing customer (unknown customer refused)
- append-only ledger posting with balance_after snapshots
- atomic balance updates in the caller's transaction (never committed here)
- unique source_event_key idempotency: safe replay, conflicting payload
- race recovery for the settings singleton and the per-customer account
- rollback: a caller rollback discards settings, account and entry together
- balance reconciliation against ledger sums (mismatch raises, never heals)
- validation: unknown event types, fractional point deltas, empty keys
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, event, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import (
    BusinessRuleError,
    ConflictError,
    DatabaseError,
    NotFoundError,
    ValidationError,
)
from app.db.base import Base
from app.domain.loyalty import (
    POINTS_PER_REWARD,
    LoyaltyMathError,
    available_rewards,
    cashback_earned,
    points_earned,
    remaining_points,
    reward_discount,
    validate_reward_percent,
)
from app.models.loyalty import (
    LOYALTY_SETTINGS_SINGLETON_ID,
    LoyaltyAccount,
    LoyaltyLedgerEntry,
    LoyaltySetting,
)
from app.models.party import Customer
from app.schemas.loyalty import LoyaltySettingsUpdateRequest
from app.services.loyalty import LoyaltyEngine, LoyaltySettingsService


@pytest.fixture()
def engine():
    # isolation_level=None + explicit BEGIN is the documented recipe for
    # real transaction/SAVEPOINT semantics on SQLite (the default pysqlite
    # driver defers BEGIN and silently commits on RELEASE, which would
    # defeat the engine's caller-owned rollback guarantees under test).
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False, "isolation_level": None},
        poolclass=StaticPool,
    )

    @event.listens_for(eng, "begin")
    def _begin(conn):  # pragma: no cover - driver glue
        conn.exec_driver_sql("BEGIN")

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
def customer(db):
    row = Customer(name="Engine Customer")
    db.add(row)
    db.commit()
    return row


@pytest.fixture()
def loyalty(db):
    return LoyaltyEngine(db)


def _count(db, model) -> int:
    return db.scalar(select(func.count()).select_from(model))


# ---------------------------------------------------------------------------
# Formula helpers — points (floor, never round up)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "amount,expected",
    [
        ("0", "0"),
        ("99.99", "0"),  # below one full point at the default rate
        ("100", "1"),
        ("199.99", "1"),
        ("200", "2"),
        ("250", "2"),  # 2.5 floors to 2 — never rounds up
        ("1234.56", "12"),
    ],
)
def test_points_earned_floors(amount, expected):
    assert points_earned(Decimal(amount), Decimal("0.01")) == Decimal(expected)


def test_points_earned_zero_rate_is_zero():
    assert points_earned(Decimal("1000000"), Decimal("0")) == Decimal(0)


def test_points_earned_rejects_negative_inputs():
    with pytest.raises(LoyaltyMathError):
        points_earned(Decimal("-1"), Decimal("0.01"))
    with pytest.raises(LoyaltyMathError):
        points_earned(Decimal("100"), Decimal("-0.01"))


def test_points_earned_custom_rate():
    # 2 points per 1 DA: 3.9 DA earns 7 points (floored).
    assert points_earned(Decimal("3.9"), Decimal("2")) == Decimal(7)


# ---------------------------------------------------------------------------
# Formula helpers — cashback
# ---------------------------------------------------------------------------


def test_cashback_disabled_is_exactly_zero():
    assert cashback_earned(Decimal("123.456"), Decimal("1.000"), enabled=False) == Decimal("0.000")


def test_cashback_enabled_one_percent():
    assert cashback_earned(Decimal("100"), Decimal("1.000"), enabled=True) == Decimal("1.000")


def test_cashback_quantizes_half_even():
    # 123.456 x 1% = 1.23456 -> 1.235 (above the half).
    assert cashback_earned(Decimal("123.456"), Decimal("1.000"), enabled=True) == Decimal("1.235")
    # 10.05 x 1% = 0.1005 -> 0.100 (exact half, even neighbour).
    assert cashback_earned(Decimal("10.05"), Decimal("1.000"), enabled=True) == Decimal("0.100")


def test_cashback_zero_amount_and_negative_rejection():
    assert cashback_earned(Decimal("0"), Decimal("1.000"), enabled=True) == Decimal("0.000")
    with pytest.raises(LoyaltyMathError):
        cashback_earned(Decimal("-1"), Decimal("1.000"), enabled=True)
    with pytest.raises(LoyaltyMathError):
        cashback_earned(Decimal("1"), Decimal("-1"), enabled=True)


# ---------------------------------------------------------------------------
# Formula helpers — reward milestones, percent validation, discount math
# ---------------------------------------------------------------------------


def test_points_per_reward_is_exactly_one_hundred():
    assert POINTS_PER_REWARD == 100


@pytest.mark.parametrize(
    "balance,rewards,remaining",
    [
        ("0", "0", "0"),
        ("30", "0", "30"),
        ("99", "0", "99"),
        ("100", "1", "0"),
        ("130", "1", "30"),
        ("230", "2", "30"),
        ("1000", "10", "0"),
    ],
)
def test_milestone_split_every_100_points_unlocks_one_reward(
    balance, rewards, remaining
):
    assert available_rewards(Decimal(balance)) == Decimal(rewards)
    assert remaining_points(Decimal(balance)) == Decimal(remaining)


def test_milestone_rejects_negative_balance():
    with pytest.raises(LoyaltyMathError):
        available_rewards(Decimal("-1"))
    with pytest.raises(LoyaltyMathError):
        remaining_points(Decimal("-1"))


def test_validate_reward_percent_accepts_within_cap():
    assert validate_reward_percent(Decimal("20"), Decimal("20")) == Decimal(
        "20"
    )
    assert validate_reward_percent(Decimal("5"), Decimal("20")) == Decimal("5")
    assert validate_reward_percent(Decimal("100"), Decimal("100")) == Decimal(
        "100"
    )


def test_validate_reward_percent_rejects_zero_and_negative():
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("0"), Decimal("20"))
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("-5"), Decimal("20"))


def test_validate_reward_percent_rejects_above_one_hundred():
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("101"), Decimal("100"))


def test_validate_reward_percent_rejects_above_owner_cap():
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("25"), Decimal("20"))


def test_validate_reward_percent_parked_cap_refuses_every_selection():
    # max = 0 parks redemption while earning continues.
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("1"), Decimal("0"))


def test_validate_reward_percent_rejects_cap_outside_0_100():
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("10"), Decimal("100.001"))
    with pytest.raises(LoyaltyMathError):
        validate_reward_percent(Decimal("10"), Decimal("-1"))


def test_reward_discount_quantizes_with_money_convention():
    assert reward_discount(Decimal("5000"), Decimal("20")) == Decimal(
        "1000.000"
    )
    assert reward_discount(Decimal("999.999"), Decimal("20")) == Decimal(
        "200.000"
    )
    assert reward_discount(Decimal("100"), Decimal("12.5")) == Decimal("12.500")
    assert reward_discount(Decimal("0"), Decimal("20")) == Decimal("0.000")


def test_reward_discount_never_lets_payable_go_negative():
    # Defense in depth: at 100% the discount equals the amount itself.
    assert reward_discount(Decimal("77.777"), Decimal("100")) == Decimal(
        "77.777"
    )


def test_reward_discount_rejects_invalid_inputs():
    with pytest.raises(LoyaltyMathError):
        reward_discount(Decimal("-1"), Decimal("20"))
    with pytest.raises(LoyaltyMathError):
        reward_discount(Decimal("100"), Decimal("-1"))
    with pytest.raises(LoyaltyMathError):
        reward_discount(Decimal("100"), Decimal("101"))


# ---------------------------------------------------------------------------
# Settings initialization (design check 2)
# ---------------------------------------------------------------------------


def test_read_api_still_never_creates_the_settings_row(db):
    service = LoyaltySettingsService(db)
    service.get()
    service.get()
    assert _count(db, LoyaltySetting) == 0


def test_ensure_settings_creates_singleton_on_first_use(db, loyalty):
    assert _count(db, LoyaltySetting) == 0
    row = loyalty.ensure_settings()
    assert row.id == LOYALTY_SETTINGS_SINGLETON_ID
    assert row.points_rate == Decimal("0.01")
    assert _count(db, LoyaltySetting) == 1
    # Second call reuses the row.
    assert loyalty.ensure_settings().id == LOYALTY_SETTINGS_SINGLETON_ID
    assert _count(db, LoyaltySetting) == 1


def test_ensure_settings_returns_admin_configured_row(db, loyalty, customer):
    LoyaltySettingsService(db).update(
        LoyaltySettingsUpdateRequest(points_rate=Decimal("0.05"))
    )
    row = loyalty.ensure_settings()
    assert row.points_rate == Decimal("0.05")


def test_ensure_settings_adopts_winner_on_create_race(db, loyalty, monkeypatch):
    loyalty.ensure_settings()
    real = loyalty._settings_repo.get_singleton
    calls = {"n": 0}

    def racy():
        calls["n"] += 1
        return None if calls["n"] == 1 else real()

    monkeypatch.setattr(loyalty._settings_repo, "get_singleton", racy)
    row = loyalty.ensure_settings()
    assert row.id == LOYALTY_SETTINGS_SINGLETON_ID
    assert _count(db, LoyaltySetting) == 1


# ---------------------------------------------------------------------------
# Accounts
# ---------------------------------------------------------------------------


def test_account_created_lazily_for_existing_customer(db, loyalty, customer):
    assert _count(db, LoyaltyAccount) == 0
    account = loyalty.get_or_create_account(customer.id)
    assert account.customer_id == customer.id
    assert account.points_balance == 0
    assert _count(db, LoyaltyAccount) == 1
    # Second call returns the same account.
    assert loyalty.get_or_create_account(customer.id).id == account.id


def test_unknown_customer_is_refused(db, loyalty, customer):
    with pytest.raises(NotFoundError):
        loyalty.get_or_create_account(uuid.uuid4())
    assert _count(db, LoyaltyAccount) == 0


def test_account_create_race_adopts_winner(db, loyalty, customer, monkeypatch):
    account = loyalty.get_or_create_account(customer.id)
    calls = {"n": 0}
    real = loyalty._select_account

    def racy(customer_id, *, for_update=True):
        calls["n"] += 1
        if calls["n"] == 1:
            return None
        return real(customer_id, for_update=for_update)

    monkeypatch.setattr(loyalty, "_select_account", racy)
    again = loyalty.get_or_create_account(customer.id)
    assert again.id == account.id
    assert _count(db, LoyaltyAccount) == 1


# ---------------------------------------------------------------------------
# Posting: ledger + balances, atomicity
# ---------------------------------------------------------------------------


def test_post_earn_writes_entry_and_balances(db, loyalty, customer):
    result = loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="sale-earn:inv-1",
        points_delta=12,
        cashback_delta=Decimal("1.235"),
    )
    assert result.replayed is False
    entry = result.entry
    assert entry.event_type == "sale_earn"
    assert entry.points_delta == 12
    assert entry.balance_after_points == 12
    assert entry.balance_after_cashback == Decimal("1.235")

    account = db.scalars(
        select(LoyaltyAccount).where(LoyaltyAccount.customer_id == customer.id)
    ).one()
    assert account.points_balance == 12
    assert account.cashback_balance == Decimal("1.235")


def test_post_never_commits_caller_transaction(db, loyalty, customer):
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="sale-earn:atomic",
        points_delta=5,
    )
    assert db.in_transaction() is True
    db.rollback()
    # Everything the engine wrote lives and dies with the caller's
    # transaction — nothing was committed behind the caller's back.
    assert _count(db, LoyaltyLedgerEntry) == 0
    assert _count(db, LoyaltyAccount) == 0
    assert _count(db, LoyaltySetting) == 0
    # The committed customer survives the rollback.
    assert db.get(Customer, customer.id) is not None


def test_multiple_posts_commit_as_one_unit(db, loyalty, customer):
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="sale-earn:inv-2",
        points_delta=10,
        cashback_delta=Decimal("2.000"),
    )
    loyalty.post(
        customer_id=customer.id,
        event_type="redeem",
        source_event_key="redeem:inv-2",
        points_delta=-4,
        cashback_delta=Decimal("-1.000"),
    )
    db.commit()
    account = db.scalars(
        select(LoyaltyAccount).where(LoyaltyAccount.customer_id == customer.id)
    ).one()
    assert account.points_balance == 6
    assert account.cashback_balance == Decimal("1.000")
    reconciled = loyalty.reconcile_account(customer.id)
    assert reconciled.points == 6
    assert reconciled.cashback == Decimal("1.000")
    assert reconciled.entry_count == 2


def test_post_refuses_negative_resulting_balance(db, loyalty, customer):
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="seed:1",
        points_delta=5,
    )
    db.commit()
    with pytest.raises(BusinessRuleError):
        loyalty.post(
            customer_id=customer.id,
            event_type="redeem",
            source_event_key="redeem:too-much",
            points_delta=-6,
        )
    db.rollback()
    assert _count(db, LoyaltyLedgerEntry) == 1
    account = db.scalars(
        select(LoyaltyAccount).where(LoyaltyAccount.customer_id == customer.id)
    ).one()
    assert account.points_balance == 5


def test_post_unknown_customer_refused(db, loyalty, customer):
    with pytest.raises(NotFoundError):
        loyalty.post(
            customer_id=uuid.uuid4(),
            event_type="sale_earn",
            source_event_key="ghost:1",
            points_delta=1,
        )
    assert _count(db, LoyaltyLedgerEntry) == 0


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


def test_replay_same_key_same_payload_writes_nothing(db, loyalty, customer):
    first = loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="sale-earn:retry",
        points_delta=10,
    )
    db.commit()
    second = loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="sale-earn:retry",
        points_delta=10,
    )
    assert second.replayed is True
    assert second.entry.id == first.entry.id
    assert _count(db, LoyaltyLedgerEntry) == 1
    account = db.scalars(
        select(LoyaltyAccount).where(LoyaltyAccount.customer_id == customer.id)
    ).one()
    assert account.points_balance == 10


def test_same_key_different_payload_is_conflict(db, loyalty, customer):
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="sale-earn:abuse",
        points_delta=10,
    )
    with pytest.raises(ConflictError):
        loyalty.post(
            customer_id=customer.id,
            event_type="sale_earn",
            source_event_key="sale-earn:abuse",
            points_delta=12,
        )
    with pytest.raises(ConflictError):
        loyalty.post(
            customer_id=customer.id,
            event_type="redeem",
            source_event_key="sale-earn:abuse",
            points_delta=10,
        )


def test_same_key_different_customer_is_conflict(db, loyalty, customer):
    other = Customer(name="Other Customer")
    db.add(other)
    db.commit()
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="shared:key",
        points_delta=1,
    )
    with pytest.raises(ConflictError):
        loyalty.post(
            customer_id=other.id,
            event_type="sale_earn",
            source_event_key="shared:key",
            points_delta=1,
        )


def test_raced_unique_insert_degrades_to_replay(db, loyalty, customer, monkeypatch):
    """Simulate a concurrent writer claiming the key between the lookup
    and the insert: the first lookup misses, the insert hits the unique
    index, and the savepoint recovery adopts the existing entry."""
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="race:key",
        points_delta=10,
    )
    db.commit()
    calls = {"n": 0}
    real = loyalty._find_by_key

    def racy(key):
        calls["n"] += 1
        if calls["n"] == 1:
            return None  # first lookup misses the committed entry
        return real(key)

    monkeypatch.setattr(loyalty, "_find_by_key", racy)
    result = loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="race:key",
        points_delta=10,
    )
    assert result.replayed is True
    assert _count(db, LoyaltyLedgerEntry) == 1


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def test_unknown_event_type_rejected(db, loyalty, customer):
    with pytest.raises(ValidationError):
        loyalty.post(
            customer_id=customer.id,
            event_type="sale_earn_typo",
            source_event_key="typo:1",
            points_delta=1,
        )


@pytest.mark.parametrize("key", ["", "k" * 121])
def test_bad_source_event_key_rejected(db, loyalty, customer, key):
    with pytest.raises(ValidationError):
        loyalty.post(
            customer_id=customer.id,
            event_type="sale_earn",
            source_event_key=key,
            points_delta=1,
        )


def test_fractional_points_delta_rejected(db, loyalty, customer):
    with pytest.raises(ValidationError):
        loyalty.post(
            customer_id=customer.id,
            event_type="sale_earn",
            source_event_key="frac:1",
            points_delta=Decimal("1.5"),
        )


# ---------------------------------------------------------------------------
# Reconciliation
# ---------------------------------------------------------------------------


def test_reconcile_matches_ledger_after_posts(db, loyalty, customer):
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="rec:earn",
        points_delta=10,
        cashback_delta=Decimal("1.000"),
    )
    loyalty.post(
        customer_id=customer.id,
        event_type="redeem",
        source_event_key="rec:redeem",
        points_delta=-3,
        cashback_delta=Decimal("-0.500"),
    )
    reconciled = loyalty.reconcile_account(customer.id)
    assert reconciled.points == 7
    assert reconciled.cashback == Decimal("0.500")
    assert reconciled.entry_count == 2


def test_reconcile_zero_account_is_consistent(db, loyalty, customer):
    loyalty.get_or_create_account(customer.id)
    reconciled = loyalty.reconcile_account(customer.id)
    assert reconciled.points == 0
    assert reconciled.cashback == 0
    assert reconciled.entry_count == 0


def test_reconcile_detects_tampered_cached_balance(db, loyalty, customer):
    loyalty.post(
        customer_id=customer.id,
        event_type="sale_earn",
        source_event_key="tamper:1",
        points_delta=10,
    )
    account = db.scalars(
        select(LoyaltyAccount).where(LoyaltyAccount.customer_id == customer.id)
    ).one()
    account.points_balance = 99  # tamper with the cache, not the ledger
    db.flush()
    with pytest.raises(DatabaseError):
        loyalty.reconcile_account(customer.id)


def test_reconcile_unknown_account_refused(db, loyalty, customer):
    with pytest.raises(NotFoundError):
        loyalty.reconcile_account(uuid.uuid4())
