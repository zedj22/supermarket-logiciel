"""Device repository (Phase 16).

Persistence only: no HTTP, no audit, no token minting.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.device import Device


class DeviceRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_device_id(self, device_id: str) -> Device | None:
        return self.db.scalar(select(Device).where(Device.device_id == device_id))

    def get_by_pairing_id(self, pairing_id: uuid.UUID) -> Device | None:
        return self.db.scalar(select(Device).where(Device.pairing_id == pairing_id))

    def get_by_id(self, device_pk: uuid.UUID) -> Device | None:
        return self.db.get(Device, device_pk)

    def list_all(self) -> tuple[Sequence[Device], int]:
        stmt = select(Device).order_by(Device.created_at.desc())
        items = self.db.scalars(stmt).all()
        total = self.db.scalar(select(func.count()).select_from(Device)) or 0
        return items, total

    def create(self, instance: Device) -> Device:
        self.db.add(instance)
        self.db.flush()
        return instance

    def count(self) -> int:
        return self.db.scalar(select(func.count()).select_from(Device)) or 0
