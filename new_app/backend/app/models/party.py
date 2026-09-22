"""Customer and supplier models.

Tables: customers, suppliers
"""

import uuid

from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import MasterModel, numeric_money


class Customer(MasterModel):
    """Customer record with receivables balance."""

    __tablename__ = "customers"

    name: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    phone: Mapped[str | None] = mapped_column(String(30), index=True)
    address: Mapped[str | None] = mapped_column(Text)
    balance: Mapped[float] = numeric_money(default=0, server_default="0")
    debt_ceiling: Mapped[float] = numeric_money(default=0, server_default="0")

    # Relationships
    sales: Mapped[list["Sale"]] = relationship(  # noqa: F821
        "Sale",
        back_populates="customer",
        lazy="noload",
    )
    debt_entries: Mapped[list["DebtLedgerEntry"]] = relationship(  # noqa: F821
        "DebtLedgerEntry",
        back_populates="customer",
        lazy="noload",
    )


class Supplier(MasterModel):
    """Supplier record with payables balance."""

    __tablename__ = "suppliers"

    name: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    phone: Mapped[str | None] = mapped_column(String(30))
    address: Mapped[str | None] = mapped_column(Text)
    balance: Mapped[float] = numeric_money(default=0, server_default="0")

    # Relationships
    purchases: Mapped[list["Purchase"]] = relationship(  # noqa: F821
        "Purchase",
        back_populates="supplier",
        lazy="noload",
    )
