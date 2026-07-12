"""
Alembic env. We use the raw SQL bootstrap in versions/0001_initial.sql
for the initial schema (it's clearer than autogenerate spam), then
subsequent revisions use the normal autogenerate flow.
"""
from logging.config import fileConfig
from pathlib import Path

from sqlalchemy import create_engine, pool, text

from alembic import context
from app.core.config import settings
from app.db.base import Base  # noqa: F401 — registers metadata

# Import all models so autogenerate sees them
from app.models import (  # noqa: F401
    audit_log,
    debt,
    expense,
    inventory_log,
    product,
    recipe,
    sale,
    shift,
    shop,
    stock_lot,
    supply,
    sync_event,
    user,
)

config = context.config
if config.config_file_name:
    fileConfig(config.config_file_name)

def psycopg_url(url: str) -> str:
    if url.startswith("postgresql://"):
        return url.replace("postgresql://", "postgresql+psycopg://", 1)
    return url


# Use the sync URL for alembic if set, else strip +asyncpg and use psycopg.
sync_url = psycopg_url(settings.database_url_sync or settings.database_url.replace("+asyncpg", ""))
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
            # If the schema already exists (e.g. created manually or by a
            # partially-tracked deploy) but the version table is missing,
            # re-running the full bootstrap SQL would fail on the first
            # CREATE TABLE. In that case only stamp the version.
            schema_exists = conn.execute(text(
                "SELECT to_regclass('public.shops')"
            )).scalar() is not None
            sql_file = Path(__file__).parent / "versions" / "0001_initial.sql"
            if not schema_exists and sql_file.exists():
                conn.execute(text(sql_file.read_text()))
            # Some revision identifiers are longer than Alembic's historical
            # 32-char default, so size the column generously to avoid
            # truncation when stamping later revisions.
            conn.execute(text(
                "CREATE TABLE IF NOT EXISTS alembic_version "
                "(version_num VARCHAR(255) NOT NULL PRIMARY KEY)"
            ))
            conn.execute(text(
                "INSERT INTO alembic_version(version_num) VALUES ('0001_initial')"
            ))
            conn.commit()
        else:
            # Widen pre-existing version tables created with the old 32-char
            # column so long revision identifiers can be stamped. Skip when
            # already widened — the ALTER takes an exclusive lock on every
            # deploy otherwise.
            current_len = conn.execute(text(
                "SELECT character_maximum_length FROM information_schema.columns "
                "WHERE table_schema = 'public' AND table_name = 'alembic_version' "
                "AND column_name = 'version_num'"
            )).scalar()
            if current_len is not None and current_len < 255:
                conn.execute(text(
                    "ALTER TABLE alembic_version "
                    "ALTER COLUMN version_num TYPE VARCHAR(255)"
                ))
                conn.commit()

        # Fall through so any revisions after the bootstrap (0002+) are applied.
        context.configure(connection=conn, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
