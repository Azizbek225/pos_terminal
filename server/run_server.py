"""Windows uchun bitta faylli server (PosServer.exe) ishga tushirgichi.

Docker va PostgreSQL kerak emas: baza (pos.db) va API kalit (api_kalit.txt)
exe yonidagi papkada saqlanadi. Ishga tushganda kompyuter IP manzili va
kalit ekranga chiqadi — ularni telefondagi Sozlamalar > Sinxronlash ga yozing.

    python run_server.py          # yoki PyInstaller bilan yig'ilgan PosServer.exe
"""

from __future__ import annotations

import os
import secrets
import socket
import subprocess
import sys
from pathlib import Path

PORT = int(os.environ.get("POS_PORT", "8000"))


def base_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def load_api_key(folder: Path) -> str:
    if os.environ.get("POS_API_KEY"):
        return os.environ["POS_API_KEY"]
    key_file = folder / "api_kalit.txt"
    if key_file.exists() and key_file.read_text(encoding="utf-8").strip():
        return key_file.read_text(encoding="utf-8").strip()
    key = secrets.token_hex(6)
    key_file.write_text(key, encoding="utf-8")
    return key


def local_ip() -> str:
    # Hech narsa yubormaydi: faqat tarmoqqa chiqadigan interfeys manzilini aniqlaydi.
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def open_firewall() -> None:
    if os.name != "nt":
        return
    rule = "POS Terminal Sync"
    try:
        exists = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={rule}"],
            capture_output=True,
        ).returncode == 0
        if not exists:
            subprocess.run(
                ["netsh", "advfirewall", "firewall", "add", "rule", f"name={rule}",
                 "dir=in", "action=allow", "protocol=TCP", f"localport={PORT}"],
                capture_output=True,
            )
    except OSError:
        pass


def main() -> None:
    folder = base_dir()
    os.chdir(folder)
    os.environ.setdefault("POS_DATABASE_URL", f"sqlite:///{(folder / 'pos.db').as_posix()}")
    os.environ["POS_API_KEY"] = load_api_key(folder)
    open_firewall()

    print("=" * 56)
    print("  POS Terminal - sinxronlash serveri ishlayapti")
    print("=" * 56)
    print(f"  Server manzili : http://{local_ip()}:{PORT}")
    print(f"  API kalit      : {os.environ['POS_API_KEY']}")
    print()
    print("  Shu ikkalasini har bir qurilmada yozing:")
    print("  Sozlamalar > Sinxronlash")
    print("  Bu oynani yopmang (yopsangiz sinxronlash to'xtaydi).")
    print("=" * 56, flush=True)

    import uvicorn

    from app.main import app

    uvicorn.run(app, host="0.0.0.0", port=PORT, loop="asyncio", http="h11", ws="none", log_level="warning")


if __name__ == "__main__":
    main()
