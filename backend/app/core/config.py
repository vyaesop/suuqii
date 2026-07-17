import json
from functools import lru_cache

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    database_url: str
    database_url_sync: str | None = None
    jwt_secret: str
    jwt_secret_previous: str | None = None
    jwt_access_ttl_min: int = 60
    jwt_refresh_ttl_days: int = 30
    jwt_owner_challenge_ttl_min: int = 5
    allowed_origins: list[str] = ["*"]
    fcm_project_id: str | None = None
    fcm_private_key: str | None = None
    sentry_dsn: str | None = None
    log_level: str = "INFO"
    # Shared slowapi/limits storage (e.g. redis://host:6379/0). Empty keeps
    # per-process memory — fine for a single instance, per-instance (weak)
    # on serverless; the DB-backed account lockout covers brute force there.
    rate_limit_redis_url: str = ""
    # Oldest mobile app version (semver "x.y.z") allowed on /v1. Empty
    # disables the check. Older/missing X-App-Version headers get a 426.
    min_app_version: str = ""
    # Bring the DB schema to head on first request per process (serverless
    # has no deploy hook to run alembic). Disable for test harnesses.
    migrate_on_start: bool = True
    default_locale: str = "en"
    timezone: str = "Africa/Addis_Ababa"

    @field_validator("allowed_origins", mode="before")
    @classmethod
    def parse_allowed_origins(cls, value: object) -> list[str] | object:
        if isinstance(value, str):
            raw = value.strip()
            if not raw:
                return []
            if raw == "*":
                return ["*"]
            if raw.startswith("["):
                return json.loads(raw)
            return [origin.strip() for origin in raw.split(",") if origin.strip()]
        return value

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        enable_decoding=False,
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()  # pyright: ignore[reportCallIssue]


settings = get_settings()
