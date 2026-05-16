from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


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
