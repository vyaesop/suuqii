from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import exists, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ConflictError, DomainError
from app.models import DebtPayment, Expense, Sale, SaleReturn, Shift


class ShiftService:
    def __init__(self, db: AsyncSession, shop_id: UUID):
        self.db = db
        self.shop_id = shop_id

    async def expected_cash(self, shift_id: UUID, opening_cash: Decimal) -> Decimal:
        # docs/13. Two refund paths feed this:
        #
        # * legacy `sale.refund` flips the sale to 'refunded' and leaves no
        #   sale_returns row; it is counted below as the whole sale total
        #   against the *original sale's* shift (unchanged behaviour).
        # * `sale.return` (docs/19) writes a sale_returns row with the cash
        #   actually handed back and the shift it left the till in. Such a
        #   sale stays in cash_sales at its full total (the customer paid it
        #   all) — even when every line is eventually returned and it reads
        #   'refunded' — and the returns term subtracts what went back out.
        # Keeping the two paths disjoint is what stops a fully returned sale
        # being subtracted twice.
        has_returns = exists().where(SaleReturn.sale_id == Sale.id)
        cash_sales = (await self.db.execute(
            select(func.coalesce(func.sum(Sale.total), 0)).where(
                Sale.shift_id == shift_id,
                Sale.payment_method == "cash",
                Sale.deleted_at.is_(None),
                Sale.status.in_(["completed", "partially_returned"])
                | ((Sale.status == "refunded") & has_returns),
            )
        )).scalar_one()
        cash_refunds = (await self.db.execute(
            select(func.coalesce(func.sum(Sale.total), 0)).where(
                Sale.shift_id == shift_id,
                Sale.payment_method == "cash",
                Sale.status == "refunded",
                ~has_returns,
            )
        )).scalar_one()
        cash_returned = (await self.db.execute(
            select(func.coalesce(func.sum(SaleReturn.refund_amount), 0)).where(
                SaleReturn.shift_id == shift_id,
                SaleReturn.refund_method == "cash",
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
            - Decimal(cash_returned)
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
