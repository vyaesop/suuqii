from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field

SyncOp = Literal[
    "sale.create", "sale.refund", "sale.void", "sale.return",
    "product.create", "product.update", "product.delete",
    "style.create", "style.update", "style.add_variants", "style.delete",
    "inventory.adjust",
    "stock.receive", "stock.spoil", "production.record",
    "handover.create", "handover.accept",
    "debt.create", "debt.payment.create", "debt.writeoff",
    "expense.create", "expense.update", "expense.delete",
    "shift.open", "shift.close",
    "supply.create", "supply.update", "supply.delete",
    "recipe.set",
]


class SyncEventIn(BaseModel):
    client_event_id: UUID
    # Inbound op is a plain string, NOT a Literal: an unrecognized op must be
    # rejected per-event by the handler map (DomainError → "rejected"), never
    # 422 the entire batch. A single bad/newer event would otherwise block every
    # other event behind it in the offline queue forever.
    op: str
    occurred_at: datetime
    payload: dict[str, Any]


class SyncPushRequest(BaseModel):
    device_id: str
    events: list[SyncEventIn] = Field(max_length=200)


class SyncResultStatus:
    APPLIED = "applied"
    CONFLICT = "conflict"
    REJECTED = "rejected"
    DUPLICATE = "duplicate"


class SyncResultOut(BaseModel):
    client_event_id: UUID
    status: str
    code: str | None = None
    detail: str | None = None
    server: dict[str, Any] | None = None


class SyncPushResponse(BaseModel):
    results: list[SyncResultOut]
    server_cursor: int


class SyncEventOut(BaseModel):
    server_id: int
    op: SyncOp
    payload: dict[str, Any]
    applied_at: datetime
    # Actor and client-side timestamp of the event. Payloads deliberately omit
    # user_id (the server derives it from auth on push), so pulling devices
    # need both here to attribute and date replicated rows (sales, shifts).
    user_id: UUID
    occurred_at: datetime


class SyncPullResponse(BaseModel):
    events: list[SyncEventOut]
    next_cursor: int
    has_more: bool
