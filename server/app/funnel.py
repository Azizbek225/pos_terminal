"""Internetdan ochish: Tailscale Funnel orqali doimiy https havola.

PosServer kompyuterida Tailscale o'rnatilgan bo'lsa, bitta tugma
`tailscale funnel --bg <port>` ni ishga tushiradi va server
https://<kompyuter>.<tailnet>.ts.net manzilida internetdan ochiladi.
Telefonga hech narsa o'rnatilmaydi — oddiy brauzer yetadi. Havola o'zgarmaydi
va Tailscale o'zi kompyuter qayta yonganda ham uni tiklaydi.

Funnel orqali kelgan so'rov serverga 127.0.0.1 dan kelgandek ko'rinadi, shuning
uchun `is_forwarded()` bilan "kompyuterning o'zi" dan ajratiladi.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time

from fastapi import Request

DOWNLOAD_URL = "https://tailscale.com/download/windows"
_URL = re.compile(r"https://login\.tailscale\.com/\S+")
_WIN_PATHS = (r"C:\Program Files\Tailscale\tailscale.exe", r"C:\Program Files (x86)\Tailscale\tailscale.exe")

_lock = threading.Lock()
_job: dict = {}  # ishlab turgan `tailscale login/funnel`: {"proc", "action", "url", "out"}
_cache: tuple[float, dict] | None = None
CACHE_SECONDS = 20


def is_forwarded(request: Request) -> bool:
    """So'rov boshqa joydan proksi (Tailscale Funnel/serve) orqali kelganmi."""
    h = request.headers
    return any(k in h for k in ("tailscale-funnel-request", "x-forwarded-for", "forwarded", "tailscale-user-login"))


def binary() -> str | None:
    found = os.environ.get("POS_TAILSCALE") or shutil.which("tailscale")
    if found and os.path.exists(found):
        return found
    if os.name == "nt":
        return next((p for p in _WIN_PATHS if os.path.exists(p)), None)
    return None


def _flags() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _run(*args: str, timeout: float = 10) -> subprocess.CompletedProcess | None:
    exe = binary()
    if not exe:
        return None
    try:
        return subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL, creationflags=_flags())
    except (OSError, subprocess.TimeoutExpired):
        return None


def _json(*args: str) -> dict:
    r = _run(*args)
    if r is None or r.returncode != 0:
        return {}
    try:
        return json.loads(r.stdout or "{}") or {}
    except ValueError:
        return {}


def _job_state() -> dict | None:
    """Kutilayotgan tasdiq (login yoki funnel ruxsati) — havolasi bilan."""
    proc = _job.get("proc")
    if proc is None:
        return None
    if proc.poll() is not None or time.time() - _job["started"] > 600:
        if proc.poll() is None:
            proc.kill()
        _job.clear()
        return None
    return {"action": _job["action"], "url": _job.get("url")}


def status(port: int, fresh: bool = False) -> dict:
    global _cache
    with _lock:
        pending = _job_state()
        if not fresh and pending is None and _cache and time.time() - _cache[0] < CACHE_SECONDS:
            return _cache[1]
        st = _status(port)
        st["pending"] = pending
        _cache = (time.time(), st)
        return st


def _status(port: int) -> dict:
    if not binary():
        return {"state": "not_installed", "download": DOWNLOAD_URL}
    info = _json("status", "--json")
    backend = info.get("BackendState")
    if not info:
        return {"state": "stopped"}  # tailscaled ishlamayapti
    if backend != "Running":
        return {"state": "need_login" if backend in ("NeedsLogin", "NoState") else "stopped",
                "login_url": info.get("AuthURL") or None}
    host = str((info.get("Self") or {}).get("DNSName") or "").rstrip(".")
    url = f"https://{host}" if host else None
    serve = _json("funnel", "status", "--json")
    funnel = any(v for k, v in (serve.get("AllowFunnel") or {}).items() if k.startswith(host))
    target = json.dumps(serve.get("Web") or {})
    on = funnel and f":{port}" in target
    return {"state": "on" if on else "off", "url": url}


def public_url(port: int) -> str | None:
    st = status(port)
    return st.get("url") if st.get("state") == "on" else None


def _start(action: str, *args: str) -> dict:
    """Buyruqni fonda boshlaydi; tasdiq havolasi chiqsa qaytaradi, tugasa natija."""
    exe = binary()
    if not exe:
        return {"ok": False, "error": "Tailscale o'rnatilmagan"}
    if _job_state() is not None:
        return {"ok": True, "pending": _job_state()}
    try:
        proc = subprocess.Popen([exe, *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                stdin=subprocess.DEVNULL, creationflags=_flags())
    except OSError as e:
        return {"ok": False, "error": str(e)}
    _job.update(proc=proc, action=action, url=None, out="", started=time.time())

    def reader() -> None:
        for line in proc.stdout:  # type: ignore[union-attr]
            _job["out"] = (_job.get("out", "") + line)[-4000:]
            m = _URL.search(line)
            if m and _job.get("proc") is proc:
                _job["url"] = m.group(0)

    threading.Thread(target=reader, name="tailscale-cli", daemon=True).start()
    deadline = time.time() + 20
    while time.time() < deadline:
        if proc.poll() is not None:
            time.sleep(0.2)
            out = _job.get("out", "").strip()
            _job.clear()
            if proc.returncode == 0:
                return {"ok": True}
            return {"ok": False, "error": out[-500:] or f"tailscale xato ({proc.returncode})"}
        if _job.get("url"):
            return {"ok": True, "pending": {"action": action, "url": _job["url"]}}
        time.sleep(0.2)
    return {"ok": True, "pending": {"action": action, "url": _job.get("url")}}


def enable(port: int) -> dict:
    global _cache
    with _lock:
        _cache = None
        st = _status(port)
        if st["state"] == "need_login":
            return _start("login", "login")
        if st["state"] in ("not_installed", "stopped"):
            return {"ok": False, "error": "Tailscale ishlamayapti — uni oching va kiring"}
        res = _start("funnel", "funnel", "--bg", "--yes", str(port))
        if not res["ok"] and "-yes" in (res.get("error") or ""):  # eski Tailscale
            res = _start("funnel", "funnel", "--bg", str(port))
        return res


def disable(port: int) -> dict:
    global _cache
    with _lock:
        _cache = None
        if _job.get("proc") is not None:
            _job["proc"].kill()
            _job.clear()
        r = _run("funnel", "--https=443", "off")
        if r is None or r.returncode != 0:
            r = _run("funnel", "reset")
        ok = r is not None and r.returncode == 0
        return {"ok": ok, "error": None if ok else ((r.stdout + r.stderr).strip()[-500:] if r else "Tailscale yo'q")}
