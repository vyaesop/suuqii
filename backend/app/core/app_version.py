"""
Forced-upgrade gate. When settings.min_app_version is set, every /v1
request must carry an `X-App-Version` header (semver "x.y.z") at or above
it; a missing, unparseable or older version gets a 426 problem+json with
code `app_update_required` so the mobile app can show an update screen.
/healthz and /readyz live outside /v1 and are never gated.
"""
from fastapi.responses import JSONResponse

from app.core.config import settings


def parse_semver(value: str) -> tuple[int, int, int] | None:
    """Parse "x.y.z" into an int tuple for numeric (not lexical) compare."""
    parts = value.strip().split(".")
    if len(parts) != 3:
        return None
    try:
        major, minor, patch = (int(p) for p in parts)
    except ValueError:
        return None
    if major < 0 or minor < 0 or patch < 0:
        return None
    return (major, minor, patch)


def app_version_rejection(path: str, header_value: str | None) -> JSONResponse | None:
    """Return the 426 response for an outdated client, or None to proceed."""
    minimum = settings.min_app_version
    if not minimum or not path.startswith("/v1"):
        return None
    required = parse_semver(minimum)
    if required is None:
        # Misconfigured setting must not lock every client out.
        return None
    offered = parse_semver(header_value) if header_value else None
    if offered is not None and offered >= required:
        return None
    return JSONResponse(
        status_code=426,
        content={
            "type": "about:blank",
            "title": "UpgradeRequired",
            "status": 426,
            "detail": f"app version {minimum} or newer is required — please update",
            "code": "app_update_required",
            "min_app_version": minimum,
        },
    )
