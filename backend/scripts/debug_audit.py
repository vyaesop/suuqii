"""Inspect what the audit trigger captured for products."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import os
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

load_dotenv()
url = os.environ["DATABASE_URL_SYNC"].replace("postgresql://", "postgresql+psycopg://", 1)
e = create_engine(url)
c = e.connect()

print("=== recent product audit rows ===")
for r in c.execute(text(
    "SELECT action, "
    "(old_value->>'stock') AS old_stock, "
    "(new_value->>'stock') AS new_stock, "
    "created_at "
    "FROM audit_logs WHERE entity_type='products' ORDER BY created_at DESC LIMIT 5"
)):
    print(" ", r)

print()
print("=== inventory log ===")
for r in c.execute(text(
    "SELECT movement, quantity_delta, created_at FROM inventory_logs ORDER BY created_at DESC LIMIT 3"
)):
    print(" ", r)
