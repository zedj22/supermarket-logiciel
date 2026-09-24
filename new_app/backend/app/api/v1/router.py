"""API v1 router.

Central router that includes all feature-specific sub-routers.
Each feature module adds its router here.
"""

from fastapi import APIRouter

from app.api.v1.auth import router as auth_router
from app.api.v1.categories import router as categories_router
from app.api.v1.health import router as health_router
from app.api.v1.inventory import router as inventory_router
from app.api.v1.products import router as products_router
from app.api.v1.system import router as system_router
from app.api.v1.users import router as users_router

api_router = APIRouter()

api_router.include_router(health_router, tags=["health"])
api_router.include_router(system_router, tags=["system"])
api_router.include_router(auth_router, prefix="/auth", tags=["auth"])
api_router.include_router(users_router, prefix="/users", tags=["users"])
api_router.include_router(products_router, prefix="/products", tags=["products"])
api_router.include_router(categories_router, prefix="/categories", tags=["categories"])
api_router.include_router(inventory_router, prefix="/inventory", tags=["inventory"])
