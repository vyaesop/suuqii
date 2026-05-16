"""
Alembic env. We use the raw SQL bootstrap in versions/0001_initial.sql
for the initial schema (it's clearer than autogenerate spam), then
subsequent revisions use the normal autogenerate flow.
"""
from logging.config import fileConfig
from pathlib import Path

from alembic import context
from sqlalchemy import create_engine, pool, text

from app.core.config import settings
from app.db.base import Base  # noqa: F401 — registers metadata

# Import all models so autogenerate sees them
from app.models import (  # noqa: F401
    audit_log,
    debt,
    expense,
    inventory_log,
    product,
    sale,
    shift,
    shop,
    sync_event,
    user,
)

config = context.config
if config.config_file_name:
    fileConfig(config.config_file_name)

# Use the sync URL for alembic (psycopg/postgresql://) if set, else strip +asyncpg.
sync_url = settings.database_url_sync or settings.database_url.replace("+asyncpg", "")
config.set_main_option("sqlalchemy.url", sync_url)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=sync_url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = create_engine(sync_url, poolclass=pool.NullPool)
    with connectable.connect() as conn:
        # Bootstrap: if alembic_version doesn't exist, apply 0001_initial.sql once.
        version_table = conn.execute(text(
            "SELECT to_regclass('public.alembic_version')"
        )).scalar()
        if version_table is None:
            sql_file = Path(__file__).parent / "versions" / "0001_initial.sql"
            if sql_file.exists():
                conn.execute(text(sql_file.read_text()))
                conn.execute(text(
                    "CREATE TABLE IF NOT EXISTS alembic_version "
                    "(version_num VARCHAR(32) NOT NULL PRIMARY KEY)"
                ))
                conn.execute(text(
                    "INSERT INTO alembic_version(version_num) VALUES ('0001_initial')"
                ))
                conn.commit()
                return

        context.configure(connection=conn, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
