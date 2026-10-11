"""Server sozlamalari (muhit o'zgaruvchilari yoki .env fayldan)."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="POS_", extra="ignore")

    # PostgreSQL: postgresql+psycopg://user:parol@host:5432/pos
    # Sinov uchun SQLite ham ishlaydi: sqlite:///./pos.db
    database_url: str = "sqlite:///./pos.db"

    # Barcha qurilmalar shu kalit bilan ulanadi (ilovadagi "API kalit").
    api_key: str = "change-me"

    # Bitta pull so'rovida qaytariladigan maksimal yozuvlar soni.
    max_pull_limit: int = 2000


settings = Settings()
