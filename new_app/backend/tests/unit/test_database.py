"""Tests for database foundation."""


def test_base_model_has_id():
    """Verify BaseModel inherits UUIDMixin which provides id column."""
    from app.db.base import BaseModel, UUIDMixin

    assert issubclass(BaseModel, UUIDMixin)
    # UUIDMixin defines id in its annotations
    annotations = getattr(UUIDMixin, "__annotations__", {})
    assert "id" in annotations


def test_base_model_inherits_timestamps():
    """Verify BaseModel inherits from TimestampMixin which has created_at/updated_at."""
    from app.db.base import BaseModel, TimestampMixin

    assert issubclass(BaseModel, TimestampMixin)
    ts_annotations = getattr(TimestampMixin, "__annotations__", {})
    assert "created_at" in ts_annotations
    assert "updated_at" in ts_annotations


def test_db_session_dependency():
    """Verify get_db is callable."""
    from app.db.session import get_db

    assert callable(get_db)
