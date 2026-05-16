# 03 — PostgreSQL schema

Authoritative DDL lives in [`backend/alembic/versions/0001_initial.sql`](../backend/alembic/versions/0001_initial.sql). This doc explains the design.

## Conventions

- All primary keys: `UUID` (client-generated v4) — required for offline-first.
- All tables carry `shop_id UUID` for tenant isolation (except `shops` itself).
- All tables have `created_at`, `updated_at` (TIMESTAMPTZ, server default `now()`).
- Soft delete: `deleted_at TIMESTAMPTZ NULL` on rows that should survive in audit history.
- Money: `NUMERIC(12,2)`. Ethiopian Birr has 2 decimal cents (santim). Never use FLOAT.
- Timestamps: TIMESTAMPTZ everywhere; store UTC, render local on device.

## Entities

```
shops ──┬── users (one of role=owner per shop, many cashiers)
        ├── products ──┬── sale_items
        │              └── inventory_logs
        ├── sales ─────┬── sale_items
        │              ├── debts (if payment_method='credit')
        │              └── audit_logs (sale.*)
        ├── debts ─── debt_payments
        ├── expenses
        ├── shifts (per user, per day-ish)
        ├── audit_logs (append-only, all entities)
        └── sync_events (server-side dedup log)
```

## DDL summary

### `shops`
```sql
id UUID PK
name TEXT NOT NULL
phone TEXT
currency CHAR(3) DEFAULT 'ETB'
debt_threshold NUMERIC(12,2) DEFAULT 500.00   -- above this, requires owner PIN
locale TEXT DEFAULT 'en'                       -- 'en' | 'om'
parent_shop_id UUID NULL REFERENCES shops(id)  -- future multi-branch
created_at, updated_at, deleted_at
```

### `users`
```sql
id UUID PK
shop_id UUID NOT NULL REFERENCES shops(id) ON DELETE CASCADE
name TEXT NOT NULL
phone TEXT UNIQUE NOT NULL                     -- login identifier
password_hash TEXT NOT NULL                    -- argon2id
role TEXT NOT NULL CHECK (role IN ('owner','cashier'))
owner_pin_hash TEXT NULL                       -- owners only, for sensitive ops
fcm_token TEXT NULL
is_active BOOLEAN DEFAULT TRUE
created_at, updated_at, deleted_at

UNIQUE (shop_id, phone)
INDEX idx_users_shop ON (shop_id) WHERE deleted_at IS NULL
```

### `device_sessions`
```sql
id UUID PK
user_id UUID NOT NULL REFERENCES users(id)
device_label TEXT                              -- "Cashier Pixel 3"
device_fingerprint TEXT NOT NULL               -- hashed device id
refresh_token_hash TEXT NOT NULL               -- only hash stored
last_seen_at TIMESTAMPTZ
revoked_at TIMESTAMPTZ NULL
created_at
```

### `products`
```sql
id UUID PK
shop_id UUID NOT NULL REFERENCES shops(id)
name TEXT NOT NULL
category TEXT
purchase_price NUMERIC(12,2) NOT NULL
selling_price NUMERIC(12,2) NOT NULL
stock NUMERIC(12,3) NOT NULL DEFAULT 0         -- 3 dp for kg/liter
low_stock_threshold NUMERIC(12,3) DEFAULT 0
unit TEXT NOT NULL DEFAULT 'piece'             -- piece|kg|liter|m|pack
barcode TEXT
image_url TEXT
created_at, updated_at, deleted_at
client_updated_at TIMESTAMPTZ                  -- for LWW conflict resolution

INDEX idx_products_shop_name ON (shop_id, name) WHERE deleted_at IS NULL
INDEX idx_products_low_stock ON (shop_id) WHERE stock <= low_stock_threshold AND deleted_at IS NULL
INDEX idx_products_barcode ON (shop_id, barcode) WHERE barcode IS NOT NULL
```

