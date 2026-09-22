"""Services package -- business logic and orchestration layers.

Base service provides transaction management.
Domain-specific services extend BaseService for each use case.
"""

from app.services.base import BaseService

__all__ = ["BaseService"]
