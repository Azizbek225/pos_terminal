"""POS Terminal sinxronlash serveri.

Ishga tushirish:
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import re
import secrets
from contextlib import asynccontextmanager
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import __version__, printers, sync, web
from .config import settings
from .db import Base, SessionLocal, engine, get_session
from .models import SyncRecord

@asynccontextmanager
async def lifespan(_: FastAPI):
    # Jadvallar birinchi ishga tushishda avtomatik yaratiladi.
    Base.metadata.create_all(engine)
    sync.migrate(engine)
    with SessionLocal() as session:
        sync.init(session)
    yield


# Ilovadagi kDefaultBranchId bilan bir xil.
DEFAULT_BRANCH_ID = "00000000-0000-4000-8000-200000000001"

app = FastAPI(title="POS Terminal Sync", version=__version__, lifespan=lifespan)
app.include_router(web.router)


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
def health(session: SessionDep) -> dict:
    return {
        "status": "ok",
        "server_id": sync.server_id(session),
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
    return sync.devices(session)


# ---------------------------------------------------------------------------
#  Tovar rasmlari: bazada faqat fayl nomi sinxronlanadi, faylning o'zi shu yerda.
# ---------------------------------------------------------------------------

_IMAGE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,80}\.(jpg|jpeg|png|webp|gif|bmp|heic)$", re.IGNORECASE)
MAX_IMAGE_BYTES = 10 * 1024 * 1024


def _images_dir() -> Path:
    d = Path(settings.images_dir)
    d.mkdir(parents=True, exist_ok=True)
    return d


def _image_path(name: str) -> Path:
    if not _IMAGE_NAME.match(name):
        raise HTTPException(status_code=400, detail="Rasm nomi noto'g'ri")
    return _images_dir() / name


@app.get("/api/images", dependencies=[Depends(require_key)])
def list_images() -> dict:
    return {"names": sorted(p.name for p in _images_dir().iterdir() if p.is_file() and _IMAGE_NAME.match(p.name))}


@app.put("/api/images/{name}", dependencies=[Depends(require_key)])
async def upload_image(name: str, request: Request) -> dict:
    path = _image_path(name)
    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="Bo'sh fayl")
    if len(body) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Rasm juda katta")
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_bytes(body)
    tmp.replace(path)
    return {"name": name, "size": len(body)}


@app.get("/api/images/{name}", dependencies=[Depends(require_key)])
def download_image(name: str) -> FileResponse:
    path = _image_path(name)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Rasm topilmadi")
    return FileResponse(path)


MAX_PRINT_BYTES = 2 * 1024 * 1024


@app.get("/api/printers", dependencies=[Depends(require_key)])
def list_printers() -> dict:
    """Server turgan kompyuterdagi printerlar (telefon chekni shu yerga yuboradi)."""
    return {"printers": printers.list_printers()}


@app.post("/api/print", dependencies=[Depends(require_key)])
async def print_raw(request: Request, printer: Annotated[str, Query(min_length=1, max_length=200)]) -> dict:
    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="Bo'sh chek")
    if len(body) > MAX_PRINT_BYTES:
        raise HTTPException(status_code=413, detail="Chek juda katta")
    try:
        printers.print_raw(printer, body)
    except printers.PrintError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    return {"printed": len(body), "printer": printer}


@app.get("/api/reports/daily", dependencies=[Depends(require_key)])
def daily_report(
    session: SessionDep,
    date_from: Annotated[str, Query(description="YYYY-MM-DD")],
    date_to: Annotated[str, Query(description="YYYY-MM-DD (shu kun ham kiradi)")],
    branch_id: Annotated[str | None, Query(description="Faqat shu filial (bo'sh — hammasi)")] = None,
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
        # Filial qo'shilishidan oldingi cheklar — asosiy filialniki.
        if branch_id and (d.get("branch_id") or DEFAULT_BRANCH_ID) != branch_id:
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
