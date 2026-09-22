"""FastAPI dependency injection for database sessions."""

from sqlalchemy.orm import Session

from app.db.session import get_db

__all__ = ["get_db"]
