from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


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


class OwnerPinRequired(DomainError):
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
