"""Tests for Phase 2 model structure — tables, columns, types, constraints, indexes.

Uses SQLite in-memory so tests run without PostgreSQL.
Validates that the SQLAlchemy models produce the expected schema.
"""

import uuid
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, inspect
from sqlalchemy.orm import configure_mappers
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.models import (
    AuditLog,
    Category,
    Customer,
    DebtLedgerEntry,
    Expense,
    InventoryMovement,
    Pack,
    PackItem,
    Permission,
    Product,
    ProductVariant,
    Purchase,
    PurchaseLine,
    Return,
    ReturnLine,
    Role,
    RolePermission,
    Sale,
    SaleLine,
    SalePayment,
    Supplier,
    User,
    UserRole,
)

# Force mapper configuration
configure_mappers()


# ── Fixtures ───────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def schema_engine():
    """Create all tables in-memory and return the inspector."""
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)
    engine.dispose()


@pytest.fixture(scope="module")
def inspector(schema_engine):
    return inspect(schema_engine)


@pytest.fixture()
def db_session(schema_engine):
    """Create a test database session with automatic rollback."""
    connection = schema_engine.connect()
    transaction = connection.begin()
    session = __import__("sqlalchemy.orm", fromlist=["sessionmaker"]).sessionmaker(bind=connection)()
    yield session
    session.close()
    transaction.rollback()
    connection.close()


# ── Table existence ────────────────────────────────────────────────────

EXPECTED_TABLES = [
    "audit_logs",
    "categories",
    "customers",
    "debt_ledger_entries",
    "expenses",
    "inventory_movements",
    "pack_items",
    "packs",
    "permissions",
    "product_variants",
    "products",
    "purchase_lines",
    "purchases",
    "return_lines",
    "returns",
    "role_permissions",
    "roles",
    "sale_lines",
    "sale_payments",
    "sales",
    "suppliers",
    "user_roles",
    "users",
]


class TestTableExistence:
    def test_all_tables_created(self, inspector):
        tables = set(inspector.get_table_names())
        # All 23 domain tables must exist
        assert set(EXPECTED_TABLES) <= tables, (
            f"Missing tables: {set(EXPECTED_TABLES) - tables}"
        )

    def test_table_count(self, inspector):
        tables = inspector.get_table_names()
        # At least 23 domain tables (may be more if test models exist)
        assert len(tables) >= 23


# ── UUID primary keys ─────────────────────────────────────────────────

class TestUUIDPrimaryKeys:
    @pytest.mark.parametrize("table_name", EXPECTED_TABLES)
    def test_pk_is_id(self, inspector, table_name):
        pk = inspector.get_pk_constraint(table_name)
        assert pk is not None
        pk_cols = pk.get("constrained_columns", [])
        assert len(pk_cols) == 1
        assert pk_cols[0] == "id"


# ── Numeric columns (money/quantity) ──────────────────────────────────

class TestNumericColumns:
    def test_product_money_columns(self, inspector):
        cols = {c["name"]: c for c in inspector.get_columns("products")}
        for col_name in ["price", "cost", "quantity", "low_stock_threshold"]:
            type_name = cols[col_name]["type"].__class__.__name__.upper()
            assert "NUMERIC" in type_name

    def test_sale_money_columns(self, inspector):
        cols = {c["name"]: c for c in inspector.get_columns("sales")}
        for col_name in ["subtotal", "discount", "total", "paid", "change"]:
            type_name = cols[col_name]["type"].__class__.__name__.upper()
            assert "NUMERIC" in type_name

    def test_sale_line_money_columns(self, inspector):
        cols = {c["name"]: c for c in inspector.get_columns("sale_lines")}
        for col_name in ["unit_price", "unit_cost", "quantity", "line_discount", "line_total"]:
            type_name = cols[col_name]["type"].__class__.__name__.upper()
            assert "NUMERIC" in type_name


# ── Foreign keys ───────────────────────────────────────────────────────

