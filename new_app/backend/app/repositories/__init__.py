"""Repositories package -- data access layers.

Base repository provides common CRUD, pagination, and filtering.
Domain-specific repositories extend BaseRepository for each model.
"""

from app.repositories.base import BaseRepository

__all__ = ["BaseRepository"]
