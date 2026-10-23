"""Sinxronlash mantiqi: push (qabul qilish + konfliktlarni hal qilish) va pull."""

from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass, field

from sqlalchemy import case, inspect, select, text, update
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from .models import Device, ServerInfo, SyncCounter, SyncRecord

# Ilovadagi SyncEntities bilan bir xil bo'lishi shart.
ENTITIES = (
    "branches",
    "users",
    "categories",
    "products",
    "sales",
    "sale_items",
    "stock_movements",
    "audit_log",
    "suppliers",
    "supplier_purchases",
    "supplier_purchase_items",
    "supplier_payments",
    "customers",
    "customer_debts",
)

# O'zgarmas yozuvlar: faqat qo'shiladi, hech qachon yangilanmaydi.
# Qoldiq shu harakatlar yig'indisidan hisoblanadi, shuning uchun parallel
# sotuvlar bir-birini "bosib" ketmaydi.
IMMUTABLE = {"sale_items", "stock_movements", "audit_log", "supplier_purchase_items"}

# Hisobot indekslari uchun bog'liq yozuv maydoni (SyncRecord.ref).
REF_FIELD = {
    "sale_items": "sale_id",
    "stock_movements": "product_id",
    "supplier_purchases": "supplier_id",
    "supplier_purchase_items": "purchase_id",
    "supplier_payments": "supplier_id",
    "customer_debts": "customer_id",
}


def index_fields(entity: str, data: dict) -> tuple[int | None, str | None]:
    """(ts, ref): JSON ichidagi yaratilgan vaqt va bog'liq yozuv ID si."""
    try:
        ts = int(data.get("created_at")) if data.get("created_at") is not None else None
    except (TypeError, ValueError):
        ts = None
    field = REF_FIELD.get(entity)
    ref = str(data.get(field))[:64] if field and data.get(field) is not None else None
    return ts, ref


def migrate(engine: Engine) -> None:
    """Eski bazaga ts/ref ustunlari va indekslarini qo'shish (bir marta)."""
    from .models import SyncRecord

    cols = {c["name"] for c in inspect(engine).get_columns("sync_records")}
    if "ts" not in cols:
        # Ustun qo'shish va mavjud yozuvlarni to'ldirish bitta tranzaksiyada (yarim
        # yo'lda to'xtasa, keyingi ishga tushishda boshidan qilinadi). Bitta SQL:
        # SQLite va PostgreSQL'da ishlaydi.
        print("  Baza hisobotlar uchun yangilanmoqda (bir marta)...", flush=True)
        ref = case(
            *[(SyncRecord.entity == e, SyncRecord.data[f].as_string()) for e, f in REF_FIELD.items()],
            else_=None,
        )
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE sync_records ADD COLUMN ts BIGINT"))
            conn.execute(text("ALTER TABLE sync_records ADD COLUMN ref VARCHAR(64)"))
            conn.execute(update(SyncRecord).values(ts=SyncRecord.data["created_at"].as_integer(), ref=ref))
    # Indekslar to'ldirishdan keyin (aks holda har qatorda indeks yangilanadi).
    for idx in SyncRecord.__table__.indexes:
        idx.create(engine, checkfirst=True)


def server_id(session: Session) -> str:
    info = session.get(ServerInfo, 1)
    if info is None:
        info = ServerInfo(id=1, server_id=uuid.uuid4().hex)
        session.add(info)
        session.commit()
    return info.server_id


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass
class PushResult:
    accepted: list[dict] = field(default_factory=list)
    conflicts: list[dict] = field(default_factory=list)
    rejected: list[dict] = field(default_factory=list)


def _next_counter(session: Session) -> SyncCounter:
    """Hisoblagichni qulflab olish (PostgreSQL: SELECT ... FOR UPDATE)."""
    counter = session.execute(
        select(SyncCounter).where(SyncCounter.id == 1).with_for_update()
    ).scalar_one_or_none()
    if counter is None:
        counter = SyncCounter(id=1, value=0)
        session.add(counter)
        session.flush()
    return counter


def incoming_wins(entity: str, data: dict, updated_at: int, device_id: str, existing: SyncRecord) -> bool:
    """Konflikt qoidasi.

    1. Chek (sales): "refunded" holati har doim ustun — qaytarish bekor bo'lmaydi.
    2. Qolganlari: Last-Write-Wins — `updated_at` kattasi yutadi.
    3. Vaqt teng bo'lsa — `device_id` bo'yicha deterministik tanlov
       (barcha qurilmalar bir xil natijaga keladi).
    """
    if entity == "sales":
        ex_ref = (existing.data or {}).get("status") == "refunded"
        in_ref = data.get("status") == "refunded"
        if in_ref and not ex_ref:
            return True
        if ex_ref and not in_ref:
            return False
    if updated_at != existing.updated_at:
        return updated_at > existing.updated_at
    return device_id > (existing.device_id or "")


def _preload(session: Session, changes: list[dict]) -> None:
    """Mavjud yozuvlarni bir nechta so'rovda yuklab olish (har biriga alohida
    SELECT o'rniga): keyingi session.get() lar bazaga bormaydi."""
    by_entity: dict[str, list[str]] = {}
    for ch in changes:
        rid = ch.get("id") or (ch.get("data") or {}).get("id")
        if ch.get("entity") in ENTITIES and rid:
            by_entity.setdefault(ch["entity"], []).append(str(rid))
    for entity, ids in by_entity.items():
        for i in range(0, len(ids), 500):
            session.execute(
                select(SyncRecord).where(SyncRecord.entity == entity, SyncRecord.id.in_(ids[i : i + 500]))
            ).scalars().all()


