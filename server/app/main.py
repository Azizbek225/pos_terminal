"""POS Terminal sinxronlash serveri.

Ishga tushirish:
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import secrets
from contextlib import asynccontextmanager
from collections import defaultdict
from datetime import datetime
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import __version__, sync
from .config import settings
from .db import Base, engine, get_session
from .models import Device, SyncRecord

@asynccontextmanager
async def lifespan(_: FastAPI):
    # Jadvallar birinchi ishga tushishda avtomatik yaratiladi.
    Base.metadata.create_all(engine)
    yield


app = FastAPI(title="POS Terminal Sync", version=__version__, lifespan=lifespan)


def require_key(x_api_key: Annotated[str | None, Header()] = None) -> None:
    if not x_api_key or not secrets.compare_digest(x_api_key, settings.api_key):
        raise HTTPException(status_code=401, detail="API kalit noto'g'ri")


def device_header(x_device_id: Annotated[str | None, Header()] = None) -> str:
    return (x_device_id or "unknown")[:64]


SessionDep = Annotated[Session, Depends(get_session)]
DeviceDep = Annotated[str, Depends(device_header)]


class Change(BaseModel):
    entity: str
    id: str
    updated_at: int | None = None
    device_id: str | None = None
    data: dict[str, Any]


class PushBody(BaseModel):
    device_id: str | None = None
    changes: list[Change] = Field(default_factory=list, max_length=5000)


@app.get("/api/health")
def health() -> dict:
    return {
        "status": "ok",
        "service": "pos-terminal-sync",
        "version": __version__,
        "time": sync.now_ms(),
    }


@app.post("/api/sync/push", dependencies=[Depends(require_key)])
def push(body: PushBody, session: SessionDep, device: DeviceDep) -> dict:
    result = sync.push(session, body.device_id or device, [c.model_dump() for c in body.changes])
    return {
        "accepted": result.accepted,
        "conflicts": result.conflicts,
        "rejected": result.rejected,
        "server_time": sync.now_ms(),
    }


@app.get("/api/sync/pull", dependencies=[Depends(require_key)])
def pull(
    session: SessionDep,
    device: DeviceDep,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1)] = 500,
) -> dict:
    return sync.pull(session, device, since, min(limit, settings.max_pull_limit))


@app.get("/api/devices", dependencies=[Depends(require_key)])
def devices(session: SessionDep) -> list[dict]:
    rows = session.execute(select(Device)).scalars().all()
    return [
        {
            "id": d.id,
            "last_push_at": d.last_push_at,
            "last_pull_at": d.last_pull_at,
            "pushed_count": d.pushed_count,
        }
        for d in rows
    ]


@app.get("/api/reports/daily", dependencies=[Depends(require_key)])
def daily_report(
    session: SessionDep,
    date_from: Annotated[str, Query(description="YYYY-MM-DD")],
    date_to: Annotated[str, Query(description="YYYY-MM-DD (shu kun ham kiradi)")],
) -> dict:
    """Barcha qurilmalar bo'yicha kunlik savdo (egasi uchun masofaviy hisobot)."""
    try:
        start = int(datetime.strptime(date_from, "%Y-%m-%d").timestamp() * 1000)
        end = int(datetime.strptime(date_to, "%Y-%m-%d").timestamp() * 1000) + 86_400_000
    except ValueError as e:
        raise HTTPException(status_code=422, detail="Sana formati: YYYY-MM-DD") from e

    rows = session.execute(select(SyncRecord).where(SyncRecord.entity == "sales")).scalars().all()
    days: dict[str, dict[str, int]] = defaultdict(lambda: {"total": 0, "count": 0})
    by_cashier: dict[str, int] = defaultdict(int)
    for r in rows:
        d = r.data
        created = int(d.get("created_at") or 0)
        if not (start <= created < end) or d.get("status") != "completed" or d.get("is_deleted"):
            continue
        key = datetime.fromtimestamp(created / 1000).strftime("%Y-%m-%d")
        days[key]["total"] += int(d.get("total") or 0)
        days[key]["count"] += 1
        by_cashier[str(d.get("cashier_name") or "")] += int(d.get("total") or 0)
    total = sum(v["total"] for v in days.values())
    count = sum(v["count"] for v in days.values())
    return {
        "days": dict(sorted(days.items())),
        "total": total,
        "count": count,
        "average": round(total / count) if count else 0,
        "by_cashier": dict(by_cashier),
    }
