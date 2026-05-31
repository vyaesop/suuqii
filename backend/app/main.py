from contextlib import asynccontextmanager

import sentry_sdk
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.v1 import auth, audit, debts, expenses, products, reports, sales, shifts, sync
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.core.rate_limit import limiter


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    if settings.sentry_dsn:
        sentry_sdk.init(dsn=settings.sentry_dsn, traces_sample_rate=0.1)
    yield


def create_app() -> FastAPI:
    app = FastAPI(
        title="Suuqii",
        version="0.1.0",
        description="Inventory & shop management API for small Ethiopian retail shops",
        lifespan=lifespan,
    )
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    register_exception_handlers(app)

    api = "/v1"
    app.include_router(auth.router, prefix=api)
    app.include_router(products.router, prefix=api)
    app.include_router(sales.router, prefix=api)
    app.include_router(debts.router, prefix=api)
    app.include_router(expenses.router, prefix=api)
    app.include_router(shifts.router, prefix=api)
    app.include_router(sync.router, prefix=api)
    app.include_router(audit.router, prefix=api)
    app.include_router(reports.router, prefix=api)

    @app.get("/healthz", tags=["meta"])
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
