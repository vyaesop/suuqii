from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ConflictError, DomainError
from app.models import DebtPayment, Expense, Sale, Shift


class ShiftService:
    def __init__(self, db: AsyncSession, shop_id: UUID):
        self.db = db
        self.shop_id = shop_id

    async def expected_cash(self, shift_id: UUID, opening_cash: Decimal) -> Decimal:
        cash_sales = (await self.db.execute(
            select(func.coalesce(func.sum(Sale.total), 0)).where(
                Sale.shift_id == shift_id,
                Sale.payment_method == "cash",
                Sale.status == "completed",
                Sale.deleted_at.is_(None),
            )
        )).scalar_one()
        cash_refunds = (await self.db.execute(
            select(func.coalesce(func.sum(Sale.total), 0)).where(
                Sale.shift_id == shift_id,
                Sale.payment_method == "cash",
                Sale.status == "refunded",
            )
        )).scalar_one()
        debt_collected = (await self.db.execute(
            select(func.coalesce(func.sum(DebtPayment.amount), 0)).where(
                DebtPayment.shift_id == shift_id,
                DebtPayment.method == "cash",
            )
        )).scalar_one()
        cash_expenses = (await self.db.execute(
            select(func.coalesce(func.sum(Expense.amount), 0)).where(
                Expense.shift_id == shift_id,
                Expense.deleted_at.is_(None),
            )
        )).scalar_one()

        return (
            Decimal(opening_cash)
            + Decimal(cash_sales)
            + Decimal(debt_collected)
            - Decimal(cash_expenses)
            - Decimal(cash_refunds)
        )

    async def close(self, shift_id: UUID, declared: Decimal, note: str | None) -> Shift:
        shift = await self.db.get(Shift, shift_id)
        if not shift:
            raise DomainError("shift not found", code="not_found", status=404)
        if shift.closed_at is not None:
            raise ConflictError("shift already closed",
                                server_payload={"id": str(shift.id),
                                                "closed_at": shift.closed_at.isoformat()})

        expected = await self.expected_cash(shift_id, shift.opening_cash)
        shift.declared_closing_cash = declared
        shift.expected_closing_cash = expected
        shift.closed_at = datetime.now(UTC)
        if note:
            shift.note = note
        return shift