class TestForeignKeys:
    def test_products_category_fk(self, inspector):
        fks = inspector.get_foreign_keys("products")
        fk_targets = {fk["referred_table"] for fk in fks}
        assert "categories" in fk_targets

    def test_product_variants_product_fk(self, inspector):
        fks = inspector.get_foreign_keys("product_variants")
        fk_targets = {fk["referred_table"] for fk in fks}
        assert "products" in fk_targets

    def test_sales_customer_fk(self, inspector):
        fks = inspector.get_foreign_keys("sales")
        fk_targets = {fk["referred_table"] for fk in fks}
        assert "customers" in fk_targets

    def test_sale_lines_sale_fk(self, inspector):
        fks = inspector.get_foreign_keys("sale_lines")
        fk_targets = {fk["referred_table"] for fk in fks}
        assert "sales" in fk_targets

    def test_debt_entries_customer_fk(self, inspector):
        fks = inspector.get_foreign_keys("debt_ledger_entries")
        fk_targets = {fk["referred_table"] for fk in fks}
        assert "customers" in fk_targets

    def test_purchases_supplier_fk(self, inspector):
        fks = inspector.get_foreign_keys("purchases")
        fk_targets = {fk["referred_table"] for fk in fks}
        assert "suppliers" in fk_targets


# ── Unique constraints ─────────────────────────────────────────────────

class TestUniqueConstraints:
    def test_user_roles_composite_unique(self, inspector):
        uqs = inspector.get_unique_constraints("user_roles")
        composite = [uq for uq in uqs if uq.get("name") == "uq_user_role"]
        assert len(composite) == 1

    def test_role_permissions_composite_unique(self, inspector):
        uqs = inspector.get_unique_constraints("role_permissions")
        composite = [uq for uq in uqs if uq.get("name") == "uq_role_permission"]
        assert len(composite) == 1

    def test_variant_product_name_unique(self, inspector):
        uqs = inspector.get_unique_constraints("product_variants")
        composite = [uq for uq in uqs if uq.get("name") == "uq_variant_product_name"]
        assert len(composite) == 1

    def test_pack_item_component_unique(self, inspector):
        uqs = inspector.get_unique_constraints("pack_items")
        composite = [uq for uq in uqs if uq.get("name") == "uq_pack_item_component"]
        assert len(composite) == 1


# ── Indexes ────────────────────────────────────────────────────────────

class TestIndexes:
    def test_product_barcode_indexed(self, inspector):
        indexes = inspector.get_indexes("products")
        barcode_indexed = any(
            "barcode" in idx.get("column_names", []) for idx in indexes
        )
        assert barcode_indexed

    def test_sales_invoice_number_indexed(self, inspector):
        indexes = inspector.get_indexes("sales")
        inv_indexed = any(
            "invoice_number" in idx.get("column_names", []) for idx in indexes
        )
        assert inv_indexed

    def test_customer_name_indexed(self, inspector):
        indexes = inspector.get_indexes("customers")
        name_indexed = any(
            "name" in idx.get("column_names", []) for idx in indexes
        )
        assert name_indexed

    def test_inventory_movement_type_indexed(self, inspector):
        indexes = inspector.get_indexes("inventory_movements")
        type_indexed = any(
            "movement_type" in idx.get("column_names", []) for idx in indexes
        )
        assert type_indexed


# ── Model instantiation (SQLite) ───────────────────────────────────────

class TestModelInstantiation:
    def test_create_user(self, db_session):
        user = User(
            full_name="Test User",
            pin_hash="hashed_pin_123",
            is_active=True,
        )
        db_session.add(user)
        db_session.commit()
        assert user.id is not None
        assert isinstance(user.id, uuid.UUID)
        assert user.full_name == "Test User"
        assert user.is_active is True
        assert user.created_at is not None

    def test_create_category(self, db_session):
        cat = Category(name="Electronics")
        db_session.add(cat)
        db_session.commit()
        assert cat.id is not None
        assert cat.name == "Electronics"

    def test_create_product(self, db_session):
        cat = Category(name="Food")
        db_session.add(cat)
        db_session.flush()

        product = Product(
            name="Milk",
            barcode="123456789",
            price=Decimal("150.000"),
            cost=Decimal("100.000"),
            quantity=Decimal("50.000"),
            category_id=cat.id,
        )
        db_session.add(product)
        db_session.commit()
        assert product.id is not None
        assert product.category_id == cat.id

    def test_create_customer(self, db_session):
        customer = Customer(name="Ahmed", phone="0555123456")
        db_session.add(customer)
        db_session.commit()
        assert customer.id is not None
        assert customer.balance == Decimal("0")

    def test_create_supplier(self, db_session):
        supplier = Supplier(name="Wholesale Co")
        db_session.add(supplier)
        db_session.commit()
        assert supplier.id is not None

    def test_create_role(self, db_session):
        role = Role(name="admin", description="Administrator")
        db_session.add(role)
        db_session.commit()
        assert role.id is not None
        assert role.name == "admin"

    def test_create_permission(self, db_session):
        perm = Permission(scope="pos_sale", description="POS Sale")
        db_session.add(perm)
        db_session.commit()
        assert perm.id is not None

    def test_create_expense(self, db_session):
        expense = Expense(title="Rent", category="rent", amount=Decimal("50000.000"))
        db_session.add(expense)
        db_session.commit()
        assert expense.id is not None

    def test_create_audit_log(self, db_session):
        audit = AuditLog(action="create", entity_type="product")
        db_session.add(audit)
        db_session.commit()
        assert audit.id is not None


