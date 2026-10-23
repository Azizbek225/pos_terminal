"""Server jadvallari.

Server har bir jadval uchun alohida sxema saqlamaydi: barcha sinxronlanadigan
yozuvlar universal `sync_records` jadvalida JSON ko'rinishida turadi. Bu:
  * mobil/desktop ilovadagi sxema o'zgarsa ham serverni migratsiya qilish
    shart emasligini;
  * konfliktlarni hal qilish qoidasi barcha jadvallar uchun bir xil bo'lishini
    ta'minlaydi.
Hisobotlar uchun PostgreSQL'da `data->>'total'` kabi JSONB so'rovlar
yoki tayyor VIEW lardan (`sql/views.sql`) foydalanish mumkin.
"""

from sqlalchemy import JSON, BigInteger, Boolean, Index, Integer, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base

# PostgreSQL da JSONB, boshqa bazalarda oddiy JSON.
JsonType = JSON().with_variant(JSONB(), "postgresql")


class SyncRecord(Base):
    __tablename__ = "sync_records"

    entity: Mapped[str] = mapped_column(String(40), primary_key=True)
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    data: Mapped[dict] = mapped_column(JsonType, nullable=False)
    updated_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    device_id: Mapped[str] = mapped_column(String(64), default="")
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    # Monoton o'suvchi global tartib raqami — pull kursori.
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False)
    received_at: Mapped[int] = mapped_column(BigInteger, nullable=False)
    # Hisobotlar uchun indekslangan nusxalar (JSON ichidan): yaratilgan vaqt va
    # bog'liq yozuv (chek qatori -> chek, harakat -> tovar ...). Millionlab
    # yozuvda web panel butun jadvalni o'qimasligi uchun.
    ts: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    ref: Mapped[str | None] = mapped_column(String(64), nullable=True)

    __table_args__ = (
        Index("ix_sync_records_seq", "seq", unique=True),
        Index("ix_sync_records_entity_ts", "entity", "ts"),
        Index("ix_sync_records_entity_ref", "entity", "ref"),
    )


class SyncCounter(Base):
    """Bitta qatorli hisoblagich. `SELECT ... FOR UPDATE` bilan bloklanadi —
    shuning uchun seq qiymatlari commit tartibida beriladi va pull hech
    qachon yozuvni o'tkazib yubormaydi."""

    __tablename__ = "sync_counter"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    value: Mapped[int] = mapped_column(BigInteger, default=0)


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    last_push_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    last_pull_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    pushed_count: Mapped[int] = mapped_column(BigInteger, default=0)


class ServerInfo(Base):
    """Bitta qatorli: shu server bazasining tasodifiy ID si. Baza yangidan
    boshlansa (yangi PosServer papkasi), ID o'zgaradi va qurilmalar barcha
    ma'lumotlarini qayta yuboradi."""

    __tablename__ = "server_info"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    server_id: Mapped[str] = mapped_column(String(64), nullable=False)
