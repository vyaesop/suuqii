"""Keyset pagination shared by the list endpoints.

A cursor is "<sort-key>|<uuid>" taken from the last row of the previous
page, where sort-key is the endpoint's ordering column (a timestamp or a
name). UUIDs contain no "|", so rsplit is unambiguous even if the sort key
does.
"""
from datetime import datetime
from uuid import UUID

from app.core.errors import DomainError


def decode_cursor(cursor: str | None) -> tuple[str, UUID] | None:
    if not cursor:
        return None
    try:
        key, id_raw = cursor.rsplit("|", 1)
        return key, UUID(id_raw)
    except ValueError as e:
        raise DomainError("malformed cursor", code="bad_cursor") from e


def decode_time_cursor(cursor: str | None) -> tuple[datetime, UUID] | None:
    decoded = decode_cursor(cursor)
    if decoded is None:
        return None
    key, id_ = decoded
    try:
        return datetime.fromisoformat(key), id_
    except ValueError as e:
        raise DomainError("malformed cursor", code="bad_cursor") from e


def encode_cursor(key: object, id_: UUID) -> str:
    if isinstance(key, datetime):
        key = key.isoformat()
    return f"{key}|{id_}"
