"""Sinxronlash mantiqi: push (qabul qilish + konfliktlarni hal qilish) va pull."""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Device, ServerInfo, SyncCounter, SyncRecord

# Ilovadagi SyncEntities bilan bir xil bo'lishi shart.
ENTITIES = (
    "users",
    "categories",
    "products",
    "sales",
    "sale_items",
    "stock_movements",
    "audit_log",
)

# O'zgarmas yozuvlar: faqat qo'shiladi, hech qachon yangilanmaydi.
# Qoldiq shu harakatlar yig'indisidan hisoblanadi, shuning uchun parallel
# sotuvlar bir-birini "bosib" ketmaydi.
IMMUTABLE = {"sale_items", "stock_movements", "audit_log"}


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


def push(session: Session, device_id: str, changes: list[dict]) -> PushResult:
    result = PushResult()
    counter = _next_counter(session)
    received = now_ms()

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
            result.accepted.append({"entity": entity, "id": rid})
        elif existing.updated_at == updated_at and existing.device_id == dev:
            # Aynan shu versiya allaqachon serverda.
            result.accepted.append({"entity": entity, "id": rid})
        else:
            result.conflicts.append({"entity": entity, "id": rid, "data": existing.data})

    dev_row = session.get(Device, device_id) or Device(id=device_id, pushed_count=0)
    dev_row.last_push_at = received
    dev_row.pushed_count = (dev_row.pushed_count or 0) + len(result.accepted)
    session.add(dev_row)
    session.commit()
    return result


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
    dev_row = session.get(Device, device_id) or Device(id=device_id, pushed_count=0)
    dev_row.last_pull_at = now_ms()
    session.add(dev_row)
    session.commit()
    return {
        "changes": [{"entity": r.entity, "id": r.id, "seq": r.seq, "data": r.data} for r in rows],
        "cursor": rows[-1].seq if rows else since,
        "has_more": has_more,
        # Mijoz kursori bundan katta bo'lsa — server yangidan o'rnatilgan
        # (masalan, yangi PosServer.exe papkasi): mijoz noldan qayta yuklaydi.
        "max_seq": counter.value if counter else 0,
        "server_id": server_id(session),
    }