### `inventory_logs`
Append-only ledger of every stock movement. Stock on `products` is the running sum.
```sql
id UUID PK
shop_id UUID NOT NULL
product_id UUID NOT NULL REFERENCES products(id)
movement TEXT NOT NULL CHECK (movement IN ('sale','restock','adjustment','refund','waste'))
quantity_delta NUMERIC(12,3) NOT NULL          -- positive or negative
reason TEXT
reference_type TEXT                            -- 'sale' | 'shift' | NULL
reference_id UUID
user_id UUID REFERENCES users(id)
created_at

INDEX idx_inv_logs_product_time ON (product_id, created_at DESC)
```

### `shifts`
```sql
id UUID PK
shop_id UUID NOT NULL
user_id UUID NOT NULL REFERENCES users(id)
opened_at TIMESTAMPTZ NOT NULL
closed_at TIMESTAMPTZ
opening_cash NUMERIC(12,2) NOT NULL
declared_closing_cash NUMERIC(12,2)            -- what cashier counted
expected_closing_cash NUMERIC(12,2)            -- computed at close
variance NUMERIC(12,2) GENERATED ALWAYS AS
  (declared_closing_cash - expected_closing_cash) STORED
note TEXT
device_id TEXT
created_at, updated_at

INDEX idx_shifts_user_open ON (user_id) WHERE closed_at IS NULL
```

### `sales`
```sql
id UUID PK
shop_id UUID NOT NULL
shift_id UUID REFERENCES shifts(id)
user_id UUID NOT NULL                          -- who rang it
customer_id UUID NULL                          -- (future)
subtotal NUMERIC(12,2) NOT NULL
discount NUMERIC(12,2) DEFAULT 0
total NUMERIC(12,2) NOT NULL
cost_total NUMERIC(12,2) NOT NULL              -- snapshot of purchase prices
profit NUMERIC(12,2) GENERATED ALWAYS AS (total - cost_total) STORED
payment_method TEXT NOT NULL CHECK (payment_method IN ('cash','mobile_money','credit','mixed'))
status TEXT NOT NULL DEFAULT 'completed'       -- completed|refunded|voided
device_id TEXT
occurred_at TIMESTAMPTZ NOT NULL               -- client time
created_at TIMESTAMPTZ DEFAULT now()           -- server insert time
deleted_at TIMESTAMPTZ NULL                    -- soft

INDEX idx_sales_shop_time ON (shop_id, occurred_at DESC) WHERE deleted_at IS NULL
INDEX idx_sales_shift ON (shift_id) WHERE deleted_at IS NULL
INDEX idx_sales_user_day ON (user_id, occurred_at)
```

### `sale_items`
```sql
id UUID PK
sale_id UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE
product_id UUID NOT NULL REFERENCES products(id)
product_name_snapshot TEXT NOT NULL            -- freeze name at sale time
quantity NUMERIC(12,3) NOT NULL
unit_price NUMERIC(12,2) NOT NULL              -- selling at time of sale
unit_cost NUMERIC(12,2) NOT NULL               -- purchase at time of sale
line_total NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED

INDEX idx_sale_items_sale ON (sale_id)
INDEX idx_sale_items_product_time ON (product_id)
```

### `debts`
```sql
id UUID PK
shop_id UUID NOT NULL
sale_id UUID REFERENCES sales(id)
customer_name TEXT NOT NULL
customer_phone TEXT
amount_owed NUMERIC(12,2) NOT NULL             -- principal
amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0
remaining NUMERIC(12,2) GENERATED ALWAYS AS (amount_owed - amount_paid) STORED
due_date DATE
status TEXT NOT NULL DEFAULT 'open'            -- open|partial|paid|written_off
created_at, updated_at, deleted_at

INDEX idx_debts_open ON (shop_id, status) WHERE status IN ('open','partial')
INDEX idx_debts_phone ON (shop_id, customer_phone)
```

### `debt_payments`
```sql
id UUID PK
debt_id UUID NOT NULL REFERENCES debts(id)
amount NUMERIC(12,2) NOT NULL
paid_at TIMESTAMPTZ NOT NULL
method TEXT NOT NULL CHECK (method IN ('cash','mobile_money'))
user_id UUID NOT NULL
note TEXT
created_at
```

