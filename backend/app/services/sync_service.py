"""
Sync engine — server side.

Replays client events into authoritative tables under a single transaction
per push request, with per-event idempotency.
"""
from __future__ import annotations

import time
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ConflictError, DomainError, OwnerPinRequired
from app.core.security import decode_token
from app.models import (
    AuditLog,
    Debt,
    DebtPayment,
    Expense,
    InventoryLog,
    Product,
    RecipeItem,
    Sale,
    SaleItem,
    Shift,
    Supply,
    SyncEvent,
    User,
)
from app.schemas.sync import SyncEventIn, SyncResultOut, SyncResultStatus

SENSITIVE_OPS = {
    "product.create",
    "product.update",
    "product.delete",
    "inventory.adjust",
    "debt.writeoff",
    "sale.refund",
    "expense.create",
    "supply.create",
    "supply.update",
    "supply.delete",
    # recipe.set intentionally excluded: it can only reference products that
    # already required owner PIN to create, and it has no financial effect.
    # sale.void intentionally excluded: the handler is not yet implemented.
}

# Single-use nonce tracking: nonce → expiry unix timestamp.
# Per-process; acceptable for v1 single-worker deployments. In multi-worker
# production move to Redis with TTL keys.
_used_nonces: dict[str, float] = {}
_NONCE_CLEANUP_INTERVAL = 300  # purge expired entries every 5 min
_last_nonce_cleanup: float = 0.0


def _consume_nonce(nonce: str, exp: float) -> bool:
    """Mark nonce as used. Returns False if already consumed or expired."""
    global _last_nonce_cleanup, _used_nonces  # noqa: PLW0603
    now = time.time()
    if now - _last_nonce_cleanup > _NONCE_CLEANUP_INTERVAL:
        _used_nonces = {n: e for n, e in _used_nonces.items() if e > now}
        _last_nonce_cleanup = now
    if nonce in _used_nonces or exp <= now:
        return False
    _used_nonces[nonce] = exp
    return True


