"""Ma'lumotlar bazasi ulanishi va sessiyalar."""

from collections.abc import Iterator

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import settings


class Base(DeclarativeBase):
    pass


def make_engine(url: str):
    is_sqlite = url.startswith("sqlite")
    engine = create_engine(
        url,
        pool_pre_ping=True,
        # timeout: boshqa qurilma yozayotgan bo'lsa, "database is locked" o'rniga kutadi.
        connect_args={"check_same_thread": False, "timeout": 30} if is_sqlite else {},
    )
    if is_sqlite:
        @event.listens_for(engine, "connect")
        def _pragma(dbapi_conn, _):  # pragma: no cover - faqat SQLite
            cur = dbapi_conn.cursor()
            cur.execute("PRAGMA journal_mode=WAL")
            # WAL bilan xavfsiz va har commit'da diskka to'liq yozishdan ancha tez.
            cur.execute("PRAGMA synchronous=NORMAL")
            cur.close()
    return engine


engine = make_engine(settings.database_url)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_session() -> Iterator[Session]:
    with SessionLocal() as session:
        yield session
