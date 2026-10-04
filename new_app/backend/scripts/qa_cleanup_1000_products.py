"""Cleanup for the QA17 acceptance fixture (QA rows only).

Companion to ``qa_seed_1000_products.py``. It NEVER touches non-QA data:
a product is only considered QA when BOTH match

    products.name    LIKE 'QA17 Product %'
    products.barcode LIKE 'QA17%'

and a category only when ``categories.name LIKE 'QA17 Category %'``.

Modes (default = report, changes nothing):

    python scripts/qa_cleanup_1000_products.py
        dry-run report: how many QA products/categories exist, which are
        already archived, which are blocked from hard deletion and why.

    python scripts/qa_cleanup_1000_products.py --archive
        soft-archive QA products (same ``ProductService.archive`` path the
        API's DELETE endpoint uses; history and stock movements are kept,
        products disappear from default POS/catalog listings).
        Add --include-categories to also archive the QA categories.

    python scripts/qa_cleanup_1000_products.py --delete
        HARD DELETE QA fixtures only. A QA product is deletable only when
        no business document references it (sale_lines, return_lines,
        purchase_lines, pack_items). Referenced products are reported and
        skipped. For each deletable product its inventory_movements rows
        are removed first (they are RESTRICT), then the product row is
        deleted (child catalog tables cascade at the database level).
        Add --include-categories to also delete QA categories that no
        longer hold any product.

The application itself never hard-deletes products; --delete is a test-
database fixture removal tool and is safe to run on PC1/PC2 QA databases.

Run from ``new_app/backend`` using the backend virtualenv.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from sqlalchemy import create_engine, delete, func, select  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

from app.models.catalog import Category, PackItem, Product  # noqa: E402
from app.models.inventory import InventoryMovement  # noqa: E402
from app.models.purchase import PurchaseLine  # noqa: E402
from app.models.return_doc import ReturnLine  # noqa: E402
from app.models.sale import SaleLine  # noqa: E402

QA_NAME_PREFIX = "QA17 Product "
QA_BARCODE_PREFIX = "QA17"
QA_CATEGORY_PREFIX = "QA17 Category "

# Tables that block a hard delete (FK ON DELETE RESTRICT).
REFERENCE_TABLES = (
    ("sale_lines", SaleLine),
    ("return_lines", ReturnLine),
    ("purchase_lines", PurchaseLine),
    ("pack_items", PackItem),
)


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
    from app.core.config import settings

    engine = create_engine(settings.DATABASE_URL, pool_pre_ping=True, future=True)
    factory = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    return engine, factory()


def qa_products(db) -> list[Product]:
    return list(
        db.scalars(
            select(Product)
            .where(
                Product.name.like(QA_NAME_PREFIX + "%"),
                Product.barcode.like(QA_BARCODE_PREFIX + "%"),
            )
            .order_by(Product.name)
        ).all()
    )


def qa_categories(db) -> list[Category]:
    return list(
        db.scalars(
            select(Category)
            .where(Category.name.like(QA_CATEGORY_PREFIX + "%"))
            .order_by(Category.name)
        ).all()
    )


def blocking_references(db, ids: list) -> dict:
    """product id -> {table: row count} for every reference that blocks delete."""
    if not ids:
        return {}
    blocked: dict = {}
    for table_name, model in REFERENCE_TABLES:
        rows = db.execute(
            select(model.product_id, func.count())
            .where(model.product_id.in_(ids))
            .group_by(model.product_id)
        ).all()
        for product_id, count in rows:
            blocked.setdefault(product_id, {})[table_name] = count
    return blocked


def report(db, include_categories: bool) -> int:
    products = qa_products(db)
    categories = qa_categories(db)
    archived = [p for p in products if p.archived_at is not None]
    ids = [p.id for p in products]
    blocked = blocking_references(db, ids)

    print(f"QA products        : {len(products)}")
    print(f"  already archived : {len(archived)}")
    print(f"  active           : {len(products) - len(archived)}")
    print(f"  hard-deletable   : {len(products) - len(blocked)}")
    print(f"  referenced       : {len(blocked)} (business documents, kept)")
    if blocked:
        for table_name, _model in REFERENCE_TABLES:
            count = sum(
                1 for refs in blocked.values() if table_name in refs
            )
            if count:
                print(f"    blocked by {table_name}: {count} product(s)")

    total_refs = sum(
        count for refs in blocked.values() for count in refs.values()
    )
    print(f"  referencing rows : {total_refs}")

    if include_categories:
        print(f"QA categories      : {len(categories)}")
        used = 0
        for category in categories:
            holders = db.scalar(
                select(func.count())
                .select_from(Product)
                .where(Product.category_id == category.id)
            )
            if holders:
                used += 1
        print(f"  still holding products: {used}")
        print(f"  empty (removable)     : {len(categories) - used}")

    print("default mode is a dry run; pass --archive or --delete to act")
    return 0


def archive(db, include_categories: bool) -> int:
    from app.services.catalog import CategoryService, ProductService

    products = [p for p in qa_products(db) if p.archived_at is None]
    print(f"archiving {len(products)} QA product(s)")
    service = ProductService(db)
    done = 0
    for product in products:
        service.archive(product.id)
        done += 1
        if done % 100 == 0:
            print(f"  archived {done}/{len(products)} ...")
    print(f"archived {done} product(s)")

    if include_categories:
        categories = [c for c in qa_categories(db) if c.archived_at is None]
        print(f"archiving {len(categories)} QA category(ies)")
        category_service = CategoryService(db)
        for category in categories:
            category_service.archive(category.id)
        print(f"archived {len(categories)} category(ies)")
    return 0


def hard_delete(db, include_categories: bool) -> int:
    products = qa_products(db)
    ids = [p.id for p in products]
    blocked = blocking_references(db, ids)
    deletable = [pid for pid in ids if pid not in blocked]
    skipped = [pid for pid in ids if pid in blocked]

    print(f"QA products        : {len(products)}")
    print(f"  deleting         : {len(deletable)}")
    print(f"  keeping (referenced): {len(skipped)}")

    try:
        if deletable:
            movements = db.execute(
                delete(InventoryMovement).where(
                    InventoryMovement.product_id.in_(deletable)
                )
            ).rowcount
            print(f"  removed inventory movements: {movements}")
            removed = db.execute(
                delete(Product).where(Product.id.in_(deletable))
            ).rowcount
            print(f"  removed products          : {removed}")
            db.commit()
        else:
            print("  no deletable QA product (all referenced or none present)")
    except Exception as exc:  # noqa: BLE001 - report and roll back
        db.rollback()
        print(f"DELETE FAILED, rolled back: {type(exc).__name__}: {exc}")
        return 1

    if include_categories:
        categories = qa_categories(db)
        removable = []
        for category in categories:
            holders = db.scalar(
                select(func.count())
                .select_from(Product)
                .where(Product.category_id == category.id)
            )
            children = db.scalar(
                select(func.count())
                .select_from(Category)
                .where(Category.parent_id == category.id)
            )
            if holders or children:
                continue
            removable.append(category.id)
        if removable:
            db.execute(delete(Category).where(Category.id.in_(removable)))
            db.commit()
            print(f"  removed empty categories   : {len(removable)}")
        else:
            print("  no empty QA category to remove")

    # Final state
    remaining_products = len(qa_products(db))
    print(f"QA products remaining: {remaining_products}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report / archive / delete the QA17 fixture (QA rows only)"
    )
    parser.add_argument(
        "--archive",
        action="store_true",
        help="soft-archive QA products (keeps history and stock movements)",
    )
    parser.add_argument(
        "--delete",
        dest="do_delete",
        action="store_true",
        help="hard-delete QA fixtures that no business document references",
    )
    parser.add_argument(
        "--include-categories",
        action="store_true",
        help="also archive/remove the QA17 categories",
    )
    args = parser.parse_args()

    if args.archive and args.do_delete:
        print("--archive and --delete are mutually exclusive")
        return 1

    engine, db = open_session()
    quiet_logs()
    try:
        print(f"target: {describe_target(engine.url)}")
        if args.archive:
            return archive(db, args.include_categories)
        if args.do_delete:
            return hard_delete(db, args.include_categories)
        return report(db, args.include_categories)
    finally:
        db.close()
        engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
