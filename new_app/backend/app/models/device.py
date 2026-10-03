"""Device registry model: devices.

Table: devices — Phase 16 (analysis §10.1).

One table is enough: a pairing request *is* a ``devices`` row whose
``status`` is ``pending`` and whose unguessable ``pairing_id`` is what the
client polls.  No ``pairing_requests`` table, no ``device_sessions`` table,
no settings table (Phase 17).

Identity layering (§9.3) — never conflated:

  device identity   ``device_id``  (``pos-…``)   public, appears in reports
  credential        ``token_hash`` (SHA-256)     secret; only the hash exists
  display name      ``display_name``             editable, human facing

There is deliberately NO foreign key from domain tables to ``devices``:
``sales.device_id`` and friends stay free text so the Phase 14 report
contract is byte-for-byte unchanged.
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin
from app.models.enums import DeviceStatus


class Device(Base, UUIDMixin, TimestampMixin):
    """One registered (or requesting) LAN device."""

    __tablename__ = "devices"

    # Immutable machine identity generated once by the Flutter client and
    # never renamed (§9). Unique — re-pairing updates the existing row.
    device_id: Mapped[str] = mapped_column(String(100), nullable=False, unique=True)

    # Unguessable UUIDv4 handed to the requester on POST /devices/pair and
    # used as the polling handle for GET /devices/pairings/{pairing_id}.
    # The UNIQUE constraint is also the poll index — no second index.
    pairing_id: Mapped[uuid.UUID] = mapped_column(
        default=uuid.uuid4, nullable=False, unique=True
    )

    # Human facing label. Defaults to the Windows machine name, editable by
    # the user (owner Q9). Never used as an identity key.
    display_name: Mapped[str] = mapped_column(String(150), nullable=False)

    # pending | approved | rejected | revoked (DeviceStatus).
    status: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        index=True,
        default=DeviceStatus.PENDING.value,
        server_default=DeviceStatus.PENDING.value,
    )

    # Reported by the client at pair time, for visibility only. Phase 16
    # enforces *protocol* compatibility, not an app-version floor (Q12).
    client_version: Mapped[str | None] = mapped_column(String(50))

    # SHA-256 hex of the one-time device token. NULL until approval and
    # again after revocation. The plaintext token exists exactly once, in
    # the approval poll response — it is never stored or logged.
    token_hash: Mapped[str | None] = mapped_column(String(64))

    # Metadata only — an IP address is never an identity (§21 T6/D-07).
    requested_ip: Mapped[str | None] = mapped_column(String(45))
    last_ip: Mapped[str | None] = mapped_column(String(45))

    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    approved_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    rejected_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Liveness, updated at most once per minute per device (§12.5) so a
    # room full of tills does not turn into write amplification.
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    approver: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        foreign_keys=[approved_by],
        lazy="selectin",
    )

    @property
    def is_approved(self) -> bool:
        return self.status == "approved"
