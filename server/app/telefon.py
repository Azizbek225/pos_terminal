"""Telefonga ilova o'rnatish: PosServer APK faylni Wi-Fi orqali beradi.

`/ulash` sahifasidagi QR — `http://<server>/telefon#pos=<ulash ma'lumoti>`.
Telefon kamerasi uni brauzerda ochadi va APK yuklanadi; o'rnatilgan ilova esa
shu QR ni skanerlab serverga ulanadi (`#` dan keyingi qism serverga bormaydi).
APK fayl PosSetup bilan PosServer.exe yoniga qo'yiladi.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse, HTMLResponse

from .config import settings

APK_NAME = "pos-terminal.apk"
DOWNLOAD_URL = "https://github.com/Azizbek225/pos_terminal/releases/download/sinov-build/pos-terminal-android.apk"
PAGE = Path(__file__).resolve().parent / "static" / "telefon.html"

router = APIRouter()


def apk_path() -> Path | None:
    p = Path(settings.apk_path)
    return p if p.is_file() else None


@router.get("/telefon", include_in_schema=False)
def phone_page() -> HTMLResponse:
    page = PAGE.read_text(encoding="utf-8")
    apk = apk_path()
    if apk:
        size = f"{apk.stat().st_size / 1024 / 1024:.0f} MB"
        page = page.replace("{{APK}}", f'<a class="go" id="dl" href="/telefon/{APK_NAME}" download>Ilovani yuklab olish ({size})</a>')
    else:
        page = page.replace(
            "{{APK}}",
            "<p>Bu kompyuterda APK fayl yo'q. Internet orqali yuklab oling:</p>"
            f'<a class="go" href="{DOWNLOAD_URL}">Ilovani yuklab olish</a>',
        )
    return HTMLResponse(page, headers={"Cache-Control": "no-store"})


@router.get(f"/telefon/{APK_NAME}", include_in_schema=False)
def download_apk() -> FileResponse:
    apk = apk_path()
    if not apk:
        raise HTTPException(status_code=404, detail="APK topilmadi")
    return FileResponse(apk, media_type="application/vnd.android.package-archive", filename=APK_NAME)
