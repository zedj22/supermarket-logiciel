"""Phase 17 §17.6 — receipt store identity (Phase 15 G19/Q3 deferrals).

The owner's phone, address and invoice footer typed into Settings now reach
the printer.  Covers:

1.  ``_store_block`` / ``_present`` — reads name/phone/address/footer from a
    dict, a schema object or nothing at all, trims blanks to ``None`` and
    falls back to ``settings.STORE_NAME`` (the ``.env`` value).
2.  ``estimate_height`` (80 mm) — budgets the contact lines and the footer at
    4 mm each so they never silently eat the roll segment.
3.  Renderers — 80 mm and A4 draw the configured identity and draw nothing
    for it when the install has never saved Settings (the pre-§17.6 output).
4.  ``PrintService._with_store_identity`` — stamps the ``app_settings`` row
    onto the document **without writing a row** (``SettingsService.get()``).
"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

import pytest
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.db.base import Base
from app.printing.document_data import (
    DocumentData,
    HeaderBlock,
    LineItem,
    MetaBlock,
    StoreBlock,
    TotalsBlock,
    _store_block,
)
from app.printing.render import render_invoice
from app.printing.templates import invoice_80mm
from app.printing.templates.invoice_a4 import build_flowables as a4_flowables
from app.printing.templates.invoice_80mm import build_flowables as t80_flowables
from app.schemas.settings import SettingsUpdateRequest
from app.services.print import PrintService
from app.services.settings import SettingsService

PHONE = "0550 12 34 56"
ADDRESS = "12 Rue Didouche Mourad, Alger"
FOOTER = "Merci de votre achat - Thank you"
STORE_NAME = "Store Alpha"


# ─── helpers ────────────────────────────────────────────────────────────────


def _pdf_text(raw: bytes) -> str:
    """Extract drawn text via the G7 spike ToUnicode extractor."""
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return "\n".join(text for _font, text in g7_spike.extract_text_blocks(raw))


def _doc(store: StoreBlock, *, lines: int = 1, locale: str = "en") -> DocumentData:
    """Minimal receipt document — templates only read the DocumentData."""
    items = [
        LineItem(
            kind="product",
            name=f"Cola {index}",
            unit_label="piece",
            qty="2",
            unit_price="100.000",
            line_total="200.000",
            sku=f"SKU{index}",
        )
        for index in range(lines)
    ]
    return DocumentData(
        store=store,
        header=HeaderBlock(
            document_number="INV-000123",
            document_title="Invoice",
            occurred_at="2026-01-05 10:30",
            status_label=None,
        ),
        customer=None,
        supplier=None,
        cashier_name="Admin",
        lines=items,
        totals=TotalsBlock(
            subtotal="200.000",
            total="200.000",
            paid="200.000",
            payment_method="cash",
        ),
        meta=MetaBlock(locale=locale, generated_at="2026-01-05 10:30"),
    )


def _paragraph_texts(story) -> list[str]:  # noqa: ANN001 - flowable list
    return [f.text for f in story if isinstance(f, Paragraph)]


@pytest.fixture()
def session():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    maker = sessionmaker(bind=engine, autoflush=False)
    db = maker()
    yield db
    db.close()
    engine.dispose()


# ─── 1. _store_block / _present ─────────────────────────────────────────────


def test_store_block_reads_identity_from_dict():
    block = _store_block(
        {
            "name": STORE_NAME,
            "phone": PHONE,
            "address": ADDRESS,
            "footer": FOOTER,
        }
    )
    assert block.name == STORE_NAME
    assert (block.phone, block.address, block.footer) == (PHONE, ADDRESS, FOOTER)


def test_store_block_reads_identity_from_object():
    class Payload:
        name = STORE_NAME
        phone = PHONE
        address = ADDRESS
        footer = FOOTER

    block = _store_block(Payload())
    assert (block.name, block.phone, block.address, block.footer) == (
        STORE_NAME,
        PHONE,
        ADDRESS,
        FOOTER,
    )


def test_store_block_from_g19_store_info_has_no_contact_fields():
    """``StoreInfo`` (sale detail payload) carries ``name`` only."""
    from app.schemas.sale import StoreInfo

    block = _store_block(StoreInfo(name=STORE_NAME))
    assert block.name == STORE_NAME
    assert block.phone is None and block.address is None and block.footer is None


def test_store_block_trims_blank_identity_to_none():
    block = _store_block(
        {"name": "   ", "phone": "  ", "address": "", "footer": "\n\t"}
    )
    assert block.name == settings.STORE_NAME  # blank name falls back to .env
    assert block.phone is None
    assert block.address is None
    assert block.footer is None


def test_store_block_without_payload_uses_env_store_name():
    block = _store_block(None)
    assert block.name == settings.STORE_NAME
    assert (block.phone, block.address, block.footer) == (None, None, None)


def test_store_block_keeps_partial_identity():
    block = _store_block({"name": STORE_NAME, "phone": PHONE})
    assert block.name == STORE_NAME
    assert block.phone == PHONE
    assert block.address is None and block.footer is None


# ─── 2. estimate_height budgets ─────────────────────────────────────────────


def test_estimate_height_budgets_each_identity_field():
    # 20 lines keeps the receipt well above the 140 mm floor, so the
    # per-field budget is observable rather than clamped.
    base = invoice_80mm.estimate_height(_doc(StoreBlock(name=STORE_NAME), lines=20))
    phone = invoice_80mm.estimate_height(
        _doc(StoreBlock(name=STORE_NAME, phone=PHONE), lines=20)
    )
    address = invoice_80mm.estimate_height(
        _doc(StoreBlock(name=STORE_NAME, address=ADDRESS), lines=20)
    )
    footer = invoice_80mm.estimate_height(
        _doc(StoreBlock(name=STORE_NAME, footer=FOOTER), lines=20)
    )
    assert phone - base == pytest.approx(4 * mm)
    assert address - base == pytest.approx(4 * mm)
    assert footer - base == pytest.approx(4 * mm)


def test_estimate_height_budgets_full_identity_block():
    base = invoice_80mm.estimate_height(_doc(StoreBlock(name=STORE_NAME), lines=20))
    full = invoice_80mm.estimate_height(
        _doc(
            StoreBlock(name=STORE_NAME, phone=PHONE, address=ADDRESS, footer=FOOTER),
            lines=20,
        )
    )
    assert full - base == pytest.approx(12 * mm)
    assert full <= 400 * mm  # still inside the roll segment


def test_estimate_height_without_identity_stays_on_the_floor():
    """A never-configured install renders exactly the pre-§17.6 height."""
    bare = invoice_80mm.estimate_height(_doc(StoreBlock(name=settings.STORE_NAME)))
    assert bare == pytest.approx(140 * mm)  # the documented minimum


# ─── 3. renderers ───────────────────────────────────────────────────────────


def test_80mm_prints_contact_block_and_footer():
    data = _doc(
        StoreBlock(name=STORE_NAME, phone=PHONE, address=ADDRESS, footer=FOOTER)
    )
    text = _pdf_text(render_invoice(data, "80mm", compress=False))
    assert STORE_NAME in text
    assert PHONE in text
    assert ADDRESS in text
    assert FOOTER in text


def test_a4_prints_contact_block_and_footer():
    data = _doc(
        StoreBlock(name=STORE_NAME, phone=PHONE, address=ADDRESS, footer=FOOTER)
    )
    text = _pdf_text(render_invoice(data, "A4", compress=False))
    assert STORE_NAME in text
    assert PHONE in text
    assert ADDRESS in text
    assert FOOTER in text


def test_contact_and_footer_flowables_absent_when_unset():
    bare = _doc(StoreBlock(name=settings.STORE_NAME))
    full = _doc(
        StoreBlock(name=STORE_NAME, phone=PHONE, address=ADDRESS, footer=FOOTER)
    )

    bare_texts = _paragraph_texts(t80_flowables(bare))
    full_texts = _paragraph_texts(t80_flowables(full))

    assert not any(PHONE in t for t in bare_texts)
    assert not any(ADDRESS in t for t in bare_texts)
    assert not any(FOOTER in t for t in bare_texts)
    # two contact lines above the items + one footer below the totals
    assert len(full_texts) == len(bare_texts) + 3
    assert sum(1 for t in full_texts if t == STORE_NAME) == 2  # header + closing

    a4_bare = _paragraph_texts(a4_flowables(bare))
    a4_full = _paragraph_texts(a4_flowables(full))
    assert not any(PHONE in t for t in a4_bare)
    assert not any(FOOTER in t for t in a4_bare)
    assert len(a4_full) == len(a4_bare) + 3


def test_contact_block_sits_under_the_store_name_and_footer_under_totals():
    story = t80_flowables(
        _doc(
            StoreBlock(name=STORE_NAME, phone=PHONE, address=ADDRESS, footer=FOOTER)
        )
    )
    texts = _paragraph_texts(story)
    # order: name → phone → address → document title (header identity)
    assert texts[0] == STORE_NAME
    assert texts[1] == PHONE
    assert texts[2] == ADDRESS
    # the configured footer is the very last drawn paragraph
    assert texts[-1] == FOOTER
    assert texts[-2] == STORE_NAME


# ─── 4. PrintService stamps app_settings ────────────────────────────────────


def test_print_service_stamps_saved_settings(session):
    SettingsService(session).update(
        SettingsUpdateRequest(
            store_name=STORE_NAME,
            store_phone=PHONE,
            store_address=ADDRESS,
            invoice_footer=FOOTER,
        )
    )

    data = _doc(StoreBlock(name=settings.STORE_NAME))
    stamped = PrintService(session)._with_store_identity(data)

    assert stamped is data  # mutated in place — templates already hold it
    assert stamped.store.name == STORE_NAME
    assert stamped.store.phone == PHONE
    assert stamped.store.address == ADDRESS
    assert stamped.store.footer == FOOTER
    text = _pdf_text(render_invoice(stamped, "80mm", compress=False))
    assert PHONE in text and FOOTER in text


def test_print_service_without_a_settings_row_keeps_env_defaults(session):
    data = _doc(StoreBlock(name="Stale Name"))
    stamped = PrintService(session)._with_store_identity(data)

    assert stamped.store.name == settings.STORE_NAME
    assert stamped.store.phone is None
    assert stamped.store.address is None
    assert stamped.store.footer is None
    # reading settings for a print must never create the singleton row
    from app.models.settings import AppSetting

    assert session.query(AppSetting).count() == 0
    assert not session.new and not session.dirty


def test_print_service_ignores_blank_settings_values(session):
    SettingsService(session).update(
        SettingsUpdateRequest(store_name=STORE_NAME, store_phone="")
    )

    data = _doc(StoreBlock(name=settings.STORE_NAME))
    stamped = PrintService(session)._with_store_identity(data)

    assert stamped.store.name == STORE_NAME
    assert stamped.store.phone is None  # "" → omitted, not printed as blank
    assert stamped.store.footer is None


def test_print_service_identity_is_unique_per_document(session):
    """A print never leaks identity onto a later, differently-configured print."""
    service = PrintService(session)
    first = service._with_store_identity(_doc(StoreBlock(name=settings.STORE_NAME)))
    assert first.store.phone is None

    SettingsService(session).update(
        SettingsUpdateRequest(store_name=STORE_NAME, store_phone=PHONE)
    )
    second = service._with_store_identity(_doc(StoreBlock(name=settings.STORE_NAME)))
    assert second.store.phone == PHONE
    assert first.store.phone is None  # the earlier DocumentData is untouched


def test_settings_read_for_print_is_stable_across_calls(session):
    service = SettingsService(session)
    before = service.get().store_phone
    PrintService(session)._with_store_identity(_doc(StoreBlock(name="X")))
    assert service.get().store_phone == before
    assert before == ""  # documented default, and still no row written
