from contextlib import asynccontextmanager

import sentry_sdk
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.v1 import auth, audit, debts, expenses, products, reports, sales, shifts, shops, supplies, sync
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.core.rate_limit import limiter
from app.db.bootstrap import ensure_migrated


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    await ensure_migrated()
    yield


def create_app() -> FastAPI:
    # Init at import time, not in lifespan — on serverless the lifespan hook
    # is not guaranteed to run before the first request is handled.
    if settings.sentry_dsn:
        sentry_sdk.init(dsn=settings.sentry_dsn, traces_sample_rate=0.1)

    app = FastAPI(
        title="Suuqii",
        version="0.1.0",
        description="Inventory & shop management API for small Ethiopian retail shops",
        lifespan=lifespan,
    )
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    # Wildcard origins + credentials is an invalid (and insecure) combination;
    # browsers reject it. Only allow credentials for an explicit origin list.
    wildcard = settings.allowed_origins == ["*"]
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_credentials=not wildcard,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    register_exception_handlers(app)

    # Belt-and-braces with lifespan: Vercel's runtime is not guaranteed to
    # run ASGI startup before the first request, so gate requests too.
    # After the first success this is a boolean check.
    @app.middleware("http")
    async def _migration_gate(request, call_next):  # noqa: ANN001, ANN202
        await ensure_migrated()
        return await call_next(request)

    api = "/v1"
    app.include_router(auth.router, prefix=api)
    app.include_router(products.router, prefix=api)
    app.include_router(sales.router, prefix=api)
    app.include_router(debts.router, prefix=api)
    app.include_router(expenses.router, prefix=api)
    app.include_router(shifts.router, prefix=api)
    app.include_router(shops.router, prefix=api)
    app.include_router(supplies.router, prefix=api)
    app.include_router(sync.router, prefix=api)
    app.include_router(audit.router, prefix=api)
    app.include_router(reports.router, prefix=api)

    @app.get("/healthz", tags=["meta"])
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
