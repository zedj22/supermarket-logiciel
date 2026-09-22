"""Tests for Pydantic schema conventions.

Verifies:
- Pagination schema validation
- PaginatedResponse structure
- OrderingParams validation
- ErrorResponse structure
- TimestampMixin
"""

import pytest
from pydantic import ValidationError as PydanticValidationError

from app.schemas.common import (
    ErrorResponse,
    PaginatedResponse,
    PaginationParams,
    OrderingParams,
    ErrorDetail,
    SuccessResponse,
    IDResponse,
)


# ── PaginationParams ──────────────────────────────────────────────────


def test_pagination_defaults():
    p = PaginationParams()
    assert p.page == 1
    assert p.page_size == 40
    assert p.offset == 0
    assert p.limit == 40


def test_pagination_custom_values():
    p = PaginationParams(page=3, page_size=20)
    assert p.page == 3
    assert p.page_size == 20
    assert p.offset == 40
    assert p.limit == 20


def test_pagination_page_must_be_positive():
    with pytest.raises(PydanticValidationError):
        PaginationParams(page=0)


def test_pagination_page_size_max():
    with pytest.raises(PydanticValidationError):
        PaginationParams(page_size=101)


def test_pagination_page_size_min():
    with pytest.raises(PydanticValidationError):
        PaginationParams(page_size=0)


# ── OrderingParams ────────────────────────────────────────────────────


def test_ordering_defaults():
    o = OrderingParams()
    assert o.field == "created_at"
    assert o.direction == "desc"


def test_ordering_asc():
    o = OrderingParams(field="name", direction="asc")
    assert o.field == "name"
    assert o.direction == "asc"


def test_ordering_invalid_direction():
    with pytest.raises(PydanticValidationError):
        OrderingParams(direction="sideways")


# ── PaginatedResponse ────────────────────────────────────────────────


def test_paginated_response_structure():
    resp = PaginatedResponse(
        items=[{"id": 1}, {"id": 2}],
        total=50,
        page=1,
        page_size=20,
        pages=3,
    )
    assert len(resp.items) == 2
    assert resp.total == 50
    assert resp.pages == 3


# ── ErrorDetail / ErrorResponse ──────────────────────────────────────


def test_error_detail_structure():
    err = ErrorDetail(
        code="NOT_FOUND",
        message_key="errors.notFound",
        message="Product not found",
        details={"id": "abc"},
        request_id="req-123",
    )
    assert err.code == "NOT_FOUND"
    assert err.request_id == "req-123"


def test_error_response_envelope():
    resp = ErrorResponse(
        error=ErrorDetail(
            code="CONFLICT",
            message_key="errors.conflict",
            message="Duplicate barcode",
        )
    )
    assert resp.error.code == "CONFLICT"
    assert resp.error.details == {}


# ── SuccessResponse ──────────────────────────────────────────────────


def test_success_response():
    resp = SuccessResponse(message="Done", details={"count": 5})
    assert resp.message == "Done"
    assert resp.details["count"] == 5


# ── IDResponse ───────────────────────────────────────────────────────


def test_id_response():
    from uuid import uuid4
    uid = uuid4()
    resp = IDResponse(id=uid)
    assert resp.id == uid
