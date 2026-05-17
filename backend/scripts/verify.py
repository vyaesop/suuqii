"""Quick read-only verification script — checks data after a test sale."""
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

print("=== latest 3 sales ===")
for r in c.execute(text(
    "SELECT total, payment_method, status, occurred_at "
    "FROM sales ORDER BY created_at DESC LIMIT 3"
)):
    print(" ", r)

print()
print("=== stock for sold product ===")
for r in c.execute(text(
    "SELECT name, stock FROM products WHERE name LIKE 'Coca%'"
)):
    print(" ", r)

print()
audit_count = c.execute(text("SELECT COUNT(*) FROM audit_logs")).scalar()
print(f"audit_logs rows: {audit_count}")

sync_count = c.execute(text("SELECT COUNT(*) FROM sync_events")).scalar()
print(f"sync_events rows (server-side idempotency log): {sync_count}")

inv_count = c.execute(text("SELECT COUNT(*) FROM inventory_logs")).scalar()
print(f"inventory_logs rows: {inv_count}")
