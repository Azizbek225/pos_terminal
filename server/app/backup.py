"""Bazaning zaxira nusxalari (soatlik, ZIP).

Har soatda — baza o'zgargan bo'lsa — pos.db ning nusxasi ZIP qilib saqlanadi:
asosiy papkada (standart: pos.db yonidagi `nusxalar`) va xohlansa Google Drive
papkasida ham (kompyuterdagi "Google Drive for desktop" papkasi — Drive o'zi
bulutga yuklaydi). Eskilari tozalanadi: oxirgi 24 ta, har kunning oxirgisi
(30 kun) va har oyning oxirgisi (12 oy) qoladi.

Tiklash: tanlangan nusxa bazaga yoziladi (oldin joriy holatdan nusxa olinadi),
server ID yangilanadi — ilovalar yangi bazani ko'rib, o'zidagi yozuvlarni
qaytadan yuboradi, shuning uchun telefonlardagi yangi ma'lumot yo'qolmaydi.
"""

from __future__ import annotations

import os
import re
import shutil
import sqlite3
import tempfile
import threading
import time
import uuid
import zipfile
from contextlib import closing
from datetime import datetime
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Cookie, Depends, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session

from . import sync
from .config import settings
from .db import SessionLocal, engine, get_session
from .models import ServerInfo, ServerSetting, SyncCounter

router = APIRouter()
SessionDep = Annotated[Session, Depends(get_session)]

KEEP_LAST, KEEP_DAYS, KEEP_MONTHS = 24, 30, 12
INTERVAL_S = 3600
NAME_RE = re.compile(r"^pos_(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})(?:_[a-z-]+)?\.zip$")
DRIVE_SUBDIR = "POS nusxalar"

K_DIR, K_DRIVE = "backup.dir", "backup.drive_dir"
K_SEQ, K_AT, K_ERR, K_DRIVE_ERR = "backup.last_seq", "backup.last_at", "backup.last_error", "backup.drive_error"

_LOCK = threading.Lock()
_thread: threading.Thread | None = None
_stop = threading.Event()


# ---------------------------------------------------------------------------
#  Yo'llar va sozlamalar
# ---------------------------------------------------------------------------

def db_path() -> Path | None:
    url = settings.database_url
    if not url.startswith("sqlite:///"):
        return None  # PostgreSQL — o'z vositalari bilan zaxiralanadi.
    return Path(url[len("sqlite:///"):]).resolve()


def default_dir() -> Path:
    db = db_path()
    return (db.parent if db else Path.cwd()) / "nusxalar"


def _get(session: Session, key: str) -> str:
    row = session.get(ServerSetting, key)
    return row.value if row else ""


def _set(session: Session, key: str, value: str) -> None:
    value = value[:255]
    row = session.get(ServerSetting, key)
    if row is None:
        session.add(ServerSetting(key=key, value=value))
    else:
        row.value = value


def backup_dir(session: Session) -> Path:
    return Path(_get(session, K_DIR) or default_dir())


def drive_dir(session: Session) -> Path | None:
    v = _get(session, K_DRIVE)
    return Path(v) if v else None


def detect_drive(roots: list[Path] | None = None) -> Path | None:
    """Kompyuterdagi Google Drive papkasini topish (Google Drive for desktop)."""
    if roots is None:
        roots = []
        if os.name == "nt":
            roots += [Path(f"{c}:\\") for c in "GHIJKLMNOPQRSTUVWXYZDEF"]
        home = Path.home()
        roots += [home, home / "Google Drive"]
    names = ("My Drive", "Мой диск", "Il mio Drive", "Meine Ablage", "Mon Drive", "Google Drive")
    for root in roots:
        for n in names:
            p = root / n
            try:
                if p.is_dir():
                    return p / DRIVE_SUBDIR
            except OSError:
                continue
    return None


# ---------------------------------------------------------------------------
#  Nusxa olish va tozalash
# ---------------------------------------------------------------------------

