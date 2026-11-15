"""Dollar kursi: Markaziy bank (cbu.uz) dan olib beradi.

Kassalar kursni o'zlari ham oladi; bu yo'l — brauzerdagi kassa (CORS sababli
cbu.uz ga to'g'ridan-to'g'ri murojaat qila olmaydi) va internetsiz, faqat
do'kon Wi-Fi'siga ulangan telefonlar uchun.
"""

from __future__ import annotations

import json
import secrets
import threading
import time
import urllib.request
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Header, HTTPException

from .config import settings

router = APIRouter()

CBU_URL = "https://cbu.uz/uz/arkhiv-kursov-valyut/json/USD/"
FALLBACK_URL = "https://open.er-api.com/v6/latest/USD"

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "data": None}
_TTL = 30 * 60


def _get_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "pos-terminal"})
    with urllib.request.urlopen(req, timeout=10) as r:  # noqa: S310 (doimiy https manzil)
        return json.loads(r.read().decode("utf-8"))


def parse_cbu(data) -> tuple[float, str] | None:
    """cbu.uz javobi: [{"Ccy": "USD", "Rate": "12050.38", "Date": "14.11.2026"}]."""
    rows = data if isinstance(data, list) else [data]
    for row in rows:
        if not isinstance(row, dict) or row.get("Ccy") != "USD":
            continue
        rate = float(str(row.get("Rate", "0")).replace(",", "."))
        nominal = float(row.get("Nominal") or 1) or 1
        d = str(row.get("Date") or "")
        try:
            iso = datetime.strptime(d, "%d.%m.%Y").strftime("%Y-%m-%d")
        except ValueError:
            iso = datetime.now().strftime("%Y-%m-%d")
        if rate > 0:
            return rate / nominal, iso
    return None


def fetch() -> dict:
    try:
        parsed = parse_cbu(_get_json(CBU_URL))
        if parsed:
            return {"rate": parsed[0], "date": parsed[1], "source": "cbu"}
    except Exception:  # noqa: BLE001 — keyingi manbaga o'tamiz
        pass
    data = _get_json(FALLBACK_URL)
    rate = float((data.get("rates") or {}).get("UZS") or 0)
    if rate <= 0:
        raise ValueError("kurs topilmadi")
    return {"rate": rate, "date": datetime.now().strftime("%Y-%m-%d"), "source": "net"}


@router.get("/api/kurs")
def kurs(x_api_key: Annotated[str | None, Header()] = None) -> dict:
    if not x_api_key or not secrets.compare_digest(x_api_key, settings.api_key):
        raise HTTPException(status_code=401, detail="API kalit noto'g'ri")
    with _lock:
        if _cache["data"] and time.time() - _cache["at"] < _TTL:
            return _cache["data"]
    try:
        data = fetch()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Kurs olinmadi: {e}") from e
    with _lock:
        _cache.update(at=time.time(), data=data)
    return data
