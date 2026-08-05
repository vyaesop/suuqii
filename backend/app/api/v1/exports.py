"""
CSV in and out (docs/20-csv.md).

Shops arriving from a spreadsheet need their history to come with them, and
they need to be able to get their data back out — an app you cannot export from
reads as a trap, however good it is. Both directions are deliberately plain
CSV: the target audience opens these in Google Sheets, not in a BI tool.

Exports stream so a year of sales does not have to fit in memory.
"""
import csv
import io
from datetime import UTC, datetime, timedelta
from decimal import Decimal, InvalidOperation
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.capabilities import MANAGE_PRODUCTS, VIEW_COSTS, VIEW_REPORTS, can
from app.core.deps import current_user, db_session
from app.models import AuditLog, InventoryLog, Product, Sale, SaleItem, User

router = APIRouter(prefix="/export", tags=["export"])

# Uploads are read fully into memory to be parsed, so the ceiling is a real
# constraint, not a formality. 2 MB is ~20k product rows.
_MAX_IMPORT_BYTES = 2 * 1024 * 1024
_MAX_IMPORT_ROWS = 5000


def _csv_response(filename: str, header: list[str], rows) -> StreamingResponse:
    """Stream rows as CSV.

    A UTF-8 BOM is written first: without it Excel mis-reads Amharic and Afaan
    Oromo product names as mojibake, which is most of what these files contain.
    """
    def generate():
        buf = io.StringIO()
        writer = csv.writer(buf)
        buf.write("﻿")
        writer.writerow(header)
        yield buf.getvalue()
        buf.seek(0)
        buf.truncate(0)
        for row in rows:
            writer.writerow(row)
            yield buf.getvalue()
            buf.seek(0)
            buf.truncate(0)

    stamp = datetime.now(UTC).strftime("%Y%m%d")
    return StreamingResponse(
        generate(),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}-{stamp}.csv"',
        },
    )


def _range_start(range_: str) -> datetime:
    days = {"7d": 7, "30d": 30, "90d": 90, "365d": 365}[range_]
    return datetime.now(UTC) - timedelta(days=days)


