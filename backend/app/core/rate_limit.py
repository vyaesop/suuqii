"""
Shared rate limiter. Per docs/04-api-design.md & docs/07-authentication.md:

- /auth/login           10/minute per IP
- /auth/owner-pin       5/minute per IP (paired with per-user 5/15min lock)
- /auth/register-shop   5/minute per IP
- /auth/invite          10/minute per IP
- /auth/accept-invite   10/minute per IP
- /auth/refresh         30/minute per IP
- /sync/push            60/minute per IP
- /sync/pull            120/minute per IP
- everything else       default 100/minute

The limiter is module-level so route modules can import the same instance
as `main.py` (slowapi requires a single shared `Limiter` per app).

Storage: per-process memory by default, which on serverless means each
instance counts separately — the limits above are best-effort noise
reduction there, and the DB-backed per-account login/PIN lockouts in
auth.py are the real brute-force defense. Set RATE_LIMIT_REDIS_URL to
share counters across instances; the backend is resolved from the URI
string by the `limits` library, so no redis import is needed here.
"""
from slowapi import Limiter
from slowapi.util import get_remote_address

from app.core.config import settings

limiter = Limiter(
    key_func=get_remote_address,
    default_limits=["100/minute"],
    storage_uri=settings.rate_limit_redis_url or "memory://",
)
