from functools import lru_cache

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
    default_locale: str = "en"
    timezone: str = "Africa/Addis_Ababa"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", case_sensitive=False)


@lru_cache
def get_settings() -> Settings:
    return Settings()  # pyright: ignore[reportCallIssue]


settings = get_settings()