### `expenses`
```sql
id UUID PK
shop_id UUID NOT NULL
user_id UUID NOT NULL
shift_id UUID REFERENCES shifts(id)
title TEXT NOT NULL
amount NUMERIC(12,2) NOT NULL
category TEXT NOT NULL                         -- rent|transport|utilities|salary|supplies|other
description TEXT
occurred_at TIMESTAMPTZ NOT NULL
created_at, updated_at, deleted_at

INDEX idx_expenses_shop_time ON (shop_id, occurred_at DESC) WHERE deleted_at IS NULL
```

### `audit_logs` (immutable)
```sql
id UUID PK
shop_id UUID NOT NULL
user_id UUID NOT NULL                          -- who did it
action TEXT NOT NULL                           -- 'product.update', 'sale.delete', 'price.change', ...
entity_type TEXT NOT NULL
entity_id UUID NOT NULL
old_value JSONB                                -- pre-image (NULL for create)
new_value JSONB                                -- post-image (NULL for delete)
device_id TEXT
client_ip INET
note TEXT
created_at TIMESTAMPTZ NOT NULL DEFAULT now()

-- no updated_at; rows are insert-only
-- no DELETE permission for any user role on this table
INDEX idx_audit_shop_time ON (shop_id, created_at DESC)
INDEX idx_audit_entity ON (entity_type, entity_id)
INDEX idx_audit_user ON (user_id, created_at DESC)
```

### `sync_events`
Server-side log of accepted client events; used for idempotency and pull replay.
```sql
id BIGSERIAL PK
shop_id UUID NOT NULL
device_id TEXT NOT NULL
client_event_id UUID NOT NULL                  -- idempotency key
op TEXT NOT NULL                               -- 'sale.create', 'product.update', ...
payload JSONB NOT NULL
applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
client_occurred_at TIMESTAMPTZ NOT NULL

UNIQUE (shop_id, client_event_id)
INDEX idx_sync_shop_time ON (shop_id, applied_at)
```

## Row-Level Security (RLS)

Enabled per table. Example for `products`:
```sql
ALTER TABLE products ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON products
    USING (shop_id = current_setting('app.current_shop_id', true)::UUID);
```
FastAPI dependency `current_shop()` runs `SET LOCAL app.current_shop_id = '<uuid>'` per request. RLS is defence-in-depth; application code already filters by `shop_id`.

## Triggers — audit capture

For tables under audit (`products`, `sales`, `debts`, `expenses`, `shifts`), AFTER INSERT/UPDATE/DELETE triggers write to `audit_logs` automatically:
```sql
CREATE OR REPLACE FUNCTION audit_capture() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO audit_logs (shop_id, user_id, action, entity_type, entity_id, old_value, new_value, device_id)
  VALUES (
    COALESCE(NEW.shop_id, OLD.shop_id),
    current_setting('app.current_user_id', true)::UUID,
    TG_TABLE_NAME || '.' || lower(TG_OP),
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id),
    to_jsonb(OLD),
    to_jsonb(NEW),
    current_setting('app.current_device_id', true)
  );
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_products
AFTER INSERT OR UPDATE OR DELETE ON products
FOR EACH ROW EXECUTE FUNCTION audit_capture();
```

## Materialized views (for dashboard)

```sql
CREATE MATERIALIZED VIEW sales_daily_mv AS
SELECT
  shop_id,
  date_trunc('day', occurred_at AT TIME ZONE 'Africa/Addis_Ababa') AS day,
  COUNT(*) AS sale_count,
  SUM(total) AS revenue,
  SUM(profit) AS profit,
  SUM(CASE WHEN payment_method='credit' THEN total ELSE 0 END) AS credit_sales
FROM sales
WHERE deleted_at IS NULL AND status='completed'
GROUP BY 1, 2;

CREATE UNIQUE INDEX ON sales_daily_mv (shop_id, day);
```
Refreshed by a cron job every 15 minutes — dashboard reads from the MV, never from raw `sales`.

## What we deliberately did NOT model

- **Customers as a first-class entity** — debts hold a flat `customer_name + phone`. Promoting to a real table is in v2 once we see how shops use it.
- **Tax / VAT** — Ethiopian small shops typically don't track VAT in this layer.
- **Multi-currency** — single ETB. `shops.currency` exists for future-proofing only.
- **Suppliers / purchase orders** — stubbed in optional migration; not built.
