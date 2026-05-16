-- Suuqii initial schema
-- Idempotent enough to run on a fresh DB. For changes, use new alembic revisions.

-- ====================================================================
-- Extensions
-- ====================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ====================================================================
-- shops
-- ====================================================================
CREATE TABLE shops (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name              TEXT        NOT NULL,
    phone             TEXT,
    currency          CHAR(3)     NOT NULL DEFAULT 'ETB',
    debt_threshold    NUMERIC(12,2) NOT NULL DEFAULT 500.00,
    locale            TEXT        NOT NULL DEFAULT 'en',
    parent_shop_id    UUID        REFERENCES shops(id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

-- ====================================================================
-- users
-- ====================================================================
CREATE TABLE users (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id           UUID        NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
    name              TEXT        NOT NULL,
    phone             TEXT        NOT NULL,
    password_hash     TEXT        NOT NULL,
    role              TEXT        NOT NULL CHECK (role IN ('owner','cashier')),
    owner_pin_hash    TEXT,
    fcm_token         TEXT,
    is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,
    UNIQUE (shop_id, phone)
);
CREATE INDEX idx_users_shop ON users(shop_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_users_phone_global ON users(phone) WHERE deleted_at IS NULL;

-- ====================================================================
-- device_sessions
-- ====================================================================
CREATE TABLE device_sessions (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_label          TEXT,
    device_fingerprint    TEXT        NOT NULL,
    refresh_token_hash    TEXT        NOT NULL,
    refresh_jti           TEXT        NOT NULL,
    last_seen_at          TIMESTAMPTZ,
    revoked_at            TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_fingerprint)
);
CREATE INDEX idx_sessions_user ON device_sessions(user_id) WHERE revoked_at IS NULL;

-- ====================================================================
-- invites
-- ====================================================================
CREATE TABLE invites (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id           UUID        NOT NULL REFERENCES shops(id),
    user_id           UUID        NOT NULL REFERENCES users(id),
    code_hash         TEXT        NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    used_at           TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_invites_user ON invites(user_id) WHERE used_at IS NULL;

-- ====================================================================
-- products
-- ====================================================================
CREATE TABLE products (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id             UUID        NOT NULL REFERENCES shops(id),
    name                TEXT        NOT NULL,
    category            TEXT,
    purchase_price      NUMERIC(12,2) NOT NULL,
    selling_price       NUMERIC(12,2) NOT NULL,
    stock               NUMERIC(12,3) NOT NULL DEFAULT 0,
    low_stock_threshold NUMERIC(12,3) NOT NULL DEFAULT 0,
    unit                TEXT        NOT NULL DEFAULT 'piece',
    barcode             TEXT,
    image_url           TEXT,
    client_updated_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ
);
CREATE INDEX idx_products_shop_name ON products(shop_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_products_low_stock ON products(shop_id)
    WHERE stock <= low_stock_threshold AND deleted_at IS NULL;
CREATE INDEX idx_products_barcode ON products(shop_id, barcode)
    WHERE barcode IS NOT NULL;

-- ====================================================================
-- shifts
-- ====================================================================
CREATE TABLE shifts (
    id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id                  UUID        NOT NULL REFERENCES shops(id),
    user_id                  UUID        NOT NULL REFERENCES users(id),
    opened_at                TIMESTAMPTZ NOT NULL,
    closed_at                TIMESTAMPTZ,
    opening_cash             NUMERIC(12,2) NOT NULL,
    declared_closing_cash    NUMERIC(12,2),
    expected_closing_cash    NUMERIC(12,2),
    variance                 NUMERIC(12,2)
        GENERATED ALWAYS AS (declared_closing_cash - expected_closing_cash) STORED,
    note                     TEXT,
    device_id                TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_shifts_user_open ON shifts(user_id) WHERE closed_at IS NULL;
CREATE INDEX idx_shifts_shop_time ON shifts(shop_id, opened_at DESC);

-- ====================================================================
-- sales + sale_items
-- ====================================================================
CREATE TABLE sales (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id         UUID        NOT NULL REFERENCES shops(id),
    shift_id        UUID        REFERENCES shifts(id),
    user_id         UUID        NOT NULL REFERENCES users(id),
    customer_id     UUID,
    subtotal        NUMERIC(12,2) NOT NULL,
    discount        NUMERIC(12,2) NOT NULL DEFAULT 0,
    total           NUMERIC(12,2) NOT NULL,
    cost_total      NUMERIC(12,2) NOT NULL,
    profit          NUMERIC(12,2) GENERATED ALWAYS AS (total - cost_total) STORED,
    payment_method  TEXT        NOT NULL CHECK (payment_method IN ('cash','mobile_money','credit','mixed')),
    status          TEXT        NOT NULL DEFAULT 'completed'
        CHECK (status IN ('completed','refunded','voided')),
    device_id       TEXT,
    occurred_at     TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);
CREATE INDEX idx_sales_shop_time ON sales(shop_id, occurred_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_sales_shift ON sales(shift_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_sales_user_day ON sales(user_id, occurred_at);

CREATE TABLE sale_items (
    id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sale_id                  UUID        NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
    product_id               UUID        NOT NULL REFERENCES products(id),
    product_name_snapshot    TEXT        NOT NULL,
    quantity                 NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
    unit_price               NUMERIC(12,2) NOT NULL,
    unit_cost                NUMERIC(12,2) NOT NULL,
    line_total               NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);
CREATE INDEX idx_sale_items_sale ON sale_items(sale_id);
CREATE INDEX idx_sale_items_product ON sale_items(product_id);

-- ====================================================================
-- inventory_logs (append-only)
-- ====================================================================
CREATE TABLE inventory_logs (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id         UUID        NOT NULL REFERENCES shops(id),
    product_id      UUID        NOT NULL REFERENCES products(id),
    movement        TEXT        NOT NULL
        CHECK (movement IN ('sale','restock','adjustment','refund','waste')),
    quantity_delta  NUMERIC(12,3) NOT NULL,
    reason          TEXT,
    reference_type  TEXT,
    reference_id    UUID,
    user_id         UUID        REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_inv_logs_product_time ON inventory_logs(product_id, created_at DESC);
CREATE INDEX idx_inv_logs_shop_time ON inventory_logs(shop_id, created_at DESC);

-- ====================================================================
-- debts + debt_payments
-- ====================================================================
CREATE TABLE debts (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id         UUID        NOT NULL REFERENCES shops(id),
    sale_id         UUID        REFERENCES sales(id),
    customer_name   TEXT        NOT NULL,
    customer_phone  TEXT,
    amount_owed     NUMERIC(12,2) NOT NULL CHECK (amount_owed > 0),
    amount_paid     NUMERIC(12,2) NOT NULL DEFAULT 0,
    remaining       NUMERIC(12,2) GENERATED ALWAYS AS (amount_owed - amount_paid) STORED,
    due_date        DATE,
    status          TEXT        NOT NULL DEFAULT 'open'
        CHECK (status IN ('open','partial','paid','written_off')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);
CREATE INDEX idx_debts_open ON debts(shop_id, status) WHERE status IN ('open','partial');
CREATE INDEX idx_debts_phone ON debts(shop_id, customer_phone);

CREATE TABLE debt_payments (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    debt_id     UUID        NOT NULL REFERENCES debts(id) ON DELETE CASCADE,
    shop_id     UUID        NOT NULL REFERENCES shops(id),
    shift_id    UUID        REFERENCES shifts(id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_at     TIMESTAMPTZ NOT NULL,
    method      TEXT        NOT NULL CHECK (method IN ('cash','mobile_money')),
    user_id     UUID        NOT NULL REFERENCES users(id),
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_debt_payments_debt ON debt_payments(debt_id);
CREATE INDEX idx_debt_payments_shift ON debt_payments(shift_id);

-- ====================================================================
-- expenses
-- ====================================================================
CREATE TABLE expenses (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id         UUID        NOT NULL REFERENCES shops(id),
    user_id         UUID        NOT NULL REFERENCES users(id),
    shift_id        UUID        REFERENCES shifts(id),
    title           TEXT        NOT NULL,
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    category        TEXT        NOT NULL DEFAULT 'other',
    description     TEXT,
    occurred_at     TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);
CREATE INDEX idx_expenses_shop_time ON expenses(shop_id, occurred_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_expenses_shift ON expenses(shift_id);

-- ====================================================================
-- audit_logs (append-only)
-- ====================================================================
CREATE TABLE audit_logs (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    shop_id     UUID        NOT NULL,
    user_id     UUID,
    action      TEXT        NOT NULL,
    entity_type TEXT        NOT NULL,
    entity_id   UUID        NOT NULL,
    old_value   JSONB,
    new_value   JSONB,
    device_id   TEXT,
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_shop_time ON audit_logs(shop_id, created_at DESC);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_user_time ON audit_logs(user_id, created_at DESC);

-- ====================================================================
-- sync_events (server-side dedup + pull replay)
-- ====================================================================
CREATE TABLE sync_events (
    id                  BIGSERIAL   PRIMARY KEY,
    shop_id             UUID        NOT NULL REFERENCES shops(id),
    device_id           TEXT        NOT NULL,
    client_event_id     UUID        NOT NULL,
    user_id             UUID        NOT NULL REFERENCES users(id),
    op                  TEXT        NOT NULL,
    payload             JSONB       NOT NULL,
    client_occurred_at  TIMESTAMPTZ NOT NULL,
    applied_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (shop_id, client_event_id)
);
CREATE INDEX idx_sync_shop_time ON sync_events(shop_id, applied_at);
CREATE INDEX idx_sync_device ON sync_events(device_id, applied_at DESC);

-- ====================================================================
-- Audit trigger
-- ====================================================================
CREATE OR REPLACE FUNCTION audit_capture() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_user TEXT;
    v_dev  TEXT;
    v_shop UUID;
BEGIN
    v_user := current_setting('app.current_user_id', true);
    v_dev  := current_setting('app.current_device_id', true);
    v_shop := COALESCE(NEW.shop_id, OLD.shop_id);

    INSERT INTO audit_logs(shop_id, user_id, action, entity_type, entity_id,
                           old_value, new_value, device_id)
    VALUES (
        v_shop,
        NULLIF(v_user, '')::UUID,
        TG_TABLE_NAME || '.' || lower(TG_OP),
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
        NULLIF(v_dev, '')
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER audit_products
AFTER INSERT OR UPDATE OR DELETE ON products
FOR EACH ROW EXECUTE FUNCTION audit_capture();

CREATE TRIGGER audit_sales
AFTER INSERT OR UPDATE OR DELETE ON sales
FOR EACH ROW EXECUTE FUNCTION audit_capture();

CREATE TRIGGER audit_debts
AFTER INSERT OR UPDATE OR DELETE ON debts
FOR EACH ROW EXECUTE FUNCTION audit_capture();

CREATE TRIGGER audit_expenses
AFTER INSERT OR UPDATE OR DELETE ON expenses
FOR EACH ROW EXECUTE FUNCTION audit_capture();

CREATE TRIGGER audit_shifts
AFTER INSERT OR UPDATE OR DELETE ON shifts
FOR EACH ROW EXECUTE FUNCTION audit_capture();

-- ====================================================================
-- Materialized view: daily sales aggregates
-- ====================================================================
CREATE MATERIALIZED VIEW sales_daily_mv AS
SELECT
    shop_id,
    date_trunc('day', occurred_at AT TIME ZONE 'Africa/Addis_Ababa')::date AS day,
    COUNT(*)::BIGINT                                                AS sale_count,
    SUM(total)                                                       AS revenue,
    SUM(profit)                                                      AS profit,
    SUM(CASE WHEN payment_method='credit' THEN total ELSE 0 END)     AS credit_sales,
    SUM(CASE WHEN payment_method='cash'   THEN total ELSE 0 END)     AS cash_sales,
    SUM(CASE WHEN payment_method='mobile_money' THEN total ELSE 0 END) AS mobile_sales
FROM sales
WHERE deleted_at IS NULL AND status='completed'
GROUP BY 1, 2;
CREATE UNIQUE INDEX ON sales_daily_mv(shop_id, day);

-- ====================================================================
-- Row-Level Security (defence in depth)
-- ====================================================================
ALTER TABLE products       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE debts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE debt_payments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses       ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_events    ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN
        SELECT unnest(ARRAY[
            'products','sales','sale_items','inventory_logs','debts',
            'debt_payments','expenses','shifts','audit_logs','sync_events'
        ])
    LOOP
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I USING (shop_id = current_setting(''app.current_shop_id'', true)::UUID)',
            t
        );
    END LOOP;
END $$;

-- Prevent any UPDATE/DELETE on audit_logs (insert-only)
REVOKE UPDATE, DELETE ON audit_logs FROM PUBLIC;

-- ====================================================================
-- Refresh helper
-- ====================================================================
CREATE OR REPLACE FUNCTION refresh_sales_daily_mv() RETURNS void
LANGUAGE SQL AS $$
    REFRESH MATERIALIZED VIEW CONCURRENTLY sales_daily_mv;
$$;
