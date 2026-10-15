"""Loyalty services (Phase A settings + Phase B posting engine).

:class:`LoyaltySettingsService` owns the loyalty rules contract, mirroring
:class:`app.services.settings.SettingsService`:

* **read** never writes — a fresh install (or an in-memory test database)
  returns the approved Phase 1 defaults without mutating anything;
* **write** is a partial update that persists exactly the fields supplied,
  creates the singleton row on first save, and appends one ``update`` audit
  row **in the same transaction**: a change that cannot be audited is not
  reported as saved;
* every numeric rule is validated server-side here (in addition to the
  pydantic schema and the database CHECK constraints), so a negative rate
  or a reward cap outside [0, 100] can never be persisted through any
  caller.

:class:`LoyaltyEngine` (Phase B) is the transactional posting engine: lazy
account creation, append-only ledger writes, atomic balance updates with
post-write reconciliation, and unique ``source_event_key`` idempotency.
It NEVER commits — every method writes through the caller's session and
flushes only, so sale/debt/return/void integrations group several posts
under one caller-owned transaction boundary.  Phase C (reward redesign)
adds the checkout helpers: unlocked preview + locked in-transaction
revalidation of a reward percentage discount (exactly
``POINTS_PER_REWARD`` points consumed), and the configured earn
calculation used by the sale flow.
"""

from __future__ import annotations

import json
import uuid
from decimal import Decimal
from typing import NamedTuple

import structlog
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.exceptions import (
    BusinessRuleError,
    ConflictError,
    DatabaseError,
    NotFoundError,
    ValidationError,
)
from app.domain.loyalty import (
    POINTS_PER_REWARD,
    LoyaltyMathError,
    available_rewards,
    cashback_earned,
    points_earned,
    reward_discount,
    validate_reward_percent,
)
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.enums import AuditAction, AuditModule, AuditOutcome
from app.models.loyalty import (
    DEFAULT_CASHBACK_ENABLED,
    DEFAULT_CASHBACK_RATE,
    DEFAULT_EARN_ON_DEBT_SETTLEMENT,
    DEFAULT_MAX_REWARD_DISCOUNT_PERCENT,
    DEFAULT_POINTS_ENABLED,
    DEFAULT_POINTS_RATE,
    LEDGER_EVENT_TYPES,
    LOYALTY_SETTINGS_SINGLETON_ID,
    LoyaltyAccount,
    LoyaltyLedgerEntry,
    LoyaltySetting,
)
from app.models.party import Customer
from app.repositories.loyalty import LoyaltySettingsRepository
from app.schemas.loyalty import LoyaltySettingsUpdateRequest
from app.services.audit import AuditService
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

#: Numeric rules enforced server-side, mirroring the database CHECK
#: constraints on ``loyalty_settings``.  The deprecated points-as-money
#: columns (``point_value``, ``min_redemption_points``,
#: ``max_redemption_percent``) are no longer writable through any API.
_NUMERIC_RULES: dict[str, tuple[bool, Decimal]] = {
    # name: (allow_zero, minimum_inclusive_bound)
    "points_rate": (True, Decimal("0")),
    "cashback_rate": (True, Decimal("0")),
    "max_reward_discount_percent": (True, Decimal("0")),
}


def loyalty_settings_defaults() -> dict[str, object]:
    """Approved default values for a fresh ``loyalty_settings`` row.

    Shared by :meth:`LoyaltySettingsService` (first admin save) and
    :meth:`LoyaltyEngine.ensure_settings` (first posted event) so both
    paths seed the singleton with identical values.  The deprecated
    money-from-points columns keep their model defaults for schema
    compatibility but no caller supplies them anymore.
    """
    return {
        "points_enabled": DEFAULT_POINTS_ENABLED,
        "points_rate": DEFAULT_POINTS_RATE,
        "cashback_enabled": DEFAULT_CASHBACK_ENABLED,
        "cashback_rate": DEFAULT_CASHBACK_RATE,
        "max_reward_discount_percent": DEFAULT_MAX_REWARD_DISCOUNT_PERCENT,
        "earn_on_debt_settlement": DEFAULT_EARN_ON_DEBT_SETTLEMENT,
    }


