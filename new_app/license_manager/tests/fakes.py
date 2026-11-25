"""A tiny in-process stand-in for ``google.cloud.firestore``.

It exists so the *production* repository code (transactions, document mapping,
sealing, status transitions) is exercised without the SDK or a Firestore
emulator.  Only the surface `FirestoreLicenseRepository` actually uses is
implemented: ``collection().document().get/set/update``, ``collection().where(filter=...).stream()``
and ``transactional``.

The ``where`` signature is **filter-only on purpose**: the deprecated positional
``where(field, op, value)`` form is rejected, so any future regression that
reintroduces it fails the suite instead of only emitting a deprecation warning.
"""

from __future__ import annotations

from typing import Any


class FakeFieldFilter:
    """The subset of ``google.cloud.firestore.FieldFilter`` the repository uses."""

    def __init__(self, field_path: str, op_string: str, value: Any) -> None:
        self.field_path = field_path
        self.op_string = op_string
        self.value = value

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"FakeFieldFilter({self.field_path!r} {self.op_string} {self.value!r})"


class FakeSnapshot:
    def __init__(self, data: dict[str, Any] | None) -> None:
        self._data = data
        self.exists = data is not None

    def to_dict(self) -> dict[str, Any]:
        return dict(self._data or {})


class FakeDocument:
    def __init__(self, data: dict[tuple[str, str], dict[str, Any]], path: tuple[str, str]) -> None:
        self._data = data
        self.path = path
        self.id = path[1]

    def get(self, transaction: Any = None) -> FakeSnapshot:
        return FakeSnapshot(self._data.get(self.path))

    def set(self, document: dict[str, Any], merge: bool = False) -> None:
        if merge and self.path in self._data:
            self._data[self.path].update(document)
        else:
            self._data[self.path] = dict(document)

    def update(self, fields: dict[str, Any]) -> None:
        self._data.setdefault(self.path, {}).update(fields)

    def to_dict(self) -> dict[str, Any]:
        return dict(self._data.get(self.path, {}))


class FakeQuery:
    def __init__(
        self,
        data: dict[tuple[str, str], dict[str, Any]],
        collection: str,
        field: str,
        value: Any,
    ) -> None:
        self._data = data
        self._collection = collection
        self._field = field
        self._value = value

    def stream(self):
        for (collection, document_id), document in sorted(self._data.items()):
            if collection != self._collection:
                continue
            if document.get(self._field) == self._value:
                yield FakeDocument(self._data, (collection, document_id))


class FakeCollection:
    def __init__(self, data: dict[tuple[str, str], dict[str, Any]], name: str) -> None:
        self._data = data
        self._name = name

    def document(self, document_id: str) -> FakeDocument:
        return FakeDocument(self._data, (self._name, document_id))

    def stream(self):
        """Every document in the collection (used by the count fallback)."""
        for (collection, document_id), _ in sorted(self._data.items()):
            if collection == self._name:
                yield FakeDocument(self._data, (collection, document_id))

    def where(self, filter: FakeFieldFilter) -> FakeQuery:
        """Filter-based only: positional ``where(field, op, value)`` is deprecated.

        Real Firestore accepts both spellings (the positional one with a
        ``FutureWarning``); the fake accepts only the supported one so the
        production code cannot silently regress.
        """
        if not isinstance(filter, FakeFieldFilter):
            raise TypeError(
                "where() takes a FieldFilter filter= argument; the positional "
                "(field, op, value) form is deprecated and unsupported here"
            )
        if filter.op_string != "==":
            raise AssertionError("the fake supports only equality filters")
        return FakeQuery(self._data, self._name, filter.field_path, filter.value)


class FakeTransaction:
    """Buffers nothing and applies immediately — enough for logic coverage."""

    def __init__(self, data: dict[tuple[str, str], dict[str, Any]]) -> None:
        self._data = data

    def set(self, reference: FakeDocument, document: dict[str, Any]) -> None:
        reference.set(document)

    def update(self, reference: FakeDocument, fields: dict[str, Any]) -> None:
        reference.update(fields)


class FakeClient:
    def __init__(self) -> None:
        self.data: dict[tuple[str, str], dict[str, Any]] = {}

    def collection(self, name: str) -> FakeCollection:
        return FakeCollection(self.data, name)

    def transaction(self) -> Any:
        return FakeTransaction(self.data)

    # -- assertions helpers -------------------------------------------- #
    def documents(self, collection: str) -> list[dict[str, Any]]:
        return [dict(value) for (name, _), value in sorted(self.data.items()) if name == collection]


class FakeFirestoreModule:
    """The module-level pieces the repository touches."""

    #: ``google.cloud.firestore.FieldFilter``, as the repository calls it.
    FieldFilter = FakeFieldFilter

    @staticmethod
    def transactional(func):
        def runner(transaction, *args, **kwargs):
            return func(transaction, *args, **kwargs)

        return runner


class FlakyFirestoreModule(FakeFirestoreModule):
    """Fails the first transaction, then behaves (retry coverage)."""

    def __init__(self) -> None:
        self.attempts = 0

    def transactional(self, func):  # type: ignore[override]
        def runner(transaction, *args, **kwargs):
            self.attempts += 1
            if self.attempts == 1:
                raise RuntimeError("transient contention")
            return func(transaction, *args, **kwargs)

        return runner
