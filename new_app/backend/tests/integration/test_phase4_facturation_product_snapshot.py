"""Phase 4 facturation product snapshot — PostgreSQL only.

Runs against the dedicated supermarket_pro_test database (production is
never touched) and proves the snapshot contract on the real schema:

1. create/select a Product and build the invoice-line prefill through
   the real InvoiceProductService (products.price + products.vat_rate)
2. store the snapshot fields on invoice_document_lines
3. change the product's price / name / VAT
4. the stored line remains bit-for-bit unchanged
5. delete the product (DB-level; the application only soft-archives)
6. invoice_document_lines.product_id becomes NULL (FK ON DELETE SET NULL)
7. every snapshot field survives the deletion
"""

from __future__ import annotations

import contextlib
import os
import subprocess
import uuid
from datetime import date
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, delete
from sqlalchemy.orm import sessionmaker

from app.models.catalog import Product
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentLine,
)
from app.services.facturation import InvoiceProductService
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

PRODUCT_NAME = "phase4_prefill_canary"
CLIENT_NAME = "phase4_prefill_client"


def _run_alembic(command: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "DATABASE_URL": PG_TEST_URL}
    return subprocess.run(
        f"python -m alembic {command}",
        shell=True,
        capture_output=True,
        text=True,
        cwd=os.path.join(os.path.dirname(__file__), "..", ".."),
        env=env,
    )


def _cleanup_rows() -> None:
    """Best-effort removal of this test's rows (phase-2 cleanup pattern)."""
    eng = create_engine(PG_TEST_URL)
    session = sessionmaker(bind=eng)()
    try:
        session.execute(delete(InvoiceDocumentLine))
        session.execute(delete(InvoiceDocument))
        session.execute(delete(InvoiceClient))
        session.execute(delete(Product).where(Product.name == PRODUCT_NAME))
        session.commit()
    finally:
        session.close()
        eng.dispose()


@pytest.fixture(autouse=True)
def _setup_db():
    result = _run_alembic("upgrade head")
    assert result.returncode == 0, f"Setup upgrade failed: {result.stderr}"
    yield
    with contextlib.suppress(Exception):
        _cleanup_rows()


@pytest.fixture()
def engine():
    eng = create_engine(PG_TEST_URL)
    yield eng
    eng.dispose()


@pytest.fixture()
def db(engine):
    session = sessionmaker(bind=engine)()
    yield session
    session.rollback()
    session.close()


def test_product_snapshot_survives_change_and_deletion(db):
    service = InvoiceProductService(db)

    product = Product(
        name=PRODUCT_NAME,
        price=Decimal("100.000"),
        vat_rate=19,
    )
    db.add(product)
    db.commit()

    prefill = service.get_product_for_invoice(product.id)
    assert prefill.product_id == product.id
    assert prefill.description == PRODUCT_NAME
    assert prefill.unit_price_ht == Decimal("100.000")
    assert prefill.tva_rate == Decimal("19")

    client = InvoiceClient(name=CLIENT_NAME)
    db.add(client)
    db.commit()

    document = InvoiceDocument(
        number=f"P4-{uuid.uuid4().hex[:10]}",
        year=2026,
        document_date=date(2026, 10, 8),
        client_id=client.id,
    )
    db.add(document)
    db.commit()

    line = InvoiceDocumentLine(
        document_id=document.id,
        product_id=prefill.product_id,
        description=prefill.description,
        quantity=Decimal("2"),
        unit_price_ht=prefill.unit_price_ht,
        tva_rate=prefill.tva_rate,
    )
    db.add(line)
    db.commit()
    line_id = line.id

    product.name = "Coca Cola 1L"
    product.price = Decimal("120.000")
    product.vat_rate = 9
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line_id)
    assert stored.product_id == product.id
    assert stored.description == PRODUCT_NAME
    assert stored.unit_price_ht == Decimal("100.000")
    assert stored.tva_rate == Decimal("19")

    db.execute(delete(Product).where(Product.id == product.id))
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line_id)
    assert stored.product_id is None
    assert stored.product is None
    assert stored.description == PRODUCT_NAME
    assert stored.unit_price_ht == Decimal("100.000")
    assert stored.tva_rate == Decimal("19")