class LoyaltySettingsService(BaseService):
    """Loyalty rules use case (settings only — Phase A)."""

    def __init__(self, db: Session):
        super().__init__(db)
        self._repo = LoyaltySettingsRepository(db)

    # -- read ---------------------------------------------------------------

    def get(self) -> LoyaltySetting:
        """Current loyalty settings.  Never writes to the database."""
        row = self._repo.get_singleton()
        if row is not None:
            return row
        return LoyaltySetting(
            id=LOYALTY_SETTINGS_SINGLETON_ID, **self._defaults()
        )

    # -- write --------------------------------------------------------------

    def update(
        self,
        request: LoyaltySettingsUpdateRequest,
        *,
        actor_id: uuid.UUID | None = None,
    ) -> LoyaltySetting:
        """Apply a partial update, validate it, persist it and audit it.

        Raises a :class:`ValidationError` when a numeric rule is out of
        bounds and an :class:`AppError` when the row cannot be written, so
        a caller is never told "saved" unless the commit really happened.
        """
        changes = request.provided()
        self._validate(changes)
        before = self.get()
        before_snapshot = {key: getattr(before, key) for key in changes}
        after_snapshot = {**before_snapshot, **changes}

        with self.transaction():
            row = self._repo.get_singleton()
            if row is None:
                row = self._repo.create_singleton(**self._defaults())
            for key, value in changes.items():
                setattr(row, key, value)
            # Same transaction as the change: no audit row, no save.
            AuditService(self.db).record(
                action=AuditAction.UPDATE,
                module=AuditModule.SETTINGS,
                outcome=AuditOutcome.SUCCESS,
                entity_type="loyalty_settings",
                entity_id=row.id,
                user_id=actor_id,
                details=json.dumps(sorted(changes)),
                before=before_snapshot,
                after=after_snapshot,
            )
        logger.info(
            "loyalty_settings_updated",
            fields=sorted(changes),
            user_id=str(actor_id) if actor_id else None,
        )
        return row

    # -- validation ---------------------------------------------------------

    @staticmethod
    def _validate(changes: dict[str, object]) -> None:
        """Domain guard mirroring the database CHECK constraints."""
        for name, (allow_zero, lower) in _NUMERIC_RULES.items():
            if name not in changes:
                continue
            value = Decimal(str(changes[name]))
            if value < lower or (value == lower and not allow_zero):
                raise ValidationError(
                    f"{name} must be {'>= ' if allow_zero else '> '}{lower}"
                )
        if "max_reward_discount_percent" in changes:
            cap = Decimal(str(changes["max_reward_discount_percent"]))
            if cap < 0 or cap > 100:
                raise ValidationError(
                    "max_reward_discount_percent must be >= 0 and <= 100"
                )

    # -- helpers ------------------------------------------------------------

    def _defaults(self) -> dict[str, object]:
        return loyalty_settings_defaults()


# ---------------------------------------------------------------------------
# Phase B — transactional posting engine
# ---------------------------------------------------------------------------


class PostedEntry(NamedTuple):
    """Result of :meth:`LoyaltyEngine.post`.

    ``replayed`` is True when an entry with the same ``source_event_key``
    already existed — the command is a retry and nothing was written.
    """

    entry: LoyaltyLedgerEntry
    replayed: bool


class ReconciledBalances(NamedTuple):
    """Ledger-derived balances confirmed to match the cached ones."""

    points: Decimal
    cashback: Decimal
    entry_count: int


class RewardDecision(NamedTuple):
    """Result of one reward eligibility evaluation.

    ``points_cost`` is always either 0 (no reward selected) or exactly
    ``POINTS_PER_REWARD`` (one reward consumed — a point balance is
    never money), ``percent`` the cashier-selected discount percentage
    within the owner's cap, and ``discount`` the DA value the server
    derived from the eligible base (money-quantized).  The
    pre-transaction preview and the in-transaction revalidation must
    agree on ALL THREE — otherwise the sale aborts before mutating
    anything.
    """

    points_cost: Decimal
    percent: Decimal
    discount: Decimal


class EarnedRewards(NamedTuple):
    """Rewards earned on one qualifying amount (both may be zero)."""

    points: Decimal
    cashback: Decimal


