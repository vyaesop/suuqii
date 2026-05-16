"""
Seed a development shop with an owner and a handful of products.

Idempotent: re-running detects the seed user by phone and exits.

Usage:
    python scripts/seed.py
"""
from __future__ import annotations

import asyncio
import sys
from decimal import Decimal
from pathlib import Path

# allow `python scripts/seed.py` from the backend/ directory
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.security import hash_password  # noqa: E402
from app.db.session import AsyncSessionLocal  # noqa: E402
from app.models import Product, Shop, User  # noqa: E402

SHOP_NAME = "Test Shop"
OWNER_PHONE = "+251911111111"
OWNER_PASSWORD = "pass1234"
OWNER_PIN = "1234"

PRODUCTS = [
    # (name, category, purchase, selling, stock, unit)
    ("Coca-Cola 300ml", "Drinks", "12.00", "20.00", 48, "piece"),
    ("Water 1L", "Drinks", "8.00", "15.00", 36, "piece"),
    ("Bread Loaf", "Bakery", "15.00", "25.00", 20, "piece"),
    ("Sugar 1kg", "Pantry", "55.00", "75.00", 25, "kg"),
    ("Rice 1kg", "Pantry", "62.00", "85.00", 30, "kg"),
    ("Cooking Oil 1L", "Pantry", "120.00", "160.00", 12, "liter"),
    ("Eggs (single)", "Dairy", "6.00", "10.00", 80, "piece"),
    ("Milk 1L", "Dairy", "45.00", "65.00", 15, "liter"),
]


async def main() -> None:
    async with AsyncSessionLocal() as db:
        existing = (await db.execute(select(User).where(User.phone == OWNER_PHONE))).scalar_one_or_none()
        if existing:
            print(f"✓ Seed already present (user {OWNER_PHONE} exists, shop {existing.shop_id}). Skipping.")
            print(f"  Login with: phone={OWNER_PHONE}  password={OWNER_PASSWORD}  pin={OWNER_PIN}")
            return

        shop = Shop(name=SHOP_NAME, phone=OWNER_PHONE, locale="en")
        db.add(shop)
        await db.flush()

        owner = User(
            shop_id=shop.id,
            name="Test Owner",
            phone=OWNER_PHONE,
            password_hash=hash_password(OWNER_PASSWORD),
            role="owner",
            owner_pin_hash=hash_password(OWNER_PIN),
            is_active=True,
        )
        db.add(owner)
        await db.flush()

        for name, cat, purchase, selling, stock, unit in PRODUCTS:
            db.add(Product(
                shop_id=shop.id,
                name=name,
                category=cat,
                purchase_price=Decimal(purchase),
                selling_price=Decimal(selling),
                stock=Decimal(str(stock)),
                low_stock_threshold=Decimal("5"),
                unit=unit,
            ))

        await db.commit()

        print(f'✓ Seeded shop "{SHOP_NAME}" (id={shop.id}) with {len(PRODUCTS)} products.')
        print("  Login with:")
        print(f"      phone:      {OWNER_PHONE}")
        print(f"      password:   {OWNER_PASSWORD}")
        print(f"      owner PIN:  {OWNER_PIN}")


if __name__ == "__main__":
    asyncio.run(main())
