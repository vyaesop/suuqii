import logging

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy.exc import ProgrammingError
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger(__name__)


class DomainError(Exception):
    code: str = "domain_error"
    status: int = 400

    def __init__(self, message: str, *, code: str | None = None, status: int | None = None):
        super().__init__(message)
        if code:
            self.code = code
        if status:
            self.status = status


class ConflictError(DomainError):
    code = "conflict"
    status = 409

    def __init__(self, message: str, server_payload: dict | None = None):
        super().__init__(message)
        self.server_payload = server_payload or {}


class OwnerPinRequired(DomainError):  # noqa: N818 — established public name
    code = "owner_pin_required"
    status = 403


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def _domain(_: Request, exc: DomainError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status,
            content={
                "type": "about:blank",
                "title": exc.__class__.__name__,
                "status": exc.status,
                "detail": str(exc),
                "code": exc.code,
            },
        )

    # Schema drift (missing table/column — deploy raced the migration, or
    # the migration failed) must read as an explicit, retryable 503 with a
    # machine code the mobile app can localize, never an opaque 500.
    @app.exception_handler(ProgrammingError)
    async def _schema(_: Request, exc: ProgrammingError) -> JSONResponse:
        name = type(exc.orig).__name__ if exc.orig else ""
        if name in ("UndefinedTableError", "UndefinedColumnError",
                    "UndefinedTable", "UndefinedColumn"):
            logger.error("schema out of date: %s", exc.orig)
            return JSONResponse(
                status_code=503,
                content={
                    "type": "about:blank",
                    "title": "ServiceUnavailable",
                    "status": 503,
                    "detail": "server database is being upgraded — retry shortly",
                    "code": "database_schema_outdated",
                },
                headers={"Retry-After": "10"},
            )
        raise exc

    # HTTPException raised throughout the routers gets the same problem+json
    # shape as DomainError, so clients only ever parse one error schema.
    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={
                "type": "about:blank",
                "title": "HTTPException",
                "status": exc.status_code,
                "detail": str(exc.detail),
                "code": "http_error",
            },
            headers=getattr(exc, "headers", None),
        )
