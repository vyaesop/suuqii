"""
Sync engine — server side.

Replays client events into authoritative tables under a single transaction
per push request, with per-event idempotency.
"""
from __future__ import annotations

import logging
import time
from datetime import UTC, date, datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ConflictError, DomainError, OwnerPinRequired
from app.core.security import decode_token
from app.core.units import convert_unit
from app.models import (
    AuditLog,
    Debt,
    DebtPayment,
    Expense,
    InventoryLog,
    Product,
    RecipeItem,
    LotConsumption,
    Sale,
    SaleItem,
    Shop,
    Shift,
    StockLot,
    Supply,
    SyncEvent,
    User,
)
from app.schemas.sync import SyncEventIn, SyncResultOut, SyncResultStatus

logger = logging.getLogger(__name__)

_CENT = Decimal("0.01")


def _parse_dt(value: str) -> datetime:
    """Parse an ISO timestamp from a client payload, coercing naive → UTC.

    Client clocks are untrusted; a naive timestamp stored into TIMESTAMPTZ
    would otherwise be interpreted by the driver's local zone.
    """
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


SENSITIVE_OPS = {
    "product.create",
    "product.update",
    "product.delete",
    "inventory.adjust",
    "debt.writeoff",
    "sale.refund",
    # expense.create is NOT blanket-sensitive; threshold-based check in handler
    "supply.create",
    "supply.update",
    "supply.delete",
    # Lot/spoilage ops move inventory definitions and are a shrinkage vector
    # ("spoil" 5 breads, pocket the cash) — PIN-gated for cashiers, audited.
    "stock.receive",
    "stock.spoil",
    "production.record",
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
        # Challenge tokens are shop-scoped: a PIN verified in shop A must not
        # authorize sensitive ops in shop B.
        if payload.get("shop_id") != str(self.shop_id):
            return None
        nonce = payload.get("nonce", "")
        exp = float(payload.get("exp", 0))
        if not _consume_nonce(nonce, exp):
            return None
        return UUID(payload["sub"])

    def _resolve_challenge(self, payload: dict[str, Any]) -> UUID | None:
        """Resolve a per-event or batch-level challenge token."""
        per_event_token: str | None = payload.get("owner_challenge")
        if per_event_token:
            return self._authorize_challenge(per_event_token)
        return self._batch_challenge_id

    async def apply(self, event: SyncEventIn) -> SyncResultOut:
        existing = await self._existing_event(event.client_event_id)
        if existing is not None:
            return SyncResultOut(client_event_id=event.client_event_id, status=SyncResultStatus.DUPLICATE)

        if event.op in SENSITIVE_OPS and self.user.role != "owner":
            challenge_id = self._resolve_challenge(event.payload)
            if challenge_id is None:
                return SyncResultOut(
                    client_event_id=event.client_event_id,
                    status=SyncResultStatus.REJECTED,
                    code="owner_pin_required",
                )

        # Each event runs inside its own SAVEPOINT. A handler may mutate the
        # session before deciding to reject; without the savepoint those
        # partial writes would survive into the batch commit even though the
        # client is told the event was rejected. The flush inside the
        # savepoint also surfaces FK/unique violations *here* (the session is
        # autoflush=False) instead of at the endpoint's commit, where they
        # would 500 the whole batch and abort the outer transaction.
        try:
            async with self.db.begin_nested():
                handler = self._handler_for(event.op)
                await handler(event.payload)
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
                await self.db.flush()
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
        except IntegrityError as e:
            # FK or unique violation — most likely a referenced entity (product,
            # supply) hasn't synced yet, or the same client_event_id appeared
            # twice in one batch. Return CONFLICT so the batch doesn't 500 and
            # the event can be retried once dependencies land.
            return SyncResultOut(client_event_id=event.client_event_id,
                                 status=SyncResultStatus.CONFLICT,
                                 code="integrity_error", detail=str(e.orig))
        except (KeyError, ValueError, TypeError, InvalidOperation) as e:
            # Malformed payload. Reject just this event — a single corrupt
            # queued event must never block the rest of the device's queue.
            return SyncResultOut(client_event_id=event.client_event_id,
                                 status=SyncResultStatus.REJECTED,
                                 code="invalid_payload",
                                 detail=f"{type(e).__name__}: {e}")
        except Exception:
            logger.exception("sync handler failed op=%s event=%s", event.op, event.client_event_id)
            return SyncResultOut(client_event_id=event.client_event_id,
                                 status=SyncResultStatus.REJECTED,
                                 code="internal_error",
                                 detail="unexpected server error applying event")

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
            "debt.writeoff": self._debt_writeoff,
            "expense.create": self._expense_create,
            "shift.open": self._shift_open,
            "shift.close": self._shift_close,
            "stock.receive": self._stock_receive,
            "stock.spoil": self._stock_spoil,
            "production.record": self._production_record,
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

    # ---------- lots (docs/16-inventory-lots.md) ----------

    async def _get_shop_product(self, product_id: UUID) -> Product | None:
        prod = await self.db.get(Product, product_id)
        if prod is None or prod.shop_id != self.shop_id:
            return None
        return prod

    async def _open_lots(self, product_id: UUID) -> list[StockLot]:
        """Open lots in FEFO order: earliest expiry first (NULLs last), then FIFO."""
        rows = await self.db.execute(
            select(StockLot)
            .where(
                StockLot.shop_id == self.shop_id,
                StockLot.product_id == product_id,
                StockLot.qty_remaining > 0,
            )
            .order_by(
                StockLot.expiry_date.is_(None),
                StockLot.expiry_date.asc(),
                StockLot.received_at.asc(),
                StockLot.id.asc(),
            )
            .with_for_update()
        )
        return list(rows.scalars())

    async def _consume_lots(
        self,
        product_id: UUID,
        qty: Decimal,
        *,
        movement: str,
        fallback_cost: Decimal,
        sale_item_id: UUID | None = None,
        lot: StockLot | None = None,
    ) -> Decimal:
        """Consume qty from lots (a specific one, or FEFO). Returns the
        weighted unit cost of what was consumed.

        Consumption beyond available lots (oversell — allowed by design,
        docs/06) is costed at fallback_cost and leaves no consumption row
        since there is no lot to draw from.
        """
        now = datetime.now(UTC)
        remaining = qty
        cost_accum = Decimal("0")
        lots = [lot] if lot is not None else await self._open_lots(product_id)
        for candidate in lots:
            if remaining <= 0:
                break
            take = min(candidate.qty_remaining, remaining)
            if take <= 0:
                continue
            candidate.qty_remaining = candidate.qty_remaining - take
            remaining -= take
            cost_accum += take * candidate.unit_cost
            self.db.add(LotConsumption(
                shop_id=self.shop_id,
                lot_id=candidate.id,
                sale_item_id=sale_item_id,
                movement=movement,
                quantity=take,
                unit_cost=candidate.unit_cost,
                consumed_at=now,
            ))
        if remaining > 0:
            cost_accum += remaining * fallback_cost
        if qty <= 0:
            return fallback_cost
        return (cost_accum / qty).quantize(_CENT, rounding=ROUND_HALF_UP)

    @staticmethod
    def _parse_expiry(p: dict[str, Any]) -> date | None:
        raw = p.get("expiry_date")
        return date.fromisoformat(raw) if raw else None

    async def _stock_receive(self, p: dict[str, Any]) -> None:
        """Receive a batch: creates a stock lot. Optional spoiled_quantity is
        drawn back out of the new lot immediately (breakage on arrival,
        burnt batch, ...)."""
        lot_id = UUID(p["id"])
        if await self.db.get(StockLot, lot_id):
            return  # idempotent
        product = await self._get_shop_product(UUID(p["product_id"]))
        if product is None:
            raise DomainError("product not found", code="not_found", status=404)

        quantity = Decimal(p["quantity"])
        spoiled = Decimal(p.get("spoiled_quantity", "0"))
        unit_cost = Decimal(p["unit_cost"]).quantize(_CENT, rounding=ROUND_HALF_UP)
        if quantity <= 0 or spoiled < 0 or spoiled > quantity or unit_cost < 0:
            raise DomainError("invalid receive quantities", code="invalid_payload")

        occurred = _parse_dt(p["occurred_at"])
        lot = StockLot(
            id=lot_id,
            shop_id=self.shop_id,
            product_id=product.id,
            qty_received=quantity,
            qty_remaining=quantity,
            unit_cost=unit_cost,
            expiry_date=self._parse_expiry(p),
            received_at=occurred,
            note=p.get("note"),
            created_by=self.user.id,
        )
        self.db.add(lot)
        # Flush before any LotConsumption references the lot: without
        # relationship() constructs SQLAlchemy does not guarantee cross-mapper
        # insert ordering, and the consumption FK would race the lot insert.
        await self.db.flush()
        self.db.add(InventoryLog(
            shop_id=self.shop_id,
            product_id=product.id,
            movement="receive",
            quantity_delta=quantity,
            reason=p.get("note"),
            reference_type="stock_lot",
            reference_id=lot_id,
            user_id=self.user.id,
            created_at=datetime.now(UTC),
        ))
        net = quantity
        if spoiled > 0:
            await self._consume_lots(
                product.id, spoiled, movement="spoilage",
                fallback_cost=unit_cost, lot=lot,
            )
            self.db.add(InventoryLog(
                shop_id=self.shop_id,
                product_id=product.id,
                movement="spoilage",
                quantity_delta=-spoiled,
                reason="spoiled on receive",
                reference_type="stock_lot",
                reference_id=lot_id,
                user_id=self.user.id,
                created_at=datetime.now(UTC),
            ))
            net = quantity - spoiled

        # Stock reflects sellable units; purchase_price tracks last cost so
        # the product card shows the newest batch's economics. Stock moves by
        # delta expression (never read-modify-write) so concurrent device
        # pushes sum correctly.
        await self.db.execute(
            Product.__table__.update()
            .where(Product.id == product.id)
            .values(stock=Product.stock + net,
                    purchase_price=unit_cost,
                    updated_at=datetime.now(UTC))
        )

    async def _stock_spoil(self, p: dict[str, Any]) -> None:
        """Record spoilage/waste after the fact (expired, broken, day-old).
        Consumes FEFO, or from a specific lot when lot_id is given."""
        product = await self._get_shop_product(UUID(p["product_id"]))
        if product is None:
            raise DomainError("product not found", code="not_found", status=404)
        quantity = Decimal(p["quantity"])
        if quantity <= 0:
            raise DomainError("spoil quantity must be positive", code="invalid_payload")

        target_lot: StockLot | None = None
        if p.get("lot_id"):
            target_lot = await self.db.get(StockLot, UUID(p["lot_id"]))
            if target_lot is None or target_lot.shop_id != self.shop_id:
                raise DomainError("lot not found", code="not_found", status=404)

        unit_cost = await self._consume_lots(
            product.id, quantity, movement="spoilage",
            fallback_cost=product.purchase_price, lot=target_lot,
        )
        self.db.add(InventoryLog(
            shop_id=self.shop_id,
            product_id=product.id,
            movement="spoilage",
            quantity_delta=-quantity,
            reason=p.get("reason"),
            user_id=self.user.id,
            created_at=datetime.now(UTC),
        ))
        await self.db.execute(
            Product.__table__.update()
            .where(Product.id == product.id)
            .values(stock=Product.stock - quantity, updated_at=datetime.now(UTC))
        )

        self.db.add(AuditLog(
            shop_id=self.shop_id,
            user_id=self.user.id,
            action="stock.spoilage",
            entity_type="product",
            entity_id=product.id,
            new_value={
                "quantity": str(quantity),
                "unit_cost": str(unit_cost),
                "value": str((quantity * unit_cost).quantize(_CENT, rounding=ROUND_HALF_UP)),
                "reason": p.get("reason"),
            },
            device_id=self.device_id,
            created_at=datetime.now(UTC),
        ))

    async def _production_record(self, p: dict[str, Any]) -> None:
        """Bakery: record a day's production of a sellable product, with a
        spoiled count. Creates a production lot valued at recipe cost.

        Spoiled units deduct ingredient supplies here — sold units deduct at
        sale time (the bakery flow), but spoiled units never reach a sale, so
        without this the ingredient counts drift upward forever.
        """
        shop = await self.db.get(Shop, self.shop_id)
        if shop is None or shop.shop_type != "bakery":
            raise DomainError("production.record is bakery-only", code="bad_shop_type")
        lot_id = UUID(p["id"])
        if await self.db.get(StockLot, lot_id):
            return  # idempotent
        product = await self._get_shop_product(UUID(p["product_id"]))
        if product is None:
            raise DomainError("product not found", code="not_found", status=404)

        produced = Decimal(p["quantity_produced"])
        spoiled = Decimal(p.get("quantity_spoiled", "0"))
        if produced <= 0 or spoiled < 0 or spoiled > produced:
            raise DomainError("invalid production quantities", code="invalid_payload")

        # Recipe cost per unit = Σ ingredient qty (converted to the supply's
        # stocked unit — recipe may say 100 g while flour is tracked in kg)
        # × supply cost. Mirrors the client's sale-time computation.
        recipe = (await self.db.execute(
            select(RecipeItem).where(
                RecipeItem.shop_id == self.shop_id,
                RecipeItem.product_id == product.id,
            )
        )).scalars().all()
        unit_cost = Decimal("0")
        supply_qty_per_unit: dict[UUID, Decimal] = {}
        for item in recipe:
            supply = await self.db.get(Supply, item.supply_id)
            if supply is not None:
                effective_unit = item.recipe_unit or supply.unit
                qty_in_supply_unit = convert_unit(item.quantity, effective_unit, supply.unit)
                supply_qty_per_unit[item.supply_id] = qty_in_supply_unit
                unit_cost += qty_in_supply_unit * supply.cost_per_unit
        unit_cost = unit_cost.quantize(_CENT, rounding=ROUND_HALF_UP)

        occurred = _parse_dt(p["occurred_at"])
        lot = StockLot(
            id=lot_id,
            shop_id=self.shop_id,
            product_id=product.id,
            qty_received=produced,
            qty_remaining=produced,
            unit_cost=unit_cost,
            expiry_date=self._parse_expiry(p),
            received_at=occurred,
            note=p.get("note") or "production",
            created_by=self.user.id,
        )
        self.db.add(lot)
        await self.db.flush()  # consumption FK must not race the lot insert
        self.db.add(InventoryLog(
            shop_id=self.shop_id,
            product_id=product.id,
            movement="production",
            quantity_delta=produced,
            reference_type="stock_lot",
            reference_id=lot_id,
            user_id=self.user.id,
            created_at=datetime.now(UTC),
        ))

        if spoiled > 0:
            await self._consume_lots(
                product.id, spoiled, movement="spoilage",
                fallback_cost=unit_cost, lot=lot,
            )
            self.db.add(InventoryLog(
                shop_id=self.shop_id,
                product_id=product.id,
                movement="spoilage",
                quantity_delta=-spoiled,
                reason="spoiled in production",
                reference_type="stock_lot",
                reference_id=lot_id,
                user_id=self.user.id,
                created_at=datetime.now(UTC),
            ))
            # Ingredients consumed by units that will never be sold.
            for item in recipe:
                per_unit = supply_qty_per_unit.get(item.supply_id, item.quantity)
                await self.db.execute(
                    Supply.__table__.update()
                    .where(Supply.id == item.supply_id, Supply.shop_id == self.shop_id)
                    .values(
                        quantity_on_hand=Supply.quantity_on_hand - (per_unit * spoiled),
                        updated_at=datetime.now(UTC),
                    )
                )

        await self.db.execute(
            Product.__table__.update()
            .where(Product.id == product.id)
            .values(stock=Product.stock + (produced - spoiled),
                    updated_at=datetime.now(UTC))
        )

    async def _sale_create(self, p: dict[str, Any]) -> None:
        sale_id = UUID(p["id"])
        # Idempotent: if a sale with this id already exists, treat as duplicate
        existing = await self.db.get(Sale, sale_id)
        if existing:
            return

        items = p["items"]
        if not items:
            raise DomainError("sale has no items", code="invalid_payload")

        # Money totals are recomputed server-side from the line items — never
        # trusted from the client. P&L, margins and shift reconciliation are
        # built on these numbers; a buggy or tampered client must not be able
        # to set them arbitrarily.
        subtotal = sum(
            (Decimal(i["quantity"]) * Decimal(i["unit_price"]) for i in items),
            Decimal("0"),
        ).quantize(_CENT, rounding=ROUND_HALF_UP)
        cost_total = sum(
            (Decimal(i["quantity"]) * Decimal(i["unit_cost"]) for i in items),
            Decimal("0"),
        ).quantize(_CENT, rounding=ROUND_HALF_UP)
        discount = Decimal(p.get("discount", "0")).quantize(_CENT, rounding=ROUND_HALF_UP)
        if discount < 0 or discount > subtotal:
            raise DomainError("discount out of range", code="invalid_payload")
        total = subtotal - discount

        client_total = Decimal(p.get("total", total))
        if (client_total - total).copy_abs() > _CENT:
            self.db.add(AuditLog(
                shop_id=self.shop_id,
                user_id=self.user.id,
                action="sale.total_mismatch",
                entity_type="sale",
                entity_id=sale_id,
                old_value={"client_total": str(client_total)},
                new_value={"server_total": str(total)},
                device_id=self.device_id,
                note="client-declared total differs from server recomputation",
                created_at=datetime.now(UTC),
            ))

        sale = Sale(
            id=sale_id,
            shop_id=self.shop_id,
            shift_id=UUID(p["shift_id"]) if p.get("shift_id") else None,
            user_id=self.user.id,
            subtotal=subtotal,
            discount=discount,
            total=total,
            cost_total=cost_total,
            payment_method=p["payment_method"],
            status=p.get("status", "completed"),
            device_id=self.device_id,
            occurred_at=_parse_dt(p["occurred_at"]),
            created_at=datetime.now(UTC),
        )
        self.db.add(sale)

        shop = await self.db.get(Shop, self.shop_id)
        is_bakery = shop is not None and shop.shop_type == "bakery"

        lot_cost_total = Decimal("0")
        for item in items:
            item_id = UUID(item["id"])
            qty = Decimal(item["quantity"])
            unit_cost = Decimal(item["unit_cost"])
            if not is_bakery:
                # COGS comes from the batches actually consumed (FEFO), not
                # from whatever cost the client had cached. The client's
                # unit_cost is only the fallback for unlotted stock.
                unit_cost = await self._consume_lots(
                    UUID(item["product_id"]), qty,
                    movement="sale",
                    fallback_cost=unit_cost,
                    sale_item_id=item_id,
                )
            lot_cost_total += qty * unit_cost
            self.db.add(SaleItem(
                id=item_id,
                sale_id=sale_id,
                product_id=UUID(item["product_id"]),
                product_name_snapshot=item["product_name_snapshot"],
                quantity=qty,
                unit_price=Decimal(item["unit_price"]),
                unit_cost=unit_cost,
            ))
            if not is_bakery:
                # delta-based stock decrement + ledger (skipped for bakery —
                # ingredient supplies are decremented via supply_deductions)
                self.db.add(InventoryLog(
                    shop_id=self.shop_id,
                    product_id=UUID(item["product_id"]),
                    movement="sale",
                    quantity_delta=-qty,
                    reference_type="sale",
                    reference_id=sale_id,
                    user_id=self.user.id,
                    created_at=datetime.now(UTC),
                ))
                await self.db.execute(
                    Product.__table__.update()
                    .where(Product.id == UUID(item["product_id"]))
                    .values(stock=Product.stock - qty,
                            updated_at=datetime.now(UTC))
                )
        sale.cost_total = lot_cost_total.quantize(_CENT, rounding=ROUND_HALF_UP)

        if p["payment_method"] == "credit":
            cust = p.get("customer", {})
            sale_total = total
            customer_phone = cust.get("phone")

            # Per-customer cumulative credit exposure check.
            # Sum all open/partial debts for this phone number and block if
            # adding this sale would exceed the shop's debt_threshold.
            if customer_phone and shop is not None:
                existing_outstanding = (await self.db.execute(
                    select(func.coalesce(func.sum(Debt.amount_owed - Debt.amount_paid), 0))
                    .where(
                        Debt.shop_id == self.shop_id,
                        Debt.customer_phone == customer_phone,
                        Debt.status.in_(["open", "partial"]),
                        Debt.deleted_at.is_(None),
                    )
                )).scalar_one()
                cumulative = Decimal(existing_outstanding) + sale_total
                if cumulative > shop.debt_threshold:
                    # Requires owner PIN — the challenge was already validated
                    # for ops in SENSITIVE_OPS; credit sales above threshold
                    # need PIN regardless of role.
                    if self.user.role != "owner" and self._resolve_challenge(p) is None:
                        raise OwnerPinRequired(
                            f"Customer {customer_phone} would have "
                            f"{cumulative} outstanding (threshold {shop.debt_threshold}). "
                            "Owner PIN required.",
                            code="customer_credit_limit_exceeded",
                        )

            self.db.add(Debt(
                id=UUID(p["debt_id"]) if p.get("debt_id") else None,
                shop_id=self.shop_id,
                sale_id=sale_id,
                customer_name=cust.get("name", "Unknown"),
                customer_phone=customer_phone,
                amount_owed=sale_total,
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

        shop = await self.db.get(Shop, self.shop_id)
        is_bakery = shop is not None and shop.shop_type == "bakery"

        items = await self.db.execute(select(SaleItem).where(SaleItem.sale_id == sale_id))
        for item in items.scalars():
            if not is_bakery:
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
                # Return quantities to the exact lots this item consumed so
                # batch reports stay truthful after refunds.
                consumptions = (await self.db.execute(
                    select(LotConsumption).where(
                        LotConsumption.shop_id == self.shop_id,
                        LotConsumption.sale_item_id == item.id,
                        LotConsumption.movement == "sale",
                    )
                )).scalars().all()
                now = datetime.now(UTC)
                for c in consumptions:
                    lot = await self.db.get(StockLot, c.lot_id)
                    if lot is not None:
                        lot.qty_remaining = lot.qty_remaining + c.quantity
                    self.db.add(LotConsumption(
                        shop_id=self.shop_id,
                        lot_id=c.lot_id,
                        sale_item_id=item.id,
                        movement="refund_reversal",
                        quantity=-c.quantity,
                        unit_cost=c.unit_cost,
                        consumed_at=now,
                    ))

        # Bakery: restore ingredient supplies consumed by the original sale.
        # The original sale.create sync event carries the supply_deductions payload.
        if is_bakery:
            original_event = await self.db.execute(
                select(SyncEvent).where(
                    SyncEvent.shop_id == self.shop_id,
                    SyncEvent.op == "sale.create",
                    SyncEvent.payload["id"].astext == str(sale_id),
                ).order_by(SyncEvent.id).limit(1)
            )
            ev = original_event.scalars().first()
            if ev is not None:
                for ded in ev.payload.get("supply_deductions", []):
                    supply_id = UUID(ded["supply_id"])
                    delta = Decimal(ded["quantity_delta"])  # negative — reverse it
                    await self.db.execute(
                        Supply.__table__.update()
                        .where(Supply.id == supply_id, Supply.shop_id == self.shop_id)
                        .values(
                            quantity_on_hand=Supply.quantity_on_hand - delta,
                            updated_at=datetime.now(UTC),
                        )
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
            client_updated_at=_parse_dt(p["client_updated_at"]) if p.get("client_updated_at") else None,
        ))

    async def _product_update(self, p: dict[str, Any]) -> None:
        prod = await self.db.get(Product, UUID(p["id"]))
        if not prod:
            raise DomainError("product not found", code="not_found", status=404)

        client_ts = _parse_dt(p["client_updated_at"]) if p.get("client_updated_at") else None
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
        # Keep the lot invariant (stock ≈ Σ qty_remaining): count corrections
        # create an adjustment lot at last cost; shrinkage consumes FEFO.
        product = await self._get_shop_product(product_id)
        if product is not None:
            if delta > 0:
                self.db.add(StockLot(
                    shop_id=self.shop_id,
                    product_id=product_id,
                    qty_received=delta,
                    qty_remaining=delta,
                    unit_cost=product.purchase_price,
                    received_at=datetime.now(UTC),
                    note=p.get("reason") or "adjustment",
                    created_by=self.user.id,
                ))
            elif delta < 0:
                await self._consume_lots(
                    product_id, -delta, movement="adjustment",
                    fallback_cost=product.purchase_price,
                )
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
            paid_at=_parse_dt(p["paid_at"]),
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

    async def _debt_writeoff(self, p: dict[str, Any]) -> None:
        """Write off a debt: mark as written_off and book the uncollected balance
        as a bad-debt expense so the P&L reflects the actual loss."""
        debt_id = UUID(p["debt_id"])
        debt = await self.db.get(Debt, debt_id)
        if not debt:
            raise DomainError("debt not found", code="not_found", status=404)
        if debt.status == "written_off":
            return  # idempotent
        if debt.status == "paid":
            raise ConflictError(
                "debt is already paid — nothing to write off",
                server_payload={"debt_id": str(debt_id)},
            )

        remaining = debt.amount_owed - debt.amount_paid
        old_status = debt.status
        debt.status = "written_off"

        # Auto-create a bad-debt expense so the write-off is visible in the P&L
        # net profit calculation. shift_id=None so it does NOT enter cash
        # reconciliation (the debt was never collected as cash).
        if remaining > Decimal("0"):
            self.db.add(Expense(
                shop_id=self.shop_id,
                user_id=self.user.id,
                shift_id=None,
                title=f"Bad debt write-off: {debt.customer_name}",
                amount=remaining,
                category="other",
                description=(
                    f"Uncollected balance on debt {debt_id} "
                    f"(customer: {debt.customer_name}, "
                    f"phone: {debt.customer_phone or 'N/A'})"
                ),
                occurred_at=datetime.now(UTC),
            ))

        self.db.add(AuditLog(
            shop_id=self.shop_id,
            user_id=self.user.id,
            action="debt.writeoff",
            entity_type="debt",
            entity_id=debt_id,
            old_value={"status": old_status, "amount_owed": str(debt.amount_owed),
                       "amount_paid": str(debt.amount_paid)},
            new_value={"status": "written_off", "written_off_amount": str(remaining)},
            device_id=self.device_id,
            created_at=datetime.now(UTC),
        ))

    async def _expense_create(self, p: dict[str, Any]) -> None:
        amount = Decimal(p["amount"])

        # Threshold-based PIN check: cashiers can create small expenses freely;
        # anything above the shop's expense_approval_threshold needs owner PIN.
        if self.user.role != "owner":
            shop = await self.db.get(Shop, self.shop_id)
            threshold = shop.expense_approval_threshold if shop else Decimal("500.00")
            if amount > threshold:
                challenge_id = self._resolve_challenge(p)
                if challenge_id is None:
                    raise OwnerPinRequired(
                        f"Expense of {amount} exceeds approval threshold {threshold}. "
                        "Owner PIN required.",
                        code="expense_approval_required",
                    )

        self.db.add(Expense(
            id=UUID(p["id"]),
            shop_id=self.shop_id,
            user_id=self.user.id,
            shift_id=UUID(p["shift_id"]) if p.get("shift_id") else None,
            title=p["title"],
            amount=amount,
            category=p.get("category", "other"),
            description=p.get("description"),
            occurred_at=_parse_dt(p["occurred_at"]),
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
            opened_at=_parse_dt(p["opened_at"]),
            opening_cash=Decimal(p["opening_cash"]),
            device_id=self.device_id,
            created_at=datetime.now(UTC),
            updated_at=datetime.now(UTC),
        ))

    async def _shift_close(self, p: dict[str, Any]) -> None:
        from app.services.shift_service import ShiftService
        shift_id = UUID(p["id"])
        # Cashiers may only close their own shift; the owner recovery path is
        # the force-close endpoint (docs/17-roles.md).
        shift = await self.db.get(Shift, shift_id)
        if (shift is not None and self.user.role != "owner"
                and shift.user_id != self.user.id):
            raise DomainError("cannot close another user's shift", code="forbidden", status=403)
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
            expiry_date=self._parse_expiry(p),
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
        if "expiry_date" in p:
            supply.expiry_date = self._parse_expiry(p)
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
                recipe_unit=item.get("recipe_unit"),
            ))