class LoyaltyEngine(BaseService):
    """Transactional loyalty posting engine (Phase B).

    The **ledger is authoritative**: every mutation appends exactly one
    ``loyalty_ledger_entries`` row, and the cached ``loyalty_accounts``
    balances are updated in the SAME transaction, locked per customer
    (``SELECT ... FOR UPDATE`` on PostgreSQL) so concurrent postings for
    one customer serialize.  After the write the engine reconciles the
    cached balances against the computed snapshots and raises
    :class:`DatabaseError` on any mismatch — a reconciliation failure is
    never swallowed.

    **This engine never commits.**  Every method writes through the
    caller's session and flushes only; the caller owns the transaction
    boundary.  A future integration posts several events (e.g. earn +
    redeem on one sale) under its own ``with engine.transaction():`` (or
    its existing service transaction) so they commit or roll back as one
    unit.

    Idempotency: ``source_event_key`` is UNIQUE.  A retry with the same
    key and the same payload returns the original entry with
    ``replayed=True`` and writes nothing; the same key with a DIFFERENT
    payload is rejected with :class:`ConflictError`.
    """

    def __init__(self, db: Session):
        super().__init__(db)
        self._settings_repo = LoyaltySettingsRepository(db)

    # -- settings -----------------------------------------------------------

    def ensure_settings(self) -> LoyaltySetting:
        """Return the singleton settings row, creating it on first use.

        The row is created inside the CALLER's transaction via a SAVEPOINT:
        if a concurrent transaction wins the race for the singleton primary
        key, the savepoint rolls back cleanly and this method adopts the
        winner's committed row instead of failing the caller.  This is the
        only path that creates the row implicitly; the read API
        (``LoyaltySettingsService.get``) keeps its Phase A
        read-never-writes contract untouched.
        """
        row = self._settings_repo.get_singleton()
        if row is not None:
            return row
        try:
            with self.db.begin_nested():
                row = self._settings_repo.create_singleton(
                    **loyalty_settings_defaults()
                )
        except IntegrityError:
            row = self._settings_repo.get_singleton()
            if row is None:
                raise
        return row

    def settings_snapshot(self) -> dict[str, object]:
        """Read-only plain-value view of the current settings.

        Returns the approved defaults when the singleton row does not
        exist yet.  Phase D callers (debt settlement) use this to evaluate
        merchant gates such as ``earn_on_debt_settlement`` without ever
        writing — creating the row stays exclusive to
        :meth:`ensure_settings` inside a posting transaction.
        """
        return self._settings_values(self._settings_repo.get_singleton())

    # -- accounts -----------------------------------------------------------

    def get_or_create_account(
        self, customer_id: uuid.UUID, *, for_update: bool = True
    ) -> LoyaltyAccount:
        """Lazily create the loyalty account for an existing customer.

        ``for_update=True`` locks the row (PostgreSQL) so subsequent
        balance arithmetic in the same transaction is serialized per
        customer.  A concurrent create race is resolved through a
        SAVEPOINT: the loser adopts the winner's row.
        """
        if self.db.get(Customer, customer_id) is None:
            raise NotFoundError(
                f"customer {customer_id} does not exist"
            )
        account = self._select_account(customer_id, for_update=for_update)
        if account is not None:
            return account
        try:
            with self.db.begin_nested():
                account = LoyaltyAccount(customer_id=customer_id)
                self.db.add(account)
                self.db.flush()
        except IntegrityError:
            account = self._select_account(
                customer_id, for_update=for_update
            )
            if account is None:
                raise
        return account

    def _select_account(
        self, customer_id: uuid.UUID, *, for_update: bool
    ) -> LoyaltyAccount | None:
        stmt = select(LoyaltyAccount).where(
            LoyaltyAccount.customer_id == customer_id
        )
        if for_update:
            stmt = stmt.with_for_update()
        return self.db.scalars(stmt).first()

    # -- redemption / earning (Phase C) -----------------------------------

    _SETTINGS_KEYS = (
        "points_enabled",
        "points_rate",
        "cashback_enabled",
        "cashback_rate",
        "max_reward_discount_percent",
        "earn_on_debt_settlement",
    )

    def _settings_values(
        self, row: LoyaltySetting | None
    ) -> dict[str, object]:
        """Plain-value view of the settings row (defaults when absent).

        Used by the read-only preview path, which must NEVER create the
        singleton row (``ensure_settings`` is the only writer, and it runs
        in-transaction).
        """
        if row is None:
            return loyalty_settings_defaults()
        return {key: getattr(row, key) for key in self._SETTINGS_KEYS}

    @staticmethod
    def _no_reward() -> RewardDecision:
        return RewardDecision(Decimal(0), Decimal(0), quantize_money(0))

    def _decide_reward(
        self,
        *,
        settings: dict[str, object],
        current_points: Decimal,
        selected_percent: Decimal,
        gross_total: Decimal,
    ) -> RewardDecision:
        """Validate the selected percent and price the decision.

        Shared by the unlocked preview and the locked in-transaction
        revalidation so both evaluate the exact same rules — any drift
        between them (balance dropped below the milestone, settings
        changed) is caught by the caller's equality check.

        One reward always costs exactly ``POINTS_PER_REWARD`` points;
        the discount is derived server-side from the eligible base and
        the cashier's percent, never taken from the client.
        """
        if selected_percent == 0:
            return self._no_reward()
        if not settings["points_enabled"]:
            raise ValidationError(
                "loyalty points are disabled",
                details={"selected_percent": str(selected_percent)},
            )
        rewards = available_rewards(current_points)
        if rewards < 1:
            raise ValidationError(
                "customer has no reward available (100 points required)",
                details={
                    "selected_percent": str(selected_percent),
                    "points_balance": str(current_points),
                    "available_rewards": str(rewards),
                },
            )
        try:
            percent = validate_reward_percent(
                selected_percent,
                settings["max_reward_discount_percent"],
            )
            discount = reward_discount(gross_total, percent)
        except LoyaltyMathError as exc:
            raise ValidationError(str(exc)) from exc
        return RewardDecision(
            points_cost=Decimal(POINTS_PER_REWARD),
            percent=percent,
            discount=discount,
        )

    def preview_reward(
        self,
        *,
        customer_id: uuid.UUID,
        reward_percent: Decimal | int | float | str,
        gross_total: Decimal | int | float | str,
    ) -> RewardDecision:
        """Pre-transaction eligibility read for a checkout preview.

        Unlocked and read-only (never creates settings or account rows):
        the authoritative check happens in :meth:`revalidate_reward`
        under the account ``FOR UPDATE`` lock, and a drift between the
        two aborts the sale.  A percent of 0 means "no reward" and
        short-circuits without touching the account.
        """
        percent = to_decimal(reward_percent)
        if percent == 0:
            return self._no_reward()
        account = self._select_account(customer_id, for_update=False)
        current = account.points_balance if account is not None else Decimal(0)
        return self._decide_reward(
            settings=self._settings_values(self._settings_repo.get_singleton()),
            current_points=to_decimal(current),
            selected_percent=percent,
            gross_total=quantize_money(gross_total),
        )

    def revalidate_reward(
        self,
        *,
        customer_id: uuid.UUID,
        reward_percent: Decimal | int | float | str,
        gross_total: Decimal | int | float | str,
        expected: RewardDecision,
    ) -> RewardDecision:
        """Authoritative in-transaction re-check under the row lock.

        Locks the loyalty account (``SELECT ... FOR UPDATE``), recomputes
        the decision from the CURRENT balance and settings, and requires
        it to equal the pre-transaction preview.  Any disagreement raises
        :class:`ValidationError` — the caller aborts before mutating the
        sale, stock or balances, and the cashier simply retries.
        """
        percent = to_decimal(reward_percent)
        if percent == 0:
            return self._no_reward()
        settings = self._settings_values(self.ensure_settings())
        account = self.get_or_create_account(customer_id, for_update=True)
        decision = self._decide_reward(
            settings=settings,
            current_points=to_decimal(account.points_balance),
            selected_percent=percent,
            gross_total=quantize_money(gross_total),
        )
        if (
            decision.points_cost != expected.points_cost
            or decision.percent != expected.percent
            or decision.discount != expected.discount
        ):
            raise ValidationError(
                "loyalty reward changed since it was previewed; retry",
                details={
                    "expected_points_cost": str(expected.points_cost),
                    "expected_percent": str(expected.percent),
                    "expected_discount": str(expected.discount),
                    "actual_points_cost": str(decision.points_cost),
                    "actual_percent": str(decision.percent),
                    "actual_discount": str(decision.discount),
                },
            )
        return decision

    def calculate_earn(
        self,
        *,
        qualifying_amount: Decimal | int | float | str,
        settings: dict[str, object] | None = None,
    ) -> EarnedRewards:
        """Points and cashback earned on ``qualifying_amount``.

        The caller decides what qualifies (sale net of redemption, debt
        settlement principal, ...); this applies the configured rates with
        the approved rounding (points floored, cashback HALF_EVEN 0.001).
        A disabled rule contributes exactly zero, never a partial rate.
        """
        if settings is None:
            settings = self._settings_values(
                self._settings_repo.get_singleton()
            )
        amount = to_decimal(qualifying_amount)
        try:
            earned = (
                points_earned(amount, settings["points_rate"])
                if settings["points_enabled"]
                else Decimal(0)
            )
            cashback = cashback_earned(
                amount,
                settings["cashback_rate"],
                enabled=bool(settings["cashback_enabled"]),
            )
        except LoyaltyMathError as exc:
            raise ValidationError(str(exc)) from exc
        return EarnedRewards(earned, cashback)

    # -- posting ------------------------------------------------------------

    def post(
        self,
        *,
        customer_id: uuid.UUID,
        event_type: str,
        source_event_key: str,
        points_delta: Decimal | int | float | str = 0,
        cashback_delta: Decimal | int | float | str = 0,
        sale_id: uuid.UUID | None = None,
        return_id: uuid.UUID | None = None,
        created_by: uuid.UUID | None = None,
        note: str | None = None,
    ) -> PostedEntry:
        """Append one ledger entry and move the cached balances with it.

        Writes are transactional and caller-owned: this method flushes but
        never commits.  The resulting balances are refused outright if they
        would go negative (:class:`BusinessRuleError`), and the post-write
        reconciliation re-reads the account and raises
        :class:`DatabaseError` if it does not match the snapshots recorded
        on the entry.

        A replay (same ``source_event_key``, same payload) returns the
        existing entry with ``replayed=True`` and writes nothing.
        """
        if event_type not in LEDGER_EVENT_TYPES:
            raise ValidationError(f"unknown loyalty event_type: {event_type}")
        if not source_event_key or len(source_event_key) > 120:
            raise ValidationError(
                "source_event_key is required (max 120 characters)"
            )
        points = to_decimal(points_delta)
        if points != points.to_integral_value():
            raise ValidationError(
                f"points_delta must be a whole number: {points}"
            )
        cashback = quantize_money(cashback_delta)

        replay = self._find_by_key(source_event_key)
        if replay is not None:
            self._assert_replay_matches(
                replay,
                customer_id=customer_id,
                event_type=event_type,
                points_delta=points,
                cashback_delta=cashback,
            )
            logger.info(
                "loyalty_post_replayed",
                source_event_key=source_event_key,
                event_type=event_type,
            )
            return PostedEntry(replay, True)

        # Evaluate the refusal BEFORE any write.  The rule is unchanged
        # (resulting balances may never go negative — same message, same
        # details), but ordering it first means a refused post leaves no
        # freshly created settings/account row behind: a rolled-back
        # transaction must not have side effects, and SQLite (which
        # commits released savepoints eagerly) would otherwise persist
        # them while PostgreSQL would roll them back.
        account = self._select_account(customer_id, for_update=True)
        current_points = (
            account.points_balance
            if account is not None
            else Decimal(0)
        )
        current_cashback = (
            account.cashback_balance
            if account is not None
            else Decimal(0)
        )
        if current_points + points < 0 or current_cashback + cashback < 0:
            raise BusinessRuleError(
                "loyalty balances cannot go negative",
                details={
                    "points_balance": str(current_points),
                    "cashback_balance": str(current_cashback),
                    "points_delta": str(points),
                    "cashback_delta": str(cashback),
                },
            )

        self.ensure_settings()
        if account is None:
            account = self.get_or_create_account(
                customer_id, for_update=True
            )

        new_points = account.points_balance + points
        new_cashback = account.cashback_balance + cashback

        entry = LoyaltyLedgerEntry(
            account_id=account.id,
            event_type=event_type,
            points_delta=points,
            cashback_delta=cashback,
            balance_after_points=new_points,
            balance_after_cashback=new_cashback,
            source_event_key=source_event_key,
            sale_id=sale_id,
            return_id=return_id,
            created_by=created_by,
            note=note,
        )
        try:
            with self.db.begin_nested():
                self.db.add(entry)
                self.db.flush()
        except IntegrityError:
            # A concurrent writer claimed the key between our lookup and
            # this insert.  The savepoint rolled back cleanly; if their
            # entry is visible and matches, treat this as a replay —
            # otherwise surface the integrity failure untouched.
            raced = self._find_by_key(source_event_key)
            if raced is not None:
                self._assert_replay_matches(
                    raced,
                    customer_id=customer_id,
                    event_type=event_type,
                    points_delta=points,
                    cashback_delta=cashback,
                )
                return PostedEntry(raced, True)
            raise

        # Ledger entry and cached balance move together — never one
        # without the other.
        account.points_balance = new_points
        account.cashback_balance = new_cashback
        self.db.flush()

        # Reconciliation: re-read the persisted balances and compare them
        # against the snapshots recorded on the entry.  A mismatch is a
        # bug or corruption — raise, never continue.
        self.db.refresh(account)
        if (
            account.points_balance != new_points
            or account.cashback_balance != new_cashback
        ):
            raise DatabaseError(
                "loyalty balance reconciliation failed after posting",
                details={
                    "source_event_key": source_event_key,
                    "expected_points": str(new_points),
                    "actual_points": str(account.points_balance),
                    "expected_cashback": str(new_cashback),
                    "actual_cashback": str(account.cashback_balance),
                },
            )

        logger.info(
            "loyalty_posted",
            event_type=event_type,
            source_event_key=source_event_key,
            customer_id=str(customer_id),
            points_delta=str(points),
            cashback_delta=str(cashback),
        )
        return PostedEntry(entry, False)

    def _find_by_key(self, source_event_key: str) -> LoyaltyLedgerEntry | None:
        return self.db.scalars(
            select(LoyaltyLedgerEntry).where(
                LoyaltyLedgerEntry.source_event_key == source_event_key
            )
        ).first()

    @staticmethod
    def _assert_replay_matches(
        entry: LoyaltyLedgerEntry,
        *,
        customer_id: uuid.UUID,
        event_type: str,
        points_delta: Decimal,
        cashback_delta: Decimal,
    ) -> None:
        """A reused key must carry the SAME logical event, or it is abuse."""
        entry_customer = entry.account.customer_id if entry.account else None
        if (
            entry_customer != customer_id
            or entry.event_type != event_type
            or entry.points_delta != points_delta
            or entry.cashback_delta != cashback_delta
        ):
            raise ConflictError(
                "source_event_key already used with a different payload",
                details={"source_event_key": entry.source_event_key},
            )

    # -- reconciliation ------------------------------------------------------

    def reconcile_account(self, customer_id: uuid.UUID) -> ReconciledBalances:
        """Re-derive balances from the ledger and compare with the cache.

        The ledger is authoritative: the SUM of every ``points_delta`` /
        ``cashback_delta`` for the account must equal the cached balances.
        Any disagreement raises :class:`DatabaseError` — reconciliation
        failures are never swallowed or auto-repaired here.
        """
        account = self.db.scalars(
            select(LoyaltyAccount).where(
                LoyaltyAccount.customer_id == customer_id
            )
        ).first()
        if account is None:
            raise NotFoundError("loyalty account does not exist")

        points_sum, cashback_sum, count = self.db.execute(
            select(
                func.coalesce(func.sum(LoyaltyLedgerEntry.points_delta), 0),
                func.coalesce(func.sum(LoyaltyLedgerEntry.cashback_delta), 0),
                func.count(),
            ).where(LoyaltyLedgerEntry.account_id == account.id)
        ).one()
        points_sum = to_decimal(points_sum)
        cashback_sum = to_decimal(cashback_sum)

        if (
            points_sum != account.points_balance
            or cashback_sum != account.cashback_balance
        ):
            raise DatabaseError(
                "loyalty account balances disagree with the ledger",
                details={
                    "customer_id": str(customer_id),
                    "ledger_points": str(points_sum),
                    "cached_points": str(account.points_balance),
                    "ledger_cashback": str(cashback_sum),
                    "cached_cashback": str(account.cashback_balance),
                },
            )
        return ReconciledBalances(points_sum, cashback_sum, count)

    # -- Phase E reads + administrative adjustment --------------------------

    def account_balance(
        self, customer_id: uuid.UUID
    ) -> LoyaltyAccount | None:
        """Read-only account fetch for the balance API.

        Never creates the account row (read-never-writes); returns
        ``None`` when the customer has no loyalty activity yet.
        """
        return self._select_account(customer_id, for_update=False)

    def history(
        self,
        customer_id: uuid.UUID,
        *,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[LoyaltyLedgerEntry], int]:
        """Paginated append-only ledger for one customer, newest first.

        Deterministic ordering (created_at DESC, id DESC as tie-break) so
        pagination never repeats or skips a row.  A customer with no
        account yet yields an empty page rather than an error.
        """
        account = self._select_account(customer_id, for_update=False)
        if account is None:
            return [], 0
        total = (
            self.db.scalar(
                select(func.count())
                .select_from(LoyaltyLedgerEntry)
                .where(LoyaltyLedgerEntry.account_id == account.id)
            )
            or 0
        )
        stmt = (
            select(LoyaltyLedgerEntry)
            .where(LoyaltyLedgerEntry.account_id == account.id)
            .order_by(
                LoyaltyLedgerEntry.created_at.desc(),
                LoyaltyLedgerEntry.id.desc(),
            )
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        return list(self.db.scalars(stmt).all()), total

    def adjust(
        self,
        customer_id: uuid.UUID,
        *,
        points_delta: int | None,
        cashback_delta: Decimal | None,
        reason: str,
        client_request_id: str,
        actor_id: uuid.UUID | None,
    ) -> PostedEntry:
        """Administrative balance adjustment (Phase E).

        Posts one ``adjustment`` ledger entry and its audit row in the
        SAME transaction.  ``client_request_id`` maps to a stable
        ``source_event_key`` so a retry replays the original entry
        instead of moving the balance twice; a reused key with a
        DIFFERENT payload is a 409 (the engine's replay guard).  The
        engine still refuses any result that would drive a balance
        negative — an over-grown deduction is a 422, never a clamp.
        """
        if self.db.get(Customer, customer_id) is None:
            raise NotFoundError(
                f"customer {customer_id} does not exist"
            )
        with self.transaction():
            posted = self.post(
                customer_id=customer_id,
                event_type="adjustment",
                source_event_key=f"admin_adjust:{client_request_id}",
                points_delta=points_delta if points_delta is not None else 0,
                cashback_delta=(
                    cashback_delta if cashback_delta is not None else 0
                ),
                created_by=actor_id,
                note=reason,
            )
            if not posted.replayed:
                AuditService(self.db).record(
                    action=AuditAction.ADJUSTMENT,
                    module=AuditModule.CUSTOMERS,
                    outcome=AuditOutcome.SUCCESS,
                    entity_type="customer",
                    entity_id=customer_id,
                    user_id=actor_id,
                    reason=reason,
                    details=json.dumps(
                        {
                            "points_delta": str(posted.entry.points_delta),
                            "cashback_delta": str(
                                posted.entry.cashback_delta
                            ),
                            "client_request_id": client_request_id,
                        }
                    ),
                )
        logger.info(
            "loyalty_admin_adjust",
            customer_id=str(customer_id),
            points_delta=str(points_delta),
            cashback_delta=str(cashback_delta),
            idempotent_replay=posted.replayed,
            user_id=str(actor_id) if actor_id else None,
        )
        return posted
