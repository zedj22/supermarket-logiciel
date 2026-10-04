"""Post-Phase-17 QA fixture: seed exactly 1000 identifiable QA products.

QA-only developer tool. It is NOT an application endpoint, NOT wired into
any router, and it does not change seeding, business rules, or schemas.

Identification of every QA row (documented in
``docs/POST_PHASE_17_MANUAL_QA.md``):

    products.name      LIKE 'QA17 Product %'      QA17 Product 0001..1000
    products.barcode   LIKE 'QA17%'               QA1700000001..QA170001000
    products.sku       LIKE 'QA17-SKU-%'          QA17-SKU-0001..1000
    categories.name    LIKE 'QA17 Category %'     QA17 Category 01..10

Everything is deterministic (name, barcode, sku, price, cost, category,
stock), so two machines see the same dataset and expected totals can be
recomputed by hand.

Products are created through the real ``ProductService.create`` — the same
code path the API uses — so barcode availability, category checks, and the
initial-stock ADJUSTMENT inventory movement all behave exactly as in
production. No image, no variant, no selling unit: none of them are
required by the current schema.

Idempotent: re-running skips products whose barcode already exists and
only creates what is missing.

Run (from ``new_app/backend``, using the backend virtualenv):

    python scripts/qa_seed_1000_products.py                 # seed 1000
    python scripts/qa_seed_1000_products.py --dry-run       # report only
    python scripts/qa_seed_1000_products.py --verify        # verify only

Cleanup of QA rows only: scripts/qa_cleanup_1000_products.py
"""

from __future__ import annotations

import argparse
import sys
import time
from decimal import Decimal
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from sqlalchemy import create_engine, func, select  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

# ---------------------------------------------------------------------------
# QA dataset definition (deterministic — do not change between machines)
# ---------------------------------------------------------------------------

QA_NAME_PREFIX = "QA17 Product "
QA_BARCODE_PREFIX = "QA17"
QA_SKU_PREFIX = "QA17-SKU-"
QA_CATEGORY_PREFIX = "QA17 Category "

QA_PRODUCT_COUNT = 1000
QA_CATEGORY_COUNT = 10
QA_UNIT = "piece"
QA_QUANTITY = Decimal("9999")  # ample for full-catalog batches and large-line sales
QA_LOW_STOCK = Decimal("5")
QA_UNIT_COST_RATIO = Decimal("0.65")


def qa_barcode(index: int) -> str:
    """QA17 + 8 digits: QA1700000001 .. QA1700001000 (<= 50 chars, unique)."""
    return f"{QA_BARCODE_PREFIX}{index:08d}"


def qa_name(index: int) -> str:
    return f"{QA_NAME_PREFIX}{index:04d}"


def qa_sku(index: int) -> str:
    return f"{QA_SKU_PREFIX}{index:04d}"


def qa_category_name(index: int) -> str:
    """Category slot 1..10 for product index (1-based)."""
    slot = ((index - 1) % QA_CATEGORY_COUNT) + 1
    return f"{QA_CATEGORY_PREFIX}{slot:02d}"


def qa_price(index: int) -> Decimal:
    """Deterministic price 10.00 .. 34.00 in 0.25 steps."""
    return (Decimal(10) + Decimal(index % 97) * Decimal("0.25")).quantize(
        Decimal("0.01")
    )


def qa_cost(price: Decimal) -> Decimal:
    return (price * QA_UNIT_COST_RATIO).quantize(Decimal("0.01"))


def describe_target(url) -> str:
    """Host/port/database only - never credentials."""
    from urllib.parse import urlsplit

    try:
        parts = urlsplit(str(url))
    except ValueError:
        return "(unparseable database url)"
    host = parts.hostname or "?"
    port = f":{parts.port}" if parts.port else ""
    database = (parts.path or "/").lstrip("/") or "?"
    return f"{parts.scheme}://{host}{port}/{database}"


def quiet_logs() -> None:
    """Hide per-row application log lines; keep warnings and errors."""
    import importlib
    import logging

    import structlog

    importlib.import_module("app.core.logging")  # app log config first
    structlog.configure(
        wrapper_class=structlog.make_filtering_bound_logger(logging.WARNING)
    )


def open_session():
    """Engine/session from application settings (never logged)."""
    from app.core.config import settings

    engine = create_engine(settings.DATABASE_URL, pool_pre_ping=True, future=True)
    factory = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    return engine, factory()


# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------