def _stamp(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d_%H-%M-%S")


def parse_name(name: str) -> datetime | None:
    m = NAME_RE.match(name)
    if not m:
        return None
    try:
        return datetime.strptime(f"{m[1]} {m[2]}:{m[3]}:{m[4]}", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None


def to_keep(names: list[str]) -> set[str]:
    """Qoladiganlar: oxirgi 24 ta, har kunning oxirgisi (30 kun), har oyning oxirgisi (12 oy)."""
    dated = sorted(((parse_name(n), n) for n in names if parse_name(n)), reverse=True)
    keep = {n for _, n in dated[:KEEP_LAST]}
    days: dict[str, str] = {}
    months: dict[str, str] = {}
    for dt, n in dated:
        days.setdefault(dt.strftime("%Y-%m-%d"), n)
        months.setdefault(dt.strftime("%Y-%m"), n)
    keep |= set(list(days.values())[:KEEP_DAYS])
    keep |= set(list(months.values())[:KEEP_MONTHS])
    return keep


def rotate(folder: Path) -> int:
    try:
        names = [p.name for p in folder.iterdir() if p.is_file() and NAME_RE.match(p.name)]
    except OSError:
        return 0
    keep = to_keep(names)
    removed = 0
    for n in names:
        if n not in keep:
            try:
                (folder / n).unlink()
                removed += 1
            except OSError:
                pass
    return removed


def _snapshot(src: Path, dst: Path) -> None:
    """Ishlab turgan bazadan izchil nusxa (SQLite backup API — yozuvlar to'xtamaydi)."""
    with closing(sqlite3.connect(str(src), timeout=30)) as s, closing(sqlite3.connect(str(dst))) as d:
        s.backup(d)
        # Bitta mustaqil fayl bo'lsin (-wal faylsiz).
        d.execute("PRAGMA journal_mode=DELETE")


def _zip(db_file: Path, target: Path) -> None:
    part = target.with_suffix(".part")
    with zipfile.ZipFile(part, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.write(db_file, "pos.db")
    os.replace(part, target)


def _counter(session: Session) -> int:
    c = session.get(SyncCounter, 1)
    return c.value if c else 0


def make_backup(force: bool = False, suffix: str = "", now: datetime | None = None) -> dict:
    """Nusxa olish. force=False bo'lsa — oxirgisidan beri o'zgarish bo'lmasa o'tkazib yuboriladi."""
    src = db_path()
    if src is None or not src.exists():
        return {"ok": False, "skipped": True, "reason": "Baza SQLite emas"}
    with _LOCK, SessionLocal() as session:
        seq = _counter(session)
        if not force and _get(session, K_AT) and _get(session, K_SEQ) == str(seq):
            return {"ok": True, "skipped": True, "reason": "O'zgarish yo'q"}
        folder = backup_dir(session)
        name = f"pos_{_stamp(now or datetime.now())}{'_' + suffix if suffix else ''}.zip"
        result: dict = {"ok": True, "skipped": False, "name": name}
        try:
            folder.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=folder) as tmp:
                snap = Path(tmp) / "pos.db"
                _snapshot(src, snap)
                _zip(snap, folder / name)
            result["size"] = (folder / name).stat().st_size
            rotate(folder)
            _set(session, K_ERR, "")
        except Exception as e:  # noqa: BLE001 — xato sahifada ko'rinadi, server to'xtamaydi
            _set(session, K_ERR, f"{datetime.now():%d.%m %H:%M} — {e}")
            session.commit()
            return {"ok": False, "skipped": False, "reason": str(e)}

        drive = drive_dir(session)
        if drive is not None:
            try:
                if not drive.parent.exists():
                    raise OSError(f"Google Drive papkasi topilmadi: {drive.parent}")
                drive.mkdir(exist_ok=True)
                shutil.copy2(folder / name, drive / name)
                rotate(drive)
                _set(session, K_DRIVE_ERR, "")
                result["drive"] = True
            except Exception as e:  # noqa: BLE001
                _set(session, K_DRIVE_ERR, f"{datetime.now():%d.%m %H:%M} — {e}")
                result["drive"] = False
        _set(session, K_SEQ, str(seq))
        _set(session, K_AT, str(int(time.time())))
        session.commit()
        return result


def _loop() -> None:
    _stop.wait(60)  # ishga tushishda baza migratsiyasi tugasin
    while not _stop.is_set():
        try:
            with SessionLocal() as session:
                last = int(_get(session, K_AT) or 0)
            if time.time() - last >= INTERVAL_S:
                make_backup()
        except Exception as e:  # noqa: BLE001
            print(f"Zaxira nusxa xatosi: {e}", flush=True)
        _stop.wait(60)


def start() -> None:
    global _thread
    if not settings.backup_auto or db_path() is None or (_thread and _thread.is_alive()):
        return
    _stop.clear()
    _thread = threading.Thread(target=_loop, name="pos-backup", daemon=True)
    _thread.start()


def stop() -> None:
    _stop.set()


# ---------------------------------------------------------------------------
#  Tiklash
# ---------------------------------------------------------------------------

def restore(zip_file: Path) -> dict:
    """Nusxani joriy bazaga yozish. Oldin joriy holatdan nusxa olinadi."""
    from . import kassa

    target = db_path()
    if target is None:
        raise HTTPException(status_code=400, detail="Baza SQLite emas")
    with tempfile.TemporaryDirectory() as tmp:
        try:
            with zipfile.ZipFile(zip_file) as z:
                z.extract("pos.db", tmp)
        except (zipfile.BadZipFile, KeyError) as e:
            raise HTTPException(status_code=400, detail=f"Nusxa fayli buzilgan: {e}") from e
        src = Path(tmp) / "pos.db"
        with closing(sqlite3.connect(str(src))) as c:
            if c.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise HTTPException(status_code=400, detail="Nusxa fayli buzilgan")
        safety = make_backup(force=True, suffix="tiklashdan-oldin")
        with sync._PUSH_LOCK, kassa._LOCK, _LOCK:
            engine.dispose()
            with closing(sqlite3.connect(str(src))) as s, closing(sqlite3.connect(str(target), timeout=30)) as d:
                s.backup(d)
            engine.dispose()
    with SessionLocal() as session:
        # Yangi server ID: ilovalar bazani "boshqa" deb bilib, o'zidagi barcha
        # yozuvlarni qayta yuboradi va noldan yuklaydi — yangi savdolar yo'qolmaydi.
        info = session.get(ServerInfo, 1)
        if info is None:
            session.add(ServerInfo(id=1, server_id=uuid.uuid4().hex))
        else:
            info.server_id = uuid.uuid4().hex
        _set(session, K_SEQ, "")
        session.commit()
    return {"ok": True, "safety": safety.get("name")}


# ---------------------------------------------------------------------------
#  API va sahifa (server kompyuterining o'zi yoki bosh admin)
# ---------------------------------------------------------------------------

def _guard(request: Request, session: Session, pos_web: str | None) -> None:
    from .web import _owner_or_local

    _owner_or_local(request, session, pos_web)


def _files(folder: Path | None, where: str) -> list[dict]:
    if folder is None:
        return []
    try:
        items = [p for p in folder.iterdir() if p.is_file() and NAME_RE.match(p.name)]
    except OSError:
        return []
    out = []
    for p in items:
        st = p.stat()
        out.append({"name": p.name, "where": where, "size": st.st_size,
                    "time": parse_name(p.name).strftime("%d.%m.%Y %H:%M"),
                    "before_restore": "tiklashdan-oldin" in p.name})
    return sorted(out, key=lambda f: f["name"], reverse=True)


def status(session: Session) -> dict:
    folder, drive = backup_dir(session), drive_dir(session)
    local = _files(folder, "local")
    remote = _files(drive, "drive")
    last = int(_get(session, K_AT) or 0)
    return {
        "supported": db_path() is not None,
        "auto": settings.backup_auto,
        "dir": str(folder),
        "default_dir": str(default_dir()),
        "drive_dir": str(drive) if drive else "",
        "drive_suggest": str(detect_drive() or ""),
        "last_at": datetime.fromtimestamp(last).strftime("%d.%m.%Y %H:%M") if last else "",
        "error": _get(session, K_ERR),
        "drive_error": _get(session, K_DRIVE_ERR) if drive else "",
        "local": local,
        "drive": remote,
        "local_size": sum(f["size"] for f in local),
        "drive_size": sum(f["size"] for f in remote),
        "db_size": db_path().stat().st_size if db_path() and db_path().exists() else 0,
    }


class BackupSettings(BaseModel):
    dir: str = ""
    drive_dir: str = ""


class FileRef(BaseModel):
    name: str
    where: str = "local"


def _resolve(session: Session, name: str, where: str) -> Path:
    folder = drive_dir(session) if where == "drive" else backup_dir(session)
    if folder is None or not NAME_RE.match(name):
        raise HTTPException(status_code=404, detail="Nusxa topilmadi")
    p = folder / name
    if not p.is_file():
        raise HTTPException(status_code=404, detail="Nusxa topilmadi")
    return p


@router.get("/api/backup")
def api_status(request: Request, session: SessionDep, pos_web: Annotated[str | None, Cookie()] = None) -> dict:
    _guard(request, session, pos_web)
    return status(session)


@router.post("/api/backup/settings")
def api_settings(body: BackupSettings, request: Request, session: SessionDep,
                 pos_web: Annotated[str | None, Cookie()] = None) -> dict:
    _guard(request, session, pos_web)
    folder = body.dir.strip().strip('"')
    drive = body.drive_dir.strip().strip('"')
    if folder:
        try:
            Path(folder).mkdir(parents=True, exist_ok=True)
            probe = Path(folder) / ".yozish-sinovi"
            probe.write_text("ok")
            probe.unlink()
        except OSError as e:
            raise HTTPException(status_code=422, detail=f"Papkaga yozib bo'lmadi: {e}") from e
        if Path(folder).resolve() == default_dir().resolve():
            folder = ""
    if drive and not Path(drive).parent.exists():
        raise HTTPException(status_code=422, detail="Google Drive papkasi topilmadi. Google Drive for desktop o'rnatilganmi?")
    _set(session, K_DIR, folder)
    _set(session, K_DRIVE, drive)
    if not drive:
        _set(session, K_DRIVE_ERR, "")
    session.commit()
    return status(session)


@router.post("/api/backup/now")
def api_now(request: Request, session: SessionDep, pos_web: Annotated[str | None, Cookie()] = None) -> dict:
    _guard(request, session, pos_web)
    res = make_backup(force=True)
    if not res.get("ok"):
        raise HTTPException(status_code=500, detail=res.get("reason") or "Nusxa olinmadi")
    session.expire_all()
    return {**res, "status": status(session)}


@router.get("/api/backup/file")
def api_file(request: Request, session: SessionDep, name: str = Query(...), where: str = Query("local"),
             pos_web: Annotated[str | None, Cookie()] = None) -> FileResponse:
    _guard(request, session, pos_web)
    return FileResponse(_resolve(session, name, where), filename=name, media_type="application/zip")


@router.post("/api/backup/restore")
def api_restore(body: FileRef, request: Request, session: SessionDep,
                pos_web: Annotated[str | None, Cookie()] = None) -> dict:
    _guard(request, session, pos_web)
    path = _resolve(session, body.name, body.where)
    session.close()
    with tempfile.TemporaryDirectory() as tmp:
        # Drive papkasidagi fayl tiklash paytida o'zgarmasin.
        local = Path(tmp) / body.name
        shutil.copy2(path, local)
        return restore(local)


@router.get("/nusxalar", include_in_schema=False)
def page(request: Request, session: SessionDep, pos_web: Annotated[str | None, Cookie()] = None) -> Response:
    try:
        _guard(request, session, pos_web)
    except HTTPException as e:
        if e.status_code == 401:
            return RedirectResponse("/panel")
        raise
    html = (Path(__file__).parent / "static" / "nusxalar.html").read_text(encoding="utf-8")
    return HTMLResponse(html, headers={"Cache-Control": "no-store"})
