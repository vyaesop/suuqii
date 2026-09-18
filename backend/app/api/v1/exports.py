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

from app.core.capabilities import ADMIN, VIEW_COSTS, VIEW_REPORTS, can
from app.core.deps import current_user, db_session
from app.core.variant_naming import compose_variant_name
from app.models import AuditLog, InventoryLog, Product, Sale, SaleItem, Style, User
from app.models.style import SEGMENTS

router = APIRouter(prefix="/export", tags=["export"])

# Uploads are read fully into memory to be parsed, so the ceiling is a real
# constraint, not a formality. 2 MB is ~20k product rows.
_MAX_IMPORT_BYTES = 2 * 1024 * 1024
_MAX_IMPORT_ROWS = 5000

# The product file's shape, shared by export and import so the round trip
# (export → edit in Sheets → import) is exact. The boutique columns
# (docs/19 §13.4) are blank for plain products.
_PRODUCT_COLUMNS = [
    "name", "category", "selling_price", "purchase_price", "stock",
    "low_stock_threshold", "unit", "barcode",
    "style", "brand", "segment", "size", "color", "sku", "min_selling_price",
]


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
    uploads back. Owner-only (docs/19 §13.4: ADMIN) — the whole catalogue in
    one file is an owner's asset, whatever is masked in it. Cost prices are
    still blanked for anyone without VIEW_COSTS.
    """
    if not can(user.role, ADMIN):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")
    show_costs = can(user.role, VIEW_COSTS)
    rows = (await db.execute(
        select(Product)
        .where(Product.shop_id == user.shop_id, Product.deleted_at.is_(None))
        .order_by(Product.name)
    )).scalars().all()
    styles = {
        s.id: s for s in (await db.execute(
            select(Style).where(Style.shop_id == user.shop_id)
        )).scalars().all()
    }

    def gen():
        for p in rows:
            style = styles.get(p.style_id) if p.style_id else None
            yield [
                p.name,
                p.category or "",
                str(p.selling_price),
                str(p.purchase_price) if show_costs else "",
                str(p.stock),
                str(p.low_stock_threshold),
                p.unit,
                p.barcode or "",
                style.name if style else "",
                (style.brand or "") if style else "",
                (style.segment or "") if style else "",
                p.size or "",
                p.color or "",
                p.sku or "",
                str(p.min_selling_price) if p.min_selling_price is not None else "",
            ]

    return _csv_response("products", _PRODUCT_COLUMNS, gen())


class ImportRowError(BaseModel):
    row: int
    message: str


class ImportResult(BaseModel):
    created: int
    updated: int
    skipped: int
    errors: list[ImportRowError]
    committed: bool
    styles_created: int = 0


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


def _optional_decimal(raw: str, field: str) -> Decimal | None:
    return _decimal(raw, field) if (raw or "").strip() else None


@router.post("/products/import", response_model=ImportResult)
async def import_products(
    file: UploadFile,
    dry_run: bool = Query(True),
    user: User = Depends(current_user),
    db: AsyncSession = Depends(db_session),
) -> ImportResult:
    """Create or update products from a CSV.

    Matched on `name` within the shop — spreadsheets have no stable ids, and
    the name is what the owner thinks of as the product's identity. A row with
    a `style` column is a variant: its name is composed from style, size and
    colour (docs/19 §13.2), rows are grouped by `(style, brand)` and the style
    is created on the fly if the shop does not have it yet. `sku` is stored as
    given — the server never composes SKUs.

    Defaults to **dry_run**: the file is parsed and validated and you get the
    counts and per-row errors back without anything being written. A partly
    applied import of somebody's whole catalogue is much worse than a rejected
    one, so the real run is all-or-nothing — any row error aborts the batch.

    Owner-only (ADMIN): an import rewrites purchase prices and creates styles
    wholesale with no per-row PIN, which MANAGE_PRODUCTS alone (cashiers hold
    it) must not be able to do.
    """
    if not can(user.role, ADMIN):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "owner only")

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
    columns = [(f or "").strip().lower() for f in (reader.fieldnames or [])]
    if "name" not in columns and "style" not in columns:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "CSV needs at least a 'name' or 'style' column"
        )

    existing = {
        p.name.strip().lower(): p
        for p in (await db.execute(
            select(Product).where(
                Product.shop_id == user.shop_id, Product.deleted_at.is_(None)
            )
        )).scalars().all()
    }
    existing_by_sku = {
        p.sku.strip().lower(): p for p in existing.values() if p.sku
    }
    # Styles are matched on (name, brand): "Slim jeans" from two brands are
    # two styles, "Slim jeans" typed twice with the same brand is one.
    styles: dict[tuple[str, str], Style] = {
        (s.name.strip().lower(), (s.brand or "").strip().lower()): s
        for s in (await db.execute(
            select(Style).where(Style.shop_id == user.shop_id, Style.deleted_at.is_(None))
        )).scalars().all()
    }

    errors: list[ImportRowError] = []
    created = updated = skipped = 0
    seen: set[str] = set()
    seen_skus: set[str] = set()
    pending: list[tuple[Product, bool, Decimal]] = []
    new_styles: list[Style] = []

    for i, row in enumerate(reader, start=2):  # row 1 is the header
        if i - 1 > _MAX_IMPORT_ROWS:
            errors.append(ImportRowError(
                row=i, message=f"more than {_MAX_IMPORT_ROWS} rows; split the file"
            ))
            break
        clean = {(k or "").strip().lower(): (v or "") for k, v in row.items()}
        style_name = clean.get("style", "").strip()
        brand = clean.get("brand", "").strip()
        size = clean.get("size", "").strip() or None
        color = clean.get("color", "").strip() or None
        # A variant's name is derived, never typed: the same rule the wizard
        # and style.create use, so a CSV-born variant is indistinguishable.
        name = (
            compose_variant_name(style_name, size, color)
            if style_name else clean.get("name", "").strip()
        )
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
            min_price = _optional_decimal(clean.get("min_selling_price", ""), "min_selling_price")
            segment = clean.get("segment", "").strip().lower() or None
            if segment is not None and segment not in SEGMENTS:
                raise ValueError(f"segment must be one of {', '.join(SEGMENTS)}")
        except ValueError as e:
            errors.append(ImportRowError(row=i, message=str(e)))
            continue

        style: Style | None = None
        if style_name:
            style_key = (style_name.lower(), brand.lower())
            style = styles.get(style_key)
            if style is None:
                style = Style(
                    id=uuid4(),
                    shop_id=user.shop_id,
                    name=style_name,
                    brand=brand or None,
                    category=clean.get("category", "").strip() or None,
                    segment=segment,
                    default_selling_price=selling,
                    default_purchase_price=purchase,
                )
                styles[style_key] = style
                new_styles.append(style)

        sku = clean.get("sku", "").strip() or None
        # Identity is the (composed) name, as documented above. A SKU on the
        # row must then be free or already belong to that same product — SKUs
        # are unique per shop (products_sku_uq), and matching by SKU first
        # would let a row quietly rename whichever product owns the SKU.
        # Catch the clash here as a row error rather than letting the commit
        # fail on the whole file.
        product = existing.get(key)
        if sku:
            if sku.lower() in seen_skus:
                errors.append(ImportRowError(row=i, message=f"sku '{sku}' appears twice"))
                continue
            owner_of_sku = existing_by_sku.get(sku.lower())
            if owner_of_sku is not None and owner_of_sku is not product:
                errors.append(ImportRowError(
                    row=i, message=f"sku '{sku}' already belongs to '{owner_of_sku.name}'"
                ))
                continue
            seen_skus.add(sku.lower())
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
        elif style is not None and style.category and not product.category:
            product.category = style.category
        barcode = clean.get("barcode", "").strip()
        if barcode:
            product.barcode = barcode
        if style is not None:
            product.style_id = style.id
            product.size = size
            product.color = color
            product.unit = "piece"
        if sku:
            product.sku = sku
        if min_price is not None:
            product.min_selling_price = min_price
        pending.append((product, is_new, stock))

    if errors or dry_run:
        # Nothing was flushed; roll back the identity-map changes so a dry run
        # cannot leak edits into the session.
        await db.rollback()
        return ImportResult(
            created=created, updated=updated, skipped=skipped,
            errors=errors, committed=False, styles_created=len(new_styles),
        )

    now = datetime.now(UTC)
    for style in new_styles:
        db.add(style)
    if new_styles:
        await db.flush()  # variants' FK must not race the style inserts
    for product, is_new, _ in pending:
        if is_new:
            db.add(product)
    # Flush before any InventoryLog references a new product: without
    # relationship() constructs SQLAlchemy does not guarantee cross-mapper
    # insert ordering, and the log's FK would race the product insert (the
    # same guard _stock_receive uses for lots).
    await db.flush()
    for product, _, stock in pending:
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
    # audit_logs.entity_id is NOT NULL; an import has no single entity, so
    # the row is keyed on a fresh batch id (the previous `entity_id=None`
    # made every committed import fail at the very end).
    db.add(AuditLog(
        shop_id=user.shop_id,
        user_id=user.id,
        action="products.csv_import",
        entity_type="csv_import",
        entity_id=uuid4(),
        new_value={
            "created": str(created), "updated": str(updated),
            "styles_created": str(len(new_styles)),
        },
        note=file.filename,
        created_at=now,
    ))
    await db.commit()
    return ImportResult(
        created=created, updated=updated, skipped=skipped,
        errors=[], committed=True, styles_created=len(new_styles),
    )
