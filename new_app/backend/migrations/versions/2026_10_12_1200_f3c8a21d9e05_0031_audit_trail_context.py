"""0031_audit_trail_context

Revision ID: f3c8a21d9e05
Revises: a1e8d3f92b47
Create Date: 2026-10-12

Audit trail slice A — additive only: ten NEW nullable columns on
``audit_logs`` plus six read-path indexes. No existing column changes,
no data rewrite, no backfill.

New columns (all nullable; legacy rows keep NULL = "unknown", which the
read API surfaces honestly instead of inventing "success"):

1. outcome           VARCHAR(10)   success / failure / denied
2. module            VARCHAR(30)   AuditModule vocabulary (auth, sales, ...)
3. actor_name        VARCHAR(120)  actor display-name snapshot at write time
4. device_name       VARCHAR(150)  validated registry display name only
5. device_verified   BOOLEAN       False = unvalidated header claim, NULL = none
6. session_id        VARCHAR(64)   JWT session id (opaque, no FK)
7. request_id        VARCHAR(64)   X-Request-ID correlation id
8. reason            TEXT          operator-given business reason
9. entity_ref        VARCHAR(100)  human business reference (invoice no ...)
10. metadata_json    TEXT          allowlisted extra context (JSON, redacted)

``recorded_at`` deliberately does NOT exist: TimestampMixin's
``created_at`` already is the recording time, and the read API exposes
it as ``recorded_at``.

Deliberately absent
-------------------
* NO backfill of outcome/module for historical rows (never fabricate).
* NO NOT NULL constraints (additive, online-safe).
* NO foreign keys on session_id / request_id (the trail must survive
  session or request cleanup).
* users.id stays ON DELETE SET NULL — actor_name snapshot keeps history
  readable after a user is deleted.

Downgrade drops ONLY what this revision added.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "f3c8a21d9e05"
down_revision = "a1e8d3f92b47"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("audit_logs", sa.Column("outcome", sa.String(10), nullable=True))
    op.add_column("audit_logs", sa.Column("module", sa.String(30), nullable=True))
    op.add_column("audit_logs", sa.Column("actor_name", sa.String(120), nullable=True))
    op.add_column("audit_logs", sa.Column("device_name", sa.String(150), nullable=True))
    op.add_column("audit_logs", sa.Column("device_verified", sa.Boolean(), nullable=True))
    op.add_column("audit_logs", sa.Column("session_id", sa.String(64), nullable=True))
    op.add_column("audit_logs", sa.Column("request_id", sa.String(64), nullable=True))
    op.add_column("audit_logs", sa.Column("reason", sa.Text(), nullable=True))
    op.add_column("audit_logs", sa.Column("entity_ref", sa.String(100), nullable=True))
    op.add_column("audit_logs", sa.Column("metadata_json", sa.Text(), nullable=True))

    op.create_index("ix_audit_logs_action_at", "audit_logs", ["action_at"])
    op.create_index(
        "ix_audit_logs_user_action_at", "audit_logs", ["user_id", "action_at"]
    )
    op.create_index(
        "ix_audit_logs_module_action_at", "audit_logs", ["module", "action_at"]
    )
    op.create_index(
        "ix_audit_logs_device_id_action_at", "audit_logs", ["device_id", "action_at"]
    )
    op.create_index(
        "ix_audit_logs_outcome_action_at", "audit_logs", ["outcome", "action_at"]
    )
    op.create_index(
        "ix_audit_logs_entity_type_entity_id",
        "audit_logs",
        ["entity_type", "entity_id"],
    )
    # Single-column indexes declared inline on the model (index=True) so
    # alembic autogenerate stays quiet.
    op.create_index("ix_audit_logs_module", "audit_logs", ["module"])
    op.create_index("ix_audit_logs_outcome", "audit_logs", ["outcome"])
    op.create_index("ix_audit_logs_session_id", "audit_logs", ["session_id"])


def downgrade() -> None:
    op.drop_index("ix_audit_logs_session_id", table_name="audit_logs")
    op.drop_index("ix_audit_logs_outcome", table_name="audit_logs")
    op.drop_index("ix_audit_logs_module", table_name="audit_logs")
    op.drop_index("ix_audit_logs_entity_type_entity_id", table_name="audit_logs")
    op.drop_index("ix_audit_logs_outcome_action_at", table_name="audit_logs")
    op.drop_index("ix_audit_logs_device_id_action_at", table_name="audit_logs")
    op.drop_index("ix_audit_logs_module_action_at", table_name="audit_logs")
    op.drop_index("ix_audit_logs_user_action_at", table_name="audit_logs")
    op.drop_index("ix_audit_logs_action_at", table_name="audit_logs")

    op.drop_column("audit_logs", "metadata_json")
    op.drop_column("audit_logs", "entity_ref")
    op.drop_column("audit_logs", "reason")
    op.drop_column("audit_logs", "request_id")
    op.drop_column("audit_logs", "session_id")
    op.drop_column("audit_logs", "device_verified")
    op.drop_column("audit_logs", "device_name")
    op.drop_column("audit_logs", "actor_name")
    op.drop_column("audit_logs", "module")
    op.drop_column("audit_logs", "outcome")