def ensure_categories(db) -> dict:
    """Create the 10 QA categories if missing. Returns name -> Category."""
    from app.models.catalog import Category
    from app.schemas.catalog import CategoryCreateRequest
    from app.services.catalog import CategoryService

    service = CategoryService(db)
    wanted = [f"{QA_CATEGORY_PREFIX}{slot:02d}" for slot in range(1, QA_CATEGORY_COUNT + 1)]
    existing = {
        row.name: row
        for row in db.scalars(select(Category).where(Category.name.in_(wanted)))
    }
    created = 0
    for position, name in enumerate(wanted, start=1):
        if name in existing:
            continue
        category = service.create(
            CategoryCreateRequest(name=name, sort_order=position)
        )
        existing[name] = category
        created += 1
    return {"by_name": existing, "created": created, "total": len(existing)}


def seed(db, product_count: int, dry_run: bool) -> int:
    from app.schemas.catalog import ProductCreateRequest
    from app.services.catalog import ProductService

    started = time.perf_counter()

    # Safety: a barcode with our prefix that does NOT belong to this dataset
    # means someone else's data — refuse to continue rather than guess.
    from app.models.catalog import Category, Product

    strays = db.scalars(
        select(Product).where(
            Product.barcode.startswith(QA_BARCODE_PREFIX),
            Product.name.not_like(QA_NAME_PREFIX + "%"),
        )
    ).all()
    if strays:
        print(
            f"ABORT: {len(strays)} product(s) use barcode prefix "
            f"{QA_BARCODE_PREFIX!r} but are not QA17 products, e.g. "
            f"{strays[0].name!r} / {strays[0].barcode!r}"
        )
        return 1

    wanted_barcodes = [qa_barcode(i) for i in range(1, product_count + 1)]
    wrong_barcodes = db.scalars(
        select(Product).where(
            Product.name.like(QA_NAME_PREFIX + "%"),
            Product.barcode.notin_(wanted_barcodes),
        )
    ).all()
    if wrong_barcodes:
        print(
            f"ABORT: {len(wrong_barcodes)} product(s) carry the QA17 name "
            f"prefix but a different barcode, e.g. "
            f"{wrong_barcodes[0].name!r} / {wrong_barcodes[0].barcode!r}"
        )
        return 1

    wanted_categories = [
        f"{QA_CATEGORY_PREFIX}{slot:02d}" for slot in range(1, QA_CATEGORY_COUNT + 1)
    ]
    present_categories = set(
        db.scalars(select(Category.name).where(Category.name.in_(wanted_categories))).all()
    )

    wanted = wanted_barcodes
    present = set(
        db.scalars(
            select(Product.barcode).where(Product.barcode.in_(wanted))
        ).all()
    )
    missing = [b for b in wanted if b not in present]
    print(
        f"categories: {len(present_categories)}/{QA_CATEGORY_COUNT} present, "
        f"{QA_CATEGORY_COUNT - len(present_categories)} to create"
    )
    print(
        f"products: {len(wanted) - len(missing)} already present, "
        f"{len(missing)} to create (target {product_count})"
    )

    if dry_run:
        print("dry run - nothing created")
        return 0

    categories = ensure_categories(db)
    by_name = categories["by_name"]
    if categories["created"]:
        print(f"created {categories['created']} category(ies)")
    missing_categories = [n for n in wanted_categories if n not in by_name]
    if missing_categories:
        print(f"ABORT: categories not available: {', '.join(missing_categories)}")
        return 1

    service = ProductService(db)
    created = 0
    for barcode in missing:
        index = int(barcode[len(QA_BARCODE_PREFIX):])
        price = qa_price(index)
        request = ProductCreateRequest(
            name=qa_name(index),
            barcode=barcode,
            sku=qa_sku(index),
            description=(
                f"QA17 acceptance fixture {index:04d} "
                f"(Post-Phase-17 manual QA, safe to delete)"
            ),
            unit=QA_UNIT,
            price=price,
            cost=qa_cost(price),
            quantity=QA_QUANTITY,
            low_stock_threshold=QA_LOW_STOCK,
            allow_negative_stock=False,
            category_id=by_name[qa_category_name(index)].id,
        )
        try:
            service.create(request)
        except Exception as exc:  # noqa: BLE001 - report, never swallow
            print(
                f"FAILED at product {index} ({barcode}): "
                f"{type(exc).__name__}: {exc}"
            )
            print(
                "Fix the cause and re-run: the script is idempotent and "
                "will continue from the first missing barcode."
            )
            return 1
        created += 1
        if created % 100 == 0:
            print(f"  created {created}/{len(missing)} ...")

    elapsed = time.perf_counter() - started
    print(f"created {created} product(s) in {elapsed:.1f}s")
    print(f"dataset size now: {len(present) + created}/{product_count}")
    return 0


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify(db, product_count: int) -> int:
    from app.models.catalog import Category, Product
    from app.models.inventory import InventoryMovement

    failures: list[str] = []

    total = db.scalar(
        select(func.count()).select_from(Product).where(
            Product.name.like(QA_NAME_PREFIX + "%")
        )
    )
    print(f"QA products by name prefix          : {total} (expected {product_count})")
    if total != product_count:
        failures.append(f"QA product count {total} != {product_count}")

    distinct_barcodes = db.scalar(
        select(func.count(func.distinct(Product.barcode))).select_from(Product).where(
            Product.name.like(QA_NAME_PREFIX + "%")
        )
    )
    if distinct_barcodes != total:
        failures.append("duplicate barcodes among QA products")

    strays = db.scalar(
        select(func.count()).select_from(Product).where(
            Product.barcode.startswith(QA_BARCODE_PREFIX),
            Product.name.not_like(QA_NAME_PREFIX + "%"),
        )
    )
    if strays:
        failures.append(f"{strays} non-QA product(s) carry the QA barcode prefix")

    categories = db.scalars(
        select(Category).where(Category.name.like(QA_CATEGORY_PREFIX + "%"))
    ).all()
    print(f"QA categories                     : {len(categories)} (expected {QA_CATEGORY_COUNT})")
    if len(categories) != QA_CATEGORY_COUNT:
        failures.append(f"QA category count {len(categories)} != {QA_CATEGORY_COUNT}")

    used_categories = db.scalar(
        select(func.count(func.distinct(Product.category_id))).select_from(Product).where(
            Product.name.like(QA_NAME_PREFIX + "%")
        )
    )
    print(f"distinct categories used by QA rows: {used_categories}")

    unassigned = db.scalar(
        select(func.count()).select_from(Product).where(
            Product.name.like(QA_NAME_PREFIX + "%"),
            Product.category_id.is_(None),
        )
    )
    if unassigned:
        failures.append(f"{unassigned} QA product(s) have no category")

    no_stock = db.scalar(
        select(func.count()).select_from(Product).where(
            Product.name.like(QA_NAME_PREFIX + "%"),
            Product.quantity <= 0,
        )
    )
    if no_stock:
        failures.append(f"{no_stock} QA product(s) have stock <= 0 (POS cannot add them)")

    stock_min = db.scalar(
        select(func.min(Product.quantity)).where(
            Product.name.like(QA_NAME_PREFIX + "%")
        )
    )
    stock_max = db.scalar(
        select(func.max(Product.quantity)).where(
            Product.name.like(QA_NAME_PREFIX + "%")
        )
    )
    print(f"QA stock range                    : min {stock_min} / max {stock_max}")

    without_movement = db.scalar(
        select(func.count())
        .select_from(Product)
        .outerjoin(
            InventoryMovement, InventoryMovement.product_id == Product.id
        )
        .where(Product.name.like(QA_NAME_PREFIX + "%"), InventoryMovement.id.is_(None))
    )
    print(f"QA products without a stock movement: {without_movement}")
    if without_movement:
        failures.append(
            f"{without_movement} QA product(s) have no inventory movement"
        )

    print("samples:")
    middle = max(1, product_count // 2)
    for label, index in (("first", 1), ("middle", middle), ("last", product_count)):
        row = db.scalar(select(Product).where(Product.barcode == qa_barcode(index)))
        if row is None:
            failures.append(f"missing product index {index}")
            print(f"  {label:<7} MISSING index {index}")
            continue
        category = db.scalar(select(Category).where(Category.id == row.category_id))
        print(
            f"  {label:<7} {row.name} | {row.barcode} | {row.sku} | "
            f"price {row.price} | cost {row.cost} | qty {row.quantity} | "
            f"category {category.name if category else None}"
        )

    if failures:
        print("VERIFY FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("VERIFY PASS")
    return 0


# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Seed/verify the QA17 1000-product acceptance fixture"
    )
    parser.add_argument(
        "--products",
        type=int,
        default=QA_PRODUCT_COUNT,
        help=f"products to seed (default {QA_PRODUCT_COUNT})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be created, change nothing",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="verify the dataset only, do not seed",
    )
    args = parser.parse_args()

    if args.products < 1 or args.products > 10_000:
        print("--products must be between 1 and 10000")
        return 1

    engine, db = open_session()
    quiet_logs()
    try:
        print(f"target: {describe_target(engine.url)}")
        if args.verify:
            return verify(db, args.products)
        return seed(db, args.products, dry_run=args.dry_run)
    finally:
        db.close()
        engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
