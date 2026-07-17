"""
Ethiopian phone number normalization.

Identity phones (register, login, invite, accept-invite) are stored and
looked up in the canonical local format `09XXXXXXXX` / `07XXXXXXXX`, so
`+251912345678`, `251912345678`, `912345678` and `0912345678` all resolve
to the same account.
"""
import re

_CANONICAL = re.compile(r"^0[97]\d{8}$")
_SEPARATORS = re.compile(r"[\s\-().]")


class InvalidPhoneError(ValueError):
    """Raised when a phone cannot be normalized to `0[97]XXXXXXXX`.

    Subclasses ValueError so Pydantic field validators surface it as a
    422 validation error rather than a 500.
    """


def normalize_phone(raw: str) -> str:
    """Normalize an Ethiopian mobile number to canonical local format.

    Accepted inputs (after stripping spaces/dashes/parens/dots):
    - ``+251XXXXXXXXX`` / ``251XXXXXXXXX`` where the X-part is 9 digits
      starting with 9 or 7 → ``0`` + those 9 digits
    - bare 9 digits ``9XXXXXXXX`` / ``7XXXXXXXX`` → ``0`` prepended
    - already-canonical ``09XXXXXXXX`` / ``07XXXXXXXX`` → unchanged

    Raises InvalidPhoneError for anything else.
    """
    cleaned = _SEPARATORS.sub("", raw)
    if cleaned.startswith("+251") and len(cleaned) == 13:
        cleaned = cleaned[4:]
    elif cleaned.startswith("251") and len(cleaned) == 12:
        cleaned = cleaned[3:]
    if len(cleaned) == 9 and cleaned[0] in "97":
        cleaned = "0" + cleaned
    if not _CANONICAL.match(cleaned):
        raise InvalidPhoneError(
            "phone must be an Ethiopian mobile number "
            "(09XXXXXXXX, 07XXXXXXXX, or +2519/+2517 equivalents)"
        )
    return cleaned
