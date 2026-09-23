"""Repositories package -- data access layers.

Base repository provides common CRUD, pagination, and filtering.
Domain-specific repositories extend BaseRepository for each model.
"""

from app.repositories.base import BaseRepository
from app.repositories.catalog import CategoryRepository, ProductRepository

__all__ = ["BaseRepository", "CategoryRepository", "ProductRepository"]
