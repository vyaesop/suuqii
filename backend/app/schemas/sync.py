from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field

SyncOp = Literal[
    "sale.create", "sale.refund", "sale.void",
    "product.create", "product.update", "product.delete",
    "inventory.adjust",
    "debt.create", "debt.payment.create", "debt.writeoff",
    "expense.create", "expense.update", "expense.delete",
    "shift.open", "shift.close",
]


class SyncEventIn(BaseModel):
    client_event_id: UUID
    op: SyncOp
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


class SyncPullResponse(BaseModel):
    events: list[SyncEventOut]
    next_cursor: int
    has_more: bool
