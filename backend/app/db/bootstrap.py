"""Self-migrating startup: bring the database to the current schema head.

Vercel has no deploy hook that runs alembic, so historically new code
shipped against an old schema and login/register died with
UndefinedTable/UndefinedColumn. Instead, the first request on each process
checks the alembic version and upgrades if behind.

- Cheap when current: one SELECT, then never again for the process life.
- Concurrent cold starts serialize on a Postgres advisory lock and re-check
  under the lock, so the upgrade runs exactly once.
- Failure is logged loudly but does not take the process down — requests
  proceed and surface the schema error explicitly (see errors.py).
"""
import asyncio
import logging
from pathlib import Path

import anyio
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text
from sqlalchemy.pool import NullPool

from alembic import command
from app.core.config import settings

logger = logging.getLogger(__name__)

_BACKEND_DIR = Path(__file__).resolve().parent.parent.parent
_LOCK_KEY = "suuqii_migrate"

_done = False
_guard = asyncio.Lock()


def _sync_url() -> str:
    url = settings.database_url_sync or settings.database_url.replace("+asyncpg", "")
    if url.startswith("postgresql://"):
        url = url.replace("postgresql://", "postgresql+psycopg://", 1)
    return url


def _current_version(conn) -> str | None:
    exists = conn.execute(text("SELECT to_regclass('public.alembic_version')")).scalar()
    if exists is None:
        return None
    return conn.execute(text("SELECT version_num FROM alembic_version")).scalar()


def _migrate_sync() -> None:
    cfg = Config(str(_BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(_BACKEND_DIR / "alembic"))
    head = ScriptDirectory.from_config(cfg).get_current_head()

    engine = create_engine(_sync_url(), poolclass=NullPool)
    try:
        with engine.connect() as conn:
            if _current_version(conn) == head:
                return
            # Serialize concurrent instances; holder connection stays open
            # for the duration of the upgrade.
            conn.execute(text("SELECT pg_advisory_lock(hashtext(:k))"), {"k": _LOCK_KEY})
            try:
                if _current_version(conn) == head:
                    return  # someone else migrated while we waited
                logger.warning("database behind (head=%s) — running migrations", head)
                command.upgrade(cfg, "head")
                logger.warning("migrations complete at %s", head)
            finally:
                conn.execute(text("SELECT pg_advisory_unlock(hashtext(:k))"), {"k": _LOCK_KEY})
    finally:
        engine.dispose()


async def ensure_migrated() -> None:
    """Idempotent, once per process; safe to call on every request."""
    global _done  # noqa: PLW0603
    if _done or not settings.migrate_on_start:
        return
    async with _guard:
        if _done:
            return
        try:
            await anyio.to_thread.run_sync(_migrate_sync)
            _done = True
        except Exception:
            # Leave _done False so the next request retries; the request
            # itself proceeds and any schema error is surfaced explicitly.
            logger.exception("startup migration failed")