@router.get("/sales.csv")
async def export_sales(
    range_: Literal["7d", "30d", "90d", "365d"] = Query("30d", alias="range"),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """One row per sale line — the grain a shop owner actually reconciles at.

    Owner-only: it carries unit cost and margin.
    """
    if not can(user.role, VIEW_REPORTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

    rows = (await db.execute(
        select(Sale, SaleItem)
        .join(SaleItem, SaleItem.sale_id == Sale.id)
        .where(
            Sale.shop_id == user.shop_id,
            Sale.deleted_at.is_(None),
            Sale.occurred_at >= _range_start(range_),
        )
        .order_by(Sale.occurred_at, Sale.id)
    )).all()

    def gen():
        for sale, item in rows:
            line_total = item.quantity * item.unit_price
            line_cost = item.quantity * item.unit_cost
            yield [
                sale.occurred_at.date().isoformat(),
                sale.occurred_at.time().isoformat(timespec="minutes"),
                str(sale.id),
                item.product_name_snapshot,
                str(item.quantity),
                str(item.unit_price),
                str(line_total),
                str(item.unit_cost),
                str(line_total - line_cost),
                sale.payment_method,
                sale.status,
                str(sale.user_id),
            ]

    return _csv_response(
        "sales",
        ["date", "time", "sale_id", "product", "quantity", "unit_price",
         "line_total", "unit_cost", "line_profit", "payment_method",
         "status", "user_id"],
        gen(),
    )


@router.get("/products.csv")
async def export_products(
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
):
    """The product list, in exactly the shape /export/products/import accepts.

    Round-tripping matters: this is the file an owner edits in Sheets and
    uploads back. Cost prices are blanked for anyone without VIEW_COSTS.
    """
    show_costs = can(user.role, VIEW_COSTS)
    rows = (await db.execute(
        select(Product)
        .where(Product.shop_id == user.shop_id, Product.deleted_at.is_(None))
        .order_by(Product.name)
    )).scalars().all()

    def gen():
        for p in rows:
            yield [
                p.name,
                p.category or "",
                str(p.selling_price),
                str(p.purchase_price) if show_costs else "",
                str(p.stock),
                str(p.low_stock_threshold),
                p.unit,
                p.barcode or "",
            ]

    return _csv_response(
        "products",
        ["name", "category", "selling_price", "purchase_price", "stock",
         "low_stock_threshold", "unit", "barcode"],
        gen(),
    )


class ImportRowError(BaseModel):
    row: int
    message: str


class ImportResult(BaseModel):
    created: int
    updated: int
    skipped: int
    errors: list[ImportRowError]
    committed: bool


def _decimal(raw: str, field: str, *, default: str = "0") -> Decimal:
    text = (raw or "").strip().replace(",", "")
    if not text:
        text = default
    try:
        value = Decimal(text)
    except InvalidOperation as e:
        raise ValueError(f"{field}: '{raw}' is not a number") from e
    if value < 0:
        raise ValueError(f"{field} must not be negative")
    return value


@router.post("/products/import", response_model=ImportResult)
async def import_products(
    file: UploadFile,
    dry_run: bool = Query(True),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> ImportResult:
    """Create or update products from a CSV.

    Matched on `name` within the shop — spreadsheets have no stable ids, and
    the name is what the owner thinks of as the product's identity.

    Defaults to **dry_run**: the file is parsed and validated and you get the
    counts and per-row errors back without anything being written. A partly
    applied import of somebody's whole catalogue is much worse than a rejected
    one, so the real run is all-or-nothing — any row error aborts the batch.
    """
    if not can(user.role, MANAGE_PRODUCTS):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not permitted")

    raw = await file.read(_MAX_IMPORT_BYTES + 1)
    if len(raw) > _MAX_IMPORT_BYTES:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            f"file exceeds {_MAX_IMPORT_BYTES // 1024 // 1024} MB",
        )
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as e:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "file must be UTF-8 (re-export from Sheets as CSV)",
        ) from e

    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None or "name" not in [
        (f or "").strip().lower() for f in reader.fieldnames
    ]:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "CSV needs at least a 'name' column"
        )

    existing = {
        p.name.strip().lower(): p
        for p in (await db.execute(
            select(Product).where(
                Product.shop_id == user.shop_id, Product.deleted_at.is_(None)
            )
        )).scalars().all()
    }

    errors: list[ImportRowError] = []
    created = updated = skipped = 0
    seen: set[str] = set()
    pending: list[tuple[Product, bool, Decimal]] = []

    for i, row in enumerate(reader, start=2):  # row 1 is the header
        if i - 1 > _MAX_IMPORT_ROWS:
            errors.append(ImportRowError(
                row=i, message=f"more than {_MAX_IMPORT_ROWS} rows; split the file"
            ))
            break
        clean = {(k or "").strip().lower(): (v or "") for k, v in row.items()}
        name = clean.get("name", "").strip()
        if not name:
            skipped += 1
            continue
        key = name.lower()
        if key in seen:
            errors.append(ImportRowError(row=i, message=f"'{name}' appears twice"))
            continue
        seen.add(key)

        try:
            selling = _decimal(clean.get("selling_price", ""), "selling_price")
            purchase = _decimal(clean.get("purchase_price", ""), "purchase_price")
            stock = _decimal(clean.get("stock", ""), "stock")
            threshold = _decimal(clean.get("low_stock_threshold", ""), "low_stock_threshold")
        except ValueError as e:
            errors.append(ImportRowError(row=i, message=str(e)))
            continue

        product = existing.get(key)
        is_new = product is None
        if is_new:
            product = Product(
                id=uuid4(),
                shop_id=user.shop_id,
                name=name,
                purchase_price=purchase,
                selling_price=selling,
                stock=Decimal("0"),
                low_stock_threshold=threshold,
                unit=(clean.get("unit") or "piece").strip() or "piece",
            )
            created += 1
        else:
            product.name = name
            product.selling_price = selling
            product.purchase_price = purchase
            product.low_stock_threshold = threshold
            if clean.get("unit", "").strip():
                product.unit = clean["unit"].strip()
            updated += 1
        category = clean.get("category", "").strip()
        if category:
            product.category = category
        barcode = clean.get("barcode", "").strip()
        if barcode:
            product.barcode = barcode
        pending.append((product, is_new, stock))

    if errors or dry_run:
        # Nothing was flushed; roll back the identity-map changes so a dry run
        # cannot leak edits into the session.
        await db.rollback()
        return ImportResult(
            created=created, updated=updated, skipped=skipped,
            errors=errors, committed=False,
        )

    now = datetime.now(UTC)
    for product, is_new, stock in pending:
        if is_new:
            db.add(product)
        delta = stock - product.stock
        product.stock = stock
        if delta != 0:
            # A stock column in an import is a physical count, so it lands in
            # the ledger as an adjustment rather than silently overwriting.
            db.add(InventoryLog(
                shop_id=user.shop_id,
                product_id=product.id,
                movement="adjustment",
                quantity_delta=delta,
                reason="csv import",
                user_id=user.id,
                created_at=now,
            ))
    db.add(AuditLog(
        shop_id=user.shop_id,
        user_id=user.id,
        action="products.csv_import",
        entity_type="product",
        entity_id=None,
        new_value={"created": str(created), "updated": str(updated)},
        note=file.filename,
        created_at=now,
    ))
    await db.commit()
    return ImportResult(
        created=created, updated=updated, skipped=skipped,
        errors=[], committed=True,
    )