# Bir vaqtda kelgan push'lar navbat bilan yoziladi. SQLite'da `FOR UPDATE` yo'q:
# qulfsiz ikki qurilma bir xil seq olib, biri "database is locked" / 500 xato
# olardi. PosServer bitta jarayon, shuning uchun oddiy qulf yetarli.
_PUSH_LOCK = threading.Lock()


def init(session: Session) -> None:
    """Bitta qatorli jadvallarni ishga tushishda yaratish (birinchi so'rovlar
    bir vaqtda kelganda ikkalasi ham yaratmoqchi bo'lib xato bermasin)."""
    server_id(session)
    if session.get(SyncCounter, 1) is None:
        session.add(SyncCounter(id=1, value=0))
        session.commit()


def push(session: Session, device_id: str, changes: list[dict]) -> PushResult:
    with _PUSH_LOCK:
        return _push(session, device_id, changes)


def _push(session: Session, device_id: str, changes: list[dict]) -> PushResult:
    result = PushResult()
    counter = _next_counter(session)
    received = now_ms()
    _preload(session, changes)

    for ch in changes:
        entity = ch.get("entity")
        data = ch.get("data")
        rid = ch.get("id") or (data or {}).get("id")
        if entity not in ENTITIES or not isinstance(data, dict) or not rid:
            result.rejected.append({"entity": entity, "id": rid, "reason": "invalid"})
            continue
        updated_at = int(data.get("updated_at") or ch.get("updated_at") or 0)
        dev = str(data.get("device_id") or ch.get("device_id") or device_id)
        deleted = bool(data.get("is_deleted") or False)
        ts, ref = index_fields(entity, data)

        existing = session.get(SyncRecord, (entity, rid))
        if existing is None:
            counter.value += 1
            session.add(
                SyncRecord(
                    entity=entity,
                    id=rid,
                    data=data,
                    updated_at=updated_at,
                    device_id=dev,
                    deleted=deleted,
                    seq=counter.value,
                    received_at=received,
                    ts=ts,
                    ref=ref,
                )
            )
            result.accepted.append({"entity": entity, "id": rid})
            continue

        if entity in IMMUTABLE:
            # Takroriy yuborish (javob yo'qolgan bo'lishi mumkin) — idempotent.
            result.accepted.append({"entity": entity, "id": rid})
            continue

        if incoming_wins(entity, data, updated_at, dev, existing):
            counter.value += 1
            existing.data = data
            existing.updated_at = updated_at
            existing.device_id = dev
            existing.deleted = deleted
            existing.seq = counter.value
            existing.received_at = received
            existing.ts = ts
            existing.ref = ref
            result.accepted.append({"entity": entity, "id": rid})
        elif existing.updated_at == updated_at and existing.device_id == dev:
            # Aynan shu versiya allaqachon serverda.
            result.accepted.append({"entity": entity, "id": rid})
        else:
            result.conflicts.append({"entity": entity, "id": rid, "data": existing.data})

    dev_row = session.get(Device, device_id) or Device(id=device_id, pushed_count=0)
    dev_row.last_push_at = received
    dev_row.last_pull_at = max(dev_row.last_pull_at or 0, LAST_PULL.get(device_id, 0)) or None
    dev_row.pushed_count = (dev_row.pushed_count or 0) + len(result.accepted)
    session.add(dev_row)
    session.commit()
    return result


# Qurilmalarning oxirgi pull vaqti xotirada: pull bazaga umuman yozmaydi, shuning
# uchun boshqa qurilma katta paket yozayotganda (SQLite qulfi) kutib qolmaydi.
# Bazaga keyingi push bilan birga tushadi.
LAST_PULL: dict[str, int] = {}


def devices(session: Session) -> list[dict]:
    rows = {d.id: d for d in session.execute(select(Device)).scalars()}
    out = []
    for dev_id in rows.keys() | LAST_PULL.keys():
        d = rows.get(dev_id)
        out.append({
            "id": dev_id,
            "last_push_at": d.last_push_at if d else None,
            "last_pull_at": max((d.last_pull_at or 0) if d else 0, LAST_PULL.get(dev_id, 0)) or None,
            "pushed_count": (d.pushed_count or 0) if d else 0,
        })
    return out


def pull(session: Session, device_id: str, since: int, limit: int) -> dict:
    rows = (
        session.execute(
            select(SyncRecord).where(SyncRecord.seq > since).order_by(SyncRecord.seq).limit(limit + 1)
        )
        .scalars()
        .all()
    )
    has_more = len(rows) > limit
    rows = rows[:limit]
    counter = session.get(SyncCounter, 1)
    LAST_PULL[device_id] = now_ms()
    return {
        "changes": [{"entity": r.entity, "id": r.id, "seq": r.seq, "data": r.data} for r in rows],
        "cursor": rows[-1].seq if rows else since,
        "has_more": has_more,
        # Mijoz kursori bundan katta bo'lsa — server yangidan o'rnatilgan
        # (masalan, yangi PosServer.exe papkasi): mijoz noldan qayta yuklaydi.
        "max_seq": counter.value if counter else 0,
        "server_id": server_id(session),
    }
