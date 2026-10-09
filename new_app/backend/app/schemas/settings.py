"""Settings API schemas (Phase 17, §17.1).

`SettingsResponse` is the flat payload Phase 0's blueprint specified for
``GET /api/v1/settings``.  `SettingsUpdateRequest` is a **partial** update:
only the keys present in the body change, so a caller never has to read
before writing and two admins editing different fields cannot clobber each
other.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field, model_validator

from app.schemas.common import StrictBaseModel

PaperSize = Literal["80mm", "A4"]


class SettingsResponse(StrictBaseModel):
    """Current store/application settings."""

    store_name: str = Field(max_length=120)
    store_phone: str = Field(max_length=40)
    store_address: str = Field(max_length=255)
    invoice_footer: str = Field(max_length=255)
    # Phase 6 — company/fiscal identity (factura_simple ``Company``): the
    # document header source of truth. Name/address/phone are the three
    # store_* fields above; these are the remaining legacy fields.
    store_wilaya: str = Field(max_length=100)
    store_email: str = Field(max_length=100)
    store_nif: str = Field(max_length=30)
    store_nis: str = Field(max_length=30)
    store_rc: str = Field(max_length=30)
    store_ai: str = Field(max_length=30)
    store_rib: str = Field(max_length=30)
    default_paper: PaperSize
    ask_before_print: bool
    auto_print_invoice: bool
    allow_debt: bool
    low_stock_threshold: int = Field(ge=0, le=100000)


class SettingsUpdateRequest(StrictBaseModel):
    """Partial update — every field optional, at least one required."""

    store_name: str | None = Field(None, min_length=1, max_length=120)
    store_phone: str | None = Field(None, max_length=40)
    store_address: str | None = Field(None, max_length=255)
    invoice_footer: str | None = Field(None, max_length=255)
    # Phase 6 fiscal/company identity: optional like every other text
    # setting, blank allowed (``""`` clears it — the source stores "" too),
    # only the column length is enforced. No NIF/RC format rules: neither
    # factura_simple nor this project defines any.
    store_wilaya: str | None = Field(None, max_length=100)
    store_email: str | None = Field(None, max_length=100)
    store_nif: str | None = Field(None, max_length=30)
    store_nis: str | None = Field(None, max_length=30)
    store_rc: str | None = Field(None, max_length=30)
    store_ai: str | None = Field(None, max_length=30)
    store_rib: str | None = Field(None, max_length=30)
    default_paper: PaperSize | None = None
    ask_before_print: bool | None = None
    auto_print_invoice: bool | None = None
    allow_debt: bool | None = None
    low_stock_threshold: int | None = Field(None, ge=0, le=100000)

    @model_validator(mode="after")
    def _at_least_one_field_and_named(self) -> SettingsUpdateRequest:
        # `min_length` runs before the model-level whitespace strip, so a
        # blank store name is rejected explicitly rather than stored as "".
        if self.store_name is not None and not self.store_name.strip():
            raise ValueError("store_name must not be blank")
        if not self.provided():
            raise ValueError("at least one setting must be provided")
        return self

    def provided(self) -> dict[str, object]:
        """Only the fields the caller actually sent, keyed by column name."""
        return {
            name: getattr(self, name)
            for name in self.model_fields_set
            if getattr(self, name) is not None
        }