# ── Relationships (SQLite) ─────────────────────────────────────────────

class TestRelationships:
    def test_category_parent_child(self, db_session):
        parent = Category(name="All")
        db_session.add(parent)
        db_session.flush()

        child = Category(name="Milk", parent_id=parent.id)
        db_session.add(child)
        db_session.commit()

        assert child.parent_id == parent.id

    def test_product_variant_relationship(self, db_session):
        product = Product(name="Soda", price=Decimal("100.000"), cost=Decimal("50.000"))
        db_session.add(product)
        db_session.flush()

        variant = ProductVariant(
            product_id=product.id,
            name="500ml",
            quantity=Decimal("20.000"),
        )
        db_session.add(variant)
        db_session.commit()

        assert variant.product_id == product.id

    def test_pack_item_relationship(self, db_session):
        product = Product(name="Bread", price=Decimal("50.000"), cost=Decimal("30.000"))
        db_session.add(product)
        db_session.flush()

        pack = Pack(name="Breakfast Pack", price=Decimal("200.000"))
        db_session.add(pack)
        db_session.flush()

        item = PackItem(pack_id=pack.id, product_id=product.id, quantity=Decimal("2.000"))
        db_session.add(item)
        db_session.commit()

        assert item.pack_id == pack.id
        assert item.product_id == product.id

    def test_user_role_assignment(self, db_session):
        user = User(full_name="Admin", pin_hash="hash123")
        role = Role(name="admin_role")
        db_session.add_all([user, role])
        db_session.flush()

        ur = UserRole(user_id=user.id, role_id=role.id)
        db_session.add(ur)
        db_session.commit()

        assert ur.user_id == user.id
        assert ur.role_id == role.id

    def test_role_permission_assignment(self, db_session):
        role = Role(name="cashier_role")
        perm = Permission(scope="pos_sale")
        db_session.add_all([role, perm])
        db_session.flush()

        rp = RolePermission(role_id=role.id, permission_id=perm.id)
        db_session.add(rp)
        db_session.commit()

        assert rp.role_id == role.id
        assert rp.permission_id == perm.id

    def test_user_roles_relationship_navigation(self, db_session):
        user = User(full_name="Cashier", pin_hash="hash456")
        role = Role(name="cashier_role")
        db_session.add_all([user, role])
        db_session.flush()

        ur = UserRole(user_id=user.id, role_id=role.id)
        db_session.add(ur)
        db_session.commit()

        # Navigate via relationship
        assert len(user.user_roles) == 1
        assert user.user_roles[0].role_id == role.id
        assert user.user_roles[0].role.name == "cashier_role"

    def test_role_permissions_relationship_navigation(self, db_session):
        role = Role(name="manager_role")
        perm = Permission(scope="product_create")
        db_session.add_all([role, perm])
        db_session.flush()

        rp = RolePermission(role_id=role.id, permission_id=perm.id)
        db_session.add(rp)
        db_session.commit()

        # Navigate via relationship
        assert len(role.role_permissions) == 1
        assert role.role_permissions[0].permission.scope == "product_create"

    def test_user_roles_property(self, db_session):
        user = User(full_name="TestUser", pin_hash="hash789")
        role = Role(name="test_role")
        db_session.add_all([user, role])
        db_session.flush()

        ur = UserRole(user_id=user.id, role_id=role.id)
        db_session.add(ur)
        db_session.commit()

        # Test the .roles property
        roles = user.roles
        assert len(roles) == 1
        assert roles[0].name == "test_role"

    def test_role_permissions_property(self, db_session):
        role = Role(name="perm_role")
        perm = Permission(scope="pos_void")
        db_session.add_all([role, perm])
        db_session.flush()

        rp = RolePermission(role_id=role.id, permission_id=perm.id)
        db_session.add(rp)
        db_session.commit()

        # Test the .permissions property
        perms = role.permissions
        assert len(perms) == 1
        assert perms[0].scope == "pos_void"
