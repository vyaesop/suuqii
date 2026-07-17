import os
from uuid import uuid4

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from app.core.config import settings

# On serverless (Vercel) every concurrent function instance would otherwise
# hold its own QueuePool (5+10 connections each) and exhaust Neon's cap.
# There we use NullPool and rely on Neon's pgbouncer; prepared-statement
# caching must be disabled because pgbouncer's transaction pooling breaks
# asyncpg's named prepared statements.
_serverless = bool(os.environ.get("VERCEL"))

if _serverless:
    engine = create_async_engine(
        settings.database_url,
        poolclass=NullPool,
        echo=False,
        connect_args={
            "statement_cache_size": 0,
            "prepared_statement_cache_size": 0,
            "prepared_statement_name_func": lambda: f"__asyncpg_{uuid4()}__",
        },
    )
else:
    engine = create_async_engine(
        settings.database_url,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
        echo=False,
    )

AsyncSessionLocal: async_sessionmaker[AsyncSession] = async_sessionmaker(
    bind=engine,
    expire_on_commit=False,
    autoflush=False,
)
