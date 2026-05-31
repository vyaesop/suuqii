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
"""
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address, default_limits=["100/minute"])
