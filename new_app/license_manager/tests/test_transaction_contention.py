"""The contention fallback in ``create_or_get_license``.

Firestore transactions are optimistic: under heavy contention on one device
document the SDK gives up after five attempts and raises
``ValueError("Failed to commit transaction in 5 attempts.")``.  For duplicate
issuance that is not a real failure -- the winning request created the license
-- so the repository must return that license instead of a 500, and must never
build or sign a second one.
"""

from __future__ import annotations

import pytest

# The repository imports the SDK in __init__ (to classify provider errors), so
# these tests need it installed; the whole module skips on a cloud-free host.
pytest.importorskip("google.cloud.firestore", reason="google-cloud-firestore is not installed")

from service.errors import StoreUnavailableError  # noqa: E402
from service.firestore_repository import (
    FirestoreLicenseRepository,
    _is_transaction_contention,
)

CONTENTION = "Failed to commit transaction in 5 attempts."


class _StubDb:
    def transaction(self):
        return object()


class _StubFirestore:
    def __init__(self, error: BaseException) -> None:
        self._error = error

    def transactional(self, _function):
        def run(*_args, **_kwargs):
            raise self._error

        return run


class _Sentinel:
    """Stands in for the LicenseRecord a competing request committed."""


def _repository(cipher, error: BaseException) -> FirestoreLicenseRepository:
    repository = FirestoreLicenseRepository(None, cipher)
    repository._db = _StubDb()
    repository._firestore = _StubFirestore(error)
    return repository


def test_contention_is_recognised_from_the_sdk_error():
    assert _is_transaction_contention(ValueError(CONTENTION))
    assert _is_transaction_contention(type("Aborted", (Exception,), {})("aborted"))
    assert not _is_transaction_contention(ValueError("something else entirely"))
    assert not _is_transaction_contention(StoreUnavailableError("down"))


def test_the_winner_license_is_returned_instead_of_sign_in_again(cipher, monkeypatch):
    repository = _repository(cipher, ValueError(CONTENTION))
    winner = _Sentinel()
    monkeypatch.setattr(repository, "_current_license_for", lambda _hw: winner)

    outcome = repository.create_or_get_license(
        hw_hash="hw-1",
        build=lambda: pytest.fail("a competing request already issued this device"),
        make_audit=lambda *_args: pytest.fail("nothing new was issued"),
    )

    assert outcome.created is False
    assert outcome.license is winner


def test_contention_without_a_visible_license_still_fails(cipher, monkeypatch):
    repository = _repository(cipher, ValueError(CONTENTION))
    monkeypatch.setattr(repository, "_current_license_for", lambda _hw: None)

    with pytest.raises(ValueError, match="Failed to commit transaction"):
        repository.create_or_get_license(
            hw_hash="hw-2",
            build=lambda: pytest.fail("must not issue without a committed winner"),
            make_audit=lambda *_args: pytest.fail("must not audit"),
        )


def test_unrelated_errors_are_never_swallowed(cipher):
    repository = _repository(cipher, ValueError("bad document reference"))

    with pytest.raises(ValueError, match="bad document reference"):
        repository.create_or_get_license(
            hw_hash="hw-3",
            build=lambda: pytest.fail("must not build"),
            make_audit=lambda *_args: pytest.fail("must not audit"),
        )


def test_the_fallback_polls_until_the_winner_is_visible(cipher, monkeypatch):
    repository = _repository(cipher, ValueError(CONTENTION))
    calls = {"n": 0}

    def read(_hw):
        calls["n"] += 1
        return _Sentinel() if calls["n"] == 3 else None

    monkeypatch.setattr(repository, "_current_license_for", read)
    found = repository._await_current_license("hw-4", attempts=5, delay=0)

    assert found is not None
    assert calls["n"] == 3