class SyncService:
    def __init__(
        self,
        db: AsyncSession,
        *,
        shop_id: UUID,
        user: User,
        device_id: str,
        owner_challenge: str | None = None,
    ):
        self.db = db
        self.shop_id = shop_id
        self.user = user
        self.device_id = device_id
        # Consume the batch-level nonce once at construction so the token
        # cannot be replayed across different sync requests.
        self._batch_challenge_id: UUID | None = self._authorize_challenge(owner_challenge)

    @staticmethod
    def _parse_challenge(token: str | None) -> UUID | None:
        """Decode and validate a challenge token; does NOT consume its nonce."""
        if not token:
            return None
        try:
            payload = decode_token(token)
        except Exception:  # noqa: BLE001
            return None
        if payload.get("purpose") != "owner_pin":
            return None
        return UUID(payload["sub"])

    def _authorize_challenge(self, token: str | None) -> UUID | None:
        """Validate token and consume its nonce. Returns owner user_id or None."""
        if not token:
            return None
        try:
            payload = decode_token(token)
        except Exception:  # noqa: BLE001
            return None
        if payload.get("purpose") != "owner_pin":
            return None
        nonce = payload.get("nonce", "")
        exp = float(payload.get("exp", 0))
        if not _consume_nonce(nonce, exp):
            return None
        return UUID(payload["sub"])

    async def apply(self, event: SyncEventIn) -> SyncResultOut:
        existing = await self._existing_event(event.client_event_id)
        if existing is not None:
            return SyncResultOut(client_event_id=event.client_event_id, status=SyncResultStatus.DUPLICATE)

        if event.op in SENSITIVE_OPS and self.user.role != "owner":
            # Per-event token (mobile stores it in payload) takes precedence;
            # fall back to the batch-level header token.
            per_event_token: str | None = event.payload.get("owner_challenge")
            challenge_id = (
                self._authorize_challenge(per_event_token)
                if per_event_token
                else self._batch_challenge_id
            )
            if challenge_id is None:
                return SyncResultOut(
                    client_event_id=event.client_event_id,
                    status=SyncResultStatus.REJECTED,
                    code="owner_pin_required",
                )

        try:
            handler = self._handler_for(event.op)
            await handler(event.payload)
        except OwnerPinRequired as e:
            return SyncResultOut(client_event_id=event.client_event_id,
                                 status=SyncResultStatus.REJECTED, code=e.code, detail=str(e))
        except ConflictError as e:
            return SyncResultOut(client_event_id=event.client_event_id,
                                 status=SyncResultStatus.CONFLICT, code=e.code,
                                 detail=str(e), server=e.server_payload)
        except DomainError as e:
            return SyncResultOut(client_event_id=event.client_event_id,
                                 status=SyncResultStatus.REJECTED, code=e.code, detail=str(e))

        self.db.add(SyncEvent(
            shop_id=self.shop_id,
            device_id=self.device_id,
            client_event_id=event.client_event_id,
            user_id=self.user.id,
            op=event.op,
            payload=event.payload,
            client_occurred_at=event.occurred_at,
            applied_at=datetime.now(UTC),
        ))
        return SyncResultOut(client_event_id=event.client_event_id, status=SyncResultStatus.APPLIED)

    async def current_cursor(self) -> int:
        row = await self.db.execute(
            select(SyncEvent.id).where(SyncEvent.shop_id == self.shop_id).order_by(SyncEvent.id.desc()).limit(1)
        )
        return row.scalar() or 0

    # ---------- handlers ----------

    def _handler_for(self, op: str):
        m = {
            "sale.create": self._sale_create,
            "sale.refund": self._sale_refund,
            "sale.void": self._sale_void,
            "product.create": self._product_create,
            "product.update": self._product_update,
            "product.delete": self._product_delete,
            "inventory.adjust": self._inventory_adjust,
            "debt.payment.create": self._debt_payment_create,
            "expense.create": self._expense_create,
            "shift.open": self._shift_open,
            "shift.close": self._shift_close,
            "supply.create": self._supply_create,
            "supply.update": self._supply_update,
            "supply.delete": self._supply_delete,
            "recipe.set": self._recipe_set,
        }
        if op not in m:
            raise DomainError(f"unsupported op: {op}", code="unsupported_op")
        return m[op]

    async def _existing_event(self, client_event_id: UUID) -> SyncEvent | None:
        row = await self.db.execute(
            select(SyncEvent).where(
                SyncEvent.shop_id == self.shop_id,
                SyncEvent.client_event_id == client_event_id,
            )
        )
        return row.scalar_one_or_none()

    async def _sale_create(self, p: dict[str, Any]) -> None:
        sale_id = UUID(p["id"])
        # Idempotent: if a sale with this id already exists, treat as duplicate
        existing = await self.db.get(Sale, sale_id)
        if existing:
            return

        sale = Sale(
            id=sale_id,
            shop_id=self.shop_id,
            shift_id=UUID(p["shift_id"]) if p.get("shift_id") else None,
            user_id=self.user.id,
            subtotal=Decimal(p["subtotal"]),
            discount=Decimal(p.get("discount", "0")),
            total=Decimal(p["total"]),
            cost_total=Decimal(p["cost_total"]),
            payment_method=p["payment_method"],
            status=p.get("status", "completed"),
            device_id=self.device_id,
            occurred_at=datetime.fromisoformat(p["occurred_at"]),
            created_at=datetime.now(UTC),
        )
        self.db.add(sale)

        for item in p["items"]:
            self.db.add(SaleItem(
                id=UUID(item["id"]),
                sale_id=sale_id,
                product_id=UUID(item["product_id"]),
                product_name_snapshot=item["product_name_snapshot"],
                quantity=Decimal(item["quantity"]),
                unit_price=Decimal(item["unit_price"]),
                unit_cost=Decimal(item["unit_cost"]),
            ))
            # delta-based stock decrement + ledger
            self.db.add(InventoryLog(
                shop_id=self.shop_id,
                product_id=UUID(item["product_id"]),
                movement="sale",
                quantity_delta=-Decimal(item["quantity"]),
                reference_type="sale",
                reference_id=sale_id,
                user_id=self.user.id,
                created_at=datetime.now(UTC),
            ))
            await self.db.execute(
                Product.__table__.update()
                .where(Product.id == UUID(item["product_id"]))
                .values(stock=Product.stock - Decimal(item["quantity"]),
                        updated_at=datetime.now(UTC))
            )

        if p["payment_method"] == "credit":
            cust = p.get("customer", {})
            self.db.add(Debt(
                id=UUID(p["debt_id"]) if p.get("debt_id") else None,
                shop_id=self.shop_id,
                sale_id=sale_id,
                customer_name=cust.get("name", "Unknown"),
                customer_phone=cust.get("phone"),
                amount_owed=Decimal(p["total"]),
                amount_paid=Decimal("0"),
                due_date=cust.get("due_date"),
                status="open",
            ))

        # Bakery: deduct supplies consumed by this sale (client pre-calculated).
        # Shop-scoped: only supplies belonging to this shop can be decremented.
        for ded in p.get("supply_deductions", []):
            supply_id = UUID(ded["supply_id"])
            delta = Decimal(ded["quantity_delta"])  # negative value
            await self.db.execute(
                Supply.__table__.update()
                .where(Supply.id == supply_id, Supply.shop_id == self.shop_id)
                .values(
                    quantity_on_hand=Supply.quantity_on_hand + delta,
                    updated_at=datetime.now(UTC),
                )
            )

    async def _sale_refund(self, p: dict[str, Any]) -> None:
        sale_id = UUID(p["sale_id"])
        sale = await self.db.get(Sale, sale_id)
        if sale is None:
            raise DomainError("sale not found", code="not_found", status=404)
        if sale.status == "refunded":
            raise ConflictError("already refunded", server_payload={"sale_id": str(sale_id)})

        sale.status = "refunded"
        items = await self.db.execute(select(SaleItem).where(SaleItem.sale_id == sale_id))
        for item in items.scalars():
            self.db.add(InventoryLog(
                shop_id=self.shop_id,
                product_id=item.product_id,
                movement="refund",
                quantity_delta=item.quantity,
                reference_type="sale",
                reference_id=sale_id,
                user_id=self.user.id,
                created_at=datetime.now(UTC),
            ))
            await self.db.execute(
                Product.__table__.update()
                .where(Product.id == item.product_id)
                .values(stock=Product.stock + item.quantity, updated_at=datetime.now(UTC))
            )

    async def _product_create(self, p: dict[str, Any]) -> None:
        if await self.db.get(Product, UUID(p["id"])):
            return
        self.db.add(Product(
            id=UUID(p["id"]),
            shop_id=self.shop_id,
            name=p["name"],
            category=p.get("category"),
            purchase_price=Decimal(p.get("purchase_price", "0")),
            selling_price=Decimal(p["selling_price"]),
            stock=Decimal(p.get("stock", "0")),
            low_stock_threshold=Decimal(p.get("low_stock_threshold", "0")),
            unit=p.get("unit", "piece"),
            barcode=p.get("barcode"),
            image_url=p.get("image_url"),
            client_updated_at=datetime.fromisoformat(p["client_updated_at"]) if p.get("client_updated_at") else None,
        ))

    async def _product_update(self, p: dict[str, Any]) -> None:
        prod = await self.db.get(Product, UUID(p["id"]))
        if not prod:
            raise DomainError("product not found", code="not_found", status=404)

        client_ts = datetime.fromisoformat(p["client_updated_at"]) if p.get("client_updated_at") else None
        if client_ts and prod.client_updated_at and prod.client_updated_at >= client_ts:
            raise ConflictError(
                "newer server version exists",
                server_payload={
                    "id": str(prod.id),
                    "name": prod.name,
                    "selling_price": str(prod.selling_price),
                    "purchase_price": str(prod.purchase_price),
                    "stock": str(prod.stock),
                    "client_updated_at": prod.client_updated_at.isoformat(),
                },
            )

        for field in ("name", "category", "unit", "barcode", "image_url"):
            if field in p:
                setattr(prod, field, p[field])
        for field in ("purchase_price", "selling_price", "low_stock_threshold"):
            if field in p:
                setattr(prod, field, Decimal(p[field]))
        if client_ts:
            prod.client_updated_at = client_ts

    async def _product_delete(self, p: dict[str, Any]) -> None:
        prod = await self.db.get(Product, UUID(p["id"]))
        if not prod:
            return  # already gone — idempotent
        prod.deleted_at = datetime.now(UTC)

    async def _inventory_adjust(self, p: dict[str, Any]) -> None:
        product_id = UUID(p["product_id"])
        delta = Decimal(p["quantity_delta"])
        self.db.add(InventoryLog(
            shop_id=self.shop_id,
            product_id=product_id,
            movement="adjustment",
            quantity_delta=delta,
            reason=p.get("reason"),
            user_id=self.user.id,
            created_at=datetime.now(UTC),
        ))
        await self.db.execute(
            Product.__table__.update()
            .where(Product.id == product_id)
            .values(stock=Product.stock + delta, updated_at=datetime.now(UTC))
        )

    async def _debt_payment_create(self, p: dict[str, Any]) -> None:
        debt_id = UUID(p["debt_id"])
        debt = await self.db.get(Debt, debt_id)
        if not debt:
            raise DomainError("debt not found", code="not_found", status=404)
        amount = Decimal(p["amount"])
        remaining_before = debt.amount_owed - debt.amount_paid
        self.db.add(DebtPayment(
            id=UUID(p["id"]),
            debt_id=debt_id,
            shop_id=self.shop_id,
            shift_id=UUID(p["shift_id"]) if p.get("shift_id") else None,
            amount=amount,
            paid_at=datetime.fromisoformat(p["paid_at"]),
            method=p["method"],
            user_id=self.user.id,
            note=p.get("note"),
            created_at=datetime.now(UTC),
        ))
        debt.amount_paid = debt.amount_paid + amount
        if debt.amount_paid >= debt.amount_owed:
            debt.status = "paid"
        elif debt.amount_paid > 0:
            debt.status = "partial"

        # Per docs/06: "Sum, even if it overpays — flag in audit". Real-world:
        # two cashiers might collect on the same debt before sync converges.
        if amount > remaining_before:
            overpayment = amount - remaining_before
            self.db.add(AuditLog(
                shop_id=self.shop_id,
                user_id=self.user.id,
                action="debt.payment.overpayment",
                entity_type="debt",
                entity_id=debt_id,
                old_value={
                    "remaining": str(remaining_before),
                    "amount_owed": str(debt.amount_owed),
                },
                new_value={
                    "payment_amount": str(amount),
                    "overpayment": str(overpayment),
                    "method": p["method"],
                },
                device_id=self.device_id,
                note=(
                    f"Payment of {amount} exceeded remaining {remaining_before} "
                    f"by {overpayment}"
                ),
                created_at=datetime.now(UTC),
            ))

    async def _expense_create(self, p: dict[str, Any]) -> None:
        self.db.add(Expense(
            id=UUID(p["id"]),
            shop_id=self.shop_id,
            user_id=self.user.id,
            shift_id=UUID(p["shift_id"]) if p.get("shift_id") else None,
            title=p["title"],
            amount=Decimal(p["amount"]),
            category=p.get("category", "other"),
            description=p.get("description"),
            occurred_at=datetime.fromisoformat(p["occurred_at"]),
        ))

    async def _shift_open(self, p: dict[str, Any]) -> None:
        # Reject if another open shift exists for this user
        existing = await self.db.execute(
            select(Shift).where(Shift.user_id == self.user.id, Shift.closed_at.is_(None))
        )
        if existing.scalar_one_or_none():
            raise ConflictError("shift already open", server_payload={"user_id": str(self.user.id)})
        self.db.add(Shift(
            id=UUID(p["id"]),
            shop_id=self.shop_id,
            user_id=self.user.id,
            opened_at=datetime.fromisoformat(p["opened_at"]),
            opening_cash=Decimal(p["opening_cash"]),
            device_id=self.device_id,
            created_at=datetime.now(UTC),
            updated_at=datetime.now(UTC),
        ))

    async def _shift_close(self, p: dict[str, Any]) -> None:
        from app.services.shift_service import ShiftService
        shift_id = UUID(p["id"])
        declared = Decimal(p["declared_closing_cash"])
        note = p.get("note")
        await ShiftService(self.db, self.shop_id).close(shift_id, declared, note)

    async def _sale_void(self, p: dict[str, Any]) -> None:
        raise DomainError("sale.void is not yet supported", code="not_implemented")

    async def _supply_create(self, p: dict[str, Any]) -> None:
        if await self.db.get(Supply, UUID(p["id"])):
            return
        self.db.add(Supply(
            id=UUID(p["id"]),
            shop_id=self.shop_id,
            name=p["name"],
            unit=p.get("unit", "piece"),
            quantity_on_hand=Decimal(p.get("quantity_on_hand", "0")),
            reorder_threshold=Decimal(p.get("reorder_threshold", "0")),
            cost_per_unit=Decimal(p.get("cost_per_unit", "0")),
        ))

    async def _supply_update(self, p: dict[str, Any]) -> None:
        supply = await self.db.get(Supply, UUID(p["id"]))
        if not supply:
            raise DomainError("supply not found", code="not_found", status=404)
        for field in ("name", "unit"):
            if field in p:
                setattr(supply, field, p[field])
        for field in ("quantity_on_hand", "reorder_threshold", "cost_per_unit"):
            if field in p:
                setattr(supply, field, Decimal(p[field]))
        supply.updated_at = datetime.now(UTC)

    async def _supply_delete(self, p: dict[str, Any]) -> None:
        supply = await self.db.get(Supply, UUID(p["id"]))
        if supply:
            supply.deleted_at = datetime.now(UTC)

    async def _recipe_set(self, p: dict[str, Any]) -> None:
        """Replace a product's recipe atomically: delete old items, insert new ones."""
        product_id = UUID(p["product_id"])
        existing = await self.db.execute(
            select(RecipeItem).where(
                RecipeItem.product_id == product_id,
                RecipeItem.shop_id == self.shop_id,
            )
        )
        for row in existing.scalars():
            await self.db.delete(row)

        for item in p.get("items", []):
            self.db.add(RecipeItem(
                id=UUID(item["id"]),
                shop_id=self.shop_id,
                product_id=product_id,
                supply_id=UUID(item["supply_id"]),
                quantity=Decimal(item["quantity"]),
            ))
