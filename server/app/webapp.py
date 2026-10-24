"""Ilovaning o'zi brauzerda: Flutter web build `/app/` da beriladi.

Ilova brauzerda ham telefondagi kabi o'z bazasida ishlaydi va shu serverga
sinxronlanadi. Server manzili va API kalit sahifaga qo'yiladi
(`window.POS_CONFIG`), shuning uchun hech narsa sozlanmaydi — faqat login.
Kalit faqat tizimga kirgan xodimga beriladi (web kassa logini).
"""

from __future__ import annotations

import json
import mimetypes
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Cookie, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session

from .config import settings
from .db import SessionLocal

# Windows'da .wasm turi ro'yxatda bo'lmasligi mumkin — brauzer uni rad etadi.
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("text/javascript", ".mjs")

WEBAPP_DIR = Path(__file__).resolve().parent / "static" / "webapp"
PLACEHOLDER = "<!--POS_CONFIG-->"

router = APIRouter()


def available() -> bool:
    return (WEBAPP_DIR / "index.html").is_file()


def _logged_in(session: Session, pos_web: str | None) -> bool:
    from .kassa import kassa_user

    try:
        kassa_user(session, pos_web)
        return True
    except HTTPException:
        return False


@router.get("/app", include_in_schema=False)
@router.get("/app/", include_in_schema=False)
@router.get("/app/index.html", include_in_schema=False)
def index(request: Request, pos_web: Annotated[str | None, Cookie()] = None) -> Response:
    if not available():
        return RedirectResponse("/kassa")
    with SessionLocal() as session:
        if not _logged_in(session, pos_web):
            return RedirectResponse("/kassa?next=/app/")
    origin = str(request.base_url).rstrip("/")
    if request.headers.get("x-forwarded-proto") == "https" and origin.startswith("http://"):
        origin = "https://" + origin[len("http://"):]  # Tailscale Funnel orqali
    cfg = json.dumps({"url": origin, "key": settings.api_key}).replace("</", "<\\/")
    page = (WEBAPP_DIR / "index.html").read_text(encoding="utf-8")
    page = page.replace(PLACEHOLDER, f"<script>window.POS_CONFIG = {cfg};</script>", 1)
    return HTMLResponse(page, headers={"Cache-Control": "no-store"})


def mount(app: FastAPI) -> None:
    """Statik fayllar (main.dart.js, sqlite3.wasm ...). Build bo'lmasa — hech narsa."""
    if WEBAPP_DIR.is_dir():
        app.mount("/app", StaticFiles(directory=WEBAPP_DIR), name="webapp")
