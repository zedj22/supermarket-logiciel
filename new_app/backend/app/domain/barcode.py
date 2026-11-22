"""EAN-13 barcode primitives (pure functions, no DB, no HTTP).

The catalogue needs an automatic barcode for every product created without
one.  The application already treats EAN-13 as a first-class scanner format
(UPC-A/EAN-13 aliasing in ``app.services.catalog``), the label printer
renders the stored digits verbatim, and the POS resolves a scan by exact
string, so the generated code must be a *valid* EAN-13:

* 13 digits, all numeric;
* the last digit is the standard GS1 check digit of the first twelve.

Internal use: the leading digit is ``2`` — the GS1 prefix reserved for
"restricted distribution / in-store" codes.  Nothing in a shop's catalogue
can collide with a manufacturer-issued (690…699 Algeria, 3xx France, …)
symbol, and the same prefix the world over means "internal article".

Nothing here generates uniqueness — that is the caller's job against the
live database (a check plus a retry on the unique index).
"""

from __future__ import annotations

import secrets

#: GS1 prefix for internal / restricted-distribution article numbers.
INTERNAL_EAN13_PREFIX = "2"

#: A complete EAN-13 is 13 characters.
EAN13_LENGTH = 13

#: Random digits generated before the check digit (prefix included).
_EAN13_PAYLOAD_LENGTH = EAN13_LENGTH - 1


def ean13_check_digit(first_twelve: str) -> str:
    """The GS1 check digit for the first twelve digits of an EAN-13.

    Positions alternate weight 1 / 3 starting from the leftmost digit
    (1-indexed odd → 1, even → 3); the check digit completes the sum to a
    multiple of ten.
    """
    if len(first_twelve) != _EAN13_PAYLOAD_LENGTH or not first_twelve.isdigit():
        raise ValueError("EAN-13 payload must be exactly 12 digits")
    total = sum(
        int(digit) * (3 if index % 2 else 1)
        for index, digit in enumerate(first_twelve)
    )
    return str((10 - total % 10) % 10)


def is_valid_ean13(code: str) -> bool:
    """True when ``code`` is a complete, checksum-valid EAN-13."""
    if not isinstance(code, str) or len(code) != EAN13_LENGTH:
        return False
    if not code.isdigit():
        return False
    return ean13_check_digit(code[:12]) == code[12]


def generate_internal_ean13() -> str:
    """A random, checksum-correct internal-use EAN-13.

    The payload is one prefix digit plus eleven random digits; the final
    digit is computed, so every produced code is a scannable EAN-13.  The
    caller must still prove uniqueness against the database.
    """
    payload = INTERNAL_EAN13_PREFIX + "".join(
        str(secrets.randbelow(10)) for _ in range(_EAN13_PAYLOAD_LENGTH - 1)
    )
    return payload + ean13_check_digit(payload)
