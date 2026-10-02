"""API v1 router.

Central router that includes all feature-specific sub-routers.
Each feature module adds its router here.
"""

from fastapi import APIRouter

from app.api.v1.auth import router as auth_router
from app.api.v1.categories import router as categories_router
from app.api.v1.customers import router as customers_router
from app.api.v1.dashboard import dashboard_router
from app.api.v1.debts import router as debts_router
from app.api.v1.expenses import router as expenses_router
from app.api.v1.exports import router as exports_router
from app.api.v1.health import router as health_router
from app.api.v1.inventory import router as inventory_router
from app.api.v1.packs import router as packs_router
from app.api.v1.pos import pos_router, sales_router
from app.api.v1.print import router as print_router
from app.api.v1.products import router as products_router
from app.api.v1.purchases import router as purchases_router
from app.api.v1.reports import reports_router
from app.api.v1.returns import router as returns_router
from app.api.v1.suppliers import router as suppliers_router
from app.api.v1.system import router as system_router
from app.api.v1.users import router as users_router

api_router = APIRouter()

api_router.include_router(health_router, tags=["health"])
api_router.include_router(system_router, tags=["system"])
api_router.include_router(auth_router, prefix="/auth", tags=["auth"])
api_router.include_router(users_router, prefix="/users", tags=["users"])
api_router.include_router(products_router, prefix="/products", tags=["products"])
api_router.include_router(packs_router, prefix="/packs", tags=["packs"])
api_router.include_router(categories_router, prefix="/categories", tags=["categories"])
api_router.include_router(customers_router, prefix="/customers", tags=["customers"])
api_router.include_router(suppliers_router, prefix="/suppliers", tags=["suppliers"])
api_router.include_router(debts_router, prefix="/debts", tags=["debts"])
api_router.include_router(
    expenses_router, prefix="/expenses", tags=["expenses"]
)
api_router.include_router(inventory_router, prefix="/inventory", tags=["inventory"])
api_router.include_router(sales_router, prefix="/sales", tags=["sales"])
api_router.include_router(purchases_router, prefix="/purchases", tags=["purchases"])
api_router.include_router(returns_router, prefix="/returns", tags=["returns"])
api_router.include_router(reports_router, prefix="/reports", tags=["reports"])
api_router.include_router(exports_router, prefix="/exports", tags=["exports"])
api_router.include_router(print_router, prefix="/print", tags=["print"])
api_router.include_router(dashboard_router, prefix="/dashboard", tags=["dashboard"])
api_router.include_router(pos_router, prefix="/pos", tags=["pos"])
