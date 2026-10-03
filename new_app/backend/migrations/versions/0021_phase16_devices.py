"""0021_phase16_devices

Revision ID: b7f3c2d91a04
Revises: 4a1e5c7b9d2f
Create Date: 2026-10-03

Phase 16 (LAN / multi-PC / devices) — ONE new table, nothing else touched
(analysis §10.1, decision record §10/§11):

devices
   device_id       VARCHAR(100) NOT NULL UNIQUE — the immutable machine
                   identity the Flutter client generated once and never
                   renames (owner Q9). It is NOT a credential.
   pairing_id      UUID NOT NULL UNIQUE — unguessable handle handed to the
                   requester at POST /devices/pair so it can poll
                   GET /devices/pairings/{pairing_id}. Acts as the CSRF
                   defence for the pairing handshake (§19), and the UNIQUE
                   constraint doubles as the poll lookup index.
   display_name    VARCHAR(150) NOT NULL — defaults to the Windows machine
                   name, editable by the user (owner Q9).
   status          VARCHAR(20) NOT NULL DEFAULT 'pending'
                       pending | approved | rejected | revoked
   client_version  VARCHAR(50) NULL — reported for visibility only; Phase 16
                   enforces PROTOCOL compatibility, not an app floor (Q12).
   token_hash      VARCHAR(64) NULL — SHA-256 hex of the one-time device
                   token. NULL while pending/rejected AND after revocation.
                   The plaintext token exists exactly once, in the approval
                   poll response; it is never stored or logged.
   requested_ip    VARCHAR(45) NULL — metadata only; an IP is never an
                   identity (§21 T6/D-07).
   last_ip         VARCHAR(45) NULL — refreshed on successful device-guard
                   calls (throttled to once/60s per device, §12.5).
   approved_at/by  attribution; FK to users ON DELETE SET NULL.
   rejected_at     denial timestamp.
   revoked_at      revocation timestamp (audit + UI only).
   last_seen_at    liveness; heartbeats are NEVER written to audit_logs.

Indexes
   ix_devices_id      (UUIDMixin.index = True, same as every other table)
   ix_devices_status  admin devices list filter/sort

Deliberately absent (Phase 16 deferrals):
   * NO foreign key from sales/audit_logs/expenses.device_id to devices —
     those columns stay free text so the Phase 14 report contract is
     byte-for-byte unchanged (§21 D-05).
   * NO ``pairing_requests`` table — a pairing request IS a devices row.
   * NO ``device_sessions`` table — one active session per device.
   * NO settings table and NO schema change for protocol/server_id —
     /system/info gains them additively in the response body (§8.2).

Downgrade drops ONLY what this revision added. Upgrade inserts no rows.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'b7f3c2d91a04'
down_revision = '4a1e5c7b9d2f'
branch_labels = None
depends_on = None

UUID_PK_SERVER_DEFAULT = sa.text("gen_random_uuid()")


def upgrade() -> None:
    op.create_table(
        "devices",
        sa.Column("device_id", sa.String(length=100), nullable=False),
        sa.Column("pairing_id", sa.Uuid(), nullable=False),
        sa.Column("display_name", sa.String(length=150), nullable=False),
        sa.Column(
            "status",
            sa.String(length=20),
            server_default="pending",
            nullable=False,
        ),
        sa.Column("client_version", sa.String(length=50), nullable=True),
        sa.Column("token_hash", sa.String(length=64), nullable=True),
        sa.Column("requested_ip", sa.String(length=45), nullable=True),
        sa.Column("last_ip", sa.String(length=45), nullable=True),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "approved_by",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("rejected_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "id",
            sa.Uuid(),
            server_default=UUID_PK_SERVER_DEFAULT,
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("device_id"),
        sa.UniqueConstraint("pairing_id"),
    )
    op.create_index(op.f("ix_devices_id"), "devices", ["id"], unique=False)
    op.create_index(op.f("ix_devices_status"), "devices", ["status"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_devices_status"), table_name="devices")
    op.drop_index(op.f("ix_devices_id"), table_name="devices")
    op.drop_table("devices")
